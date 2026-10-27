// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import S400Menu

// This backend never calls Vault or Security. The semaphore deliberately blocks
// the worker, not the main actor; a bounded escape also prevents a broken test
// implementation from permanently occupying the process-wide credential gate.
private final class CredentialBackendProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var invocationCount = 0
    private var threads: [Bool] = []
    private var blocked = false
    private var timedOut = false
    private var failure: CredentialAccessError?
    let blocksFirst: Bool
    init(blocksFirst: Bool = true, failure: CredentialAccessError? = nil) {
        self.blocksFirst = blocksFirst; self.failure = failure
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return invocationCount }
    var ranOnMain: [Bool] { lock.lock(); defer { lock.unlock() }; return threads }
    var escapedByTimeout: Bool { lock.lock(); defer { lock.unlock() }; return timedOut }
    func unblock() { release.signal() }
    func execute(_ request: CredentialRequest) throws -> CredentialResult {
        lock.lock()
        invocationCount += 1; threads.append(Thread.isMainThread)
        let shouldWait = blocksFirst && !blocked
        if shouldWait { blocked = true }
        let error = failure; failure = nil
        lock.unlock()
        if shouldWait, release.wait(timeout: .now() + 3) == .timedOut {
            lock.lock(); timedOut = true; lock.unlock()
        }
        if let error { throw error }
        switch request {
        case .read: return .data(Data("fictional-credential".utf8))
        case .save, .delete: return .success
        case .contains: return .exists(true)
        }
    }
}

