import Foundation
@testable import HealthLog
import Testing

/// **#115 P2 — every convertible quantity reads in the account's unit.**
///
/// TestFlight 1.1.0 (284), en-US, imperial account: the dashboard weight tile
/// said "162.1 lb" and, under it, "Target 61.9–83.3 kg". The target payload is
/// canonical SI (server `target-unit-display.ts`, v1.39.5) and nothing on the
/// phone converted it. This suite pins the one account-unit transform
/// (`UnitPreferences.transform(for:)`) across every quantity × unit system, and
/// then every surface the P2 sweep routed through it.
///
/// Numbers are compared as numbers; text is compared against the same
/// FormatStyle the surface uses, so the suite holds in any test-host locale.
@Suite("#115 P2 — account unit across quantities × unit system")
struct AccountUnitDisplayTests {
    static let metric = UnitPreferences(weight: .kg, glucose: .mgdL, system: .metric)
    static let imperial = UnitPreferences(weight: .lb, glucose: .mmolL, system: .imperial)

    /// One convertible quantity: a canonical value, and what the metric and
    /// the imperial account read.
    struct Quantity: CustomTestStringConvertible, Sendable {
        let kind: MetricKind
        let canonical: Double
        let metricLabel: String
        let imperialValue: Double
        let imperialLabel: String
        var testDescription: String {
            kind.rawValue
        }
    }

    static let quantities: [Quantity] = [
        Quantity(kind: .weight, canonical: 73.5, metricLabel: "kg", imperialValue: 162.04, imperialLabel: "lb"),
        Quantity(kind: .bodyWater, canonical: 40, metricLabel: "kg", imperialValue: 88.18, imperialLabel: "lb"),
        Quantity(kind: .boneMass, canonical: 3.2, metricLabel: "kg", imperialValue: 7.05, imperialLabel: "lb"),
        Quantity(kind: .muscleMass, canonical: 30, metricLabel: "kg", imperialValue: 66.14, imperialLabel: "lb"),
        Quantity(kind: .fatMass, canonical: 15, metricLabel: "kg", imperialValue: 33.07, imperialLabel: "lb"),
        Quantity(kind: .fatFreeMass, canonical: 55, metricLabel: "kg", imperialValue: 121.25, imperialLabel: "lb"),
        Quantity(kind: .leanBodyMass, canonical: 55, metricLabel: "kg", imperialValue: 121.25, imperialLabel: "lb"),
        Quantity(kind: .gripStrength, canonical: 38, metricLabel: "kg", imperialValue: 83.78, imperialLabel: "lb"),
        Quantity(kind: .bodyTemperature, canonical: 37, metricLabel: "°C", imperialValue: 98.6, imperialLabel: "°F"),
        Quantity(kind: .skinTemperature, canonical: 33, metricLabel: "°C", imperialValue: 91.4, imperialLabel: "°F"),
        Quantity(kind: .wristTemperature, canonical: 35, metricLabel: "°C", imperialValue: 95, imperialLabel: "°F"),
        Quantity(kind: .waistCircumference, canonical: 84, metricLabel: "cm", imperialValue: 33.07, imperialLabel: "in"),
        Quantity(kind: .distanceWalkingRunning, canonical: 5000, metricLabel: "m", imperialValue: 3.107, imperialLabel: "mi"),
        Quantity(kind: .walkingSpeed, canonical: 1.3, metricLabel: "m/s", imperialValue: 2.908, imperialLabel: "mph"),
        Quantity(kind: .glucose, canonical: 90, metricLabel: "mg/dL", imperialValue: 4.995, imperialLabel: "mmol/L")
    ]

    // MARK: - The transform

    @Test("Metric: the exact identity, canonical label", arguments: quantities)
    func metricIsIdentity(_ q: Quantity) {
        #expect(Self.metric.displayValue(q.canonical, kind: q.kind) == q.canonical)
        #expect(Self.metric.unitLabel(for: q.kind) == q.metricLabel)
        #expect(Self.metric.canonicalValue(fromDisplayed: q.canonical, kind: q.kind) == q.canonical)
    }

