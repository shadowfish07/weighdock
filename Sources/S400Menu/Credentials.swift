// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Security
import LocalAuthentication
import AppKit
import AppAuth
import GTMAppAuth
import S400Core

enum Vault {
    static let service = "local.S400Menu.credentials"
    static func read(_ name: String) throws -> Data? {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let context = LAContext(); context.interactionNotAllowed = true
        var value: CFTypeRef?
        let result = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: service,
             kSecAttrAccount: name, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne,
             kSecUseAuthenticationContext: context] as CFDictionary, &value)
        if result == errSecItemNotFound { return nil }
        guard result == errSecSuccess else { throw CredentialAccessError.system(result) }
        return value as? Data
    }
    static func contains(_ name: String) throws -> Bool {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let context = LAContext(); context.interactionNotAllowed = true
        let result = SecItemCopyMatching([kSecClass: kSecClassGenericPassword,
            kSecAttrService: service, kSecAttrAccount: name,
            kSecUseAuthenticationContext: context] as CFDictionary, nil)
        if result == errSecItemNotFound { return false }
        guard result == errSecSuccess else { throw CredentialAccessError.system(result) }
        return true
    }
    static func save(_ data: Data, name: String) throws {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: name]
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if update == errSecItemNotFound {
            var item = query; item[kSecValueData] = data
            item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw CredentialAccessError.system(added) }
        } else if update != errSecSuccess { throw CredentialAccessError.system(update) }
    }
    static func delete(_ name: String) throws {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let result = SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: name] as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw CredentialAccessError.system(result) }
    }
}

struct ScaleCredential: Codable { let mac: String; let key: Data }

// Google's official GTMAppAuth owns refresh logic. AppAuth owns state, PKCE,
// loopback redirect validation, and presentation in the system browser.
@MainActor final class GoogleAuthorization: NSObject, @preconcurrency OIDAuthStateChangeDelegate {
    private(set) var session: AuthSession?
    private let credentials: any CredentialStoring
    private var redirect: OIDRedirectHTTPHandler?
    var onChange: (() -> Void)?
    private var persistenceFailed = false
    private var generation = UUID()
    private var pendingArchive: (Data, AuthSession, UUID)?
    private var persistenceTask: Task<Void, Never>?
    var authorized: Bool { session?.authState.isAuthorized == true && !persistenceFailed }

