// SPDX-License-Identifier: GPL-3.0-or-later
// Swift adaptation of openScale S400Decryptor (C) 2025 olie.xdev,
// S400Aggregator / body-fat subset of S400BodyComposition (C) 2026 Dany Mestas.
// Modified 2026: authenticated CoreBluetooth decoding, timer expiry, weight-only fallback.
import Foundation
import CommonCrypto
import CryptoKit
import MiHomeCompatibility

public enum ScaleError: Error { case invalidInput, authentication, storage, consent, simulated, response(Int), operation }

public extension Data {
    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes = [UInt8](); var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            bytes.append(b); i = j
        }
        self.init(bytes)
    }
}

// CCM with a 12-byte nonce, four-byte tag, and Xiaomi's single AAD byte 0x11.
// Uses Apple's public AES ECB primitive; never returns unauthenticated plaintext.
enum XiaomiCCM {
    static func aes(_ block: [UInt8], key: [UInt8]) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: 16); var moved = 0
        let result = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode), key, key.count, nil, block, block.count, &output, 16, &moved)
        guard result == kCCSuccess && moved == 16 else { throw ScaleError.authentication }
        return output
    }
    static func open(cipher: [UInt8], tag: [UInt8], nonce: [UInt8], key: [UInt8]) throws -> [UInt8] {
        guard nonce.count == 12, key.count == 16, tag.count == 4, cipher.count == 12 else { throw ScaleError.invalidInput }
        func counter(_ n: UInt8) -> [UInt8] { [2] + nonce + [0, 0, n] }
        let stream = try aes(counter(1), key: key)
        let plain = zip(cipher, stream).map { $0 ^ $1 }
        var mac = try aes([0x4a] + nonce + [0, 0, UInt8(plain.count)], key: key)
        for block in [[0, 1, 0x11] + Array(repeating: UInt8(0), count: 13), plain + Array(repeating: UInt8(0), count: 4)] {
            mac = try aes(zip(mac, block).map { $0 ^ $1 }, key: key)
        }
        let s0 = try aes(counter(0), key: key)
        var mismatch: UInt8 = 0
        for i in 0..<4 { mismatch |= mac[i] ^ s0[i] ^ tag[i] }
        guard mismatch == 0 else { throw ScaleError.authentication }
        return plain
    }
}

public struct ScalePacket: Equatable {
    public let weight: Double
    public let low: Double?
    public let high: Double?
    public let heartRate: Int?
    public let fingerprint: String?
    public init(weight: Double, low: Double?, high: Double?, heartRate: Int? = nil, fingerprint: String? = nil) {
        self.weight = weight; self.low = low; self.high = high; self.heartRate = heartRate
        self.fingerprint = fingerprint
    }
}
public enum S400Decoder {
    public static func validMAC(_ mac: String) -> Bool {
        mac.range(of: "^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$", options: .regularExpression) != nil
    }
    public static func decode(_ advertisement: Data, mac: String, key: Data) throws -> ScalePacket {
        guard validMAC(mac), key.count == 16, [24, 26].contains(advertisement.count) else { throw ScaleError.invalidInput }
        let data = Array(advertisement.suffix(24))
        let address = Array(Data(hex: mac.replacingOccurrences(of: ":", with: ""))!)
        let nonce = Array(address.reversed()) + Array(data[2..<5]) + Array(data[17..<20])
        let plain = try XiaomiCCM.open(cipher: Array(data[5..<17]), tag: Array(data[20..<24]), nonce: nonce, key: Array(key))
        let value = (0..<4).reduce(UInt32(0)) { $0 | UInt32(plain[4 + $1]) << (8 * $1) }
        let weight = Double(value & 0x7ff) / 10
        let heart = Int((value >> 11) & 0x7f)
        // Unsigned shift avoids negative impedance at the top end of the word.
        let impedance = Double(value >> 18) / 10
        guard weight > 0 || impedance > 0 else { throw ScaleError.invalidInput }
        return ScalePacket(weight: weight, low: weight > 0 && impedance > 0 ? impedance : nil,
                           high: weight == 0 && impedance > 0 ? impedance : nil,
                           heartRate: (1...126).contains(heart) ? heart + 50 : nil,
                           fingerprint: SHA256.hash(data: Data(data)).map { String(format: "%02x", $0) }.joined())
    }
}

