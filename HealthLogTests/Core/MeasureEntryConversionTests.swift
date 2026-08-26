import Foundation
@testable import HealthLog
import Testing

/// Audit v0162 H-5 — locks the **entry-path** inverse-unit conversion contract.
///
/// The DISPLAY path (`UnitPreferences.convert*`, routed via `MetricKind.unitFamily`)
/// turns canonical SI values into the user's preferred unit. Before this fix the
/// ENTRY path stored the typed number VERBATIM as canonical and validated it
/// against canonical-unit ranges — so a user on lb / kPa / mmol/L silently
/// corrupted the store (weight ×2.2 too high; glucose in mmol/L range-blocked).
///
/// These tests assert the inverse transform (`MeasureEntryConversion`) and the
/// canonical-space validation (`MeasureEntryValidation`) that `MeasureSheetView`
/// now applies before `store.capture` + range checks. Default-unit users see the
/// identity transform (byte-identical to the pre-fix behaviour).
@Suite("Measure entry inverse-unit conversion (audit H-5)")
struct MeasureEntryConversionTests {
    // MARK: - (a) weight pref = lb → canonical kg

    @Test("weight entered in lb is stored as canonical kg, not verbatim")
    func weightLbToCanonicalKg() {
        let units = UnitPreferences(weight: .lb)
        // 154 lb / 2.2046226218 ≈ 69.853 kg
        let canonical = MeasureEntryConversion.canonicalScalar(154, kind: .weight, units: units)
        #expect(abs(canonical - 69.853) < 0.01)
        // The pre-fix bug stored 154 verbatim — assert we do NOT.
        #expect(canonical < 100)
    }

    // MARK: - (b) glucose pref = mmol/L → canonical mg/dL, passes range

    @Test("glucose entered in mmol/L is stored as canonical mg/dL and passes range")
    func glucoseMmolToCanonicalMgdl() {
        let units = UnitPreferences(glucose: .mmolL)
        // 5.5 mmol/L * 18.0182 ≈ 99.10 mg/dL
        let canonical = MeasureEntryConversion.canonicalScalar(5.5, kind: .glucose, units: units)
        #expect(abs(canonical - 99.10) < 0.05)
        // Pre-fix: raw 5.5 validated as `belowMinimum` (5.5 < 20 mg/dL) → un-loggable.
        #expect(MeasureEntryValidation.validateScalar("5.5", kind: .glucose, units: units) == .ok)
    }

    // MARK: - Round-trip (enter in preferred → canonical → display back = original)

    @Test("weight round-trips lb → canonical kg → lb")
    func weightRoundTrip() {
        let units = UnitPreferences(weight: .lb)
        let entered = 154.0
        let canonical = MeasureEntryConversion.canonicalScalar(entered, kind: .weight, units: units)
        #expect(abs(units.convertWeight(canonical) - entered) < 0.0001)
    }

    @Test("glucose round-trips mmol/L → canonical mg/dL → mmol/L")
    func glucoseRoundTrip() {
        let units = UnitPreferences(glucose: .mmolL)
        let entered = 5.5
        let canonical = MeasureEntryConversion.canonicalScalar(entered, kind: .glucose, units: units)
        #expect(abs(units.convertGlucose(canonical) - entered) < 0.0001)
    }

    @Test("blood pressure round-trips kPa → canonical mmHg → kPa")
    func bloodPressureRoundTrip() {
        let units = UnitPreferences(bloodPressure: .kPa)
        let entered = 16.0
        let canonical = units.canonicalBloodPressure(fromDisplayed: entered)
        #expect(abs(units.convertBloodPressure(canonical) - entered) < 0.0001)
    }

    // MARK: - Blood pressure kPa entry

    @Test("blood pressure entered in kPa is stored as canonical mmHg and passes range")
    func bloodPressureKpaToCanonical() {
        let units = UnitPreferences(bloodPressure: .kPa)
        // 16 kPa / 0.133322387415 ≈ 120.01 mmHg
        let canonical = units.canonicalBloodPressure(fromDisplayed: 16.0)
        #expect(abs(canonical - 120.01) < 0.05)
        #expect(MeasureEntryValidation.validateBloodPressure("16.0", component: .systolic, units: units) == .ok)
    }

    // MARK: - Default units are the identity transform

    @Test("default units leave entry values untouched")
    func defaultUnitsIdentity() {
        let units = UnitPreferences.standard
        #expect(MeasureEntryConversion.canonicalScalar(72.4, kind: .weight, units: units) == 72.4)
        #expect(MeasureEntryConversion.canonicalScalar(92, kind: .glucose, units: units) == 92)
        #expect(units.canonicalBloodPressure(fromDisplayed: 120) == 120)
        #expect(MeasureEntryValidation.validateScalar("72,4", kind: .weight, units: units) == .ok)
    }

    // MARK: - Weight family siblings (body-water, bone-mass ride kg↔lb too)

    @Test("body-water + bone-mass inverse-convert on the weight family")
    func weightFamilySiblings() {
        let units = UnitPreferences(weight: .lb)
        #expect(abs(MeasureEntryConversion.canonicalScalar(154, kind: .bodyWater, units: units) - 69.853) < 0.01)
        // 11 lb / 2.2046226218 ≈ 4.9895 kg
        #expect(abs(MeasureEntryConversion.canonicalScalar(11, kind: .boneMass, units: units) - 4.9895) < 0.01)
    }

    // MARK: - Non-re-unitable kinds pass through untouched

    @Test("non-re-unitable kinds ignore unit prefs on entry")
    func passthrough() {
        let weird = UnitPreferences(weight: .lb, bloodPressure: .kPa, glucose: .mmolL)
        #expect(MeasureEntryConversion.canonicalScalar(62, kind: .pulse, units: weird) == 62)
        #expect(MeasureEntryConversion.canonicalScalar(8000, kind: .steps, units: weird) == 8000)
    }

    // MARK: - Range hint reads in the unit the operator is typing

    @Test("out-of-range hint is expressed in the entry unit, not the canonical unit")
    func rangeHintInEntryUnit() {
        let units = UnitPreferences(glucose: .mmolL)
        // 50 mmol/L ≈ 900 mg/dL → above the 20…800 mg/dL canonical band.
        let outcome = MeasureEntryValidation.validateScalar("50", kind: .glucose, units: units)
        #expect(outcome == .aboveMaximum)
        let msg = MeasureEntryValidation.localizedError(for: outcome, kind: .glucose, units: units)
        #expect(msg?.contains("mmol/L") == true)
        #expect(msg?.contains("mg/dL") == false)
    }
}