    init(credentials: (any CredentialStoring)? = nil) {
        self.credentials = credentials ?? KeychainCredentials()
        super.init()
    }
    func restoreAfterConsent() async throws {
        let current = generation
        let data = try await credentials.read("google-auth")
        try Task.checkCancellation()
        guard current == generation else { throw CancellationError() }
        guard let data else { session = nil; persistenceFailed = false; return }
        let restored = try NSKeyedUnarchiver.unarchivedObject(ofClass: AuthSession.self, from: data)
        guard current == generation else { throw CancellationError() }
        session = restored; persistenceFailed = false
        session?.authState.stateChangeDelegate = self
    }
    func existingClientConfiguration() -> OAuthClientConfiguration? {
        guard let request = session?.authState.lastAuthorizationResponse.request,
              let secret = request.clientSecret else { return nil }
        return try? OAuthClientConfiguration(clientID: request.clientID, clientSecret: secret)
    }
    private func archive(_ session: AuthSession) throws -> Data {
        // SDK objects remain on MainActor; only their immutable Data snapshot is
        // passed to the serial Security worker.
        try NSKeyedArchiver.archivedData(withRootObject: session, requiringSecureCoding: true)
    }
    func didChange(_ state: OIDAuthState) {
        guard let session, state === session.authState else { return }
        do { pendingArchive = (try archive(session), session, generation) }
        catch { persistenceFailed = true; onChange?(); return }
        // One active save plus one replaceable latest snapshot. A stalled system
        // write cannot accumulate tasks or an unbounded queue of refresh states.
        if persistenceTask == nil {
            persistenceTask = Task { [weak self] in
                guard let self else { return }
                while let (data, owner, epoch) = self.pendingArchive {
                    self.pendingArchive = nil
                    guard self.session === owner, self.generation == epoch else { continue }
                    do {
                        try await self.credentials.save(data, name: "google-auth")
                        if self.session === owner, self.generation == epoch { self.persistenceFailed = false }
                    } catch {
                        if self.session === owner, self.generation == epoch { self.persistenceFailed = true }
                        if self.pendingArchive?.2 == epoch { self.pendingArchive = nil }
                    }
                    self.onChange?()
                }
                self.persistenceTask = nil
            }
        }
        onChange?()
    }
    func disconnect() async throws {
        cancel()
        let current = generation
        persistenceFailed = true; onChange?()
        try await credentials.delete("google-auth")
        try Task.checkCancellation()
        guard generation == current else { throw CancellationError() }
        session = nil; persistenceFailed = false; onChange?()
    }
    func cancel() {
        generation = UUID(); pendingArchive = nil
        redirect?.cancelHTTPListener(); redirect = nil
    }
    func begin(clientID: String, clientSecret: String, completion: @escaping (Bool) -> Void) async throws {
        guard clientID.hasSuffix(".apps.googleusercontent.com"), !clientSecret.isEmpty else { throw ScaleError.invalidInput }
        guard !credentials.activity.isBusy else { throw CredentialAccessError.busy }
        cancel()
        let currentGeneration = generation
        let handler = OIDRedirectHTTPHandler(successURL: nil)
        var listenerError: NSError?
        let redirectURL = handler.startHTTPListener(&listenerError)
        if listenerError != nil { throw ScaleError.operation }
        redirect = handler
        let request = OIDAuthorizationRequest(configuration: AuthSession.configurationForGoogle(),
            clientId: clientID, clientSecret: clientSecret, scopes: [HealthPayload.scope],
            redirectURL: redirectURL, responseType: OIDResponseTypeCode,
            additionalParameters: ["access_type": "offline", "prompt": "consent"])
        handler.currentAuthorizationFlow = OIDAuthState.authState(byPresenting: request, externalUserAgent: DesktopBrowser()) { [weak self] state, _ in
            guard let self, self.generation == currentGeneration else { return }
            self.redirect = nil
            guard let state, state.isAuthorized, state.refreshToken != nil,
                  state.lastTokenResponse?.scope?.split(separator: " ").contains(Substring(HealthPayload.scope)) == true else {
                completion(false); return
            }
            let candidate = AuthSession(authState: state)
            Task { @MainActor [weak self] in
                guard let self, self.generation == currentGeneration else { return }
                do {
                    try await self.credentials.save(self.archive(candidate), name: "google-auth")
                    guard self.generation == currentGeneration else { return }
                    self.session = candidate; self.persistenceFailed = false
                    state.stateChangeDelegate = self; completion(true)
                } catch {
                    guard self.generation == currentGeneration else { return }
                    completion(false)
                }
            }
        }
    }
    func authorize(_ request: URLRequest) async throws -> URLRequest {
        guard authorized, let session else { throw ScaleError.consent }
        let currentGeneration = generation
        let mutable = (request as NSURLRequest).mutableCopy() as! NSMutableURLRequest
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.authorizeRequest(mutable) { error in
                if self.session !== session || self.generation != currentGeneration || error != nil {
                    continuation.resume(throwing: ScaleError.consent)
                } else { continuation.resume() }
            }
        }
        // A refresh can update the archive while authorizing. Do not deliver a
        // health request until that existing persistence task has actually ended.
        if let persistenceTask { await persistenceTask.value }
        try Task.checkCancellation()
        guard self.session === session, generation == currentGeneration else { throw ScaleError.consent }
        guard !persistenceFailed else { throw ScaleError.storage }
        return mutable as URLRequest
    }
}

// Desktop OAuth uses a random-port IPv4 loopback redirect. Open the system
// browser explicitly; AppAuth still validates state and exchanges the PKCE code.
final class DesktopBrowser: NSObject, OIDExternalUserAgent {
    func present(_ request: OIDExternalUserAgentRequest, session: OIDExternalUserAgentSession) -> Bool {
        NSWorkspace.shared.open(request.externalUserAgentRequestURL())
    }
    func dismiss(animated: Bool, completion: @escaping () -> Void) { completion() }
}