@Suite(.serialized) @MainActor struct CredentialAccessTests {
    private func waitUntil(_ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(1)
        while !predicate(), Date() < deadline { try? await Task.sleep(nanoseconds: 1_000_000) }
        return predicate()
    }
    private func expectBusy(_ operation: () async throws -> Void) async {
        do { try await operation(); Issue.record("An occupied credential gate must reject new work") }
        catch { #expect(error as? CredentialAccessError == .busy) }
    }

    @Test func blockedWorkerDoesNotBlockMainActorAndCallbacksStayOnMainActor() async throws {
        let probe = CredentialBackendProbe()
        defer { probe.unblock() }
        let access = KeychainCredentials(waitingAfter: 0.01, backend: { try probe.execute($0) })
        var events: [CredentialActivity] = []
        var callbackThreads: [Bool] = []
        access.onActivityChange = { events.append($0); callbackThreads.append(Thread.isMainThread) }
        let operation = Task { try await access.read("synthetic-account-not-for-ui") }
        #expect(await waitUntil { probe.count == 1 })
        let heartbeat = Task { @MainActor in true }
        #expect(await heartbeat.value)
        #expect(await waitUntil { access.activity.isWaiting })
        #expect(access.activity.isBusy && probe.count == 1)
        #expect(!access.activity.message.contains("synthetic-account"))
        probe.unblock()
        let result = try await operation.value
        #expect(result == Data("fictional-credential".utf8))
        #expect(probe.ranOnMain == [false] && !probe.escapedByTimeout)
        #expect(events.first == .running("读取凭据") && events.contains(.waiting("读取凭据")) && events.last == .idle)
        #expect(callbackThreads.allSatisfy { $0 } && access.activity == .idle)
    }

    @Test func logicalTimeoutKeepsSingleFlightAndRejectsEveryOperationWithoutEnqueueing() async throws {
        let probe = CredentialBackendProbe()
        defer { probe.unblock() }
        let access = KeychainCredentials(waitingAfter: 0.01, backend: { try probe.execute($0) })
        let operation = Task { try await access.read("synthetic") }
        #expect(await waitUntil { access.activity.isWaiting })
        await expectBusy { _ = try await access.read("another") }
        await expectBusy { try await access.save(Data([1, 2]), name: "another") }
        await expectBusy { try await access.delete("another") }
        await expectBusy { _ = try await access.contains("another") }
        // Multiple adapters still cannot queue behind the same blocked system call.
        let other = KeychainCredentials(waitingAfter: 0.01, backend: { try probe.execute($0) })
        await expectBusy { _ = try await other.read("another") }
        #expect(probe.count == 1 && access.activity.isWaiting)
        probe.unblock(); _ = try await operation.value
        #expect(access.activity == .idle && probe.count == 1)
        _ = try await access.contains("explicit-retry")
        #expect(probe.count == 2 && probe.ranOnMain == [false, false])
    }

    @Test func cancellationDoesNotReleaseBusyUntilActualReturnAndNeverRetriesAutomatically() async throws {
        let probe = CredentialBackendProbe()
        defer { probe.unblock() }
        let access = KeychainCredentials(waitingAfter: 0.01, backend: { try probe.execute($0) })
        var events: [CredentialActivity] = []
        access.onActivityChange = { events.append($0) }
        let operation = Task { try await access.read("synthetic") }
        #expect(await waitUntil { probe.count == 1 })
        operation.cancel()
        #expect(await waitUntil { access.activity.isWaiting })
        await expectBusy { try await access.delete("synthetic") }
        #expect(access.activity.isBusy && probe.count == 1 && !events.contains(.idle))
        probe.unblock()
        do { _ = try await operation.value; Issue.record("The cancelled caller must discard the returned credential") }
        catch { #expect(error is CancellationError) }
        #expect(access.activity == .idle && events.last == .idle && probe.count == 1)
        await Task.yield()
        #expect(probe.count == 1)
        try await access.delete("explicit-retry")
        #expect(probe.count == 2 && access.activity == .idle)
    }

    @Test func alreadyCancelledTaskDoesNotDispatchBackend() async {
        let probe = CredentialBackendProbe(blocksFirst: false)
        let access = KeychainCredentials(backend: { try probe.execute($0) })
        let operation = Task { try await access.contains("synthetic") }
        operation.cancel() // MainActor has not yielded to the child yet.
        do { _ = try await operation.value; Issue.record("Cancellation must be checked before dispatch") }
        catch { #expect(error is CancellationError) }
        #expect(probe.count == 0 && access.activity == .idle)
    }

    @Test func systemFailureReleasesBusyAndKeepsRedactedError() async throws {
        let probe = CredentialBackendProbe(blocksFirst: false, failure: .system(-25293))
        let access = KeychainCredentials(backend: { try probe.execute($0) })
        do { _ = try await access.read("synthetic-hidden-account"); Issue.record("Expected a synthetic system failure") }
        catch {
            #expect(error as? CredentialAccessError == .system(-25293))
            #expect(!error.localizedDescription.contains("synthetic-hidden-account"))
        }
        #expect(access.activity == .idle && probe.count == 1)
        #expect(try await access.contains("explicit-retry"))
        #expect(probe.count == 2 && access.activity == .idle)
    }

    @Test func allMethodsExecuteOnWorkerAndUnexpectedErrorsDoNotExposeBackendText() async throws {
        let probe = CredentialBackendProbe(blocksFirst: false)
        let access = KeychainCredentials(backend: { try probe.execute($0) })
        _ = try await access.read("synthetic")
        try await access.save(Data([1, 2, 3]), name: "synthetic")
        try await access.delete("synthetic")
        #expect(try await access.contains("synthetic"))
        #expect(probe.count == 4 && probe.ranOnMain == [false, false, false, false])
        let failing = KeychainCredentials(backend: { _ in
            throw NSError(domain: "synthetic-sensitive-domain", code: 42,
                          userInfo: [NSLocalizedDescriptionKey: "synthetic-sensitive-backend-content"])
        })
        do { try await failing.save(Data([4]), name: "synthetic"); Issue.record("Expected sanitized backend failure") }
        catch {
            #expect(error as? CredentialAccessError == .system(-1))
            #expect(!error.localizedDescription.contains("sensitive"))
        }
        #expect(failing.activity == .idle)
    }
}
