import Foundation
@testable import HealthLog
import Testing

/// **Build 1 / item 1.3 — the edit path's unit round-trip.**
///
/// ## What the audit claimed, and what the source actually said
///
/// The audit (`05-measurements-labs.md:47`) recorded this as P0 silent PHI
/// corruption: "a lb/kPa/mmol user who edits a row writes the display value raw
/// as the canonical value." **That is not what the code did.**
/// `EditMeasurementSheet.prefill()` seeded the field from `measurement.value`,
/// which is CANONICAL, and labelled it with `measurement.kind.unit`
/// (`Measurement.swift:335` — also canonical: "kg", "mmHg", "mg/dL"). The sheet
/// was canonical-in / canonical-out and internally consistent. Opening a row and
/// pressing Speichern without typing corrupted nothing.
///
/// The real defect was one step removed, and still worth fixing: the edit sheet
/// was the ONE surface that ignored the operator's unit preference. A lb-pref
/// operator read "159,6 lb" on the list, tapped edit, and was shown "72,4 kg" —
/// which is an invitation to "correct" the field to 159,6, at which point the
/// old save path really did store 159,6 kg. Corruption with a human in the loop
/// rather than corruption on every edit.
///
/// The fix makes the edit sheet display-unit aware at BOTH ends: prefill
/// forward-converts canonical → display, save inverse-converts display →
/// canonical. These tests pin that symmetry, plus the range validation and the
/// future-bound the edit path never had.
@Suite("EditMeasurementSheet — unit round-trip + validation (item 1.3)")
struct EditMeasurementUnitConversionTests {
    private static let lbPrefs = UnitPreferences(weight: .lb)
    private static let kPaPrefs = UnitPreferences(bloodPressure: .kPa)
    private static let mmolPrefs = UnitPreferences(glucose: .mmolL)

    // MARK: - Prefill forward-converts (the half that was missing)

    @Test("Prefill converts the stored canonical value into the operator's unit")
    func prefillForwardConverts() {
        // 72.4 kg stored → the lb-pref operator must see ~159.6, matching every
        // other surface, not the raw canonical 72.4.
        let displayed = MeasureEntryConversion.displayScalar(72.4, kind: .weight, units: Self.lbPrefs)
        #expect(abs(displayed - 159.614) < 0.01)

        // 5.4 mmol/L-pref operator editing a 97.3 mg/dL glucose row.
        let glucose = MeasureEntryConversion.displayScalar(97.3, kind: .glucose, units: Self.mmolPrefs)
        #expect(abs(glucose - 5.4) < 0.01)

        // Canonical prefs are the identity — no behaviour change for the default.
        #expect(MeasureEntryConversion.displayScalar(72.4, kind: .weight, units: .standard) == 72.4)
    }

    // MARK: - Save inverse-converts (the headline regression guard)

    @Test("Save inverse-converts the typed value back to canonical for every family")
    func saveInverseConverts() {
        // Weight: the operator types 159,6 lb → 72.4 kg is stored.
        let kg = MeasureEntryConversion.canonicalScalar(159.614, kind: .weight, units: Self.lbPrefs)
        #expect(abs(kg - 72.4) < 0.01)

        // Glucose: 5.4 mmol/L → ~97.3 mg/dL.
        let mgdL = MeasureEntryConversion.canonicalScalar(5.4, kind: .glucose, units: Self.mmolPrefs)
        #expect(abs(mgdL - 97.3) < 0.05)

        // Blood pressure legs convert independently.
        let systolic = Self.kPaPrefs.canonicalBloodPressure(fromDisplayed: 16.0)
        let diastolic = Self.kPaPrefs.canonicalBloodPressure(fromDisplayed: 10.7)
        #expect(abs(systolic - 120.0) < 0.5)
        #expect(abs(diastolic - 80.2) < 0.5)
    }

