// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import S400Core

@MainActor protocol CredentialStoring: AnyObject {
    var activity: CredentialActivity { get }
    var onActivityChange: ((CredentialActivity) -> Void)? { get set }
    func read(_ name: String) async throws -> Data?
    func save(_ data: Data, name: String) async throws
    func delete(_ name: String) async throws
    func contains(_ name: String) async throws -> Bool
}
@MainActor protocol ScaleReceiving: AnyObject {
    var onStatus: ((String) -> Void)? { get set }
    var onReading: ((FinalReading) -> Void)? { get set }
    func start(_ credential: ScaleCredential)
    func stop()
    func tick()
}
extension BluetoothReceiver: ScaleReceiving {}

@MainActor protocol GoogleConnecting: HealthAuthorizing {
    var onChange: (() -> Void)? { get set }
    func restoreAfterConsent() async throws
    func existingClientConfiguration() -> OAuthClientConfiguration?
    func begin(clientID: String, clientSecret: String, completion: @escaping (Bool) -> Void) async throws
    func cancel()
    func disconnect() async throws
}
extension GoogleAuthorization: GoogleConnecting {}

// Debug previews and injected tests use only these in-memory services. They have
// no Keychain, BLE, browser, file importer, or URLSession delivery side effects.
final class EphemeralDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    private let lock = NSLock()
    init() { super.init(suiteName: "local.S400Menu.volatile.\(UUID().uuidString)")! }
    override func object(forKey name: String) -> Any? { lock.lock(); defer { lock.unlock() }; return values[name] }
    override func set(_ value: Any?, forKey name: String) { lock.lock(); defer { lock.unlock() }; values[name] = value }
    override func set(_ value: Bool, forKey name: String) { set(value as Any, forKey: name) }
    override func set(_ value: Int, forKey name: String) { set(value as Any, forKey: name) }
    override func set(_ value: Double, forKey name: String) { set(value as Any, forKey: name) }
    override func set(_ value: Float, forKey name: String) { set(value as Any, forKey: name) }
    override func removeObject(forKey name: String) { set(nil as Any?, forKey: name) }
    override func bool(forKey name: String) -> Bool { object(forKey: name) as? Bool ?? false }
    override func integer(forKey name: String) -> Int { object(forKey: name) as? Int ?? 0 }
    override func string(forKey name: String) -> String? { object(forKey: name) as? String }
    override func data(forKey name: String) -> Data? { object(forKey: name) as? Data }
}
@MainActor final class MemoryCredentials: CredentialStoring {
    var values: [String: Data] = [:]
    var activity = CredentialActivity.idle
    var onActivityChange: ((CredentialActivity) -> Void)?
    func read(_ name: String) async throws -> Data? { values[name] }
    func save(_ data: Data, name: String) async throws { values[name] = data }
    func delete(_ name: String) async throws { values.removeValue(forKey: name) }
    func contains(_ name: String) async throws -> Bool { values[name] != nil }
}
@MainActor final class PreviewReceiver: ScaleReceiving {
    var onStatus: ((String) -> Void)?
    var onReading: ((FinalReading) -> Void)?
    func start(_ credential: ScaleCredential) { onStatus?("正在接收 S400") }
    func stop() { onStatus?("接收已暂停") }
    func tick() {}
}
@MainActor final class PreviewGoogle: GoogleConnecting {
    var authorized = false
    var onChange: (() -> Void)?
    private var client: OAuthClientConfiguration?
    func restoreAfterConsent() async throws {}
    func existingClientConfiguration() -> OAuthClientConfiguration? { client }
    func begin(clientID: String, clientSecret: String, completion: @escaping (Bool) -> Void) async throws {
        client = try OAuthClientConfiguration(clientID: clientID, clientSecret: clientSecret)
        authorized = true; onChange?(); completion(true)
    }
    func cancel() {}
    func disconnect() async throws { authorized = false; client = nil; onChange?() }
    func authorize(_ request: URLRequest) async throws -> URLRequest { throw ScaleError.simulated }
}
