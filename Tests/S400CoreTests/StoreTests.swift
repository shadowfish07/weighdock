// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import S400Core

final class StoreTests {
    func fixture(simulated: Bool = false, date: Date = Date()) -> S400Core.Measurement {
        Measurement(reading: FinalReading(weight: 76.5, low: 402, high: 365, date: date),
                    profile: Profile(birthYear: Calendar.current.component(.year, from: date) - 27, height: 172, male: true), simulated: simulated)
    }
    @Test func testPersistenceAndDedupSurviveRestart() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("measurements.json")
        let store = try MeasurementStore(url: url), now = Date()
        let row = fixture(date: now)
        XCTAssertTrue(try store.insert(row))
        let reopened = try MeasurementStore(url: url)
        XCTAssertFalse(try reopened.insert(fixture(date: now.addingTimeInterval(30))))
        XCTAssertTrue(try reopened.insert(fixture(date: now.addingTimeInterval(120))))
        XCTAssertTrue(try reopened.insert(fixture(simulated: true, date: now)))
        XCTAssertEqual(reopened.pendingCount, 4)
        XCTAssertEqual(reopened.rows.count, 3)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber
        XCTAssertEqual(mode.intValue & 0o777, 0o600)
    }
    @Test func testCorruptStoreFailsClosed() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("corrupt".utf8).write(to: url)
        XCTAssertThrowsError(try MeasurementStore(url: url))
    }
    @Test func testAuthenticatedPacketDedupSurvivesLongRestart() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("record.json"), now = Date()
        let a = Measurement(reading: FinalReading(weight: 74.2, low: nil, high: nil, date: now, fingerprint: String(repeating: "a", count: 64)), profile: nil, simulated: false)
        let b = Measurement(reading: FinalReading(weight: 74.2, low: nil, high: nil, date: now.addingTimeInterval(3600), fingerprint: String(repeating: "a", count: 64)), profile: nil, simulated: false)
        let store = try MeasurementStore(url: url); XCTAssertTrue(try store.insert(a))
        let reopened = try MeasurementStore(url: url); XCTAssertFalse(try reopened.insert(b))
        XCTAssertEqual(reopened.rows.count, 1)
    }
    @Test func testFailedSaveDoesNotAdvanceMemory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir)
        let store = try MeasurementStore(url: dir.appendingPathComponent("record.json"))
        XCTAssertThrowsError(try store.insert(fixture()))
        XCTAssertTrue(store.rows.isEmpty)
    }
    @Test func testPayloadUnitsTimeAndStableIdentity() throws {
        var row = fixture(); row.utcOffset = 28800
        let request = try HealthPayload.request(row: row, metric: "weight", consent: true)
        let object = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let weight = object["weight"] as! [String: Any]
        XCTAssertEqual(weight["weightGrams"] as? Double, 76500)
        XCTAssertEqual((weight["sampleTime"] as! [String: String])["utcOffset"], "28800s")
        XCTAssertEqual(request.url?.absoluteString, "https://health.googleapis.com/v4/users/me/dataTypes/weight/dataPoints")
        XCTAssertEqual(request.httpBody, try HealthPayload.request(row: row, metric: "weight", consent: true).httpBody)
        XCTAssertLessThanOrEqual(row.id.count, 63)
        let fat = try HealthPayload.request(row: row, metric: "body-fat", consent: true)
        let fatObject = try JSONSerialization.jsonObject(with: fat.httpBody!) as! [String: Any]
        XCTAssertEqual((fatObject["bodyFat"] as! [String: Any])["percentage"] as? Double, row.fat)
    }
    @Test func testConsentAndSimulationHardGates() {
        XCTAssertThrowsError(try HealthPayload.request(row: fixture(), metric: "weight", consent: false))
        XCTAssertThrowsError(try HealthPayload.request(row: fixture(simulated: true), metric: "weight", consent: true))
        var row = fixture(); row.fat = nil
        XCTAssertThrowsError(try HealthPayload.request(row: row, metric: "body-fat", consent: true))
        row.weight = .nan
        XCTAssertThrowsError(try HealthPayload.request(row: row, metric: "weight", consent: true))
        XCTAssertEqual(HealthPayload.scope, "https://www.googleapis.com/auth/googlehealth.health_metrics_and_measurements.writeonly")
    }
    @Test func testBackoffPersistsAndHonorsRetryAfter() throws {
        var delivery = Delivery(); let now = Date()
        delivery.failed(now: now); XCTAssertEqual(delivery.retryAt.timeIntervalSince(now), 30)
        delivery.failed(now: now, retryAfter: 300); XCTAssertEqual(delivery.retryAt.timeIntervalSince(now), 300)
        let copy = try JSONDecoder().decode(Delivery.self, from: JSONEncoder().encode(delivery))
        XCTAssertEqual(copy, delivery)
        for _ in 0..<30 { delivery.failed(now: now) }
        XCTAssertEqual(delivery.retryAt.timeIntervalSince(now), 21600)
    }
}
