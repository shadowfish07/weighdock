#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Our offline arithmetic oracle for the reviewed BodyMiScale release subset.

Does not import upstream Python, Home Assistant, application state or credentials.
Reads only the committed anonymous test fixtures; does not generate health uploads.
This validates a language port, not the original firmware or clinical accuracy.
"""
import json
from pathlib import Path


def reference(sex, height_cm, weight_kg, age_years, z50_ohms):
    coeffs = ((-0.3315, 0.6216, 0.0183, 0.0085, 22.554) if sex == "male"
              else (-0.3332, 0.7509, 0.0196, 0.0072, 22.7193))
    raw = 100 * (coeffs[0] * height_cm + coeffs[1] * weight_kg
                 + coeffs[2] * age_years + coeffs[3] * z50_ohms + coeffs[4]) / weight_kg
    truncated = int(raw * 100)
    rounded = (truncated // 10 * 10 + (10 if truncated % 10 >= 5 else 0)) / 100
    fat = max(3, min(55, rounded))
    return raw, fat, weight_kg * (1 - fat / 100)


def main():
    root = Path(__file__).resolve().parent.parent
    fixtures = json.loads((root / "Tests/MiHomeCompatibilityTests/Fixtures/public-comparison.json").read_text())
    max_error = 0
    for row in fixtures:
        raw, fat, lean = reference(row["gender"], row["heightCM"], row["weightKG"], row["ageYears"], row["z50Ohms"])
        error = max(abs(raw - row["referenceUnroundedPercent"]),
                    abs(fat - row["referenceBodyFatPercent"]), abs(lean - row["referenceLeanMassKG"]))
        max_error = max(max_error, error)
        assert error < 1e-10, row["id"]
        if not row["knownBodyFatGap"]:
            assert abs(fat - row["publishedBodyFatPercent"]) <= row["publishedTolerance"], row["id"]
    print(json.dumps({"anonymous_cases": len(fixtures), "max_reference_error": max_error,
                      "executed_upstream_code": False}, indent=2))


if __name__ == "__main__":
    main()
