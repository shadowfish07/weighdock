// SPDX-License-Identifier: Apache-2.0
// Our standalone optimized check, compiled with the isolated algorithm source.
// Reads only committed anonymous fixtures; never application data or credentials.
import Foundation

@main enum MiHomeOptimizedCheck {
    enum CheckError: Error { case referenceMismatch }
    static func main() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let file = root.appendingPathComponent("Tests/MiHomeCompatibilityTests/Fixtures/public-comparison.json")
        let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [[String: Any]]
        var maxError = 0.0
        for row in rows {
            let input = MiHomeCompatibility.Input(sex: MiHomeCompatibility.Sex(rawValue: row["gender"] as! String)!,
                heightCM: row["heightCM"] as! Double, weightKG: row["weightKG"] as! Double,
                ageYears: row["ageYears"] as! Double, z50Ohms: row["z50Ohms"] as! Double)
            let result = try MiHomeCompatibility.calculate(input)
            maxError = max(maxError, abs(result.unroundedBodyFatPercent - (row["referenceUnroundedPercent"] as! Double)))
            maxError = max(maxError, abs(result.firmwareBodyFatPercent - (row["referenceBodyFatPercent"] as! Double)))
            maxError = max(maxError, abs(result.leanBodyMassKG - (row["referenceLeanMassKG"] as! Double)))
        }
        guard maxError < 1e-10 else { throw CheckError.referenceMismatch }
        print("Optimized standalone Swift: \(rows.count) anonymous public cases; maximum parity error \(maxError)")
    }
}
