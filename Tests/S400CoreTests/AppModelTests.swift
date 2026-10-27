// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import S400Core
@testable import S400Menu

@MainActor private final class CredentialSpy: CredentialStoring {
    var values: [String: Data] = [:]
    var reads: [String] = []
    var saves: [String] = []
    var deletions: [String] = []
    var activity = CredentialActivity.idle
    var onActivityChange: ((CredentialActivity) -> Void)?
    var saveFails = false
    var readFails = false
    func read(_ name: String) async throws -> Data? {
        reads.append(name)
        if readFails { throw ScaleError.storage }
        return values[name]
    }
    func save(_ data: Data, name: String) async throws {
        saves.append(name)
        if saveFails { throw ScaleError.storage }
        values[name] = data
    }
    func delete(_ name: String) async throws { deletions.append(name); values.removeValue(forKey: name) }
    func contains(_ name: String) async throws -> Bool { values[name] != nil }
    func clearCalls() { reads = []; saves = []; deletions = [] }
}

@MainActor private final class ReceiverSpy: ScaleReceiving {
    var onStatus: ((String) -> Void)?
    var onReading: ((FinalReading) -> Void)?
    var starts = 0
    var stops = 0
    var ticks = 0
    func start(_ credential: ScaleCredential) { starts += 1; onStatus?("正在接收 S400") }
    func stop() { stops += 1; onStatus?("接收已暂停") }
    func tick() { ticks += 1 }
}

@MainActor private final class ControlledGoogle: GoogleConnecting {
    var authorized = false
    var onChange: (() -> Void)?
    var client: OAuthClientConfiguration?
    var beginCalls = 0
    var cancelCalls = 0
    var disconnectCalls = 0
    var restoreCalls = 0
    var authorizeCalls = 0
    var beginFails = false
    var completions: [(Bool) -> Void] = []
    func restoreAfterConsent() async throws { restoreCalls += 1 }
    func existingClientConfiguration() -> OAuthClientConfiguration? { client }
    func begin(clientID: String, clientSecret: String, completion: @escaping (Bool) -> Void) async throws {
        beginCalls += 1
        if beginFails { throw ScaleError.operation }
        client = try OAuthClientConfiguration(clientID: clientID, clientSecret: clientSecret)
        completions.append(completion)
    }
    func complete(_ index: Int = 0, success: Bool, notify: Bool = true) {
        authorized = success
        if notify { onChange?() }
        completions[index](success)
    }
    func cancel() { cancelCalls += 1 }
    func disconnect() async throws { disconnectCalls += 1; authorized = false; client = nil; onChange?() }
    func authorize(_ request: URLRequest) async throws -> URLRequest {
        authorizeCalls += 1
        throw ScaleError.simulated
    }
}

