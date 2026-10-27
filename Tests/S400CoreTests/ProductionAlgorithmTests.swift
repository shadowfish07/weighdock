// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import S400Core
import MiHomeCompatibility

struct ProductionAlgorithmTests {
    let date = Date(timeIntervalSince1970: 1_798_545_600) // 2026-12-29; fixed year, not user history.
    func profile(age: Int = 46, height: Double = 176, male: Bool = true) -> Profile {
        Profile(birthYear: 2026 - age, height: height, male: male)
    }

    @Test func newMeasurementUsesCompatibilityFormulaAndVersionTag() throws {
        let row = S400Core.Measurement(reading: FinalReading(weight: 79.9, low: 576.7, high: 514.6, date: date),
                                      profile: profile(), simulated: false)
        #expect(row.fat == 24.6)
        #expect(row.bodyFatAlgorithm == MiHomeCompatibility.algorithmIdentifier)
        #expect(row.deliveries.keys.sorted() == ["body-fat", "weight"])
        let data = try JSONEncoder().encode(row)
        #expect(try JSONDecoder().decode(S400Core.Measurement.self, from: data) == row)
        let request = try HealthPayload.request(row: row, metric: "body-fat", consent: true)
        let payload = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as! [String: Any]
        #expect((payload["bodyFat"] as? [String: Any])?["percentage"] as? Double == 24.6)
        #expect(!String(decoding: request.httpBody!, as: UTF8.self).contains("algorithm"))
    }

    @Test func deurenergSpecificChecksDoNotRejectNewResult() {
        let p = profile(age: 40, height: 180)
        #expect(p.legacyDeurenbergBodyFat(weight: 100, low: 250, high: 220, at: date) == nil)
        #expect(p.bodyFat(weight: 100, low: 250, high: 220, at: date) == 27.9)
    }

    @Test func formulaClampsAreUsedWithoutLegacyWaterFractionGate() {
        #expect(profile(age: 40, height: 230).bodyFat(weight: 80, low: 350, high: 300, at: date) == 3)
        #expect(profile(age: 40, height: 120, male: false).bodyFat(weight: 50, low: 1500, high: 1200, at: date) == 55)
    }

    @Test func validBandSwapAndExistingAgeConventionArePreserved() {
        let p = profile()
        #expect(p.bodyFat(weight: 79.9, low: 514.6, high: 576.7, at: date) == 24.6)
        let followingYear = Date(timeIntervalSince1970: 1_830_254_400) // 2027-12-31; used only to derive the year.
        let expectedAge = Calendar.current.component(.year, from: followingYear) - p.birthYear
        let expected = try? MiHomeCompatibility.calculateDual(sex: .male, heightCM: 176, weightKG: 79.9,
            ageYears: Double(expectedAge), impedanceAOhms: 576.7, impedanceBOhms: 514.6).firmwareBodyFatPercent
        #expect(p.bodyFat(weight: 79.9, low: 576.7, high: 514.6, at: followingYear) == expected)
    }

    @Test func missingImpedanceAndProfileStayWeightOnly() {
        let reading = FinalReading(weight: 79.9, low: 576.7, high: nil, date: date)
        for p in [profile(), nil] {
            let row = S400Core.Measurement(reading: reading, profile: p, simulated: false)
            #expect(row.fat == nil && row.bodyFatAlgorithm == nil)
            #expect(row.deliveries.keys.sorted() == ["weight"])
        }
    }

    @Test func genericInputAndContactValidationRemainActive() {
        let p = profile()
        for bad in [0.0, -1, 1600, Double.nan, Double.infinity] {
            #expect(p.bodyFat(weight: 79.9, low: bad, high: 514.6, at: date) == nil)
            #expect(p.bodyFat(weight: 79.9, low: 576.7, high: bad, at: date) == nil)
        }
        #expect(p.bodyFat(weight: .nan, low: 576.7, high: 514.6, at: date) == nil)
        #expect(p.bodyFat(weight: 19, low: 576.7, high: 514.6, at: date) == nil)
        #expect(p.bodyFat(weight: 79.9, low: 576.7, high: 576, at: date) == nil)
        #expect(profile(age: 17).bodyFat(weight: 79.9, low: 576.7, high: 514.6, at: date) == nil)
        #expect(profile(height: .infinity).bodyFat(weight: 79.9, low: 576.7, high: 514.6, at: date) == nil)
        #expect(p.bodyFat(weight: 79.9, low: 576.7, high: 514.6, at: Date(timeIntervalSinceReferenceDate: .nan)) == nil)
        #expect(Profile(birthYear: .min, height: 176, male: true).bodyFat(weight: 79.9, low: 576.7, high: 514.6, at: date) == nil)
    }

    @Test func legacyDecodeAndMixedQueueDoNotRecalculateOrMigrate() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("fixture.json")
        var legacy = S400Core.Measurement(reading: FinalReading(weight: 79.9, low: 576.7, high: 514.6, date: date),
                                         profile: profile(), simulated: false)
        legacy.fat = 31.7; legacy.bodyFatAlgorithm = nil
        legacy.deliveries["weight"]?.state = "synced"
        legacy.deliveries["body-fat"]?.attempts = 2
        legacy.deliveries["body-fat"]?.retryAt = date.addingTimeInterval(3600)
        let original = try JSONEncoder().encode([legacy])
        try original.write(to: url)
        #expect(!String(decoding: original, as: UTF8.self).contains("bodyFatAlgorithm"))
        let store = try MeasurementStore(url: url)
        #expect(try Data(contentsOf: url) == original) // Opening a store performs no migration write.
        #expect(store.rows == [legacy] && store.pendingCount == 1)
        #expect(store.rows[0].bodyFatAlgorithm == nil)
        let request = try HealthPayload.request(row: store.rows[0], metric: "body-fat", consent: true)
        let payload = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as! [String: Any]
        #expect((payload["bodyFat"] as? [String: Any])?["percentage"] as? Double == 31.7)
        let next = S400Core.Measurement(reading: FinalReading(weight: 80, low: 576.7, high: 514.6, date: date.addingTimeInterval(120)),
                                       profile: profile(), simulated: false)
        #expect(try store.insertWithResult(next) == .added)
        let reopened = try MeasurementStore(url: url)
        #expect(reopened.rows[0] == legacy) // Saved fat, retry time, attempts, ID and successful metric untouched.
        #expect(reopened.rows[1].bodyFatAlgorithm == MiHomeCompatibility.algorithmIdentifier)
        #expect(reopened.pendingCount == 3)
    }
}
