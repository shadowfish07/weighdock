// SPDX-License-Identifier: Apache-2.0
// Public, minimal fixtures adapted from BodyMiScale 2026.10.4 tests (Apache-2.0).
// Participants' labels and unrelated health metrics are deliberately omitted.
import Foundation
import Testing
import MiHomeCompatibility
import S400Core

struct PublicCase: Decodable {
    let id: String
    let gender: MiHomeCompatibility.Sex
    let ageYears: Double
    let heightCM: Double
    let weightKG: Double
    let z50Ohms: Double
    let z250Ohms: Double?
    let publishedBodyFatPercent: Double
    let publishedTolerance: Double
    let knownBodyFatGap: Bool
    let publishedLeanMassKG: Double?
    let leanTolerance: Double?
    let referenceBodyFatPercent: Double
    let referenceLeanMassKG: Double
    let referenceUnroundedPercent: Double
    var input: MiHomeCompatibility.Input {
        .init(sex: gender, heightCM: heightCM, weightKG: weightKG, ageYears: ageYears, z50Ohms: z50Ohms)
    }
}

struct CompatibilityTests {
    func cases() throws -> [PublicCase] {
        let url = try #require(Bundle.module.url(forResource: "public-comparison", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode([PublicCase].self, from: Data(contentsOf: url))
    }
    func input(sex: MiHomeCompatibility.Sex = .male, height: Double = 176, weight: Double = 79.9,
               age: Double = 46, z50: Double = 576.7) -> MiHomeCompatibility.Input {
        .init(sex: sex, heightCM: height, weightKG: weight, ageYears: age, z50Ohms: z50)
    }

    @Test func publishedAssertionsAndReferenceParity() throws {
        let fixtures = try cases()
        #expect(fixtures.count == 13)
        #expect(fixtures.filter(\.knownBodyFatGap).count == 2)
        for row in fixtures {
            let result = try MiHomeCompatibility.calculate(row.input)
            #expect(abs(result.firmwareBodyFatPercent - row.referenceBodyFatPercent) < 1e-10)
            #expect(abs(result.leanBodyMassKG - row.referenceLeanMassKG) < 1e-10)
            #expect(abs(result.unroundedBodyFatPercent - row.referenceUnroundedPercent) < 1e-10)
            if !row.knownBodyFatGap {
                #expect(abs(result.firmwareBodyFatPercent - row.publishedBodyFatPercent) <= row.publishedTolerance)
            }
            if let expected = row.publishedLeanMassKG {
                #expect(abs(result.leanBodyMassKG - expected) <= (row.leanTolerance ?? 1e-6))
            }
        }
    }

    @Test func knownGapsAreNotSilentlyTreatedAsExactMatches() throws {
        let gaps = try cases().filter(\.knownBodyFatGap)
        for row in gaps {
            let result = try MiHomeCompatibility.calculate(row.input)
            let expectedDelta = row.id == "public-06" ? -0.1 : 0.9
            #expect(abs(result.firmwareBodyFatPercent - row.publishedBodyFatPercent - expectedDelta) < 1e-10)
        }
    }

    @Test func roundMatchesReleasedPublishedBoundaries() throws {
        let pairs: [(Double, Double)] = [(23.349, 23.3), (23.35, 23.4), (23.3499, 23.3),
                                        (0.049, 0), (0.05, 0.1), (-0.05, 0), (-23.35, -23.3), (-23.36, -23.4)]
        for (value, expected) in pairs {
            #expect(abs(try MiHomeCompatibility.roundToTenthLikeRelease(value) - expected) < 1e-10)
        }
    }

    @Test func firmwareAndIntegrationClampsAreKeptSeparate() throws {
        let floor = try MiHomeCompatibility.calculate(input(height: 167, weight: 41.4, age: 12, z50: 701))
        #expect(floor.firmwareBodyFatPercent == 3)
        #expect(floor.bodyMiScaleMetricBodyFatPercent == 5)
        #expect(abs(floor.leanBodyMassKG - 40.158) < 1e-10)
        let ceiling = try MiHomeCompatibility.calculate(input(sex: .female, height: 100, weight: 20, age: 30, z50: 1500))
        #expect(ceiling.firmwareBodyFatPercent == 55)
        #expect(ceiling.bodyMiScaleMetricBodyFatPercent == 55)
        #expect(abs(ceiling.leanBodyMassKG - 9) < 1e-10)
    }

