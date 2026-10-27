// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Validation is shared by settings persistence and ingestion, never silently clamped.
public struct WeightFilterSettings: Codable, Equatable, Sendable {
    public let enabled: Bool
    public let thresholdPercent: Int
    public static let allowedThreshold = 1...50
    public static let `default` = try! WeightFilterSettings()

    public init(enabled: Bool = true, thresholdPercent: Int = 10) throws {
        guard Self.allowedThreshold.contains(thresholdPercent) else { throw ScaleError.invalidInput }
        self.enabled = enabled; self.thresholdPercent = thresholdPercent
    }
    private enum CodingKeys: String, CodingKey { case enabled, thresholdPercent }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(enabled: container.decode(Bool.self, forKey: .enabled),
                      thresholdPercent: container.decode(Int.self, forKey: .thresholdPercent))
    }
}

public struct MeasurementExclusion: Codable, Equatable, Sendable {
    public enum Reason: String, Codable, Sendable { case weightDeviation }
    public let reason: Reason
    public let thresholdPercent: Int
    public let baselineWeight: Double
    public init(thresholdPercent: Int, baselineWeight: Double) {
        reason = .weightDeviation
        self.thresholdPercent = thresholdPercent; self.baselineWeight = baselineWeight
    }
}