    @Test("Imperial: converted value and label", arguments: quantities)
    func imperialConverts(_ q: Quantity) {
        #expect(abs(Self.imperial.displayValue(q.canonical, kind: q.kind) - q.imperialValue) < 0.01)
        #expect(Self.imperial.unitLabel(for: q.kind) == q.imperialLabel)
    }

    @Test("Imperial: typed value inverts back to canonical", arguments: quantities)
    func imperialRoundTrips(_ q: Quantity) {
        let shown = Self.imperial.displayValue(q.canonical, kind: q.kind)
        #expect(abs(Self.imperial.canonicalValue(fromDisplayed: shown, kind: q.kind) - q.canonical) < 1e-9)
    }

    @Test("A temperature DIFFERENCE takes the factor alone, never the +32")
    func temperatureDeltaIsFactorOnly() {
        #expect(abs(Self.imperial.displayDelta(0.5, kind: .bodyTemperature) - 0.9) < 1e-9)
        #expect(abs(Self.imperial.displayValue(0.5, kind: .bodyTemperatureDeviation) - 0.9) < 1e-9)
        #expect(Self.imperial.unitLabel(for: .bodyTemperatureDeviation) == "°F")
    }

    @Test("Kinds without a transform never convert", arguments: [MetricKind.pulse, .steps, .bodyFat, .spo2, .sleep, .bmi])
    func untransformedKindsPassThrough(_ kind: MetricKind) {
        #expect(Self.imperial.displayValue(42, kind: kind) == 42)
        #expect(Self.imperial.unitLabel(for: kind) == kind.unit)
    }

    // MARK: - Headline formatter (tile, list, hero, widget, watch glance)

    @Test("Headline text + suffix in the account's unit", arguments: quantities)
    func headlineFollowsAccount(_ q: Quantity) {
        let metric = DashboardMetric(
            id: q.kind.rawValue, kind: q.kind, title: "", latestValue: q.canonical, secondaryValue: nil,
            unit: "", trend: .flat, sparkline: [], updatedAt: nil
        )
        #expect(metric.unitSuffix(units: Self.imperial) == q.imperialLabel)
        // The number itself is pinned above; here the text must be that
        // number at the display unit's precision.
        let shown = Self.imperial.displayValue(q.canonical, kind: q.kind)
        let digits = Self.imperial.transform(for: q.kind).fractionDigits ?? 1
        let expected = digits == 0
            ? shown.safeServerIntString()
            : shown.formatted(.number.precision(.fractionLength(digits)))
        #expect(metric.formattedPrimary(units: Self.imperial) == expected)
    }
}

/// The screenshot: the tile's target band and every other target surface.
@Suite("#115 P2 — target bands in the account's unit")
struct AccountUnitTargetBandTests {
    private func targets(type: String, unit: String, min: Double, max: Double) -> InsightsTargetsResponseDTO {
        let item = InsightsTargetsResponseDTO.TargetItem(
            type: type, label: type, current: 73.5, average30: 73.2, trend: nil, unit: unit,
            range: .init(min: min, max: max), classification: nil, source: "profile",
            daysInRange7d: 7, daysLogged7d: 7, daysInRange30d: 30, daysLogged30d: 30,
            lastMetGoalAt: nil, streakDays: 3, insufficientData: false, consistency7d: []
        )
        return InsightsTargetsResponseDTO(
            targets: [item],
            pageSummary: .init(targetsMetThisWeek: 1, totalTargets: 1, streakHighlight: nil),
            bpDiastolic: nil,
            profile: nil
        )
    }