    @Test func leanMassUsesRoundedClampedFatWithoutExtraMassRounding() throws {
        let result = try MiHomeCompatibility.calculate(input())
        #expect(result.firmwareBodyFatPercent == 24.6)
        #expect(abs(result.leanBodyMassKG - 60.2446) < 1e-10)
        #expect(result.leanBodyMassKG != 60.2)
    }

    @Test func dualAdapterOrdersBandsAndRequiresBoth() throws {
        let a = try MiHomeCompatibility.calculateDual(sex: .male, heightCM: 176, weightKG: 79.9, ageYears: 46,
                                                      impedanceAOhms: 576.7, impedanceBOhms: 514.6)
        let b = try MiHomeCompatibility.calculateDual(sex: .male, heightCM: 176, weightKG: 79.9, ageYears: 46,
                                                      impedanceAOhms: 514.6, impedanceBOhms: 576.7)
        #expect(a == b)
        #expect(a.z50Ohms == 576.7)
        #expect(throws: MiHomeCompatibility.CalculationError.missingImpedance) {
            try MiHomeCompatibility.calculateDual(sex: .male, heightCM: 176, weightKG: 79.9, ageYears: 46,
                                                  impedanceAOhms: 576.7, impedanceBOhms: nil)
        }
    }

    @Test func highFrequencyDoesNotEnterBodyFatEquation() throws {
        let first = try MiHomeCompatibility.calculateDual(sex: .male, heightCM: 176, weightKG: 79.9, ageYears: 46,
                                                          impedanceAOhms: 576.7, impedanceBOhms: 500)
        let second = try MiHomeCompatibility.calculateDual(sex: .male, heightCM: 176, weightKG: 79.9, ageYears: 46,
                                                           impedanceAOhms: 576.7, impedanceBOhms: 400)
        #expect(first == second)
    }

    @Test func statelessResultDoesNotDependOnCallHistory() throws {
        let first = try MiHomeCompatibility.calculate(input())
        _ = try MiHomeCompatibility.calculate(input(sex: .female, height: 160, weight: 55, age: 30, z50: 650))
        #expect(try MiHomeCompatibility.calculate(input()) == first)
    }

    @Test(arguments: [0.0, -1, Double.nan, Double.infinity, -Double.infinity])
    func invalidInputsFailInsteadOfCreatingZeroBodyFat(value: Double) {
        for item in [input(height: value), input(weight: value), input(age: value), input(z50: value)] {
            #expect(throws: MiHomeCompatibility.CalculationError.invalidInput) { try MiHomeCompatibility.calculate(item) }
        }
        #expect(throws: MiHomeCompatibility.CalculationError.invalidInput) {
            try MiHomeCompatibility.calculateDual(sex: .male, heightCM: 176, weightKG: 79.9, ageYears: 46,
                                                  impedanceAOhms: 600, impedanceBOhms: value)
        }
    }

    @Test func overflowFailsWithoutIntegerConversionTrap() {
        #expect(throws: MiHomeCompatibility.CalculationError.numericOverflow) {
            try MiHomeCompatibility.roundToTenthLikeRelease(.greatestFiniteMagnitude)
        }
        #expect(throws: MiHomeCompatibility.CalculationError.numericOverflow) {
            try MiHomeCompatibility.calculate(input(weight: .leastNonzeroMagnitude))
        }
    }

    @Test func sexAgeAndOhmUnitsAreNotInterchangeable() throws {
        let original = try MiHomeCompatibility.calculate(input())
        let female = try MiHomeCompatibility.calculate(input(sex: .female))
        let rawIntegerMistake = try MiHomeCompatibility.calculate(input(z50: 5767))
        #expect(female.firmwareBodyFatPercent != original.firmwareBodyFatPercent)
        #expect(rawIntegerMistake.firmwareBodyFatPercent != original.firmwareBodyFatPercent)
        let ageOne = try MiHomeCompatibility.calculate(input(age: 46))
        let ageTwo = try MiHomeCompatibility.calculate(input(age: 47))
        #expect(ageOne.unroundedBodyFatPercent != ageTwo.unroundedBodyFatPercent)
    }
}