public struct Profile: Codable, Equatable {
    public static let bodyFatAlgorithmIdentifier = MiHomeCompatibility.algorithmIdentifier
    public var birthYear: Int
    public var height: Double
    public var male: Bool
    public init(birthYear: Int, height: Double, male: Bool) { self.birthYear = birthYear; self.height = height; self.male = male }
    private func validBodyFatInput(weight: Double, low: Double?, high: Double?, at date: Date) -> (age: Int, low: Double, high: Double)? {
        guard date.timeIntervalSinceReferenceDate.isFinite,
              let low, let high, [height, weight, low, high].allSatisfy(\.isFinite),
              (100...230).contains(height), (20...250).contains(weight),
              (200...1500).contains(low), (200...1500).contains(high) else { return nil }
        let (age, overflow) = Calendar.current.component(.year, from: date).subtractingReportingOverflow(birthYear)
        guard !overflow, (18...120).contains(age) else { return nil }
        let rLow = max(low, high), rHigh = min(low, high)
        guard (12...60).contains(weight / pow(height / 100, 2)), (rLow - rHigh) / rHigh >= 0.01 else { return nil }
        return (age, rLow, rHigh)
    }
    /// New measurements use the same formula-level result as the offline study.
    /// Age intentionally retains the app's existing year-difference convention.
    public func bodyFat(weight: Double, low: Double?, high: Double?, at date: Date) -> Double? {
        guard let input = validBodyFatInput(weight: weight, low: low, high: high, at: date) else { return nil }
        return try? MiHomeCompatibility.calculateDual(sex: male ? .male : .female, heightCM: height,
            weightKG: weight, ageYears: Double(input.age), impedanceAOhms: input.low, impedanceBOhms: input.high).firmwareBodyFatPercent
    }
    /// Retained only for explicit offline comparison; never a fallback or migration.
    public func legacyDeurenbergBodyFat(weight: Double, low: Double?, high: Double?, at date: Date) -> Double? {
        guard let input = validBodyFatInput(weight: weight, low: low, high: high, at: date) else { return nil }
        let age = input.age, rLow = input.low
        let bmi = weight / pow(height / 100, 2)
        let sex = male ? 1.0 : 0.0
        let ffm = 0.340 * height * height / rLow + 15.34 * height / 100 + 0.273 * weight - 0.127 * Double(age) + 4.56 * sex - 12.44
        let fat = (weight - ffm) / weight * 100
        let bmiFat = 1.20 * bmi + 0.23 * Double(age) - 10.8 * sex - 5.4
        let waterFraction = 0.732 * ffm / weight
        guard (male ? 0.38...0.68 : 0.35...0.63).contains(waterFraction), abs(fat - bmiFat) <= 12, (0...100).contains(fat) else { return nil }
        return fat
    }
}

public struct FinalReading {
    public let weight: Double
    public let low: Double?
    public let high: Double?
    public let date: Date
    public let fingerprint: String?
    public init(weight: Double, low: Double?, high: Double?, date: Date, fingerprint: String? = nil) {
        self.weight = weight; self.low = low; self.high = high; self.date = date
        self.fingerprint = fingerprint
    }
}
public struct S400Session {
    private var started: Date?
    private var weight: Double?
    private var low: Double?
    private var high: Double?
    private var fingerprint: String?
    public init() {}
    public mutating func ingest(_ packet: ScalePacket, now: Date) -> FinalReading? {
        // Discard a stale impedance-only packet before associating a new weighing.
        if let started, now.timeIntervalSince(started) >= 10 { self = S400Session() }
        if started == nil { started = now }
        if packet.weight > 0 { weight = packet.weight; low = packet.low; fingerprint = packet.fingerprint }
        if let value = packet.high { high = value }
        if weight != nil && low != nil && high != nil { return finish() }
        return nil
    }
    public mutating func expire(now: Date) -> FinalReading? {
        guard let started, now.timeIntervalSince(started) >= 10 else { return nil }
        return finish()
    }
    private mutating func finish() -> FinalReading? {
        defer { self = S400Session() }
        guard let weight, let started, weight > 0, weight <= 250 else { return nil }
        return FinalReading(weight: weight, low: low, high: high, date: started, fingerprint: fingerprint)
    }
}
