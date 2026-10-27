// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import MiHomeCompatibility
import S400Core

struct ComparisonReportTests {
    private struct Row: Codable {
        let id: String
        let publishedBodyFat: Double
        let compatibilityBodyFat: Double
        let legacyBodyFat: Double?
        let compatibilityLeanMass: Double
        let deltaFromPublished: Double
        let referenceParityError: Double
        let knownPublishedGap: Bool
    }
    private struct Report: Codable {
        let sourceCommit: String
        let rows: [Row]
        let publicS400MeanAbsoluteGap: Double
        let publicS400LegacyMeanAbsoluteGap: Double
        let publicS400LegacyAvailable: Int
        let doubleVersusFloat32SweepCount: Int
        let doubleVersusFloat32DifferentRoundedResults: Int
        let doubleVersusFloat32MaxPercentPointGap: Double
        let maxReferenceRawParityError: Double
    }
    @Test func writeOfflineComparisonAndPrecisionReport() throws {
        let fixtures = try CompatibilityTests().cases()
        let date = try #require(ISO8601DateFormatter().date(from: "2026-10-27T12:00:00Z"))
        var maxRawError = 0.0
        let rows = try fixtures.map { row -> Row in
            let next = try MiHomeCompatibility.calculate(row.input)
            let profile = Profile(birthYear: 2026 - Int(row.ageYears), height: row.heightCM, male: row.gender == .male)
            let current = profile.legacyDeurenbergBodyFat(weight: row.weightKG, low: row.z50Ohms, high: row.z250Ohms, at: date)
            maxRawError = max(maxRawError, abs(next.unroundedBodyFatPercent - row.referenceUnroundedPercent))
            return Row(id: row.id, publishedBodyFat: row.publishedBodyFatPercent,
                       compatibilityBodyFat: next.firmwareBodyFatPercent, legacyBodyFat: current,
                       compatibilityLeanMass: next.leanBodyMassKG,
                       deltaFromPublished: next.firmwareBodyFatPercent - row.publishedBodyFatPercent,
                       referenceParityError: next.firmwareBodyFatPercent - row.referenceBodyFatPercent,
                       knownPublishedGap: row.knownBodyFatGap)
        }
        let publicS400 = rows.prefix(10)
        let oldAvailable = publicS400.filter { $0.legacyBodyFat != nil }
        var different = 0, checked = 0, maxFloatGap = 0.0
        func comparePrecision(_ input: MiHomeCompatibility.Input) throws {
            let next = try MiHomeCompatibility.calculate(input)
            let c: [Float] = input.sex == .male ? [-0.3315, 0.6216, 0.0183, 0.0085, 22.554] : [-0.3332, 0.7509, 0.0196, 0.0072, 22.7193]
            let mass = c[0] * Float(input.heightCM) + c[1] * Float(input.weightKG) + c[2] * Float(input.ageYears) + c[3] * Float(input.z50Ohms) + c[4]
            let raw = Float(100) * mass / Float(input.weightKG)
            let fat32 = max(3, min(55, try MiHomeCompatibility.roundToTenthLikeRelease(Double(raw))))
            let gap = abs(fat32 - next.firmwareBodyFatPercent)
            if gap > 1e-10 { different += 1 }
            maxFloatGap = max(maxFloatGap, gap); checked += 1
        }
        // Synthetic arithmetic stress cases, not QEMU or clinical validation.
        for i in 0..<10_000 {
            let sex: MiHomeCompatibility.Sex = i.isMultiple(of: 2) ? .male : .female
            let h = 140 + Double(i % 80), w = 35 + Double(i % 130) / 1.1
            let age = 18 + Double(i % 70), z = 200 + Double((i * 137) % 13_000) / 10
            try comparePrecision(.init(sex: sex, heightCM: h, weightKG: w, ageYears: age, z50Ohms: z))
        }
        // Deliberately probe rounding cutovers; a broad sweep alone can miss them.
        for i in 0..<1_000 {
            let sex: MiHomeCompatibility.Sex = i.isMultiple(of: 2) ? .male : .female
            let c: [Double] = sex == .male ? [-0.3315, 0.6216, 0.0183, 0.0085, 22.554] : [-0.3332, 0.7509, 0.0196, 0.0072, 22.7193]
            let rawTarget = 15.05 + Double(i % 300) / 10
            let z = (rawTarget * 70 / 100 - c[0] * 170 - c[1] * 70 - c[2] * 40 - c[4]) / c[3]
            if !(200...1500).contains(z) { continue }
            for epsilon in [-1e-8, 0.0, 1e-8] {
                try comparePrecision(.init(sex: sex, heightCM: 170, weightKG: 70, ageYears: 40, z50Ohms: z + epsilon))
            }
        }
        let report = Report(sourceCommit: "3d75ed80e2f3b437f96c7b442a144f4fd9c12c97", rows: rows,
                            publicS400MeanAbsoluteGap: publicS400.reduce(0) { $0 + abs($1.deltaFromPublished) } / 10,
                            publicS400LegacyMeanAbsoluteGap: oldAvailable.reduce(0) { $0 + abs($1.legacyBodyFat! - $1.publishedBodyFat) } / Double(oldAvailable.count),
                            publicS400LegacyAvailable: oldAvailable.count,
                            doubleVersusFloat32SweepCount: checked,
                            doubleVersusFloat32DifferentRoundedResults: different,
                            doubleVersusFloat32MaxPercentPointGap: maxFloatGap,
                            maxReferenceRawParityError: maxRawError)
        #expect(rows.allSatisfy { abs($0.referenceParityError) < 1e-10 })
        #expect(maxRawError < 1e-10)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let destination = root.appendingPathComponent("build/evidence/mihome-comparison.json")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: destination, options: .atomic)
    }
}
