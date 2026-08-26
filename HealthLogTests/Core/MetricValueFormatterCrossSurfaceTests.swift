import Foundation
@testable import HealthLog
import Testing

/// A360-5 C-1/C-2 — locks the cross-surface unit-conversion contract: every
/// drill-down surface (list rows, chrono feed, chart hero, scrub callout, stats
/// row) routes through `MetricValueFormatter` so it renders the SAME number +
/// unit as the dashboard tile, in the user's chosen unit.
///
/// Two invariants under test:
///   1. A NON-default-unit user (lb / kPa / mmol/L) sees the SAME converted
///      value across every surface (no drift between detail/list/chart/callout/
///      stats).
///   2. A DEFAULT-unit user (kg / mmHg / mg/dL) sees the canonical value
///      unchanged from before the fix (no regression).
@Suite("MetricValueFormatter cross-surface consistency (A360-5)")
struct MetricValueFormatterCrossSurfaceTests {
    private typealias M = HealthLog.Measurement

    /// Decimal-separator-agnostic expectation: format through the SAME
    /// FormatStyle the production formatter uses so the test passes in any locale.
    private func oneDP(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(1)))
    }

    private func scalar(_ kind: MetricKind, _ v: Double) -> M {
        M(id: "m", kind: kind, recordedAt: .now, value: .scalar(v), source: .manual)
    }

    private func bp(_ s: Double, _ d: Double) -> M {
        M(id: "bp", kind: .bloodPressure, recordedAt: .now, value: .bloodPressure(systolic: s, diastolic: d), source: .manual)
    }

    // MARK: - Default units → unchanged (no regression)

    @Test("weight kg user: list value matches the dashboard 1-dp value")
    func weightDefaultUnchanged() {
        let units = UnitPreferences.standard
        let metric = DashboardMetricFixture.weight(72.4)
        // Dashboard (ground truth) and the shared formatter agree on the number.
        #expect(MetricValueFormatter.formatScalar(72.4, kind: .weight, units: units) == metric.formattedPrimary(units: units))
        #expect(MetricValueFormatter.unitSuffix(for: .weight, units: units) == "kg")
    }

    @Test("glucose mg/dL user: integer, matches dashboard")
    func glucoseDefaultUnchanged() {
        let units = UnitPreferences.standard
        let metric = DashboardMetricFixture.glucose(100)
        #expect(MetricValueFormatter.formatScalar(100, kind: .glucose, units: units) == metric.formattedPrimary(units: units))
        #expect(MetricValueFormatter.formatScalar(100, kind: .glucose, units: units) == Int(100).formatted())
        #expect(MetricValueFormatter.unitSuffix(for: .glucose, units: units) == "mg/dL")
    }

    @Test("BP mmHg user: integer pair, matches dashboard")
    func bpDefaultUnchanged() {
        let units = UnitPreferences.standard
        let metric = DashboardMetricFixture.bp(systolic: 128, diastolic: 82)
        #expect(MetricValueFormatter.formatBloodPressure(systolic: 128, diastolic: 82, units: units) == "128/82")
        #expect(MetricValueFormatter.formatBloodPressure(systolic: 128, diastolic: 82, units: units) == metric
            .formattedPrimary(units: units))
    }

    // MARK: - Non-default units → converted, consistent across surfaces

    @Test("weight lb user: every surface renders the converted lb value")
    func weightLbConsistent() {
        let units = UnitPreferences(weight: .lb)
        let converted = oneDP(72.4 * UnitPreferences.kgToLb)
        // Dashboard tile (ground truth)
        #expect(DashboardMetricFixture.weight(72.4).formattedPrimary(units: units) == converted)
        // List row / chrono feed
        #expect(MetricValueFormatter.formattedValue(scalar(.weight, 72.4), units: units) == converted)
        // Chart hero / callout (series weight is canonical → convert)
        #expect(MetricValueFormatter.formatScalar(72.4, kind: .weight, units: units, glucose: .seriesPreConvertedGlucose) == converted)
        #expect(MetricValueFormatter.unitSuffix(for: .weight, units: units) == "lb")
    }

    @Test("glucose mmol/L user: list converts; series passes pre-converted through")
    func glucoseMmolConsistent() {
        let units = UnitPreferences(glucose: .mmolL)
        let converted = oneDP(100 / 18.0182)
        // Dashboard + list (canonical mg/dL source → convert)
        #expect(DashboardMetricFixture.glucose(100).formattedPrimary(units: units) == converted)
        #expect(MetricValueFormatter.formattedValue(scalar(.glucose, 100), units: units) == converted)
        // Chart series: server already converted → the SAME number must pass
        // through untouched (NOT double-converted).
        let preConverted = 100 / 18.0182
        #expect(MetricValueFormatter
            .formatScalar(preConverted, kind: .glucose, units: units, glucose: .seriesPreConvertedGlucose) == converted)
        // The double-convert hazard: canonical-mode on an already-converted value
        // would be WRONG (≈0.3), proving the flag matters.
        #expect(MetricValueFormatter.formatScalar(preConverted, kind: .glucose, units: units, glucose: .canonical) != converted)
        #expect(MetricValueFormatter.unitSuffix(for: .glucose, units: units) == "mmol/L")
    }

    @Test("BP kPa user: chart no longer hard-rounds to Int (C-2)")
    func bpKpaOneDecimal() {
        let units = UnitPreferences(bloodPressure: .kPa)
        let expSys = oneDP(128 * UnitPreferences.mmHgToKPa)
        let expDia = oneDP(82 * UnitPreferences.mmHgToKPa)
        let expected = "\(expSys)/\(expDia)"
        // Dashboard ground truth
        #expect(DashboardMetricFixture.bp(systolic: 128, diastolic: 82).formattedPrimary(units: units) == expected)
        // Chart hero / callout / stats (was "128/82" hard-rounded → now 1-dp kPa)
        #expect(MetricValueFormatter.formatBloodPressure(systolic: 128, diastolic: 82, units: units) == expected)
        // List value path agrees too
        #expect(MetricValueFormatter.formattedValue(bp(128, 82), units: units) == expected)
        // Concretely NOT the old integer rendering.
        #expect(MetricValueFormatter.formatBloodPressure(systolic: 128, diastolic: 82, units: units) != "128/82")
    }

    // MARK: - BH-final-diff H6 — whole-number weight matches dashboard EXACTLY

    @Test("weight kg user: a WHOLE number renders identically to the dashboard (no stray .0 drift)")
    func wholeWeightMatchesDashboard() {
        let units = UnitPreferences.standard
        let dashboard = DashboardMetricFixture.weight(80).formattedPrimary(units: units)
        // The dashboard canonical for weight is 1-dp. Every value surface must
        // render the SAME string — list/feed AND chart hero.
        #expect(MetricValueFormatter.formatScalar(80, kind: .weight, units: units) == dashboard)
        #expect(MetricValueFormatter.formattedValue(scalar(.weight, 80), units: units) == dashboard)
        #expect(
            MetricValueFormatter.formatScalar(80, kind: .weight, units: units, glucose: .seriesPreConvertedGlucose)
                == dashboard
        )
        // Concretely: the dashboard keeps ONE fraction digit on a whole number
        // (e.g. "80.0" / "80,0" depending on locale), so the list must NOT drop
        // to a bare integer ("80"). Assert the canonical 1-dp rendering matches
        // and is NOT the integer form — locale-agnostic (separator may be `,`).
        let oneDigit = 80.0.formatted(.number.precision(.fractionLength(1)))
        let bareInt = 80.formatted()
        #expect(dashboard == oneDigit)
        #expect(dashboard != bareInt)
    }

    // MARK: - Non-finite guard (W-CRASHGUARD parity)

    @Test("non-finite scalar renders em-dash, never traps")
    func nonFiniteSafe() {
        #expect(MetricValueFormatter.formatScalar(.nan, kind: .weight, units: .standard) == "—")
        #expect(MetricValueFormatter.formatBloodPressure(systolic: .infinity, diastolic: 80, units: .standard) == "—")
    }
}

/// Minimal `DashboardMetric` fixtures so the cross-surface tests can assert
/// against the canonical dashboard formatter (`formattedPrimary(units:)`).
private enum DashboardMetricFixture {
    static func weight(_ v: Double) -> DashboardMetric {
        make(.weight, latest: v)
    }

    static func glucose(_ v: Double) -> DashboardMetric {
        make(.glucose, latest: v)
    }

    static func bp(systolic: Double, diastolic: Double) -> DashboardMetric {
        make(.bloodPressure, latest: systolic, secondary: diastolic)
    }

    private static func make(_ kind: MetricKind, latest: Double, secondary: Double? = nil) -> DashboardMetric {
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
