// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import AppAuth
import GTMAppAuth
import S400Core
@testable import S400Menu

/// Any accidental SDK refresh is intercepted and fails locally. No test invokes
/// begin(), opens a browser, starts a listener, or submits an HTTP request.
private final class RejectSDKNetwork: URLProtocol {
    private static let lock = NSLock()
    private static var attempts = 0
    static var count: Int { lock.lock(); defer { lock.unlock() }; return attempts }
    static func reset() { lock.lock(); attempts = 0; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.attempts += 1; Self.lock.unlock()
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}

@MainActor private final class SDKNetworkSandbox {
    let previous = OIDURLSessionProvider.session()
    let session: URLSession
    init() {
        RejectSDKNetwork.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RejectSDKNetwork.self]
        session = URLSession(configuration: configuration)
        OIDURLSessionProvider.setSession(session)
    }
    func cleanup() {
        OIDURLSessionProvider.setSession(previous)
        session.invalidateAndCancel()
    }
}

@MainActor private final class PersistenceCredentials: CredentialStoring {
    var values: [String: Data] = [:]
    var activity = CredentialActivity.idle
    var onActivityChange: ((CredentialActivity) -> Void)?
    var holdRead = false
    var holdSaves = false
    var holdDelete = false
    var failSaves = false
    var failDelete = false
    var readCalls = 0
    var saveSnapshots: [Data] = []
    var deleteCalls = 0
    var active = 0
    var peakActive = 0
    private var readContinuation: CheckedContinuation<Void, Never>?
    private var saveContinuations: [CheckedContinuation<Void, Never>] = []
    private var deleteContinuation: CheckedContinuation<Void, Never>?
    var readPending: Bool { readContinuation != nil }
    var savePendingCount: Int { saveContinuations.count }
    var deletePending: Bool { deleteContinuation != nil }
    private func enter() {
        active += 1; peakActive = max(peakActive, active)
        activity = .running("处理凭据"); onActivityChange?(activity)
    }
    private func leave() {
        active -= 1
        if active == 0 { activity = .idle; onActivityChange?(activity) }
    }
    func releaseRead() { let value = readContinuation; readContinuation = nil; value?.resume() }
    func releaseSave() { if !saveContinuations.isEmpty { saveContinuations.removeFirst().resume() } }
    func releaseDelete() { let value = deleteContinuation; deleteContinuation = nil; value?.resume() }
    func cleanup() {
        holdRead = false; holdSaves = false; holdDelete = false
        releaseRead(); while !saveContinuations.isEmpty { releaseSave() }; releaseDelete()
    }
    func read(_ name: String) async throws -> Data? {
        readCalls += 1; enter(); defer { leave() }
        let snapshot = values[name]
        if holdRead { await withCheckedContinuation { readContinuation = $0 } }
        return snapshot
    }
    func save(_ data: Data, name: String) async throws {
        saveSnapshots.append(data); enter(); defer { leave() }
        if holdSaves { await withCheckedContinuation { saveContinuations.append($0) } }
        if failSaves { throw ScaleError.storage }
        values[name] = data
    }
    func delete(_ name: String) async throws {
        deleteCalls += 1; enter(); defer { leave() }
        if holdDelete { await withCheckedContinuation { deleteContinuation = $0 } }
        if failDelete { throw ScaleError.storage }
        values.removeValue(forKey: name)
    }
    func contains(_ name: String) async throws -> Bool { values[name] != nil }
}

