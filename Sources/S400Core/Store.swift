// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit

public struct Delivery: Codable, Equatable {
    public var state = "pending"
    public var attempts = 0
    public var retryAt = Date.distantPast
    public var operation: String?
    public init() {}
    public mutating func failed(now: Date, retryAfter: TimeInterval? = nil) {
        attempts += 1
        retryAt = now.addingTimeInterval(max(retryAfter ?? 0, min(21600, 30 * pow(2, Double(min(attempts - 1, 10))))))
    }
}
public struct Measurement: Codable, Identifiable, Equatable {
    public var id: String
    public var date: Date
    public var utcOffset: Int
    public var weight: Double
    public var fat: Double?
    public var low: Double?
    public var high: Double?
    // Missing on older rows; decoding never recalculates their saved fat or queue.
    public var bodyFatAlgorithm: String?
    // Absent on legacy rows. This records a final exclusion, never a pending delivery.
    public var exclusion: MeasurementExclusion?
    public var isFiltered: Bool { exclusion != nil }
    public var simulated: Bool
    public var deliveries: [String: Delivery]
    public init(reading: FinalReading, profile: Profile?, simulated: Bool) {
        if !simulated, let fingerprint = reading.fingerprint {
            id = "s400-" + String(fingerprint.prefix(58))
        } else { id = "s400-" + UUID().uuidString.lowercased() }
        date = reading.date; utcOffset = TimeZone.current.secondsFromGMT(for: date)
        weight = reading.weight; low = reading.low; high = reading.high; self.simulated = simulated
        fat = profile?.bodyFat(weight: weight, low: low, high: high, at: date)
        bodyFatAlgorithm = fat == nil ? nil : Profile.bodyFatAlgorithmIdentifier
        deliveries = ["weight": Delivery()]
        if fat != nil { deliveries["body-fat"] = Delivery() }
    }
}

// Main-thread owned in the app. Atomic replacement means a failed save never advances in-memory state.
// No raw BLE packets, MACs or credentials are written into this measurement file.
public final class MeasurementStore {
    public enum InsertResult: Equatable { case added, duplicate, filtered }
    public private(set) var rows: [Measurement]
    public let url: URL
    public init(url: URL) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            rows = try JSONDecoder().decode([Measurement].self, from: Data(contentsOf: url))
        } else { rows = [] }
    }
    private func commit(_ updated: [Measurement]) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(updated)
        // Protection is applied at creation, before the atomic rename.
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        rows = updated
    }
    private static func validWeight(_ value: Double) -> Bool {
        value.isFinite && value > 0 && value <= 250
    }
    // Older rows without exclusion metadata retain their accepted status. Loading
    // does not reinterpret or rewrite previously saved values or delivery states.
    public var lastAcceptedWeight: Double? {
        rows.last(where: { !$0.simulated && !$0.isFiltered && Self.validWeight($0.weight) })?.weight
    }
    @discardableResult public func insert(_ row: Measurement, filter: WeightFilterSettings = .default) throws -> Bool {
        try insertWithResult(row, filter: filter) == .added
    }
    @discardableResult public func insertWithResult(_ row: Measurement, filter: WeightFilterSettings = .default) throws -> InsertResult {
        guard Self.validWeight(row.weight) else { throw ScaleError.invalidInput }
        if rows.contains(where: { $0.id == row.id }) { return .duplicate }
        if rows.contains(where: {
            $0.simulated == row.simulated && abs($0.date.timeIntervalSince(row.date)) < 90 &&
            abs($0.weight - row.weight) < 0.05 && $0.low == row.low
        }) { return .duplicate }
        var stored = row
        if row.isFiltered {
            stored.deliveries = [:]
            try commit(rows + [stored]); return .filtered
        }
        if !row.simulated, filter.enabled, let previous = lastAcceptedWeight {
            // Decimal comparison accepts exact percentage boundaries, including values whose
            // decimal boundary is not exactly representable as a binary Double.
            let locale = Locale(identifier: "en_US_POSIX")
            guard let current = Decimal(string: String(row.weight), locale: locale),
                  let baseline = Decimal(string: String(previous), locale: locale) else { throw ScaleError.invalidInput }
            let delta = current >= baseline ? current - baseline : baseline - current
            if delta * 100 > baseline * Decimal(filter.thresholdPercent) {
                stored.exclusion = MeasurementExclusion(thresholdPercent: filter.thresholdPercent, baselineWeight: previous)
                stored.deliveries = [:]
                try commit(rows + [stored]); return .filtered
            }
        }
        try commit(rows + [row]); return .added
    }
    public func update(_ row: Measurement) throws {
        guard let index = rows.firstIndex(where: { $0.id == row.id }) else { throw ScaleError.storage }
        // No settings change or delivery retry may reactivate an excluded record.
        if rows[index].isFiltered {
            guard row == rows[index] else { throw ScaleError.invalidInput }
            return
        }
        var updated = rows; updated[index] = row; try commit(updated)
    }
    private var eligibleRows: [Measurement] { rows.filter { !$0.simulated && !$0.isFiltered } }
    /// Legacy metric count, including items held for review. New UI distinguishes those states.
    public var pendingCount: Int { eligibleRows.reduce(0) { $0 + $1.deliveries.values.filter { $0.state != "synced" }.count } }
    public var pendingMetricCount: Int {
        eligibleRows.reduce(0) { $0 + $1.deliveries.values.filter { ["pending", "operation"].contains($0.state) }.count }
    }
    public var pendingMeasurementCount: Int {
        eligibleRows.filter { $0.deliveries.values.contains { ["pending", "operation"].contains($0.state) } }.count
    }
    public var blockedMeasurementCount: Int {
        eligibleRows.filter { $0.deliveries.values.contains { $0.state == "blocked" } }.count
    }
}

public enum HealthPayload {
    public static let scope = "https://www.googleapis.com/auth/googlehealth.health_metrics_and_measurements.writeonly"
    public static func request(row: Measurement, metric: String, consent: Bool) throws -> URLRequest {
        guard consent else { throw ScaleError.consent }
        guard !row.simulated else { throw ScaleError.simulated }
        guard !row.isFiltered else { throw ScaleError.invalidInput }
        guard row.weight.isFinite, row.weight > 0, row.weight <= 250 else { throw ScaleError.invalidInput }
        let sample: [String: Any] = ["physicalTime": ISO8601DateFormatter().string(from: row.date), "utcOffset": "\(row.utcOffset)s"]
        var value: [String: Any] = ["sampleTime": sample]
        let field: String
        if metric == "weight" { field = "weight"; value["weightGrams"] = row.weight * 1000 }
        else if metric == "body-fat", let fat = row.fat, fat.isFinite, (0...100).contains(fat) { field = "bodyFat"; value["percentage"] = fat }
        else { throw ScaleError.invalidInput }
        let parent = "users/me/dataTypes/\(metric)"
        var request = URLRequest(url: URL(string: "https://health.googleapis.com/v4/\(parent)/dataPoints")!)
        request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["name": "\(parent)/dataPoints/\(row.id)", field: value], options: [.sortedKeys])
        return request
    }
}