@MainActor private final class ModelHarness {
    let suiteName = "local.S400Menu.tests.\(UUID().uuidString)"
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("S400-model-tests-\(UUID().uuidString)")
    let defaults: UserDefaults
    let credentials = CredentialSpy()
    let google = ControlledGoogle()
    let receiver = ReceiverSpy()
    var url: URL { directory.appendingPathComponent("fixture.json") }
    init() throws {
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
    func model() async -> AppModel {
        let model = AppModel(preview: true, defaults: defaults, storeURL: url,
                 credentials: credentials, authorization: google, receiver: receiver, runTimer: false)
        await model.waitForCredentialRecovery()
        return model
    }
    func storeDevice() throws {
        // Deliberately synthetic; this is never handed to CoreBluetooth or Keychain.
        credentials.values["scale"] = try JSONEncoder().encode(ScaleCredential(mac: "AA:BB:CC:DD:EE:FF", key: Data(repeating: 17, count: 16)))
    }
    func config(_ name: String = "demo-one") throws -> OAuthClientConfiguration {
        try OAuthClientConfiguration(clientID: "123-\(name).apps.googleusercontent.com", clientSecret: "fictional-\(name)-secret")
    }
    func storeClient() throws {
        credentials.values["google-client"] = try JSONEncoder().encode(config())
    }
    func storedProfile() throws -> Profile {
        let p = Profile(birthYear: Calendar.current.component(.year, from: Date()) - 40, height: 172, male: false)
        defaults.set(try JSONEncoder().encode(p), forKey: "profile")
        return p
    }
    func row(_ weight: Double = 70, offset: TimeInterval = 0, profile: Profile? = nil) -> S400Core.Measurement {
        S400Core.Measurement(reading: FinalReading(weight: weight, low: 600, high: 500,
            date: Date(timeIntervalSince1970: 1_800_000_000 + offset)), profile: profile, simulated: false)
    }
}

@MainActor struct AppModelTests {
    @Test func isolatedDefaultsNeverCarryPreferencesBetweenPreviewInstances() {
        let first = EphemeralDefaults(), second = EphemeralDefaults()
        first.set(true, forKey: "receiverAllowed")
        first.set(3, forKey: "setupStep")
        first.set(Data([1, 2, 3]), forKey: "profile")
        #expect(first.bool(forKey: "receiverAllowed") && first.integer(forKey: "setupStep") == 3)
        #expect(first.data(forKey: "profile") == Data([1, 2, 3]))
        #expect(!second.bool(forKey: "receiverAllowed") && second.integer(forKey: "setupStep") == 0)
        #expect(second.data(forKey: "profile") == nil)
        first.removeObject(forKey: "receiverAllowed")
        #expect(!first.bool(forKey: "receiverAllowed"))
    }

    @Test func firstRunCanAdvanceReturnDeferAndResumeWithoutLosingProgress() async throws {
        let h = try ModelHarness(); defer { h.cleanup() }
        let model = await h.model()
        #expect(model.setupStep == 1 && model.needsSetup)
        model.advanceSetup()
        #expect(model.setupStep == 1)
        #expect(await model.saveDevice(mac: "not-a-mac", bindKey: "") == false)
        #expect(h.receiver.starts == 0 && h.credentials.saves.isEmpty)
        #expect(await model.saveDevice(mac: "AA:BB:CC:DD:EE:FF", bindKey: String(repeating: "11", count: 16)))
        model.advanceSetup(); #expect(model.setupStep == 2)
        model.previousSetupStep(); #expect(model.setupStep == 1)
        model.advanceSetup(); #expect(model.setupStep == 2)
        #expect(model.saveProfile(ProfileDraft()))
        model.advanceSetup(); #expect(model.setupStep == 3)
        model.deferSetup()
        #expect(model.setupStep == nil && !model.receiving && model.needsSetup)
        let reopened = await h.model()
        #expect(reopened.setupStep == nil && !reopened.receiving && reopened.needsSetup)
        reopened.continueSetup(); #expect(reopened.setupStep == 3)
        reopened.previousSetupStep(); #expect(reopened.setupStep == 2)
        reopened.advanceSetup(); await reopened.completeSetup()
        #expect(!reopened.needsSetup && reopened.setupStep == nil && reopened.receiving)
        #expect(h.defaults.bool(forKey: "receiverAllowed"))
        let completedRestart = await h.model()
        #expect(completedRestart.setupStep == nil && !completedRestart.needsSetup && completedRestart.receiving)
        #expect(h.google.beginCalls == 0 && h.google.authorizeCalls == 0)
    }

