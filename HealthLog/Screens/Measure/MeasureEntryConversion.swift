import Foundation

// MARK: - Entry-path inverse unit conversion (audit v0162 H-5)

//
// The DISPLAY path converts canonical SI → the user's preferred unit everywhere
// (tiles, charts, list rows) via `UnitPreferences.convert*`, routed on
// `MetricKind.unitFamily`. Before this fix the ENTRY path (`MeasureSheetView`)
// stored the typed number VERBATIM as canonical and validated it against
// canonical-unit ranges. So a user whose unit preference is non-default silently
// corrupted the store: weight typed in lb landed ×2.2 too high as kg (and
// mirrored wrong into HealthKit); glucose in mmol/L was range-blocked and
// un-loggable (5.5 < 20 mg/dL). This is silent PHI corruption.
//
// This seam is the exact INVERSE of the display path. It reuses the SAME factor
// constants the forward `UnitPreferences.convert*` methods use (dividing where
// they multiply) and the SAME `unitFamily` routing, so the two directions can
// never drift. It lives beside `MeasureSheetView` (app target only) and is a
// pure, unit-testable transform — no SwiftUI render context required.

extension UnitPreferences {
    /// Inverse of ``convertWeight(_:)`` — a displayed weight-family value (kg or
    /// lb, per the user's pref) back to canonical kg. Divides by the SAME factor
    /// the forward path multiplies by.
    func canonicalWeight(fromDisplayed displayed: Double) -> Double {
        switch weight {
        case .kg: displayed
        case .lb: displayed / Self.kgToLb
        }
    }

    /// Inverse of ``convertBloodPressure(_:)`` — displayed mmHg/kPa back to
    /// canonical mmHg.
    func canonicalBloodPressure(fromDisplayed displayed: Double) -> Double {
        switch bloodPressure {
        case .mmHg: displayed
        case .kPa: displayed / Self.mmHgToKPa
        }
    }

    /// Inverse of ``convertGlucose(_:)`` — displayed mg/dL / mmol/L back to
    /// canonical mg/dL. Divides by `mgdLToMmolL` (= 1/18.0182), i.e. multiplies
    /// by 18.0182, reusing the forward constant so the round-trip is exact.
    func canonicalGlucose(fromDisplayed displayed: Double) -> Double {
        switch glucose {
        case .mgdL: displayed
        case .mmolL: displayed / Self.mgdLToMmolL
        }
    }
}

/// Pure entry-path conversions keyed on the SAME `MetricKind.unitFamily` routing
/// the display formatters use, so weight/body-water/bone-mass, blood-pressure,
/// and glucose all inverse-convert consistently with how they render.
enum MeasureEntryConversion {
    /// Convert a single displayed scalar value into its canonical unit for
    /// `kind`. Non-re-unitable kinds pass through unchanged.
    static func canonicalScalar(_ displayed: Double, kind: MetricKind, units: UnitPreferences) -> Double {
        switch kind.unitFamily {
        case .weight: units.canonicalWeight(fromDisplayed: displayed)
        case .glucose: units.canonicalGlucose(fromDisplayed: displayed)
        // Blood-pressure never reaches the scalar path (it uses the paired
        // systolic/diastolic fields), but route it correctly for completeness.
        case .bloodPressure: units.canonicalBloodPressure(fromDisplayed: displayed)
        case .none: displayed
        }
    }

    /// Forward-convert a stored canonical scalar into the unit the operator is
    /// typing in — the exact inverse of ``canonicalScalar(_:kind:units:)``.
    ///
    /// Build 1 / item 1.3: the EDIT sheet prefills from a stored measurement,
    /// which is canonical. Without this the sheet showed "72,4 kg" to an operator
    /// whose every other surface says "159,6 lb" — self-consistent, but a standing
    /// invitation to retype 159,6 into a field the save path treats as kg.
    static func displayScalar(_ canonical: Double, kind: MetricKind, units: UnitPreferences) -> Double {
        switch kind.unitFamily {
        case .weight: units.convertWeight(canonical)
        case .glucose: units.convertGlucose(canonical)
        case .bloodPressure: units.convertBloodPressure(canonical)
        case .none: canonical
        }
    }

