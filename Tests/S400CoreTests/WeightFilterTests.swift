// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import S400Core

final class WeightFilterTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var url: URL { dir.appendingPathComponent("fixture.json") }
    deinit { try? FileManager.default.removeItem(at: dir) }
    func row(_ weight: Double, _ index: Int = 0, simulated: Bool = false, fingerprint: String? = nil) -> S400Core.Measurement {
        let date = Date(timeIntervalSince1970: 1_800_000_000 + Double(index * 120))
        return Measurement(reading: FinalReading(weight: weight, low: 402, high: 365, date: date, fingerprint: fingerprint),
            profile: Profile(birthYear: 1999, height: 172, male: true), simulated: simulated)
    }
    @Test func firstRealSampleAccepted() throws {
        let store = try MeasurementStore(url: url)
        #expect(try store.insertWithResult(row(76.5)) == .added)
        #expect(store.lastAcceptedWeight == 76.5)
        #expect(store.pendingCount == 2)
    }
    @Test(arguments: [90.0, 110.0, 89.9, 110.1]) func tenPercentBoundaries(weight: Double) throws {
        let store = try MeasurementStore(url: url)
        try store.insert(row(100))
        let expected: MeasurementStore.InsertResult = (90...110).contains(weight) ? .added : .filtered
        #expect(try store.insertWithResult(row(weight, 1)) == expected)
        #expect(store.lastAcceptedWeight == (expected == .added ? weight : 100))
    }
    @Test(arguments: [66.78, 81.62]) func decimalBoundariesAccepted(weight: Double) throws {
        let store = try MeasurementStore(url: url)
        try store.insert(row(74.2))
        #expect(try store.insertWithResult(row(weight, 1)) == .added)
    }
    @Test func repeatedOutliersDoNotMoveBaselineAndNormalReadingRecovers() throws {
        let store = try MeasurementStore(url: url)
        try store.insert(row(76.5))
        for (index, weight) in [90.0, 98, 110, 60, 50].enumerated() {
            #expect(try store.insertWithResult(row(weight, index + 1)) == .filtered)
            #expect(store.lastAcceptedWeight == 76.5)
        }
        #expect(store.rows.count == 6)
        #expect(store.rows.dropFirst().allSatisfy { $0.isFiltered && $0.deliveries.isEmpty })
        #expect(store.rows.dropFirst().allSatisfy { $0.exclusion?.baselineWeight == 76.5 && $0.exclusion?.thresholdPercent == 10 })
        #expect(store.pendingCount == 2)
        #expect(try store.insertWithResult(row(77, 10)) == .added)
        #expect(store.lastAcceptedWeight == 77)
    }
    @Test func restartRestoresAcceptedBaselineAndPreservesHistory() throws {
        let store = try MeasurementStore(url: url)
        var first = row(76.5)
        first.deliveries["weight"]?.state = "synced"
        first.deliveries["body-fat"]?.failed(now: Date())
        try store.insert(first)
        #expect(try store.insertWithResult(row(95, 1)) == .filtered)
        let reopened = try MeasurementStore(url: url)
        #expect(reopened.lastAcceptedWeight == 76.5)
        #expect(try reopened.insertWithResult(row(96, 2)) == .filtered)
        #expect(reopened.rows.count == 3 && reopened.rows[0] == first)
        #expect(reopened.rows.dropFirst().allSatisfy { $0.isFiltered })
        #expect(try reopened.insertWithResult(row(77, 3)) == .added)
        #expect(reopened.rows[0] == first)
    }
    @Test func legacyMocksAndInvalidRowsNeverBecomeBaseline() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let history = [row(76.5), row(0, 1), row(-12, 2), row(251, 3), row(200, 4, simulated: true)]
        try JSONEncoder().encode(history).write(to: url)
        let store = try MeasurementStore(url: url)
        #expect(store.lastAcceptedWeight == 76.5)
        #expect(try store.insertWithResult(row(77, 5)) == .added)
        #expect(Array(store.rows.prefix(history.count)) == history)
    }
    @Test func onlyMocksDoesNotBlockFirstRealSample() throws {
        let store = try MeasurementStore(url: url)
        try store.insert(row(200, simulated: true))
        #expect(store.lastAcceptedWeight == nil)
        #expect(store.pendingCount == 0)
        #expect(try store.insertWithResult(row(76.5, 1)) == .added)
    }
    @Test(arguments: [0.0, -1, 251, Double.nan, Double.infinity, -Double.infinity])
    func invalidSamplesCannotEnterStore(weight: Double) throws {
        let store = try MeasurementStore(url: url)
        #expect(throws: ScaleError.self) { try store.insertWithResult(row(weight)) }
        #expect(store.rows.isEmpty)
        #expect(store.lastAcceptedWeight == nil)
        #expect(try store.insertWithResult(row(76.5, 1)) == .added)
    }
    @Test func duplicateBroadcastDoesNotChangeBaseline() throws {
        let store = try MeasurementStore(url: url)
        let fingerprint = String(repeating: "f", count: 64)
        try store.insert(row(76.5, fingerprint: fingerprint))
        #expect(try store.insertWithResult(row(76.5)) == .duplicate)
        try store.insert(row(80, 1))
        #expect(try store.insertWithResult(row(76.5, 20, fingerprint: fingerprint)) == .duplicate)
        #expect(store.lastAcceptedWeight == 80)
        #expect(store.rows.count == 2)
    }

    @Test(arguments: [1, 10, 50]) func customThresholdBoundaries(percent: Int) throws {
        let settings = try WeightFilterSettings(thresholdPercent: percent)
        for sign in [-1, 1] {
            let location = dir.appendingPathComponent("\(percent)-\(sign).json")
            let store = try MeasurementStore(url: location)
            try store.insert(row(100))
            let boundary = Double(100 + sign * percent)
            #expect(try store.insertWithResult(row(boundary, 1), filter: settings) == .added)
            // A separate store ensures each assertion compares to the same baseline.
            let rejectedStore = try MeasurementStore(url: dir.appendingPathComponent("beyond-\(percent)-\(sign).json"))
            try rejectedStore.insert(row(100))
            #expect(try rejectedStore.insertWithResult(row(boundary + Double(sign) * 0.1, 1), filter: settings) == .filtered)
            #expect(rejectedStore.lastAcceptedWeight == 100)
            #expect(rejectedStore.rows.last?.exclusion?.thresholdPercent == percent)
        }
    }

    @Test func settingsValidationAndRoundTrip() throws {
        for invalid in [-1, 0, 51, Int.max] {
            #expect(throws: ScaleError.self) { try WeightFilterSettings(thresholdPercent: invalid) }
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(WeightFilterSettings.self,
                    from: Data("{\"enabled\":false,\"thresholdPercent\":\(invalid)}".utf8))
            }
        }
        for invalidJSON in [#"{"enabled":true,"thresholdPercent":10.5}"#, #"{"enabled":true,"thresholdPercent":"10"}"#] {
            #expect(throws: (any Error).self) { try JSONDecoder().decode(WeightFilterSettings.self, from: Data(invalidJSON.utf8)) }
        }
        let settings = try WeightFilterSettings(enabled: false, thresholdPercent: 37)
        #expect(try JSONDecoder().decode(WeightFilterSettings.self, from: JSONEncoder().encode(settings)) == settings)
        #expect(WeightFilterSettings.default.enabled && WeightFilterSettings.default.thresholdPercent == 10)
    }

    @Test func disablingAndChangingFilterNeverReactivatesExclusions() throws {
        let store = try MeasurementStore(url: url)
        try store.insert(row(100))
        #expect(try store.insertWithResult(row(120, 1)) == .filtered)
        let excluded = store.rows[1]
        #expect(excluded.isFiltered && excluded.deliveries.isEmpty)
        let disabled = try WeightFilterSettings(enabled: false)
        #expect(try store.insertWithResult(row(130, 2), filter: disabled) == .added)
        #expect(store.lastAcceptedWeight == 130)
        let wider = try WeightFilterSettings(thresholdPercent: 50)
        #expect(try store.insertWithResult(row(180, 3), filter: wider) == .added)
        #expect(store.rows[1] == excluded)
        #expect(store.pendingMeasurementCount == 3)
        let reopened = try MeasurementStore(url: url)
        #expect(reopened.rows[1] == excluded && reopened.lastAcceptedWeight == 180)
        var reactivated = excluded
        reactivated.exclusion = nil; reactivated.deliveries = ["weight": Delivery()]
        #expect(throws: ScaleError.self) { try reopened.update(reactivated) }
        #expect(reopened.rows[1] == excluded)
    }

    @Test func filteredDuplicateNeverBecomesAcceptedWhenPolicyChanges() throws {
        let store = try MeasurementStore(url: url)
        try store.insert(row(100))
        let candidate = row(130, 1, fingerprint: String(repeating: "a", count: 64))
        #expect(try store.insertWithResult(candidate) == .filtered)
        #expect(try store.insertWithResult(candidate, filter: WeightFilterSettings(enabled: false)) == .duplicate)
        #expect(store.lastAcceptedWeight == 100 && store.rows.count == 2)
    }

    @Test func legacyDecodeDoesNotRewriteAndMissingExclusionMeansAccepted() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var legacy = row(100)
        legacy.fat = 31.7; legacy.bodyFatAlgorithm = nil
        legacy.deliveries["weight"]?.state = "synced"
        legacy.deliveries["body-fat"]?.failed(now: Date(timeIntervalSince1970: 1_800_000_000))
        let bytes = try JSONEncoder().encode([legacy])
        #expect(!String(decoding: bytes, as: UTF8.self).contains("exclusion"))
        try bytes.write(to: url)
        let store = try MeasurementStore(url: url)
        #expect(store.rows == [legacy] && store.lastAcceptedWeight == 100)
        #expect(try Data(contentsOf: url) == bytes)
        #expect(try store.insertWithResult(row(130, 1)) == .filtered)
        #expect(store.rows[0] == legacy)
    }

    @Test func failedFilteredSaveCannotAdvanceMemoryOrBaseline() throws {
        let store = try MeasurementStore(url: url)
        try store.insert(row(100))
        let original = store.rows
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try store.insertWithResult(row(130, 1)) }
        #expect(store.rows == original && store.lastAcceptedWeight == 100)
    }

    @Test func countersSeparateMeasurementsMetricsAndBlockedItems() throws {
        let store = try MeasurementStore(url: url)
        var first = row(100)
        first.deliveries = ["weight": Delivery(), "body-fat": Delivery()]
        try store.insert(first)
        #expect(store.pendingMeasurementCount == 1 && store.pendingMetricCount == 2)
        var partial = first
        partial.deliveries["weight"]?.state = "synced"
        try store.update(partial)
        #expect(store.pendingMeasurementCount == 1 && store.pendingMetricCount == 1)
        partial.deliveries["body-fat"]?.state = "blocked"
        try store.update(partial)
        #expect(store.pendingMeasurementCount == 0 && store.pendingMetricCount == 0 && store.blockedMeasurementCount == 1)
        #expect(try store.insertWithResult(row(130, 1)) == .filtered)
        try store.insert(row(200, 2, simulated: true))
        #expect(store.pendingMeasurementCount == 0 && store.blockedMeasurementCount == 1)
    }
}
