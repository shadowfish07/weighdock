// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Client inputs only; authorization endpoints and redirect handling remain fixed by the app.
public struct OAuthClientConfiguration: Codable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let clientID: String
    public let clientSecret: String
    public static let maximumJSONBytes = 64 * 1024
    public static let maximumClientIDBytes = 256
    public static let maximumClientSecretBytes = 512

    public enum ValidationError: Error, Equatable, LocalizedError {
        case invalidJSON, desktopClientRequired, missingClientID, missingClientSecret
        case invalidClientID, invalidClientSecret, oversizedJSON
        public var errorDescription: String? {
            switch self {
            case .invalidJSON: return "无法读取 JSON 文件"
            case .desktopClientRequired: return "请选择 Desktop 客户端 JSON"
            case .missingClientID: return "请输入 Client ID"
            case .missingClientSecret: return "请输入 Client Secret"
            case .invalidClientID: return "请输入有效的 Desktop Client ID"
            case .invalidClientSecret: return "请检查 Client Secret"
            case .oversizedJSON: return "JSON 文件过大"
            }
        }
    }

    public init(clientID: String, clientSecret: String) throws {
        // Validate before trimming so embedded or trailing newlines cannot be hidden.
        guard !clientID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              clientID.utf8.count <= Self.maximumClientIDBytes else { throw ValidationError.invalidClientID }
        guard !clientSecret.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              clientSecret.utf8.count <= Self.maximumClientSecretBytes else { throw ValidationError.invalidClientSecret }
        let id = clientID.trimmingCharacters(in: .whitespaces)
        let secret = clientSecret.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { throw ValidationError.missingClientID }
        guard !secret.isEmpty else { throw ValidationError.missingClientSecret }
        guard id.range(of: "^[A-Za-z0-9_-]+\\.apps\\.googleusercontent\\.com$", options: .regularExpression) != nil else {
            throw ValidationError.invalidClientID
        }
        self.clientID = id
        self.clientSecret = secret
    }

    /// Parses Google's downloaded Desktop JSON without persisting it or trusting its URLs.
    public static func parseDesktopJSON(_ data: Data) throws -> Self {
        guard data.count <= maximumJSONBytes else { throw ValidationError.oversizedJSON }
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data) }
        catch { throw ValidationError.invalidJSON }
        guard let root = object as? [String: Any] else { throw ValidationError.invalidJSON }
        guard root["web"] == nil, let installed = root["installed"] as? [String: Any] else {
            throw ValidationError.desktopClientRequired
        }
        guard let id = installed["client_id"] as? String else { throw ValidationError.missingClientID }
        guard let secret = installed["client_secret"] as? String else { throw ValidationError.missingClientSecret }
        return try Self(clientID: id, clientSecret: secret)
    }

    private enum CodingKeys: String, CodingKey { case clientID, clientSecret }
    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(clientID: fields.decode(String.self, forKey: .clientID),
                      clientSecret: fields.decode(String.self, forKey: .clientSecret))
    }

    public var description: String { "OAuthClientConfiguration(凭据已隐藏)" }
    public var debugDescription: String { description }
}