    @Test func returningExistingUserAndPausedLegacyUserSkipSetupAndKeepProfile() async throws {
        for receiving in [true, false] {
            let h = try ModelHarness(); defer { h.cleanup() }
            try h.storeDevice()
            let oldProfile = try h.storedProfile()
            h.defaults.set(receiving, forKey: "receiverAllowed")
            h.defaults.set(true, forKey: "uploadAllowed")
            h.google.authorized = true; h.google.client = try h.config()
            let model = await h.model()
            #expect(model.hasDevice && !model.needsSetup && model.setupStep == nil)
            #expect(model.profile == oldProfile && model.profileDraft.includesBodyFat)
            #expect(model.receiving == receiving && h.receiver.starts == (receiving ? 1 : 0))
            #expect(model.hasClient && model.connected && model.syncing)
            #expect(h.google.restoreCalls == 1 && h.google.beginCalls == 0)
            #expect(h.credentials.saves.isEmpty && h.google.authorizeCalls == 0)
            await model.completeSetup()
            #expect(model.receiving == receiving && h.receiver.starts == (receiving ? 1 : 0))
            #expect(h.defaults.bool(forKey: "receiverAllowed") == receiving)
        }
    }

    @Test func profileCanChangeIndependentlyWithoutDeviceKeyOrRecalculatingHistory() async throws {
        let h = try ModelHarness(); defer { h.cleanup() }
        try h.storeDevice(); h.defaults.set(false, forKey: "receiverAllowed")
        let store = try MeasurementStore(url: h.url)
        var old = h.row()
        old.fat = 31.7; old.bodyFatAlgorithm = nil
        old.deliveries["body-fat"] = Delivery()
        old.deliveries["weight"]?.state = "synced"
        #expect(try store.insert(old))
        let original = try Data(contentsOf: h.url)
        let model = await h.model(); h.credentials.clearCalls()
        let draft = ProfileDraft(includesBodyFat: true,
            birthYear: String(Calendar.current.component(.year, from: Date()) - 35), height: "180", male: true)
        #expect(model.saveProfile(draft))
        #expect(model.profile?.height == 180 && model.profileDraft == draft)
        #expect(h.credentials.reads.isEmpty && h.credentials.saves.isEmpty && h.credentials.deletions.isEmpty)
        #expect(try Data(contentsOf: h.url) == original)
        #expect(model.rows == [old] && model.pendingMeasurements == 1 && model.pendingMetrics == 1)
        let reopened = await h.model()
        #expect(reopened.profile == model.profile && reopened.rows == [old])
        #expect(reopened.saveProfile(ProfileDraft()))
        #expect(reopened.profile == nil && h.defaults.data(forKey: "profile") == nil)
        #expect(reopened.rows == [old])
    }

    @Test func weightOnlySetupDoesNotRequirePersonalInformation() async throws {
        let h = try ModelHarness(); defer { h.cleanup() }
        let model = await h.model()
        #expect(await model.saveDevice(mac: "AA:BB:CC:DD:EE:FF", bindKey: String(repeating: "11", count: 16)))
        #expect(model.saveProfile(ProfileDraft(includesBodyFat: false, birthYear: "", height: "", male: false)))
        model.accept(FinalReading(weight: 70, low: 600, high: 500, date: Date(timeIntervalSince1970: 1_800_000_000)))
        #expect(model.rows.count == 1 && model.rows[0].fat == nil && model.rows[0].bodyFatAlgorithm == nil)
        #expect(model.pendingMeasurements == 1 && model.pendingMetrics == 1)
    }

    @Test func invalidProfileNeverReplacesSavedProfile() async throws {
        let h = try ModelHarness(); defer { h.cleanup() }
        let saved = try h.storedProfile()
        let model = await h.model()
        let year = Calendar.current.component(.year, from: Date())
        for draft in [
            ProfileDraft(includesBodyFat: true, birthYear: "", height: "172"),
            ProfileDraft(includesBodyFat: true, birthYear: "0000", height: "172"),
            ProfileDraft(includesBodyFat: true, birthYear: String(year - 17), height: "172"),
            ProfileDraft(includesBodyFat: true, birthYear: String(year - 121), height: "172"),
            ProfileDraft(includesBodyFat: true, birthYear: String(year - 40), height: "nan"),
            ProfileDraft(includesBodyFat: true, birthYear: String(year - 40), height: "inf"),
            ProfileDraft(includesBodyFat: true, birthYear: String(year - 40), height: "99"),
            ProfileDraft(includesBodyFat: true, birthYear: String(year - 40), height: "231")
        ] {
            #expect(!model.saveProfile(draft))
            #expect(model.profile == saved)
        }
        #expect(throws: FormError.self) {
            try ProfileDraft(includesBodyFat: true, birthYear: String(year - 40), height: "172")
                .validated(at: Date(timeIntervalSinceReferenceDate: .nan))
        }
    }

