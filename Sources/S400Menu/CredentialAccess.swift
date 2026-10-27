// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum CredentialActivity: Equatable, Sendable {
    case idle
    case running(String)
    case waiting(String)

    var isBusy: Bool { self != .idle }
    var isWaiting: Bool { if case .waiting = self { return true }; return false }
    var message: String {
        switch self {
        case .idle: return ""
        case .running(let operation): return "正在\(operation)…"
        case .waiting: return "钥匙串仍在处理，请稍候"
        }
    }
}

enum CredentialAccessError: LocalizedError, Equatable, Sendable {
    case busy
    case system(Int32)

    var errorDescription: String? {
        switch self {
        case .busy: return "钥匙串仍在处理，请稍后重试"
        case .system: return "无法访问钥匙串，请稍后重试"
        }
    }
}

enum CredentialRequest: Sendable {
    case read(String)
    case save(Data, name: String)
    case delete(String)
    case contains(String)

    // Only these static categories reach UI activity. Account names, keys and
    // serialized data are never interpolated into diagnostics or user messages.
    fileprivate var operation: String {
        switch self {
        case .read: return "读取凭据"
        case .save: return "保存凭据"
        case .delete: return "移除凭据"
        case .contains: return "检查凭据"
        }
    }
}

enum CredentialResult: Sendable {
    case data(Data?)
    case success
    case exists(Bool)
}

private enum CredentialBackend {
    static func execute(_ request: CredentialRequest) throws -> CredentialResult {
        dispatchPrecondition(condition: .notOnQueue(.main))
        switch request {
        case .read(let name): return .data(try Vault.read(name))
        case .save(let data, let name): try Vault.save(data, name: name); return .success
        case .delete(let name): try Vault.delete(name); return .success
        case .contains(let name): return .exists(try Vault.contains(name))
        }
    }
}

/// The gate and activity live on MainActor; blocking SecItem calls never do.
/// A logical timeout is an activity change, not cancellation of a system call.
@MainActor final class KeychainCredentials: CredentialStoring {
    private static let worker = DispatchQueue(label: "local.S400Menu.credentials.worker", qos: .userInitiated)
    private static var occupied: UUID?
    private(set) var activity = CredentialActivity.idle
    var onActivityChange: ((CredentialActivity) -> Void)?
    private let backend: @Sendable (CredentialRequest) throws -> CredentialResult
    private let waitingNanoseconds: UInt64
    private var activeTicket: UUID?

    init(waitingAfter: TimeInterval = 8,
         backend: @escaping @Sendable (CredentialRequest) throws -> CredentialResult = { try CredentialBackend.execute($0) }) {
        let interval = waitingAfter.isFinite ? min(3600, max(0.001, waitingAfter)) : 8
        waitingNanoseconds = UInt64(interval * 1_000_000_000)
        self.backend = backend
    }

    func read(_ name: String) async throws -> Data? {
        guard case .data(let value) = try await perform(.read(name)) else { throw CredentialAccessError.system(-50) }
        return value
    }
    func save(_ data: Data, name: String) async throws {
        guard case .success = try await perform(.save(data, name: name)) else { throw CredentialAccessError.system(-50) }
    }
    func delete(_ name: String) async throws {
        guard case .success = try await perform(.delete(name)) else { throw CredentialAccessError.system(-50) }
    }
    func contains(_ name: String) async throws -> Bool {
        guard case .exists(let value) = try await perform(.contains(name)) else { throw CredentialAccessError.system(-50) }
        return value
    }

    private func setActivity(_ next: CredentialActivity) {
        activity = next
        onActivityChange?(next)
    }

    private func perform(_ request: CredentialRequest) async throws -> CredentialResult {
        try Task.checkCancellation()
        guard Self.occupied == nil else { throw CredentialAccessError.busy }
        let ticket = UUID()
        Self.occupied = ticket; activeTicket = ticket
        setActivity(.running(request.operation))
        let waiting = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: self?.waitingNanoseconds ?? 8_000_000_000) }
            catch { return }
            guard let self, self.activeTicket == ticket else { return }
            self.setActivity(.waiting(request.operation))
        }
        defer {
            waiting.cancel()
            activeTicket = nil
            if Self.occupied == ticket { Self.occupied = nil }
            setActivity(.idle)
        }
        let execute = backend
        let result: Result<CredentialResult, CredentialAccessError> = await withCheckedContinuation { continuation in
            Self.worker.async {
                dispatchPrecondition(condition: .notOnQueue(.main))
                let result: Result<CredentialResult, CredentialAccessError>
                do { result = .success(try execute(request)) }
                catch let error as CredentialAccessError { result = .failure(error) }
                catch { result = .failure(.system(-1)) }
                continuation.resume(returning: result)
            }
        }
        // SecItem has actually returned now. A cancelled caller may discard the
        // result, but cancellation never releases the gate while it is in flight.
        try Task.checkCancellation()
        return try result.get()
    }
}
