import Foundation

/// **v0.5.5.2 — per-kind sane-input ranges for the manual MeasureSheet.**
///
/// Before this helper, the operator could type `-500` weight or `99999`
/// glucose into the sheet, hit Speichern, and the server would 422 with
/// no inline feedback (W-FUNCTION-SMOKE-AUDIT finding). We now refuse
/// the input client-side and surface a localised "Wert ausserhalb des
/// sinnvollen Bereichs" message under the field — the submit button
/// stays disabled until the operator either clears the field or types a
/// value inside the range.
///
/// The bounds are intentionally *forgiving* — they catch typos and
/// fat-fingered swipes, not "is the patient hypoglycaemic" calls. Range
/// values stay in the user's locale via `formatRange(for:)`, which
/// emits a `Foundation.NumberFormatter`-driven string ("0,1 – 600,0" in
/// de-DE, "0.1 – 600.0" in en-US).
public enum MeasurementRanges {
    /// Sentinel returned by `validate(value:for:)` when the input parses
    /// but lands outside the per-kind range. The caller renders the
    /// localised "ausserhalb des Bereichs" copy via `localizedError(for:)`.
    public enum ValidationOutcome: Equatable {
        /// Field is empty or whitespace — submit-button stays disabled
        /// but no inline error renders (matches the displayName "first
        /// edit" gate's UX vocabulary).
        case empty
        /// Value parses + is inside the range. Submit may proceed.
        case ok
        /// Value parses but is below the per-kind lower bound.
        case belowMinimum
        /// Value parses but is above the per-kind upper bound.
        case aboveMaximum
        /// Value does not parse as a number at all.
        case notANumber
    }

    /// Pickable range per `MetricKind`. Returns `nil` for kinds we don't
    /// guard yet (Sleep, BMI, walking metrics — those either come from
    /// HK exclusively or have no medically-meaningful "wrong" range
    /// against typo-input). The caller treats `nil` as "skip validation".
    static func range(for kind: MetricKind) -> ClosedRange<Double>? {
        switch kind {
        case .weight: 0.1 ... 600
        case .bodyFat: 1 ... 70
        case .pulse: 30 ... 250
        case .restingHeartRate: 30 ... 250
        case .bodyTemperature: 30 ... 45
        case .spo2: 50 ... 100
        case .glucose: 20 ... 800
        case .bodyWater: 1 ... 100
        case .boneMass: 0.5 ... 10
        case .hrv: 1 ... 500
        case .vo2Max: 10 ... 90
        case .respiratoryRate: respiratoryRate
        // v0158 — v1.25 manual clinical signals. Bounds mirror the server sane
        // bands (`src/lib/validations/measurement.ts` L580-587). Pain NRS is a
        // 0–10 integer; the MeasureSheet enforces the integer via a picker, this
        // range is the belt-and-braces submit guard.
        case .painNRS: 0 ... 10
        case .gripStrength: 0 ... 120
        case .waistCircumference: 30 ... 250
        case .bloodPressure, .sleep, .steps, .walkingSpeed, .walkingAsymmetry,
             .walkingStepLength, .walkingDoubleSupport, .walkingSteadiness,
             .audioExposureEnvironment, .audioExposureHeadphone, .bmi,
             // v0.8.3 W-D — HK-only activity aggregates, no manual typo guard.
             .activeEnergy, .flightsClimbed, .distanceWalkingRunning, .timeInDaylight,
             // v0.11 W21 — server/Withings-sourced web-parity kinds; no manual
             // entry surface, so no typo guard needed.
             .fatFreeMass, .leanBodyMass, .muscleMass, .skinTemperature,
             .pulseWaveVelocity, .vascularAge, .visceralFat, .walkingHeartRate,
             .fatMass,
             // v0.13.1 IC — v1.10.0 additive signals; read/display-only, no
             // manual entry, so no typo guard.
             .falls, .sixMinuteWalk, .stairAscentSpeed, .stairDescentSpeed,
             .breathingDisturbances, .cardioRecovery, .wristTemperature,
             // v0.14.6 — v1.12.8 WHOOP-native read-only types; no manual entry.
             .averageHeartRate, .maxHeartRate, .sleepDisturbanceCount,
             // v0.14.1 W-B189 — v1.17.1 source-fixed render-only signals (#23);
             // read/display-only, no manual entry, so no typo guard.
             .ansCharge, .cardioLoad, .sleepScore, .bodyTemperatureDeviation,
             // v0158 — waist-to-height is render-only (no manual entry), so no
             // client-side typo guard is needed.
             .waistToHeight,
             // Build 3 / item 3.3 — the 21 decoder catch-up types are
             // read/display-only (no manual-entry surface), so no client-side
             // typo guard is needed.
             .phq9Score, .gad7Score, .who5Score, .sciScore,
             .recoveryScore, .stressScore, .strainScore, .hrvRMSSD,
             .dayStrain, .workoutStrain, .sleepPerformance, .sleepEfficiency,
             .sleepConsistency, .sleepNeed, .energyExpenditureKJ, .resilience,
             .irregularRhythmNotification, .highHeartRateEvent, .lowHeartRateEvent,
             .walkingSteadinessEvent, .breathingDisturbanceEvent,
             // Build 7 / item 7.3 — mood has no manual MeasureSheet entry (it is
             // logged via its own State-of-Mind flow), so no typo guard applies.
             .mood:
            nil
        }
    }