    @Test func filterConfigurationDefaultsPersistsAndRejectsInvalidEdits() async throws {
        let h = try ModelHarness(); defer { h.cleanup() }
        let model = await h.model()
        #expect(model.filterSettings == .default)
        // A view owns this unsaved draft; dismissing it never calls saveFilter.
        var draft = model.filterSettings; draft = try WeightFilterSettings(enabled: false, thresholdPercent: 25)
        #expect(!draft.enabled && model.filterSettings == .default)
        for invalid in ["", "0", "-1", "51", "nan", "1.5", "100", "2e1", "十"] {
            #expect(!model.saveFilter(enabled: true, threshold: invalid))
            #expect(model.filterSettings == .default)
        }
        #expect(model.saveFilter(enabled: true, threshold: " 20 "))
        let reopenedEnabled = await h.model()
        #expect(model.filterSettings.thresholdPercent == 20 && reopenedEnabled.filterSettings == model.filterSettings)
        #expect(model.saveFilter(enabled: false, threshold: "20"))
        let reopenedDisabled = await h.model()
        #expect(!reopenedDisabled.filterSettings.enabled && reopenedDisabled.filterSettings.thresholdPercent == 20)
        #expect(model.saveFilter(enabled: true, threshold: "10"))
        let reopenedDefault = await h.model()
        #expect(model.filterSettings == .default && reopenedDefault.filterSettings == .default)
    }

    @Test func disablingFilterIgnoresInvalidDraftAndPreservesLastValidThresholdForReenable() async throws {
        let h = try ModelHarness(); defer { h.cleanup() }
        let model = await h.model()
        #expect(model.saveFilter(enabled: true, threshold: "25"))
        for invalid in ["", "0", "-1", "51", "nan", "1.5", "100", "2e1", "十"] {
            #expect(model.saveFilter(enabled: false, threshold: invalid))
            #expect(!model.filterSettings.enabled && model.filterSettings.thresholdPercent == 25)
            let reopened = await h.model()
            #expect(!reopened.filterSettings.enabled && reopened.filterSettings.thresholdPercent == 25)
            #expect(!reopened.saveFilter(enabled: true, threshold: invalid))
            #expect(!reopened.filterSettings.enabled && reopened.filterSettings.thresholdPercent == 25)
            #expect(reopened.saveFilter(enabled: true, threshold: String(reopened.filterSettings.thresholdPercent)))
            #expect(reopened.filterSettings.enabled && reopened.filterSettings.thresholdPercent == 25)
        }
        // A valid but unsaved percentage is not adopted while the input is disabled.
        #expect(model.saveFilter(enabled: false, threshold: "40"))
        #expect(model.filterSettings.thresholdPercent == 25)
    }