@Suite(.serialized) @MainActor struct GooglePersistenceTests {
    private func reaches(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<300 {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }
    private func settle() async { for _ in 0..<15 { await Task.yield() } }
    private func token(_ number: Int, request: OIDTokenRequest) -> OIDTokenResponse {
        let fields: [String: NSObject & NSCopying] = [
            "access_token": "fictional-access-token-\(number)" as NSString,
            "refresh_token": "fictional-refresh-token" as NSString,
            "token_type": "Bearer" as NSString,
            "expires_in": NSNumber(value: 3600),
            "scope": HealthPayload.scope as NSString
        ]
        return OIDTokenResponse(request: request, parameters: fields)
    }
    private func fixture() throws -> AuthSession {
        let configuration = OIDServiceConfiguration(
            authorizationEndpoint: URL(string: "https://oauth.invalid.example/authorize")!,
            tokenEndpoint: URL(string: "https://oauth.invalid.example/token")!)
        let request = OIDAuthorizationRequest(configuration: configuration,
            clientId: "123-fictional-sdk.apps.googleusercontent.com", clientSecret: "fictional-sdk-secret",
            scopes: [HealthPayload.scope], redirectURL: URL(string: "http://127.0.0.1:12345/callback")!,
            responseType: OIDResponseTypeCode, additionalParameters: nil)
        let response = OIDAuthorizationResponse(request: request, parameters: [
            "code": "fictional-authorization-code" as NSString,
            "state": request.state! as NSString
        ])
        let tokenRequest = try #require(response.tokenExchangeRequest())
        return AuthSession(authState: OIDAuthState(authorizationResponse: response, tokenResponse: token(0, request: tokenRequest)))
    }
    private func archive(_ session: AuthSession) throws -> Data {
        try NSKeyedArchiver.archivedData(withRootObject: session, requiringSecureCoding: true)
    }
    private func decoded(_ data: Data) throws -> AuthSession {
        let session = try NSKeyedUnarchiver.unarchivedObject(ofClass: AuthSession.self, from: data)
        return try #require(session)
    }
    private func restored(_ credentials: PersistenceCredentials) async throws -> GoogleAuthorization {
        credentials.values["google-auth"] = try archive(fixture())
        let authorization = GoogleAuthorization(credentials: credentials)
        try await authorization.restoreAfterConsent()
        return authorization
    }

    @Test func actualSDKArchiveRestoresSessionAndClientWithoutNetworkOrWrites() async throws {
        let network = SDKNetworkSandbox(); defer { network.cleanup() }
        let credentials = PersistenceCredentials(); defer { credentials.cleanup() }
        let authorization = try await restored(credentials)
        #expect(authorization.authorized)
        #expect(authorization.session?.authState.lastTokenResponse?.accessToken == "fictional-access-token-0")
        #expect(authorization.existingClientConfiguration()?.clientID == "123-fictional-sdk.apps.googleusercontent.com")
        #expect(credentials.readCalls == 1 && credentials.saveSnapshots.isEmpty && credentials.deleteCalls == 0)
        // SDK delegates from another session must never overwrite this session.
        authorization.didChange(try fixture().authState)
        await settle()
        #expect(credentials.saveSnapshots.isEmpty && RejectSDKNetwork.count == 0)
    }

    @Test func cancelledTaskOrAuthorizationGenerationRejectsLateArchiveRead() async throws {
        let network = SDKNetworkSandbox(); defer { network.cleanup() }
        for cancelTask in [true, false] {
            let credentials = PersistenceCredentials(); defer { credentials.cleanup() }
            credentials.values["google-auth"] = try archive(fixture()); credentials.holdRead = true
            let authorization = GoogleAuthorization(credentials: credentials)
            let restoration = Task { try await authorization.restoreAfterConsent() }
            #expect(await reaches { credentials.readPending })
            if cancelTask { restoration.cancel() } else { authorization.cancel() }
            credentials.releaseRead()
            let result = await restoration.result
            switch result {
            case .success: Issue.record("取消后的旧归档不应恢复")
            case .failure(let error): #expect(error is CancellationError)
            }
            #expect(authorization.session == nil && !authorization.authorized)
            #expect(credentials.saveSnapshots.isEmpty && credentials.deleteCalls == 0)
        }
        #expect(RejectSDKNetwork.count == 0)
    }

    @Test func malformedArchiveDoesNotBecomeAuthorizedOrChangeStoredBytes() async throws {
        let network = SDKNetworkSandbox(); defer { network.cleanup() }
        let credentials = PersistenceCredentials(); defer { credentials.cleanup() }
        let invalid = Data("fictional-invalid-archive".utf8)
        credentials.values["google-auth"] = invalid
        let authorization = GoogleAuthorization(credentials: credentials)
        do { try await authorization.restoreAfterConsent(); Issue.record("坏归档应报告恢复失败") }
        catch { #expect(!authorization.authorized && authorization.session == nil) }
        #expect(credentials.values["google-auth"] == invalid && credentials.saveSnapshots.isEmpty)
        #expect(RejectSDKNetwork.count == 0)
    }

    @Test func stateChangesCoalesceToOneActiveAndOneLatestSaveAndAuthorizeWaits() async throws {
        let network = SDKNetworkSandbox(); defer { network.cleanup() }
        let credentials = PersistenceCredentials(); defer { credentials.cleanup() }
        let authorization = try await restored(credentials)
        let session = try #require(authorization.session)
        let request = try #require(session.authState.lastTokenResponse?.request)
        credentials.holdSaves = true
        session.authState.update(with: token(1, request: request), error: nil)
        #expect(await reaches { credentials.savePendingCount == 1 })
        for number in 2...30 { session.authState.update(with: token(number, request: request), error: nil) }
        await settle()
        #expect(credentials.saveSnapshots.count == 1 && credentials.savePendingCount == 1 && credentials.peakActive == 1)
        var returned = false
        let delivery = Task { @MainActor in
            let result = try await authorization.authorize(URLRequest(url: URL(string: "https://health.invalid.example/fixture")!))
            returned = true; return result
        }
        await settle(); #expect(!returned)
        credentials.releaseSave()
        #expect(await reaches { credentials.saveSnapshots.count == 2 && credentials.savePendingCount == 1 })
        #expect(!returned && credentials.peakActive == 1)
        let latest = try decoded(credentials.saveSnapshots[1])
        #expect(latest.authState.lastTokenResponse?.accessToken == "fictional-access-token-30")
        credentials.releaseSave()
        let authorized = try await delivery.value
        #expect(returned && authorized.value(forHTTPHeaderField: "Authorization") == "Bearer fictional-access-token-30")
        let saved = try decoded(#require(credentials.values["google-auth"]))
        #expect(saved.authState.lastTokenResponse?.accessToken == "fictional-access-token-30")
        #expect(credentials.saveSnapshots.count == 2 && authorization.authorized && RejectSDKNetwork.count == 0)
    }

    @Test func saveFailureClosesAuthorizationAndPendingDeliveryFailsLocally() async throws {
        let network = SDKNetworkSandbox(); defer { network.cleanup() }
        let credentials = PersistenceCredentials(); defer { credentials.cleanup() }
        let authorization = try await restored(credentials)
        let session = try #require(authorization.session)
        let request = try #require(session.authState.lastTokenResponse?.request)
        let prior = credentials.values["google-auth"]
        credentials.holdSaves = true
        session.authState.update(with: token(2, request: request), error: nil)
        #expect(await reaches { credentials.savePendingCount == 1 })
        var finished = false
        let delivery = Task { @MainActor in
            defer { finished = true }
            return try await authorization.authorize(URLRequest(url: URL(string: "https://health.invalid.example/fixture")!))
        }
        await settle(); #expect(!finished)
        credentials.failSaves = true; credentials.releaseSave()
        let result = await delivery.result
        switch result {
        case .success: Issue.record("保存失败时不得返回可发送的健康请求")
        case .failure: break
        }
        #expect(!authorization.authorized && credentials.values["google-auth"] == prior)
        #expect(RejectSDKNetwork.count == 0)
    }

    @Test func disconnectReportsCompletionOnlyAfterDeleteAndDoesNotHideFailure() async throws {
        let network = SDKNetworkSandbox(); defer { network.cleanup() }
        for fails in [false, true] {
            let credentials = PersistenceCredentials(); defer { credentials.cleanup() }
            let authorization = try await restored(credentials)
            let prior = credentials.values["google-auth"]
            credentials.holdDelete = true; credentials.failDelete = fails
            var finished = false
            let removal = Task { @MainActor in
                defer { finished = true }
                try await authorization.disconnect()
            }
            #expect(await reaches { credentials.deletePending })
            #expect(!finished && authorization.session != nil && !authorization.authorized)
            #expect(credentials.values["google-auth"] == prior)
            credentials.releaseDelete()
            let result = await removal.result
            switch result {
            case .success:
                #expect(!fails && authorization.session == nil && credentials.values["google-auth"] == nil)
            case .failure:
                #expect(fails && authorization.session != nil && credentials.values["google-auth"] == prior)
            }
            #expect(finished && !authorization.authorized)
        }
        #expect(RejectSDKNetwork.count == 0)
    }
}
