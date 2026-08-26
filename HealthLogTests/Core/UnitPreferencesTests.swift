import Foundation
@testable import HealthLog
import Testing

/// v0.11 N1 — locks the display-unit conversion contract end-to-end:
/// pure conversion math (`UnitPreferences`), the `MetricKind.unitFamily`
/// routing, and the unit-aware formatters on `DashboardMetric`.
///
/// The server stores canonical SI units (kg / mmHg / mg/dL); these tests
/// assert the at-display-time conversion the dashboard surfaces apply.
@Suite("UnitPreferences conversion + formatting")
struct UnitPreferencesTests {
    // MARK: - Pure conversion math

    @Test("weight kg→lb factor")
    func weightConversion() {
        let lb = UnitPreferences(weight: .lb)
        #expect(abs(lb.convertWeight(100) - 220.46226218) < 0.0001)
        #expect(UnitPreferences(weight: .kg).convertWeight(72.4) == 72.4)
    }

    @Test("blood pressure mmHg→kPa factor")
    func bloodPressureConversion() {
        let kpa = UnitPreferences(bloodPressure: .kPa)
        #expect(abs(kpa.convertBloodPressure(120) - 15.9986864898) < 0.0001)
        #expect(UnitPreferences(bloodPressure: .mmHg).convertBloodPressure(80) == 80)
    }

    @Test("glucose mg/dL→mmol/L factor")
    func glucoseConversion() {
        let mmol = UnitPreferences(glucose: .mmolL)
        // 100 mg/dL ≈ 5.5507 mmol/L
        #expect(abs(mmol.convertGlucose(100) - 5.5507) < 0.001)
        #expect(UnitPreferences(glucose: .mgdL).convertGlucose(90) == 90)
    }

    // MARK: - Unit-family routing

    @Test("unit families map the re-unitable kinds")
    func unitFamilies() {
        #expect(MetricKind.weight.unitFamily == .weight)
        #expect(MetricKind.bodyWater.unitFamily == .weight)
        #expect(MetricKind.boneMass.unitFamily == .weight)
        #expect(MetricKind.bloodPressure.unitFamily == .bloodPressure)
        #expect(MetricKind.glucose.unitFamily == .glucose)
        #expect(MetricKind.steps.unitFamily == nil)
        #expect(MetricKind.pulse.unitFamily == nil)
    }

    // MARK: - Formatter output

    /// Decimal-separator-agnostic expectation: format the converted value
    /// through the same FormatStyle so the test passes under any locale.
    private func expected1dp(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }

    @Test("weight tile renders chosen unit + suffix")
    func weightFormatting() {
        let metric = Self.metric(kind: .weight, latest: 100)
        #expect(metric.formattedPrimary(units: .standard) == metric.formattedPrimary(units: UnitPreferences(weight: .kg)))
        #expect(metric.unitSuffix(units: UnitPreferences(weight: .kg)) == "kg")
        let lb = UnitPreferences(weight: .lb)
        // 100 kg → 220.46 lb, 1-decimal display.
        #expect(metric.formattedPrimary(units: lb) == expected1dp(220.46226218))
        #expect(metric.unitSuffix(units: lb) == "lb")
    }

    @Test("glucose tile is integer mg/dL, one-decimal mmol/L")
    func glucoseFormatting() {
        let metric = Self.metric(kind: .glucose, latest: 100)
        #expect(metric.formattedPrimary(units: UnitPreferences(glucose: .mgdL)) == Int(100).formatted())
        #expect(metric.unitSuffix(units: UnitPreferences(glucose: .mgdL)) == "mg/dL")
        let mmol = UnitPreferences(glucose: .mmolL)
        #expect(metric.formattedPrimary(units: mmol) == expected1dp(100 / 18.0182))
        #expect(metric.unitSuffix(units: mmol) == "mmol/L")
    }

    @Test("blood pressure compound converts both legs")
    func bloodPressureFormatting() {
        let metric = Self.metric(kind: .bloodPressure, latest: 120, secondary: 80)
        #expect(metric.formattedPrimary(units: UnitPreferences(bloodPressure: .mmHg)) == "120/80")
        #expect(metric.unitSuffix(units: UnitPreferences(bloodPressure: .mmHg)) == "mmHg")
        let kpa = UnitPreferences(bloodPressure: .kPa)
        let expSys = expected1dp(120 * UnitPreferences.mmHgToKPa)
        let expDia = expected1dp(80 * UnitPreferences.mmHgToKPa)
        #expect(metric.formattedPrimary(units: kpa) == "\(expSys)/\(expDia)")
        #expect(metric.unitSuffix(units: kpa) == "kPa")
    }

    @Test("non-re-unitable kind ignores prefs")
    func passthroughKind() {
        let metric = Self.metric(kind: .steps, latest: 8234)
        let weird = UnitPreferences(weight: .lb, bloodPressure: .kPa, glucose: .mmolL)
        #expect(metric.formattedPrimary(units: weird) == metric.formattedPrimary())
    }

    // MARK: - Fixture

    private static func metric(
        kind: MetricKind,
        latest: Double?,
        secondary: Double? = nil
    ) -> DashboardMetric {
        DashboardMetric(
            id: kind.rawValue,
            kind: kind,
            title: kind.rawValue,
            latestValue: latest,
            secondaryValue: secondary,
            unit: "",
            trend: .flat,
            sparkline: [],
            updatedAt: nil
        )
    }
}