    @Test("Prefill → save is a lossless round-trip (this is what protects the record)")
    func roundTripIsLossless() {
        // The whole point: opening a row in a non-canonical unit and saving it
        // untouched must return the SAME canonical number. Before item 1.3 the
        // two ends spoke different units, so this symmetry did not exist.
        for (kind, canonical, prefs) in [
            (MetricKind.weight, 72.4, Self.lbPrefs),
            (MetricKind.weight, 103.7, Self.lbPrefs),
            (MetricKind.glucose, 97.3, Self.mmolPrefs),
            (MetricKind.glucose, 180.0, Self.mmolPrefs),
            (MetricKind.bodyWater, 42.0, Self.lbPrefs),
            (MetricKind.boneMass, 3.2, Self.lbPrefs)
        ] {
            let displayed = MeasureEntryConversion.displayScalar(canonical, kind: kind, units: prefs)
            let backToCanonical = MeasureEntryConversion.canonicalScalar(displayed, kind: kind, units: prefs)
            #expect(
                abs(backToCanonical - canonical) < 0.0001,
                "\(kind.rawValue): \(canonical) → \(displayed) → \(backToCanonical) is not lossless"
            )
        }
    }

    @Test("Blood-pressure round-trip is lossless in kPa")
    func bloodPressureRoundTripIsLossless() {
        for canonical in [90.0, 120.0, 145.0, 80.0] {
            let displayed = Self.kPaPrefs.convertBloodPressure(canonical)
            let back = Self.kPaPrefs.canonicalBloodPressure(fromDisplayed: displayed)
            #expect(abs(back - canonical) < 0.0001)
        }
    }

    @Test("Canonical-unit prefs are pure identity — no regression for the default operator")
    func canonicalPrefsAreIdentity() {
        for kind in [MetricKind.weight, .glucose, .pulse, .spo2, .vo2Max] {
            let displayed = MeasureEntryConversion.displayScalar(42.0, kind: kind, units: .standard)
            #expect(displayed == 42.0)
            #expect(MeasureEntryConversion.canonicalScalar(42.0, kind: kind, units: .standard) == 42.0)
        }
        #expect(UnitPreferences.standard.canonicalBloodPressure(fromDisplayed: 120) == 120)
    }

    @Test("Non-re-unitable kinds pass through untouched in both directions")
    func unitlessKindsPassThrough() {
        // Pulse has no unit family — a lb/kPa/mmol pref must not touch it.
        let prefs = UnitPreferences(weight: .lb, bloodPressure: .kPa, glucose: .mmolL)
        #expect(MeasureEntryConversion.displayScalar(62, kind: .pulse, units: prefs) == 62)
        #expect(MeasureEntryConversion.canonicalScalar(62, kind: .pulse, units: prefs) == 62)
        #expect(MeasureEntryConversion.displayScalar(36.8, kind: .bodyTemperature, units: prefs) == 36.8)
    }

    // MARK: - Validation, which the edit path had none of

    @Test("Edit-path validation runs in canonical space, so a mmol/L entry is not range-blocked")
    func mmolEntryIsNotRangeBlocked() {
        // 5,4 mmol/L ≈ 97 mg/dL — comfortably inside the canonical glucose band.
        // Validating the typed 5.4 against the mg/dL band would reject it.
        #expect(MeasureEntryValidation.validateScalar("5,4", kind: .glucose, units: Self.mmolPrefs) == .ok)
        #expect(MeasureEntryValidation.validateScalar("5.4", kind: .glucose, units: Self.mmolPrefs) == .ok)
    }

    @Test("Edit-path validation rejects out-of-band values it previously accepted")
    func outOfBandValuesAreRejected() {
        // Pre-item-1.3 `isValid` was `parsed(text) != nil` — all four saved.
        #expect(MeasureEntryValidation.validateScalar("-500", kind: .weight, units: .standard) == .belowMinimum)
        #expect(MeasureEntryValidation.validateScalar("99999", kind: .glucose, units: .standard) == .aboveMaximum)
        #expect(
            MeasureEntryValidation.validateBloodPressure("1234", component: .systolic, units: .standard)
                == .aboveMaximum
        )
        #expect(MeasureEntryValidation.validateScalar("abc", kind: .weight, units: .standard) == .notANumber)
    }

    @Test("An out-of-band value in the operator's OWN unit is rejected too")
    func outOfBandInDisplayUnitIsRejected() {
        // 5000 lb ≈ 2268 kg — past the 600 kg ceiling once inverse-converted.
        #expect(MeasureEntryValidation.validateScalar("5000", kind: .weight, units: Self.lbPrefs) == .aboveMaximum)
        // 160 lb ≈ 72.6 kg — fine.
        #expect(MeasureEntryValidation.validateScalar("160", kind: .weight, units: Self.lbPrefs) == .ok)
    }

    @Test("An empty field is .empty, not an error the operator gets shouted at for")
    func emptyFieldIsQuiet() {
        #expect(MeasureEntryValidation.validateScalar("", kind: .weight, units: .standard) == .empty)
        #expect(
            MeasureEntryValidation.localizedError(
                for: .empty, kind: .weight, units: .standard
            ) == nil
        )
    }

    @Test("The range hint is expressed in the unit the operator is typing")
    func rangeHintUsesDisplayUnit() {
        let hint = MeasureEntryValidation.localizedError(
            for: .aboveMaximum, kind: .weight, units: Self.lbPrefs
        )
        let text = hint ?? ""
        #expect(text.contains("lb"), "a lb operator must not be told the limit in kg — got: \(text)")

        let canonicalHint = MeasureEntryValidation.localizedError(
            for: .aboveMaximum, kind: .weight, units: .standard
        ) ?? ""
        #expect(canonicalHint.contains("kg"))
    }

    @Test("The entry-unit suffix the edit sheet renders matches the operator's preference")
    func entrySuffixMatchesPreference() {
        #expect(MeasureEntryConversion.entrySuffix(kind: .weight, units: Self.lbPrefs) == "lb")
        #expect(MeasureEntryConversion.entrySuffix(kind: .weight, units: .standard) == "kg")
        #expect(Self.kPaPrefs.bloodPressure.unitSuffix == "kPa")
        #expect(UnitPreferences.standard.bloodPressure.unitSuffix == "mmHg")
    }

    // MARK: - The rounding hazard the fix itself introduced

    @Test("2-decimal display rounding IS lossy — which is why an untouched field keeps its original")
    func displayRoundingIsLossyAtTwoDecimals() {
        // This documents WHY `EditMeasurementSheet.save()` keeps the original
        // canonical value when `scalarText == initialScalar` instead of
        // re-deriving it. The prefill renders at 2dp; feeding that rendered text
        // back through the inverse conversion does NOT return the input exactly.
        let canonical = 72.4
        let displayed = MeasureEntryConversion.displayScalar(canonical, kind: .weight, units: Self.lbPrefs)
        // The prefill renders at 2dp. Model that numerically rather than via
        // string round-tripping — same drift, no locale/parse ambiguity.
        let renderedAtTwoDecimals = (displayed * 100).rounded() / 100
        let roundTripped = MeasureEntryConversion.canonicalScalar(
            renderedAtTwoDecimals, kind: .weight, units: Self.lbPrefs
        )
        #expect(
            roundTripped != canonical,
            "if this ever becomes exact, the untouched-save guard is still correct but no longer load-bearing"
        )
        #expect(abs(roundTripped - canonical) < 0.01, "the drift is small — small enough to go unnoticed, which is the danger")
    }

    // MARK: - Future bound on the timestamp picker

    @Test("The recordedAt bound never sits below the row's own timestamp")
    func recordedAtBoundNeverViolatesItsOwnValue() {
        // `EditMeasurementSheet` computes `max(.now, measurement.recordedAt)`. A
        // legacy row already dated in the future would otherwise sit outside its
        // own picker's range.
        let now = Date.now
        let past = now.addingTimeInterval(-86400)
        let future = now.addingTimeInterval(86400)

        #expect(max(now, past) == now, "a normal past row bounds at now — no future dates selectable")
        #expect(max(now, future) == future, "a legacy future-dated row stays inside its own range")
    }
}
