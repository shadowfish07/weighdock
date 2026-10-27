// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import S400Core
@testable import S400Menu

/// Deliberately ignores task cancellation until its underlying operation returns,
/// matching a pending SecItem call without ever touching the real Keychain.
@MainActor private final class DeferredCredentials: CredentialStoring {
    var values: [String: Data] = [:]
    var activity = CredentialActivity.idle
    var onActivityChange: ((CredentialActivity) -> Void)?
    var calls: [String] = []
    var holdNext = false
    var holdKind: String?
    var failureKinds = Set<String>()
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var pendingKind: String?
    var hasPendingOperation: Bool { continuation != nil }

    private func change(_ next: CredentialActivity) { activity = next; onActivityChange?(next) }
    func waiting() { if hasPendingOperation { change(.waiting("读取凭据")) } }
    func release() { let saved = continuation; continuation = nil; saved?.resume() }
    func operation(_ kind: String) async throws {
        calls.append(kind)
        guard !activity.isBusy else { throw CredentialAccessError.busy }
        change(.running("读取凭据"))
        defer { pendingKind = nil; change(.idle) }
        if holdNext || holdKind == kind {
            holdNext = false; holdKind = nil; pendingKind = kind
            await withCheckedContinuation { continuation = $0 }
        }
        if failureKinds.contains(kind) { throw CredentialAccessError.system(-1) }
    }
    func read(_ name: String) async throws -> Data? {
        let snapshot = values[name]
        try await operation("read:\(name)")
        return snapshot
    }
    func save(_ data: Data, name: String) async throws {
        try await operation("save:\(name)")
        values[name] = data
    }
    func delete(_ name: String) async throws { try await operation("delete:\(name)"); values.removeValue(forKey: name) }
    func contains(_ name: String) async throws -> Bool {
        let snapshot = values[name] != nil
        try await operation("contains:\(name)")
        return snapshot
    }
}

@MainActor private final class RecoveryGoogle: GoogleConnecting {
    let credentials: DeferredCredentials
    var authorized = false
    var onChange: (() -> Void)?
    var restoredClient: OAuthClientConfiguration?
    var restoreCalls = 0
    var beginCalls = 0
    var authorizeCalls = 0
    var disconnectCalls = 0
    var cancelCalls = 0
    init(credentials: DeferredCredentials) { self.credentials = credentials }
    func restoreAfterConsent() async throws {
        restoreCalls += 1
        try await credentials.operation("google-restore")
        authorized = restoredClient != nil
        onChange?()
    }
    func existingClientConfiguration() -> OAuthClientConfiguration? { restoredClient }
    func begin(clientID: String, clientSecret: String, completion: @escaping (Bool) -> Void) async throws {
        beginCalls += 1; completion(false)
    }
    func cancel() { cancelCalls += 1 }
    func disconnect() async throws { disconnectCalls += 1; authorized = false; restoredClient = nil; onChange?() }
    func authorize(_ request: URLRequest) async throws -> URLRequest { authorizeCalls += 1; throw ScaleError.simulated }
}

@MainActor private final class RecoveryReceiver: ScaleReceiving {
    var onStatus: ((String) -> Void)?
    var onReading: ((FinalReading) -> Void)?
    var starts = 0
    var stops = 0
    func start(_ credential: ScaleCredential) { starts += 1; onStatus?("正在接收 S400") }
    func stop() { stops += 1; onStatus?("接收已暂停") }
    func tick() {}
}

