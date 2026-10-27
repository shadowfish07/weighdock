// SPDX-License-Identifier: GPL-3.0-or-later
// Public fixtures adapted from openScale S400DecryptorTest (C) 2025 olie.xdev.
// These are public upstream test vectors, never the user's credentials.
import Foundation
import Testing
@testable import S400Core

final class ProtocolTests {
    let mac = "84:46:93:64:A5:E6"
    let key = Data(hex: "58305740b64e4b425e518aa1f4e51339")!
    let raw = Data(hex: "4859d53b2d3314943c58b133638c7457a4000000c3e670dc")!
    @Test func testPublic24ByteVector() throws {
        XCTAssertEqual(try S400Decoder.decode(raw, mac: mac, key: key).weight, 74.2, accuracy: 0.01)
    }
    @Test func testPublic26ByteVector() throws {
        let data = Data(hex: "95FE4859D53B3BDE6BC8D05B51C0CDFD9021C9000000925C5039")!
        XCTAssertEqual(try S400Decoder.decode(data, mac: mac, key: key).weight, 73.2, accuracy: 0.01)
    }
    @Test func testDualFrequencyPublicVectors() throws {
        let address = "8C:D0:B2:F6:BE:EF", bind = Data(hex: "0728974d657a4b60964c1b1677f35f7c")!
        let a = try S400Decoder.decode(Data(hex: "4859d53b0abc078ff2348c844138e930220000009e538599")!, mac: address, key: bind)
        let b = try S400Decoder.decode(Data(hex: "4859d53b0bd6ef0b25db72785e7e2f46d6000000d8642df6")!, mac: address, key: bind)
        XCTAssertEqual(a.weight, 69.9); XCTAssertEqual(a.low!, 543.2); XCTAssertNil(a.high); XCTAssertEqual(a.heartRate, 92)
        XCTAssertEqual(b.weight, 0); XCTAssertEqual(b.high!, 497.6); XCTAssertNil(b.low)
    }
    @Test func testEveryAuthenticatedByteTamperFails() {
        // Frame-control bytes 0/1 are outside upstream's authentication inputs.
        for i in 2..<raw.count {
            var changed = raw; changed[i] ^= 1
            XCTAssertThrowsError(try S400Decoder.decode(changed, mac: mac, key: key), "byte \(i)")
        }
    }
    @Test func testWrongMACAndKeyFail() {
        XCTAssertThrowsError(try S400Decoder.decode(raw, mac: "00:00:00:00:00:00", key: key))
        XCTAssertThrowsError(try S400Decoder.decode(raw, mac: mac, key: Data(repeating: 0, count: 16)))
        XCTAssertFalse(S400Decoder.validMAC(UUID().uuidString))
    }
    @Test func testMalformedInputFails() {
        for length in [0, 1, 23, 25, 27, 100] {
            XCTAssertThrowsError(try S400Decoder.decode(Data(repeating: 0, count: length), mac: mac, key: key))
        }
        XCTAssertNil(Data(hex: "0")); XCTAssertNil(Data(hex: "gg"))
        XCTAssertThrowsError(try S400Decoder.decode(raw, mac: mac, key: Data()))
    }
    @Test func testPacketOrderAndTimerFallback() {
        let now = Date(); var session = S400Session()
        XCTAssertNil(session.ingest(ScalePacket(weight: 0, low: nil, high: 365), now: now))
        let merged = session.ingest(ScalePacket(weight: 76.5, low: 402, high: nil), now: now.addingTimeInterval(1))
        XCTAssertEqual(merged?.high, 365); XCTAssertEqual(merged?.low, 402)
        XCTAssertNil(session.ingest(ScalePacket(weight: 70, low: nil, high: nil), now: now))
        XCTAssertNil(session.expire(now: now.addingTimeInterval(9)))
        XCTAssertEqual(session.expire(now: now.addingTimeInterval(10))?.weight, 70)
        XCTAssertNil(session.expire(now: now.addingTimeInterval(11)))
    }
    @Test func testStaleImpedanceDoesNotPairWithNewWeight() {
        let now = Date(); var session = S400Session()
        _ = session.ingest(ScalePacket(weight: 0, low: nil, high: 365), now: now)
        XCTAssertNil(session.ingest(ScalePacket(weight: 76.5, low: 402, high: nil), now: now.addingTimeInterval(11)))
        XCTAssertNil(session.expire(now: now.addingTimeInterval(21))?.high)
    }
    @Test func testBodyFatReferenceAndLabelSwap() {
        let date = ISO8601DateFormatter().date(from: "2026-10-26T10:00:00Z")!
        let p = Profile(birthYear: 1999, height: 172, male: true)
        XCTAssertEqual(p.legacyDeurenbergBodyFat(weight: 76.5, low: 402, high: 365, at: date)!, 20.29, accuracy: 0.1)
        XCTAssertEqual(p.bodyFat(weight: 76.5, low: 365, high: 402, at: date), p.bodyFat(weight: 76.5, low: 402, high: 365, at: date))
    }
    @Test func testInvalidContactAndMissingBandNeverBecomeZeroFat() {
        let p = Profile(birthYear: 1996, height: 180, male: true), now = Date()
        XCTAssertNil(p.bodyFat(weight: 85, low: 398, high: 395, at: now))
        XCTAssertNil(p.bodyFat(weight: 85, low: 398, high: nil, at: now))
        XCTAssertNil(p.bodyFat(weight: 85, low: 1600, high: 395, at: now))
        XCTAssertNil(Profile(birthYear: 2020, height: 180, male: true).bodyFat(weight: 85, low: 600, high: 550, at: now))
    }
}