    @Test func filteredRecordIsDurableNeverQueuedAndDoesNotDriftBaselineOrRetroUpload() async throws {
        let h = try ModelHarness(); defer { h.cleanup() }
        let model = await h.model()
        #expect(await model.saveDevice(mac: "AA:BB:CC:DD:EE:FF", bindKey: String(repeating: "11", count: 16)))
        let p = ProfileDraft(includesBodyFat: true, birthYear: String(Calendar.current.component(.year, from: Date()) - 40), height: "172")
        #expect(model.saveProfile(p))
        let origin = Date(timeIntervalSince1970: 1_800_000_000)
        for (index, weight) in [70.0, 100.0, 102.0, 71.0].enumerated() {
            model.accept(FinalReading(weight: weight, low: 600, high: 500, date: origin.addingTimeInterval(Double(index) * 120)))
        }
        #expect(model.rows.count == 4 && model.rows[1].isFiltered && model.rows[2].isFiltered)
        #expect(model.rows[1].deliveries.isEmpty && model.rows[2].deliveries.isEmpty)
        #expect(model.store?.lastAcceptedWeight == 71 && model.latestRow?.weight == 71)
        #expect(model.pendingMeasurements == 2 && model.pendingMetrics == 4)
        let excluded = Array(model.rows[1...2])
        #expect(model.saveFilter(enabled: false, threshold: "10"))
        #expect(model.rows[1] == excluded[0] && model.rows[2] == excluded[1])
        let reopened = await h.model()
        #expect(reopened.rows[1] == excluded[0] && reopened.rows[2] == excluded[1])
        model.accept(FinalReading(weight: 100, low: 600, high: 500, date: origin.addingTimeInterval(600)))
        #expect(model.rows.last?.isFiltered == false && model.store?.lastAcceptedWeight == 100)
        #expect(model.pendingMeasurements == 3 && model.pendingMetrics == 6)
        #expect(h.google.beginCalls == 0 && h.google.authorizeCalls == 0)
    }

    @Test func saveClientDoesNotConnectOrUploadAndSurvivesRestart() async throws {
        let h = try ModelHarness(); defer { h.cleanup() }
        let model = await h.model(), config = try h.config()
        #expect(await model.saveClient(config, method: .json))
        #expect(model.hasClient && !model.connected && !model.syncing && model.clientMethod == .json)
        #expect(h.google.beginCalls == 0 && h.google.authorizeCalls == 0)
        let reopened = await h.model()
        #expect(reopened.hasClient && reopened.clientMethod == .json && !reopened.connected && !reopened.syncing)
        #expect(h.credentials.values["google-client"] != nil)
        await model.beginOAuth(confirmed: false)
        model.enableSync(confirmed: false)
        #expect(h.google.beginCalls == 0 && !model.authorizing && !model.syncing)
    }

    @Test func sameClientPreservesConnectionAndReplacementPausesWithoutRewritingRecords() async throws {
        let h = try ModelHarness(); defer { h.cleanup() }
        try h.storeClient(); h.google.client = try h.config(); h.google.authorized = true
        h.defaults.set(true, forKey: "uploadAllowed")
        let model = await h.model()
        #expect(model.connected && model.syncing)
        let disconnects = h.google.disconnectCalls, cancels = h.google.cancelCalls
        #expect(await model.saveClient(try h.config(), method: .manual))
        #expect(model.connected && model.syncing && h.google.disconnectCalls == disconnects && h.google.cancelCalls == cancels)
        #expect(await model.saveClient(try h.config("demo-two"), method: .json))
        #expect(!model.connected && !model.syncing && !h.defaults.bool(forKey: "uploadAllowed"))
        #expect(h.google.disconnectCalls == disconnects + 1 && h.google.beginCalls == 0)
        #expect(model.store?.rows.isEmpty == true)
        let reopened = await h.model()
        #expect(reopened.hasClient && !reopened.connected && !reopened.syncing)
    }

    @Test func clientReauthorizationMarkerOrSessionMismatchNeverRestoresAutomaticSync() async throws {
        for explicitMarker in [true, false] {
            let h = try ModelHarness(); defer { h.cleanup() }
            try h.storeDevice(); try h.storeClient()
            h.defaults.set(true, forKey: "uploadAllowed")
            h.defaults.set(explicitMarker, forKey: "clientNeedsAuthorization")
            h.google.authorized = true
            h.google.client = try h.config(explicitMarker ? "demo-one" : "different-session-client")
            let model = await h.model()
            #expect(model.hasClient && !model.connected && !model.syncing)
            #expect(model.sync?.consent == false && h.google.beginCalls == 0 && h.google.authorizeCalls == 0)
            model.enableSync(confirmed: true)
            #expect(!model.syncing && model.sync?.consent == false)
            h.google.onChange?()
            #expect(!model.connected && !model.syncing)
            let reopened = await h.model()
            #expect(reopened.hasClient && !reopened.connected && !reopened.syncing)
            #expect(h.google.beginCalls == 0 && h.google.authorizeCalls == 0)
        }
    }