    /// Forward-convert a canonical range's bounds into the displayed unit, so an
    /// out-of-range hint reads in the unit the operator is actually typing.
    static func displayRange(
        _ range: ClosedRange<Double>,
        kind: MetricKind,
        units: UnitPreferences
    ) -> ClosedRange<Double> {
        switch kind.unitFamily {
        case .weight: units.convertWeight(range.lowerBound) ... units.convertWeight(range.upperBound)
        case .glucose: units.convertGlucose(range.lowerBound) ... units.convertGlucose(range.upperBound)
        case .bloodPressure:
            units.convertBloodPressure(range.lowerBound) ... units.convertBloodPressure(range.upperBound)
        case .none: range
        }
    }

    /// The unit suffix the operator is currently typing in for `kind` — the same
    /// suffix the display surfaces show, so entry + read agree.
    static func entrySuffix(kind: MetricKind, units: UnitPreferences) -> String {
        MetricValueFormatter.unitSuffix(for: kind, units: units)
    }
}

/// Canonical-space validation for the entry path. Parses the displayed string,
/// inverse-converts to canonical, then checks it against the canonical range in
/// ``MeasurementRanges`` (whose bounds are in SI units). This keeps the range
/// math in the SAME unit space as the value we store.
enum MeasureEntryValidation {
    /// Validate a single scalar field. Mirrors ``MeasurementRanges/validate(value:for:)``
    /// but converts to canonical first.
    static func validateScalar(
        _ raw: String,
        kind: MetricKind,
        units: UnitPreferences
    ) -> MeasurementRanges.ValidationOutcome {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .empty }
        guard let displayed = LocaleDecimalParser.parse(trimmed) else { return .notANumber }
        let canonical = MeasureEntryConversion.canonicalScalar(displayed, kind: kind, units: units)
        guard let range = MeasurementRanges.range(for: kind) else { return .ok }
        if canonical < range.lowerBound { return .belowMinimum }
        if canonical > range.upperBound { return .aboveMaximum }
        return .ok
    }

    /// Validate one leg of a blood-pressure pair against the canonical mmHg band.
    static func validateBloodPressure(
        _ raw: String,
        component: MeasurementRanges.BloodPressureComponent,
        units: UnitPreferences
    ) -> MeasurementRanges.ValidationOutcome {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .empty }
        guard let displayed = LocaleDecimalParser.parse(trimmed) else { return .notANumber }
        let canonical = units.canonicalBloodPressure(fromDisplayed: displayed)
        let range = component == .systolic
            ? MeasurementRanges.bloodPressureSystolic
            : MeasurementRanges.bloodPressureDiastolic
        if canonical < range.lowerBound { return .belowMinimum }
        if canonical > range.upperBound { return .aboveMaximum }
        return .ok
    }

    /// Localised range-hint copy, expressed in the unit the operator is typing.
    /// Reuses the existing xcstrings keys ("Please enter a number." + "Value
    /// outside the expected range (%@).") — no new localisation keys added.
    static func localizedError(
        for outcome: MeasurementRanges.ValidationOutcome,
        kind: MetricKind,
        component: MeasurementRanges.BloodPressureComponent? = nil,
        units: UnitPreferences
    ) -> String? {
        switch outcome {
        case .ok, .empty:
            return nil
        case .notANumber:
            return String(localized: "Please enter a number.")
        case .belowMinimum, .aboveMaximum:
            let suffix = MeasureEntryConversion.entrySuffix(kind: kind, units: units)
            let canonicalRange: ClosedRange<Double>
            if let component {
                canonicalRange = component == .systolic
                    ? MeasurementRanges.bloodPressureSystolic
                    : MeasurementRanges.bloodPressureDiastolic
            } else if let range = MeasurementRanges.range(for: kind) {
                canonicalRange = range
            } else {
                return nil
            }
            let displayRange = MeasureEntryConversion.displayRange(canonicalRange, kind: kind, units: units)
            let rangeText = MeasurementRanges.formatRange(displayRange, unit: suffix)
            return String(
                format: String(localized: "Value outside the expected range (%@)."),
                rangeText
            )
        }
    }
}
