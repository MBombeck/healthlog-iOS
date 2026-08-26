@testable import HealthLog
import Testing

/// **v0.5.5.2 — MeasureSheetView per-kind range validation.**
///
/// Before this fix the MeasureSheet's submit-gate only checked
/// `Double(input) != nil`. A `-500` weight or a `99999` glucose passed
/// the client check, hit the server, came back as 422, and the operator
/// never saw inline feedback (PROJECT_GUIDE.md anti-pattern: "Silent error
/// swallowing").
///
/// The `MeasurementRanges` helper now owns the per-kind sane bounds. The
/// view threads its raw text input through `validate(value:for:)` (or
/// the BP-specific component variant) and refuses submit until the
/// outcome lands on `.ok`. These tests pin the bounds + outcome mapping
/// per kind — three cases per kind (below-min / in-range / above-max)
/// so a future tweak to a bound trips the test rather than ships.
@Suite("MeasureSheetView — per-kind range validation (v0.5.5.2)")
struct MeasureSheetRangeValidationTests {
    // MARK: - Scalar kinds

    @Test("Weight: -1 below min, 72.4 in range, 999 above max")
    func weightRange() {
        #expect(MeasurementRanges.validate(value: "-1", for: .weight) == .belowMinimum)
        #expect(MeasurementRanges.validate(value: "72,4", for: .weight) == .ok)
        #expect(MeasurementRanges.validate(value: "999", for: .weight) == .aboveMaximum)
        #expect(MeasurementRanges.range(for: .weight) == 0.1 ... 600)
    }

    @Test("BodyFat: 0 below min, 22.5 in range, 99 above max")
    func bodyFatRange() {
        #expect(MeasurementRanges.validate(value: "0", for: .bodyFat) == .belowMinimum)
        #expect(MeasurementRanges.validate(value: "22.5", for: .bodyFat) == .ok)
        #expect(MeasurementRanges.validate(value: "99", for: .bodyFat) == .aboveMaximum)
        #expect(MeasurementRanges.range(for: .bodyFat) == 1 ... 70)
    }

    @Test("Pulse: 20 below min, 72 in range, 300 above max")
    func pulseRange() {
        #expect(MeasurementRanges.validate(value: "20", for: .pulse) == .belowMinimum)
        #expect(MeasurementRanges.validate(value: "72", for: .pulse) == .ok)
        #expect(MeasurementRanges.validate(value: "300", for: .pulse) == .aboveMaximum)
        #expect(MeasurementRanges.range(for: .pulse) == 30 ... 250)
    }

    @Test("BodyTemperature: 25 below min, 36.8 in range, 50 above max")
    func bodyTemperatureRange() {
        #expect(MeasurementRanges.validate(value: "25", for: .bodyTemperature) == .belowMinimum)
        #expect(MeasurementRanges.validate(value: "36.8", for: .bodyTemperature) == .ok)
        #expect(MeasurementRanges.validate(value: "50", for: .bodyTemperature) == .aboveMaximum)
        #expect(MeasurementRanges.range(for: .bodyTemperature) == 30 ... 45)
    }

    @Test("Spo2: 40 below min, 98 in range, 150 above max")
    func spo2Range() {
        #expect(MeasurementRanges.validate(value: "40", for: .spo2) == .belowMinimum)
        #expect(MeasurementRanges.validate(value: "98", for: .spo2) == .ok)
        #expect(MeasurementRanges.validate(value: "150", for: .spo2) == .aboveMaximum)
        #expect(MeasurementRanges.range(for: .spo2) == 50 ... 100)
    }

    @Test("Glucose: 10 below min, 92 in range, 9999 above max")
    func glucoseRange() {
        #expect(MeasurementRanges.validate(value: "10", for: .glucose) == .belowMinimum)
        #expect(MeasurementRanges.validate(value: "92", for: .glucose) == .ok)
        #expect(MeasurementRanges.validate(value: "9999", for: .glucose) == .aboveMaximum)
        #expect(MeasurementRanges.range(for: .glucose) == 20 ... 800)
    }

    @Test("RestingHeartRate: 25 below min, 55 in range, 260 above max")
    func restingHeartRateRange() {
        #expect(MeasurementRanges.validate(value: "25", for: .restingHeartRate) == .belowMinimum)
        #expect(MeasurementRanges.validate(value: "55", for: .restingHeartRate) == .ok)
        #expect(MeasurementRanges.validate(value: "260", for: .restingHeartRate) == .aboveMaximum)
    }

