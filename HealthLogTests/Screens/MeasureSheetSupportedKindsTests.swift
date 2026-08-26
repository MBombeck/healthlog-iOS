import Foundation
@testable import HealthLog
import Testing

/// **MeasureSheetView supported-kinds contract.**
///
/// Originally a V052-R3 U-H2 regression guard: every `MetricKind` the dashboard
/// surfaces as a tile should also be reachable from the kind picker, so a
/// tile-visible metric is never a manual-entry dead end.
///
/// **Build 1 / item 1.4a inverted the emphasis.** Chasing tile coverage had
/// pushed nine HealthKit-derived kinds into the picker that
/// `Measurement.toCreateDTOs()` cannot serialize at all — `.bmi`, four walking
/// metrics, two audio exposures, `.steps`, `.sleep`. They fell into that
/// switch's `default: []`, `MeasurementsRepository+Writes`'s
/// `guard !dtos.isEmpty` threw, and the operator got an error banner on a value
/// the app had invited them to type. (Not silent data loss — the guard threw and
/// `.unknown` is not outbox-persistable — but a promise the app could not keep.)
///
/// So the binding contract is now the STRICTER one, pinned by
/// ``pickerMatchesSerializableKinds`` below: **the picker offers exactly the
/// kinds that serialize, no more.** Tile coverage remains a goal, but it may
/// never again outrun the wire.
@Suite("MeasureSheetView — supported-kinds contract")
struct MeasureSheetSupportedKindsTests {
    /// Mirrors the private `supportedKinds` computed property on
    /// `MeasureSheetView`. Item 1.4a trimmed this from 25 to 16.
    private static let expectedSupportedKinds: [MetricKind] = [
        .bloodPressure, .pulse, .restingHeartRate, .hrv, .respiratoryRate, .glucose, .spo2, .bodyTemperature,
        // v0158 — pain NRS sits with the vitals.
        .painNRS,
        .weight, .bodyFat, .bodyWater, .boneMass,
        // v0158 — waist circumference + grip strength (manual clinical signals).
        .waistCircumference, .gripStrength,
        .vo2Max
    ]

    /// The nine kinds item 1.4a removed. Kept named here so the removal is
    /// documented rather than inferred from a diff, and so
    /// ``removedKindsGenuinelyCannotSerialize`` can prove the removal was
    /// warranted instead of merely asserted.
    private static let removedInItem14a: [MetricKind] = [
        .bmi,
        .walkingSpeed, .walkingAsymmetry, .walkingStepLength, .walkingDoubleSupport,
        .audioExposureEnvironment, .audioExposureHeadphone,
        .steps, .sleep
    ]

    /// Build a minimal manual measurement of `kind` so `toCreateDTOs()` can be
    /// exercised. BP needs the paired value; everything else is a scalar.
    private static func sample(_ kind: MetricKind) -> HealthLog.Measurement {
        HealthLog.Measurement(
            id: "m-\(kind.rawValue)",
            kind: kind,
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000),
            value: kind == .bloodPressure ? .bloodPressure(systolic: 120, diastolic: 80) : .scalar(1),
            note: nil,
            source: .manual
        )
    }

    // MARK: - The item-1.4a contract

    @Test("Every kind the picker offers actually serializes to at least one wire DTO")
    func pickerMatchesSerializableKinds() {
        for kind in Self.expectedSupportedKinds {
            let dtos = Self.sample(kind).toCreateDTOs()
            #expect(
                !dtos.isEmpty,
                "\(kind.rawValue) is offered in the picker but toCreateDTOs() yields no wire row — saving it throws measurement.error.notSerializable at the operator"
            )
        }
    }

    @Test("Blood pressure still fans out to the two server rows")
    func bloodPressureFansOut() {
        #expect(Self.sample(.bloodPressure).toCreateDTOs().count == 2)
    }

    @Test("The nine removed kinds genuinely cannot serialize (the removal was warranted)")
    func removedKindsGenuinelyCannotSerialize() {
        for kind in Self.removedInItem14a {
            #expect(
                Self.sample(kind).toCreateDTOs().isEmpty,
                "\(kind.rawValue) DOES serialize — it should be back in the picker, not removed"
            )
        }
    }

    @Test("None of the removed kinds is still offered by the picker")
    func removedKindsAreGone() {
        let supported = Set(Self.expectedSupportedKinds)
        for kind in Self.removedInItem14a {
            #expect(!supported.contains(kind), "\(kind.rawValue) is still in the picker")
        }
    }

    @Test("A stale recent-kind MRU entry for a removed kind never surfaces a dead chip")
    func staleRecentKindIsFiltered() {
        // The MRU is persisted raw in @AppStorage, so an operator who logged
        // `.steps` before this build still has it in `measure.recentKinds`.
        let raw = "steps,weight,sleep"
        let parsed = MeasureRecentKinds.parse(raw, allowed: Self.expectedSupportedKinds)
        #expect(parsed == [.weight], "removed kinds must be filtered out of the chip row")
    }

    // MARK: - Picker hygiene (unchanged contracts)

    @Test("Supported-kinds order is stable so the picker doesn't reshuffle between releases")
    func orderIsStable() {
        // `MeasureSheetView` initialises `kind = .bloodPressure` — keep BP at
        // index 0 so the pre-seed frame matches the seeded one.
        #expect(Self.expectedSupportedKinds.first == .bloodPressure)
        #expect(Self.expectedSupportedKinds.last == .vo2Max)
        #expect(Self.expectedSupportedKinds.count == 16)
    }

    @Test("Every supported kind has a descriptor with a non-empty SF Symbol")
    func everyKindHasSymbol() {
        for kind in Self.expectedSupportedKinds {
            #expect(!kind.descriptor.sfSymbol.isEmpty, "\(kind.rawValue) has no SF Symbol")
        }
    }

    @Test("Every supported kind has a non-empty unit label")
    func everyKindHasUnit() {
        for kind in Self.expectedSupportedKinds {
            // v0158 — `.painNRS` is dimensionless (a 0–10 NRS score), so it is
            // exempt. (`.steps`, the other dimensionless kind, left the picker
            // in item 1.4a.)
            if kind == .painNRS { continue }
            #expect(!kind.unit.isEmpty, "\(kind.rawValue) has no unit string")
        }
    }

    @Test("No kind is offered twice")
    func noDuplicates() {
        #expect(Set(Self.expectedSupportedKinds).count == Self.expectedSupportedKinds.count)
    }
}