    @Test func failedClientSavePreservesOldConfigurationAndActiveConnection() async throws {
        let h = try ModelHarness(); defer { h.cleanup() }
        try h.storeClient(); h.google.client = try h.config(); h.google.authorized = true
        h.defaults.set(true, forKey: "uploadAllowed")
        let model = await h.model(), old = h.credentials.values["google-client"]
        h.credentials.saveFails = true
        #expect(await model.saveClient(try h.config("replacement"), method: .json) == false)
        #expect(h.credentials.values["google-client"] == old && model.clientMethod == .manual)
        #expect(model.connected && model.syncing && h.google.disconnectCalls == 0)
        #expect(h.google.beginCalls == 0 && h.google.authorizeCalls == 0)
    }

    @Test func oauthConfirmationDedupAndSyncAreIndependent() async throws {
        let h = try ModelHarness(); defer { h.cleanup() }
        let model = await h.model()
        #expect(await model.saveClient(try h.config(), method: .manual))
        await model.beginOAuth(confirmed: false); #expect(h.google.beginCalls == 0)
        await model.beginOAuth(confirmed: true); await model.beginOAuth(confirmed: true)
        #expect(h.google.beginCalls == 1 && model.authorizing && !model.syncing)
        h.google.complete(success: true)
        #expect(model.connected && !model.authorizing && !model.syncing)
        model.enableSync(confirmed: false); #expect(!model.syncing)
        model.enableSync(confirmed: true); #expect(model.syncing && h.defaults.bool(forKey: "uploadAllowed"))
        #expect(h.google.authorizeCalls == 0) // preview mode never schedules actual delivery.
        model.pauseSync(); #expect(!model.syncing && model.connected)
        #expect(await model.disconnectGoogle())
        #expect(!model.connected && !model.syncing)
    }

    @Test func cancelOAuthIgnoresLateCompletionAndAuthorizationNotification() async throws {
        let h = try ModelHarness(); defer { h.cleanup() }
        try h.storeClient() // Previously saved config, not a newly changed config.
        let model = await h.model()
        await model.beginOAuth(confirmed: true); #expect(model.authorizing)
        model.cancelOAuth(); #expect(!model.authorizing && !model.connected)
        h.google.complete(success: true)
        #expect(!model.authorizing && !model.connected && !model.syncing)
        #expect(h.google.beginCalls == 1 && h.google.authorizeCalls == 0)
    }

    @Test func sameClientReauthorizationMarkerSurvivesCancelledLateSuccessAndRestart() async throws {
        let h = try ModelHarness(); defer { h.cleanup() }
        try h.storeClient(); h.google.client = try h.config(); h.google.authorized = true
        h.defaults.set(true, forKey: "uploadAllowed")
        let model = await h.model()
        #expect(model.connected && model.syncing && !h.defaults.bool(forKey: "clientNeedsAuthorization"))
        await model.beginOAuth(confirmed: true)
        #expect(h.defaults.bool(forKey: "clientNeedsAuthorization") && model.authorizing)
        #expect(!model.connected && !model.syncing)
        model.cancelOAuth()
        // A backend may finish storing this same-client state after cancellation.
        // Reopening with that authorized state must still honor the saved marker.
        h.google.complete(0, success: true)
        #expect(h.defaults.bool(forKey: "clientNeedsAuthorization"))
        #expect(!model.connected && !model.syncing && !model.authorizing)
        let reopened = await h.model()
        #expect(!reopened.connected && !reopened.syncing && reopened.hasClient)
        await reopened.beginOAuth(confirmed: true)
        #expect(h.google.beginCalls == 2 && h.defaults.bool(forKey: "clientNeedsAuthorization"))
        h.google.complete(1, success: true)
        #expect(reopened.connected && !reopened.syncing && !h.defaults.bool(forKey: "clientNeedsAuthorization"))
        reopened.enableSync(confirmed: true)
        #expect(reopened.syncing && h.google.authorizeCalls == 0)
    }

