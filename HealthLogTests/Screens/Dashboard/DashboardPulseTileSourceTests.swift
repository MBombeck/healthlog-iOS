import Foundation
@testable import HealthLog
import Testing

/// #20 — the Dashboard pulse slot follows the web rule (`page-client.tsx`
/// `hasRestingHr` / `pulseTileSummary`, HealthLog v1.39.x): with resting heart
/// rate in the digest summaries the slot shows the resting series, otherwise raw
/// `PULSE`. Every stat on the tile (headline, sparkline, 7d/30d, trend, in-range
/// bar, target) then describes one series, and the resting band never sits next
/// to raw heart rate (HealthLog#584).
@Suite("DashboardPulseTileSource — pulse slot picks one series")
struct DashboardPulseTileSourceTests {
    private func metric(_ kind: MetricKind, latest: Double?, sparkline: [Double] = []) -> DashboardMetric {
        DashboardMetric(
            id: kind.rawValue,
            kind: kind,
            title: kind.rawValue,
            latestValue: latest,
            secondaryValue: nil,
            unit: "bpm",
            trend: .flat,
            sparkline: sparkline,
            updatedAt: nil
        )
    }

    private func digest(pulseCount: Int?, restingCount: Int?) -> ComprehensiveDigest {
        var summaries: [String: MetricSummary] = [:]
        if let pulseCount { summaries["PULSE"] = MetricSummary(count: pulseCount, avg7: 80, avg30: 81) }
        if let restingCount { summaries["RESTING_HEART_RATE"] = MetricSummary(count: restingCount, avg7: 72, avg30: 71) }
        return ComprehensiveDigest(summaries: summaries)
    }

    private var weight: DashboardMetric {
        metric(.weight, latest: 72.4)
    }

    private var pulse: DashboardMetric {
        metric(.pulse, latest: 80, sparkline: [78, 84, 80])
    }

    private var resting: DashboardMetric {
        metric(.restingHeartRate, latest: 72, sparkline: [71, 73, 72])
    }

    // MARK: - Has-resting signal (web: `summaries.RESTING_HEART_RATE.count > 0`)

    @Test("resting data is decided from the digest summaries count, like the web")
    func hasRestingDataFromSummaries() {
        #expect(DashboardPulseTileSource.hasRestingData(digest(pulseCount: 10, restingCount: 3)))
        #expect(!DashboardPulseTileSource.hasRestingData(digest(pulseCount: 10, restingCount: 0)))
        #expect(!DashboardPulseTileSource.hasRestingData(digest(pulseCount: 10, restingCount: nil)))
        #expect(!DashboardPulseTileSource.hasRestingData(nil))
    }

    // MARK: - Slots

    @Test("resting + raw: the pulse slot shows the resting tile, the resting figure appears once")
    func restingAndRawShowsRestingInPulseSlot() {
        let slots = DashboardPulseTileSource.slots(
            for: [weight, pulse, resting],
            digest: digest(pulseCount: 400, restingCount: 30),
            pulseTileVisible: true
        )
        #expect(slots.map(\.layoutKind) == [.weight, .pulse])
        #expect(slots.map(\.metric.kind) == [.weight, .restingHeartRate])
        #expect(slots[1].metric.latestValue == 72, "The headline is the resting figure, not raw 80.")
        #expect(slots[1].metric.sparkline == [71, 73, 72], "The sparkline is the resting series.")
    }

    @Test("raw only: the pulse slot stays raw heart rate")
    func rawOnlyKeepsPulse() {
        let slots = DashboardPulseTileSource.slots(
            for: [weight, pulse, resting],
            digest: digest(pulseCount: 400, restingCount: nil),
            pulseTileVisible: true
        )
        #expect(slots.map(\.metric.kind) == [.weight, .pulse, .restingHeartRate])
        #expect(slots.map(\.layoutKind) == [.weight, .pulse, .restingHeartRate])
    }

    @Test("resting only: the pulse slot (a synthesized placeholder) shows the resting tile")
    func restingOnlyShowsResting() {
        let placeholder = metric(.pulse, latest: nil)
        let slots = DashboardPulseTileSource.slots(
            for: [placeholder, resting],
            digest: digest(pulseCount: nil, restingCount: 30),
            pulseTileVisible: true
        )
        #expect(slots.map(\.layoutKind) == [.pulse])
        #expect(slots.map(\.metric.kind) == [.restingHeartRate])
    }

    @Test("no digest yet: nothing is swapped (raw pulse, which never carries a band)")
    func noDigestKeepsIdentity() {
        let slots = DashboardPulseTileSource.slots(for: [pulse, resting], digest: nil, pulseTileVisible: true)
        #expect(slots.map(\.metric.kind) == [.pulse, .restingHeartRate])
    }

    @Test("pulse tile hidden by the user: the resting tile keeps its own slot")
    func hiddenPulseTileKeepsRestingStandalone() {
        let slots = DashboardPulseTileSource.slots(
            for: [pulse, resting],
            digest: digest(pulseCount: 400, restingCount: 30),
            pulseTileVisible: false
        )
        #expect(slots.map(\.metric.kind) == [.pulse, .restingHeartRate])
        #expect(slots.map(\.layoutKind) == [.pulse, .restingHeartRate])
    }

    @Test("resting tile not loaded yet: the pulse slot stays raw rather than inventing a value")
    func missingRestingMetricKeepsPulse() {
        let slots = DashboardPulseTileSource.slots(
            for: [weight, pulse],
            digest: digest(pulseCount: 400, restingCount: 30),
            pulseTileVisible: true
        )
        #expect(slots.map(\.metric.kind) == [.weight, .pulse])
    }
}