    /// Blood-pressure systolic bound. The MeasureSheet runs this against
    /// the *systolic* text-field when `kind == .bloodPressure`.
    static let bloodPressureSystolic: ClosedRange<Double> = 50 ... 260

    /// Blood-pressure diastolic bound. Mirrors `bloodPressureSystolic`
    /// but with the lower clinical floor + upper hypertension ceiling.
    static let bloodPressureDiastolic: ClosedRange<Double> = 30 ... 180

    /// Respiratory rate (breaths / min). Reserved for the future
    /// `.respiratoryRate` MetricKind cutover (currently on the legacy
    /// HK anchor path, see `PROJECT_GUIDE.md` Phase A note). Kept here as the
    /// single source of truth so the cutover lands without a magic-
    /// numbers hunt.
    static let respiratoryRate: ClosedRange<Double> = 4 ... 60

    /// Validate the raw text input against the per-kind range. Handles
    /// both `.` and `,` as decimal separators so de-DE users can paste
    /// "72,4" without the field bouncing.
    static func validate(value: String, for kind: MetricKind) -> ValidationOutcome {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .empty }
        // A360-5 H-4 — locale-aware parse (de "72,4" + grouped "1.234,5").
        guard let number = LocaleDecimalParser.parse(trimmed) else { return .notANumber }
        guard let range = range(for: kind) else { return .ok }
        if number < range.lowerBound { return .belowMinimum }
        if number > range.upperBound { return .aboveMaximum }
        return .ok
    }

    /// Validate one half of a blood-pressure pair. The MeasureSheet
    /// passes the systolic + diastolic strings through this separately
    /// so each gets its own inline error label below the field.
    static func validateBloodPressure(
        value: String,
        component: BloodPressureComponent
    ) -> ValidationOutcome {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .empty }
        // A360-5 H-4 — locale-aware parse (de comma decimal + grouping).
        guard let number = LocaleDecimalParser.parse(trimmed) else { return .notANumber }
        let range = component == .systolic ? bloodPressureSystolic : bloodPressureDiastolic
        if number < range.lowerBound { return .belowMinimum }
        if number > range.upperBound { return .aboveMaximum }
        return .ok
    }

    /// Locale-aware range copy for the inline error label. Uses
    /// `Foundation.NumberFormatter` so de-DE renders "0,1 – 600,0" and
    /// en-US renders "0.1 – 600.0" without us hand-rolling separators.
    static func formatRange(_ range: ClosedRange<Double>, unit: String) -> String {
        let formatter = NumberFormatter()
        formatter.locale = .current
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        let lo = formatter.string(from: NSNumber(value: range.lowerBound)) ?? "\(range.lowerBound)"
        let hi = formatter.string(from: NSNumber(value: range.upperBound)) ?? "\(range.upperBound)"
        if unit.isEmpty {
            return "\(lo) – \(hi)"
        }
        return "\(lo) – \(hi) \(unit)"
    }

    /// Localised error string for the outcome + kind, ready to render
    /// under the field. Returns `nil` for `.ok` and `.empty`, matching
    /// the UI's "show error only when the value is invalid AND present"
    /// rule.
    static func localizedError(
        for outcome: ValidationOutcome,
        kind: MetricKind,
        component: BloodPressureComponent? = nil
    ) -> String? {
        switch outcome {
        case .ok, .empty:
            return nil
        case .notANumber:
            return String(localized: "Please enter a number.")
        case .belowMinimum, .aboveMaximum:
            let unit = kind.unit
            let rangeText: String
            if let component {
                let bpRange = component == .systolic ? bloodPressureSystolic : bloodPressureDiastolic
                rangeText = formatRange(bpRange, unit: unit)
            } else if let range = range(for: kind) {
                rangeText = formatRange(range, unit: unit)
            } else {
                return nil
            }
            return String(
                format: String(localized: "Value outside the expected range (%@)."),
                rangeText
            )
        }
    }

    public enum BloodPressureComponent {
        case systolic
        case diastolic
    }
}