    private func label(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0 ... 1)))
    }

    @Test("TestFlight 284: imperial weight tile band reads lb, not kg")
    func weightTileBandImperial() throws {
        let band = try #require(DashboardTileTargetResolver.targetBand(
            for: .weight,
            targets: targets(type: "WEIGHT", unit: "kg", min: 61.9, max: 83.3),
            units: AccountUnitDisplayTests.imperial
        ))
        #expect(band.unit == "lb")
        #expect(band.lowerLabel == label(136.5))
        #expect(band.upperLabel == label(183.6))
        #expect(band.pctInRange == 100)
    }

    @Test("Metric weight tile band is unchanged")
    func weightTileBandMetric() throws {
        let band = try #require(DashboardTileTargetResolver.targetBand(
            for: .weight,
            targets: targets(type: "WEIGHT", unit: "kg", min: 61.9, max: 83.3),
            units: AccountUnitDisplayTests.metric
        ))
        #expect(band.unit == "kg")
        #expect(band.lowerLabel == label(61.9))
        #expect(band.upperLabel == label(83.3))
    }

    /// The glucose trap: the server stamps `unit` with the ACCOUNT's glucose
    /// unit while the numbers stay mg/dL.
    @Test("Glucose band converts and never trusts the payload's unit label")
    func glucoseBandIgnoresStampedUnit() throws {
        let band = try #require(InsightsTargetRangeBand.rangeBand(
            range: .init(min: 70, max: 140), insufficient: false, daysInRange30d: 10, daysLogged30d: 10,
            unit: "mmol/L", type: "BLOOD_GLUCOSE_FASTING", units: AccountUnitDisplayTests.imperial
        ))
        #expect(band.unit == "mmol/L")
        #expect(band.lowerLabel == label(3.9))
        #expect(band.upperLabel == label(7.8))
        let mgdl = try #require(InsightsTargetRangeBand.rangeBand(
            range: .init(min: 70, max: 140), insufficient: false, daysInRange30d: 10, daysLogged30d: 10,
            unit: "mmol/L", type: "BLOOD_GLUCOSE_FASTING", units: AccountUnitDisplayTests.metric
        ))
        #expect(mgdl.unit == "mg/dL")
        #expect(mgdl.lowerLabel == "70")
    }

    @Test("Untransformed targets keep the server's unit", arguments: ["PULSE", "BODY_FAT", "ACTIVITY_STEPS", "SLEEP_DURATION"])
    func untransformedTargetPassesThrough(_ type: String) throws {
        let band = try #require(InsightsTargetRangeBand.rangeBand(
            range: .init(min: 60, max: 80), insufficient: false, daysInRange30d: 5, daysLogged30d: 10,
            unit: "x", type: type, units: AccountUnitDisplayTests.imperial
        ))
        #expect(band.unit == "x")
        #expect(band.lowerLabel == "60")
    }

    @Test("Insights status card: headline, unit and band in lb")
    func insightsStatusCardImperial() throws {
        let payload = targets(type: "WEIGHT", unit: "kg", min: 61.9, max: 83.3)
        let descriptor = InsightsMetricStatusDescriptor.build(
            kind: .weight,
            digest: ComprehensiveDigest(summaries: ["WEIGHT": MetricSummary(avg7: 73.1, avg30: 73.5)]),
            target: payload.targets.first,
            latestValue: 73.9,
            units: AccountUnitDisplayTests.imperial
        )
        #expect(descriptor.unitCaption == "lb")
        #expect(descriptor.headlineValue == (73.5 * 2.20462262185).formatted(.number.precision(.fractionLength(1))))
        let caption = try #require(descriptor.targetBandCaption)
        #expect(caption.contains("lb"))
        #expect(!caption.contains("kg"))
        #expect(caption.contains(136.5.formatted(.number.precision(.fractionLength(1)))))
    }

    @Test("Target editor: 150 lb → 68.04 kg → 150 lb, guardrails round inward")
    func thresholdAdapterRoundTrip() {
        let adapter = ThresholdMetric.weight.unitAdapter(AccountUnitDisplayTests.imperial)
        #expect(adapter.unit == "lb")
        #expect(adapter.toCanonical(150) == 68.04)
        #expect(adapter.toDisplay(68.04) == 150)
        let window = adapter.bounds(ThresholdMetric.weight.bounds)
        #expect(window.min == 66.2)
        #expect(window.max == 661.3)
        #expect(adapter.toCanonical(window.min) >= ThresholdMetric.weight.bounds.min)
        #expect(adapter.toCanonical(window.max) <= ThresholdMetric.weight.bounds.max)
        let metric = ThresholdMetric.weight.unitAdapter(AccountUnitDisplayTests.metric)
        #expect(metric.unit == "kg")
        #expect(metric.toCanonical(72.345) == 72.345)
    }
}
