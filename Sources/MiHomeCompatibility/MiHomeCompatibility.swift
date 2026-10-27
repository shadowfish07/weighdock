// SPDX-License-Identifier: Apache-2.0
// Adapted from BodyMiScale 2026.10.4, xiaomi_home.py (Apache-2.0).
// Firmware formula transcription: RX14; BodyMiScale integration: its contributors.
// Swift subset and validation added 2026-10-27 by S400Menu contributors.
// See Reference/BodyMiScale/NOTICE.md and LICENSE for provenance and limitations.
import Foundation

/// The released BodyMiScale formula subset, shared by new ingestion and offline comparisons.
/// It neither reads history nor performs the firmware's profile-dependent smoothing.
public enum MiHomeCompatibility {
    public static let algorithmIdentifier = "xiaomi-home-s400/bodymiscale-2026.10.4@3d75ed8/formula-v1"
    public enum Sex: String, Codable, Sendable { case male, female }
    public enum CalculationError: Error, Equatable { case invalidInput, missingImpedance, numericOverflow }

    public struct Input: Sendable {
        public let sex: Sex
        public let heightCM: Double
        public let weightKG: Double
        /// Explicit age in years; no birth-year approximation is performed here.
        public let ageYears: Double
        /// Physical 50 kHz impedance magnitude, in ohms, not the raw BLE integer.
        public let z50Ohms: Double
        public init(sex: Sex, heightCM: Double, weightKG: Double, ageYears: Double, z50Ohms: Double) {
            self.sex = sex; self.heightCM = heightCM; self.weightKG = weightKG
            self.ageYears = ageYears; self.z50Ohms = z50Ohms
        }
    }

    public struct Result: Equatable, Sendable {
        public let unroundedBodyFatPercent: Double
        /// Formula-level firmware clamp: 3...55 percent, after 0.1 rounding.
        public let firmwareBodyFatPercent: Double
        /// The released Home Assistant metric wrapper adds a 5...75 clamp.
        /// This differs from the formula only below 5 percent.
        public let bodyMiScaleMetricBodyFatPercent: Double
        /// Uses formula-level fat, as upstream does; not rounded to 0.1 kg here.
        public let leanBodyMassKG: Double
        public let z50Ohms: Double
    }

    /// Mirrors int(x*100), Python floor-division/modulo, then half-up to a tenth.
    /// Swift's default rounding and signed integer division would differ at boundaries.
    public static func roundToTenthLikeRelease(_ value: Double) throws -> Double {
        let scaled = value * 100
        guard scaled.isFinite, scaled > Double(Int64.min), scaled < Double(Int64.max) else {
            throw CalculationError.numericOverflow
        }
        let n = Int64(scaled) // Truncate toward zero, as Python int does.
        let quotient = n / 10
        let remainder = n % 10
        let floorQuotient = remainder < 0 ? quotient - 1 : quotient
        let positiveRemainder = remainder < 0 ? remainder + 10 : remainder
        return Double(floorQuotient * 10 + (positiveRemainder >= 5 ? 10 : 0)) / 100
    }

    /// The input domain guard is deliberately separate from the physiological gates
    /// in the app's ingestion adapter. It mirrors positive integration inputs,
    /// while also rejecting non-finite values and overflow instead of returning zero.
    public static func calculate(_ input: Input) throws -> Result {
        guard [input.heightCM, input.weightKG, input.ageYears, input.z50Ohms].allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw CalculationError.invalidInput
        }
        let c: (Double, Double, Double, Double, Double) = input.sex == .male
            ? (-0.3315, 0.6216, 0.0183, 0.0085, 22.554)
            : (-0.3332, 0.7509, 0.0196, 0.0072, 22.7193)
        // Keep upstream evaluation order and Double precision; do not use FMA.
        let massTerm = c.0 * input.heightCM + c.1 * input.weightKG + c.2 * input.ageYears + c.3 * input.z50Ohms + c.4
        let raw = 100 * massTerm / input.weightKG
        let rounded = try roundToTenthLikeRelease(raw)
        let fat = max(3, min(55, rounded))
        let lean = input.weightKG * (1 - fat / 100)
        guard lean.isFinite else { throw CalculationError.numericOverflow }
        return Result(unroundedBodyFatPercent: raw, firmwareBodyFatPercent: fat,
                      bodyMiScaleMetricBodyFatPercent: max(5, min(75, fat)),
                      leanBodyMassKG: lean, z50Ohms: input.z50Ohms)
    }

    /// Mirrors the released dual-frequency adapter: both bands must be present,
    /// and max/min resolves inverted entity labels. The formula itself uses z50 only.
    public static func calculateDual(sex: Sex, heightCM: Double, weightKG: Double, ageYears: Double,
                                     impedanceAOhms: Double?, impedanceBOhms: Double?) throws -> Result {
        guard let a = impedanceAOhms, let b = impedanceBOhms else { throw CalculationError.missingImpedance }
        guard a.isFinite, b.isFinite, a > 0, b > 0 else { throw CalculationError.invalidInput }
        return try calculate(Input(sex: sex, heightCM: heightCM, weightKG: weightKG,
                                   ageYears: ageYears, z50Ohms: max(a, b)))
    }
}