    @Test func authorizationFailureOrStartErrorDoesNotEnableSync() async throws {
        let h = try ModelHarness(); defer { h.cleanup() }
        let model = await h.model()
        #expect(await model.saveClient(try h.config(), method: .manual))
        await model.beginOAuth(confirmed: true); h.google.complete(success: false)
        #expect(!model.authorizing && !model.connected && !model.syncing)
        h.google.beginFails = true; await model.beginOAuth(confirmed: true)
        #expect(!model.authorizing && !model.connected && !model.syncing)
        #expect(model.hasClient && h.google.authorizeCalls == 0)
    }

    @Test func corruptStoreFailsClosedAndDoesNotModifyDataOrStartServices() async throws {
        let h = try ModelHarness(); defer { h.cleanup() }
        try h.storeDevice(); try h.storeClient()
        h.defaults.set(true, forKey: "receiverAllowed"); h.defaults.set(true, forKey: "uploadAllowed")
        h.google.client = try h.config(); h.google.authorized = true
        let original = Data("{invalid-synthetic-json".utf8)
        try original.write(to: h.url)
        let model = await h.model()
        #expect(!model.storageAvailable && !model.receiving && !model.syncing && model.sync == nil)
        #expect(h.receiver.starts == 0)
        #expect(try Data(contentsOf: h.url) == original)
        #expect(await model.saveDevice(mac: "AA:BB:CC:DD:EE:FF", bindKey: String(repeating: "11", count: 16)) == false)
        await model.startSavedReceiver(); await model.beginOAuth(confirmed: true); model.enableSync(confirmed: true)
        #expect(h.receiver.starts == 0 && h.google.beginCalls == 0 && h.google.authorizeCalls == 0)
        #expect(!model.receiving && !model.syncing)
    }

    @Test func unreadableStorePathFailsClosedWithoutStartingServices() async throws {
        let h = try ModelHarness(); defer { h.cleanup() }
        try h.storeDevice(); try h.storeClient()
        h.defaults.set(true, forKey: "receiverAllowed"); h.defaults.set(true, forKey: "uploadAllowed")
        h.google.client = try h.config(); h.google.authorized = true
        // A directory cannot be decoded as the measurement file. This avoids
        // chmod-based tests whose behavior depends on runner privilege.
        try FileManager.default.createDirectory(at: h.url, withIntermediateDirectories: true)
        let model = await h.model()
        #expect(!model.storageAvailable && !model.receiving && !model.syncing)
        #expect(h.receiver.starts == 0 && h.google.beginCalls == 0 && h.google.authorizeCalls == 0)
        #expect(h.defaults.bool(forKey: "receiverAllowed") && h.defaults.bool(forKey: "uploadAllowed"))
    }

    @Test func receivePauseResumeUsesSavedCredentialWithoutReplacingConfiguration() async throws {
        let h = try ModelHarness(); defer { h.cleanup() }
        try h.storeDevice(); let saved = h.credentials.values["scale"]
        h.defaults.set(true, forKey: "receiverAllowed")
        let model = await h.model()
        #expect(model.receiving && h.receiver.starts == 1)
        model.stopReceiver()
        #expect(!model.receiving && !h.defaults.bool(forKey: "receiverAllowed"))
        await model.startSavedReceiver()
        #expect(model.receiving && h.receiver.starts == 2 && h.defaults.bool(forKey: "receiverAllowed"))
        #expect(h.credentials.values["scale"] == saved && h.credentials.saves.isEmpty && h.credentials.deletions.isEmpty)
        #expect(h.google.beginCalls == 0 && h.google.authorizeCalls == 0)
    }
}