    // MARK: - Blood-pressure pair

    @Test("BP systolic: 40 below min, 120 in range, 300 above max")
    func bpSystolicRange() {
        #expect(MeasurementRanges.validateBloodPressure(value: "40", component: .systolic) == .belowMinimum)
        #expect(MeasurementRanges.validateBloodPressure(value: "120", component: .systolic) == .ok)
        #expect(MeasurementRanges.validateBloodPressure(value: "300", component: .systolic) == .aboveMaximum)
        #expect(MeasurementRanges.bloodPressureSystolic == 50 ... 260)
    }

    @Test("BP diastolic: 20 below min, 80 in range, 250 above max")
    func bpDiastolicRange() {
        #expect(MeasurementRanges.validateBloodPressure(value: "20", component: .diastolic) == .belowMinimum)
        #expect(MeasurementRanges.validateBloodPressure(value: "80", component: .diastolic) == .ok)
        #expect(MeasurementRanges.validateBloodPressure(value: "250", component: .diastolic) == .aboveMaximum)
        #expect(MeasurementRanges.bloodPressureDiastolic == 30 ... 180)
    }

    // MARK: - Empty + parse-fail outcomes

    @Test("Empty input returns .empty (no error rendered, submit stays disabled)")
    func emptyInput() {
        #expect(MeasurementRanges.validate(value: "", for: .weight) == .empty)
        #expect(MeasurementRanges.validate(value: "   ", for: .weight) == .empty)
        #expect(MeasurementRanges.validateBloodPressure(value: "", component: .systolic) == .empty)
    }

    @Test("Non-numeric input returns .notANumber")
    func nonNumericInput() {
        #expect(MeasurementRanges.validate(value: "abc", for: .weight) == .notANumber)
        #expect(MeasurementRanges.validate(value: "12.3.4", for: .weight) == .notANumber)
    }

    @Test("Decimal comma accepted (de-DE input convention)")
    func decimalCommaAccepted() {
        #expect(MeasurementRanges.validate(value: "72,4", for: .weight) == .ok)
        #expect(MeasurementRanges.validate(value: "36,8", for: .bodyTemperature) == .ok)
    }

    // MARK: - Localised error copy

    @Test("Localised error renders 'Wert ausserhalb des sinnvollen Bereichs (...)' when out of range")
    func localizedErrorRangeCopy() {
        let msg = MeasurementRanges.localizedError(
            for: .aboveMaximum,
            kind: .weight
        )
        #expect(msg?.hasPrefix(String(localized: "Wert außerhalb des sinnvollen Bereichs (").prefix(8)) == true)
    }

    @Test("Localised error renders 'Bitte eine Zahl eingeben.' for non-numeric input")
    func localizedErrorNonNumeric() {
        let msg = MeasurementRanges.localizedError(
            for: .notANumber,
            kind: .weight
        )
        #expect(msg == String(localized: "Please enter a number."))
    }

    @Test("Localised error returns nil for .ok + .empty (no premature shouting)")
    func localizedErrorSuppressed() {
        #expect(MeasurementRanges.localizedError(for: .ok, kind: .weight) == nil)
        #expect(MeasurementRanges.localizedError(for: .empty, kind: .weight) == nil)
    }

    // MARK: - Format helper

    @Test("formatRange uses current locale for separators + appends the unit")
    func formatRangeRoundTrip() {
        let formatted = MeasurementRanges.formatRange(0.1 ... 600, unit: "kg")
        // We don't assert the exact separator (locale-dependent in CI),
        // but both endpoints + unit + dash must surface.
        #expect(formatted.contains("0"))
        #expect(formatted.contains("600"))
        #expect(formatted.contains("kg"))
        #expect(formatted.contains("–"))
    }

    @Test("formatRange omits the unit when empty (e.g. steps)")
    func formatRangeNoUnit() {
        let formatted = MeasurementRanges.formatRange(1 ... 10, unit: "")
        #expect(formatted.contains("1"))
        #expect(formatted.contains("10"))
        #expect(formatted.contains("–"))
        // No trailing space when unit is empty.
        #expect(formatted.hasSuffix(" ") == false)
    }
}