@MainActor private final class RecoveryHarness {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("S400-recovery-tests-\(UUID().uuidString)")
    let defaults = EphemeralDefaults()
    let credentials = DeferredCredentials()
    let google: RecoveryGoogle
    let receiver = RecoveryReceiver()
    weak var lastModel: AppModel?
    var url: URL { directory.appendingPathComponent("fixture.json") }
    init(legacy: Bool = true) throws {
        google = RecoveryGoogle(credentials: credentials)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if legacy {
            defaults.set(true, forKey: "receiverAllowed")
            defaults.set(true, forKey: "uploadAllowed")
            credentials.values["scale"] = try JSONEncoder().encode(ScaleCredential(mac: "AA:BB:CC:DD:EE:FF", key: Data(repeating: 17, count: 16)))
            let client = try configuration()
            credentials.values["google-client"] = try JSONEncoder().encode(client)
            google.restoredClient = client
        }
    }
    func configuration(_ suffix: String = "old") throws -> OAuthClientConfiguration {
        try OAuthClientConfiguration(clientID: "123-fictional-\(suffix).apps.googleusercontent.com", clientSecret: "fictional-\(suffix)-secret")
    }
    func model() -> AppModel {
        let model = AppModel(preview: true, defaults: defaults, storeURL: url,
            credentials: credentials, authorization: google, receiver: receiver, runTimer: false)
        lastModel = model
        return model
    }
    func cleanup() {
        lastModel?.cancelCredentialRecovery()
        credentials.holdNext = false; credentials.holdKind = nil; credentials.release()
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor struct CredentialRecoveryTests {
    private func reaches(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }
    private func settle() async { for _ in 0..<12 { await Task.yield() } }

    @Test func startupReturnsImmediatelyAndShowsWaitingWithoutClaimingReceiverOrSync() async throws {
        let h = try RecoveryHarness(); defer { h.cleanup() }
        h.credentials.holdNext = true
        let model = h.model()
        #expect(model.isRestoring && !model.receiving && !model.syncing)
        #expect(model.setupStep == nil && !model.needsSetup)
        #expect(await reaches { h.credentials.hasPendingOperation })
        h.credentials.waiting()
        #expect(model.credentialBusy && model.keychainActivity.isWaiting)
        #expect(!model.receiving && !model.syncing && !model.connected)
        // UI state remains writable while the fake system operation is suspended.
        model.selectedTab = .settings
        #expect(model.selectedTab == .settings)
        #expect(model.saveFilter(enabled: false, threshold: ""))
        #expect(!model.filterSettings.enabled)
        let calls = h.credentials.calls.count
        model.retryCredentialRecovery(); model.retryCredentialRecovery()
        await settle()
        #expect(h.credentials.calls.count == calls)
        h.credentials.release()
        await model.waitForCredentialRecovery()
        #expect(!model.isRestoring && !model.recoveryUnresolved)
        #expect(model.receiving && model.connected && model.syncing)
        #expect(!model.filterSettings.enabled)
        #expect(h.receiver.starts == 1 && h.google.beginCalls == 0 && h.google.authorizeCalls == 0)
    }

    @Test func unknownCredentialPresenceDoesNotPrematurelyEnterFirstSetup() async throws {
        let h = try RecoveryHarness(legacy: false); defer { h.cleanup() }
        h.credentials.holdNext = true
        let model = h.model()
        #expect(model.setupStep == nil && !model.needsSetup)
        #expect(await reaches { h.credentials.hasPendingOperation })
        model.cancelCredentialRecovery()
        #expect(model.setupStep == nil && model.recoveryUnresolved)
        h.credentials.release(); await settle()
        #expect(model.setupStep == nil && model.recoveryUnresolved)
        model.retryCredentialRecovery(); await model.waitForCredentialRecovery()
        #expect(!model.recoveryUnresolved && model.needsSetup && model.setupStep == 1)
        #expect(h.receiver.starts == 0 && h.google.beginCalls == 0 && h.google.authorizeCalls == 0)
    }

    @Test func cancelledRecoveryIgnoresLateResultAndCannotRetryWhileBackendIsBusy() async throws {
        let h = try RecoveryHarness(); defer { h.cleanup() }
        h.credentials.holdNext = true
        let model = h.model()
        #expect(await reaches { h.credentials.hasPendingOperation })
        let calls = h.credentials.calls.count
        model.cancelCredentialRecovery()
        #expect(!model.isRestoring && model.recoveryUnresolved && model.credentialBusy)
        model.retryCredentialRecovery(); model.retryCredentialRecovery()
        await settle()
        #expect(h.credentials.calls.count == calls && h.credentials.hasPendingOperation)
        h.credentials.release()
        #expect(model.credentialBusy) // Resuming a continuation is not a completed system return.
        await settle()
        #expect(!model.receiving && !model.syncing && !model.connected && model.recoveryUnresolved)
        #expect(h.receiver.starts == 0 && h.google.beginCalls == 0)
        model.retryCredentialRecovery(); await model.waitForCredentialRecovery()
        #expect(!model.recoveryUnresolved && model.receiving && model.connected && model.syncing)
        #expect(h.credentials.calls.count > calls && h.google.beginCalls == 0 && h.google.authorizeCalls == 0)
    }

    @Test func pauseAndStopDuringRecoveryAreRespectedWhenSavedCredentialsArrive() async throws {
        let h = try RecoveryHarness(); defer { h.cleanup() }
        h.credentials.holdNext = true
        let model = h.model()
        #expect(await reaches { h.credentials.hasPendingOperation })
        model.stopReceiver(); model.pauseSync()
        h.credentials.release(); await model.waitForCredentialRecovery()
        #expect(!model.receiving && !model.syncing && model.connected)
        #expect(h.receiver.starts == 0 && !h.defaults.bool(forKey: "receiverAllowed") && !h.defaults.bool(forKey: "uploadAllowed"))
        #expect(h.google.beginCalls == 0 && h.google.authorizeCalls == 0)
    }

    @Test func cancelledOldReadCannotOverwriteClientSavedAfterBackendReturns() async throws {
        let h = try RecoveryHarness(); defer { h.cleanup() }
        h.credentials.holdKind = "read:google-client"
        let model = h.model()
        #expect(await reaches { h.credentials.hasPendingOperation })
        model.cancelCredentialRecovery()
        let replacement = try h.configuration("replacement")
        #expect(await model.saveClient(replacement, method: .manual) == false)
        h.credentials.release(); await settle()
        #expect(!model.hasClient && !model.connected && !model.syncing)
        #expect(h.google.restoreCalls == 0)
        #expect(await model.saveClient(replacement, method: .manual))
        await settle()
        let saved = try #require(h.credentials.values["google-client"])
        #expect(try JSONDecoder().decode(OAuthClientConfiguration.self, from: saved) == replacement)
        #expect(model.hasClient && !model.connected && !model.syncing)
        #expect(h.google.beginCalls == 0 && h.google.authorizeCalls == 0)
    }

    @Test func failedCredentialReadLeavesRecoveryUnresolvedUntilExplicitRetry() async throws {
        let h = try RecoveryHarness(); defer { h.cleanup() }
        h.credentials.failureKinds.insert("read:google-client")
        let model = h.model()
        await model.waitForCredentialRecovery()
        #expect(!model.isRestoring && model.recoveryUnresolved && model.setupStep == nil)
        #expect(model.receiving && !model.syncing && h.receiver.starts == 1)
        let calls = h.credentials.calls.count
        await settle()
        #expect(h.credentials.calls.count == calls) // no automatic retry loop.
        h.credentials.failureKinds.removeAll()
        model.retryCredentialRecovery(); await model.waitForCredentialRecovery()
        #expect(!model.recoveryUnresolved && model.receiving && model.syncing)
        #expect(h.google.beginCalls == 0 && h.google.authorizeCalls == 0)
    }

    @Test func corruptStoreDoesNotStartServicesOrRewriteSyntheticFixture() async throws {
        let h = try RecoveryHarness(); defer { h.cleanup() }
        let bytes = Data("{synthetic-corrupt-json".utf8)
        try bytes.write(to: h.url)
        let model = h.model()
        await model.waitForCredentialRecovery()
        #expect(!model.storageAvailable && !model.receiving && !model.syncing)
        #expect(h.receiver.starts == 0 && h.google.beginCalls == 0 && h.google.authorizeCalls == 0)
        #expect(try Data(contentsOf: h.url) == bytes)
    }

    @Test func restoredProfileNeverRecalculatesOrRewritesExistingRecords() async throws {
        let h = try RecoveryHarness(); defer { h.cleanup() }
        let profile = Profile(birthYear: Calendar.current.component(.year, from: Date()) - 40, height: 172, male: false)
        h.defaults.set(try JSONEncoder().encode(profile), forKey: "profile")
        var legacy = S400Core.Measurement(reading: FinalReading(weight: 70, low: 600, high: 500,
            date: Date(timeIntervalSince1970: 1_800_000_000)), profile: nil, simulated: false)
        legacy.fat = 31.7; legacy.bodyFatAlgorithm = nil; legacy.deliveries["body-fat"] = Delivery()
        legacy.deliveries["weight"]?.state = "synced"
        let original = try JSONEncoder().encode([legacy])
        try original.write(to: h.url)
        h.credentials.holdNext = true
        let model = h.model()
        #expect(await reaches { h.credentials.hasPendingOperation })
        #expect(model.profile == profile && model.rows == [legacy] && model.pendingMetrics == 1)
        #expect(try Data(contentsOf: h.url) == original)
        h.credentials.release(); await model.waitForCredentialRecovery()
        #expect(model.rows == [legacy] && model.pendingMetrics == 1)
        #expect(try Data(contentsOf: h.url) == original)
        #expect(h.google.beginCalls == 0 && h.google.authorizeCalls == 0)
    }

    @Test func googleRestoreCanSuspendAndLateAuthorizationCannotUndoCancellation() async throws {
        let h = try RecoveryHarness(); defer { h.cleanup() }
        h.credentials.holdKind = "google-restore"
        let model = h.model()
        #expect(await reaches { h.credentials.pendingKind == "google-restore" })
        #expect(model.isRestoring && !model.connected && model.receiving && !model.syncing)
        #expect(h.receiver.starts == 1)
        model.cancelCredentialRecovery()
        h.credentials.release(); await settle()
        // The fake deliberately emits onChange after cancellation; only the model
        // generation guard may accept a recovered authorization in a new attempt.
        #expect(!model.connected && model.receiving && !model.syncing && model.recoveryUnresolved)
        #expect(h.receiver.starts == 1)
        model.retryCredentialRecovery(); await model.waitForCredentialRecovery()
        #expect(model.connected && model.receiving && model.syncing && !model.recoveryUnresolved)
        #expect(h.google.beginCalls == 0 && h.google.authorizeCalls == 0)
    }

    @Test func cancellingOnlyDeviceRecoveryPreservesAlreadyRecoveredGoogleChannel() async throws {
        let h = try RecoveryHarness(); defer { h.cleanup() }
        h.credentials.failureKinds.insert("read:scale")
        let model = h.model()
        await model.waitForCredentialRecovery()
        #expect(model.recoveryUnresolved && !model.receiving && model.connected && model.syncing)
        #expect(h.google.restoreCalls == 1)
        h.credentials.failureKinds.removeAll()
        h.credentials.holdKind = "read:scale"
        model.retryCredentialRecovery()
        #expect(await reaches { h.credentials.pendingKind == "read:scale" })
        let cancels = h.google.cancelCalls
        model.cancelCredentialRecovery()
        #expect(h.google.cancelCalls == cancels && model.connected && model.syncing)
        h.credentials.release(); await settle()
        #expect(!model.receiving && model.connected && model.syncing)
        #expect(h.google.restoreCalls == 1 && h.defaults.bool(forKey: "uploadAllowed"))
        #expect(h.google.beginCalls == 0 && h.google.authorizeCalls == 0)
    }

    @Test func deferringFirstSetupDuringDeviceSaveDoesNotResumeReceiverAndCanContinueAfterRestart() async throws {
        let h = try RecoveryHarness(legacy: false); defer { h.cleanup() }
        let model = h.model()
        await model.waitForCredentialRecovery()
        #expect(model.needsSetup && model.setupStep == 1)
        h.credentials.holdKind = "save:scale"
        let saving = Task { await model.saveDevice(mac: "AA:BB:CC:DD:EE:FF", bindKey: String(repeating: "11", count: 16)) }
        #expect(await reaches { h.credentials.pendingKind == "save:scale" })
        model.deferSetup()
        #expect(model.setupStep == nil && !model.receiving)
        h.credentials.release()
        #expect(await saving.value)
        #expect(model.hasDevice && model.needsSetup && !model.receiving && h.receiver.starts == 0)
        #expect(h.defaults.object(forKey: "setupCompleted") as? Bool == false)
        #expect(h.credentials.values["scale"] != nil)
        let reopened = h.model()
        await reopened.waitForCredentialRecovery()
        #expect(reopened.needsSetup && reopened.setupStep == nil && !reopened.receiving)
        reopened.continueSetup()
        #expect(reopened.setupStep == 1 && reopened.needsSetup)
        #expect(h.google.beginCalls == 0 && h.google.authorizeCalls == 0)
    }

    @Test func knownMissingDeviceItemAllowsReconfigurationWithoutChangingHistoryOrExistingPreferences() async throws {
        let h = try RecoveryHarness(); defer { h.cleanup() }
        h.credentials.values.removeValue(forKey: "scale")
        let profile = Profile(birthYear: Calendar.current.component(.year, from: Date()) - 40, height: 172, male: false)
        let profileBytes = try JSONEncoder().encode(profile)
        h.defaults.set(profileBytes, forKey: "profile")
        let legacy = S400Core.Measurement(reading: FinalReading(weight: 70, low: nil, high: nil,
            date: Date(timeIntervalSince1970: 1_800_000_000)), profile: nil, simulated: false)
        let history = try JSONEncoder().encode([legacy]); try history.write(to: h.url)
        let model = h.model()
        await model.waitForCredentialRecovery()
        #expect(!model.recoveryUnresolved && !model.hasDevice && !model.receiving)
        #expect(model.needsSetup && model.setupStep == 1)
        #expect(model.profile == profile && model.rows == [legacy])
        #expect(h.defaults.data(forKey: "profile") == profileBytes && h.defaults.bool(forKey: "receiverAllowed"))
        #expect(try Data(contentsOf: h.url) == history)
        #expect(h.receiver.starts == 0 && h.google.beginCalls == 0 && h.google.authorizeCalls == 0)
    }
}
