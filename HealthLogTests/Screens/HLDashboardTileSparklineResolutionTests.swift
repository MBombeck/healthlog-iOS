import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// Type alias to disambiguate the project's domain `Measurement` model from
/// `HealthKit.HKQuantitySample`-adjacent `Foundation.Measurement<Unit>`,
/// which both surface in the test module's name-lookup pass.
private typealias DomainMeasurement = HealthLog.Measurement

/// **REG-11 (v0.5.6) — tile-level resolution contract.** Locks the
/// precedence rules `HLDashboardTile.sparklineValues` uses to pick between
/// the summary's pre-aggregated sparkline + the unified-data-state's raw
/// samples. The five-time-recurring "BP / Puls / Körperfett tile zeigt
/// keinen Chart" symptom traced to a fence-post on this gate: the prior
/// `!metric.sparkline.isEmpty` check let a server-emitted single-point
/// sparkline win, and `HLSparkline` then collapsed it to the empty-hairline
/// branch (`values.count < 2`). The post-fix precedence prefers the
/// `dataState` projection whenever the summary sparkline is too thin to
/// render a real chart.
@Suite("HLDashboardTile — sparkline resolution precedence")
struct HLDashboardTileSparklineResolutionTests {
    private func bpSamples(_ now: Date) -> [DomainMeasurement] {
        [
            DomainMeasurement(
                id: "b1",
                kind: .bloodPressure,
                recordedAt: now.addingTimeInterval(-86400 * 3),
                value: .bloodPressure(systolic: 122, diastolic: 79)
            ),
            DomainMeasurement(
                id: "b2",
                kind: .bloodPressure,
                recordedAt: now.addingTimeInterval(-86400 * 2),
                value: .bloodPressure(systolic: 124, diastolic: 81)
            ),
            DomainMeasurement(
                id: "b3",
                kind: .bloodPressure,
                recordedAt: now.addingTimeInterval(-86400),
                value: .bloodPressure(systolic: 126, diastolic: 83)
            )
        ]
    }

    @Test("server multi-point sparkline wins over dataState samples")
    func serverMultiPointWins() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let samples = bpSamples(now)
        let serverSparkline: [Double] = [120, 122, 121, 124, 123, 125, 124]
        let resolved = HLDashboardTile.resolveSparklineValues(
            summarySparkline: serverSparkline,
            dataState: .ready(latest: samples[2], samples: samples),
            kind: .bloodPressure
        )
        #expect(resolved == serverSparkline, "Server-emitted multi-point sparkline should win when it can render")
    }

    /// **REG-11 regression core.** Pre-fix the single-point sparkline won,
    /// the tile rendered the hairline placeholder, the user reported "kein
    /// Chart". Post-fix the resolver falls through to the dataState
    /// projection when the summary sparkline has `< 2` points.
    @Test("single-point summary sparkline falls through to dataState projection")
    func singlePointFallsThrough() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let samples = bpSamples(now)
        let resolved = HLDashboardTile.resolveSparklineValues(
            summarySparkline: [124],
            dataState: .ready(latest: samples[2], samples: samples),
            kind: .bloodPressure
        )
        #expect(
            resolved.count >= 2,
            "Single-point summary sparkline must fall through to the projected samples so HLSparkline renders a chart, not the hairline"
        )
        // Every value should be a systolic reading (projection drops the
        // diastolic component + any unpaired-DIA artifacts).
        for value in resolved {
            #expect(value >= 80 && value <= 200, "Projected sparkline must carry systolic values, got \(value)")
        }
    }

    @Test("empty summary sparkline falls through to dataState projection")
    func emptyFallsThrough() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let samples = bpSamples(now)
        let resolved = HLDashboardTile.resolveSparklineValues(
            summarySparkline: [],
            dataState: .ready(latest: samples[2], samples: samples),
            kind: .bloodPressure
        )
        #expect(resolved.count == 3, "Empty summary sparkline must yield the full projected samples")
    }

    @Test("empty summary + non-ready dataState yields empty")
    func emptyAllAround() {
        let resolved = HLDashboardTile.resolveSparklineValues(
            summarySparkline: [],
            dataState: .empty(reason: .noData),
            kind: .bloodPressure
        )
        #expect(resolved.isEmpty, "Empty inputs → empty result (renders as hairline, which is the correct empty-state signal)")
    }

    /// Pulse projection — the dataState fallback path for the heart-rate
    /// kinds (`.pulse` + `.restingHeartRate`) routes through
    /// `MetricSeriesProjection.heartRate` which drops non-positive values.
    @Test("Pulse single-point summary sparkline falls through to dataState")
    func pulseSinglePointFallsThrough() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let samples: [DomainMeasurement] = [
            DomainMeasurement(id: "p1", kind: .pulse, recordedAt: now.addingTimeInterval(-3600 * 5), value: .scalar(66)),
            DomainMeasurement(id: "p2", kind: .pulse, recordedAt: now.addingTimeInterval(-3600 * 4), value: .scalar(68)),
            DomainMeasurement(id: "p3", kind: .pulse, recordedAt: now.addingTimeInterval(-3600), value: .scalar(70))
        ]
        let resolved = HLDashboardTile.resolveSparklineValues(
            summarySparkline: [70],
            dataState: .ready(latest: samples[2], samples: samples),
            kind: .pulse
        )
        #expect(resolved.count == 3)
        #expect(resolved == [66, 68, 70])
    }

    @Test("BodyFat single-point summary sparkline falls through to dataState")
    func bodyFatSinglePointFallsThrough() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let samples: [DomainMeasurement] = [
            DomainMeasurement(id: "bf1", kind: .bodyFat, recordedAt: now.addingTimeInterval(-86400 * 5), value: .scalar(22.1)),
            DomainMeasurement(id: "bf2", kind: .bodyFat, recordedAt: now.addingTimeInterval(-86400), value: .scalar(21.8))
        ]
        let resolved = HLDashboardTile.resolveSparklineValues(
            summarySparkline: [22.0],
            dataState: .ready(latest: samples[1], samples: samples),
            kind: .bodyFat
        )
        #expect(resolved.count == 2)
    }

    /// **REG-11 5th-attempt regression (v0.5.5.5).** Pre-fix the resolver
    /// preferred any summary sparkline with `count >= 2`. So when the
    /// server emitted a sparse `[120, 122]` (two daily rollup buckets) but
    /// the wide-page fan-out had 22 fully-resolved BP samples, the tile
    /// rendered the sparse 2-point chart instead of the richer 22-point
    /// chart — and the operator still read the result as "barely a chart"
    /// because the line was so flat across 2 points it visually approximated
    /// the hairline. Post-fix: when both paths render, the one with MORE
    /// detail wins. The tile painting is now driven by the same density
    /// `ChartDetailScreen` consumes.
    @Test("when both paths render, the longer one wins (server 2 vs dataState 22)")
    func longerPathWins() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // Build 22 BP samples spread across the last 22 days — what the
        // operator's actual production data carries (per W-DATA-FLOW-AUDIT
        // §47 — `/api/measurements/series?kind=bloodPressure` returns 22
        // points for the audited demo account).
        var samples: [DomainMeasurement] = []
        for i in 1 ... 22 {
            let recordedAt = now.addingTimeInterval(-86400 * Double(i))
            let systolic = Double(120 + i % 6)
            let diastolic = Double(78 + i % 4)
            let value: MeasurementValue = .bloodPressure(systolic: systolic, diastolic: diastolic)
            samples.append(DomainMeasurement(
                id: "b\(i)",
                kind: .bloodPressure,
                recordedAt: recordedAt,
                value: value
            ))
        }
        let latest = samples[samples.count - 1]
        let resolved = HLDashboardTile.resolveSparklineValues(
            summarySparkline: [120, 122],
            dataState: .ready(latest: latest, samples: samples),
            kind: .bloodPressure
        )
        #expect(
            resolved.count == 22,
            "When dataState has more points than the summary, the resolver should pick the denser series so the tile chart matches what ChartDetailScreen shows."
        )
    }

    /// **REG-11 5th-attempt regression (v0.5.5.5).** Verifies the dataState
    /// fall-through still fires when the summary is exactly one point —
    /// the canonical operator-reported case for low-frequency manual entry
    /// kinds (BP weekly, Pulse from a non-Watch user, BodyFat monthly).
    @Test("Pulse: single-point summary + ready dataState picks dataState")
    func pulseSinglePointSummaryPicksDataState() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let samples: [DomainMeasurement] = [
            DomainMeasurement(id: "p1", kind: .pulse, recordedAt: now.addingTimeInterval(-3600 * 6), value: .scalar(64)),
            DomainMeasurement(id: "p2", kind: .pulse, recordedAt: now.addingTimeInterval(-3600 * 4), value: .scalar(68)),
            DomainMeasurement(id: "p3", kind: .pulse, recordedAt: now.addingTimeInterval(-3600 * 2), value: .scalar(72)),
            DomainMeasurement(id: "p4", kind: .pulse, recordedAt: now.addingTimeInterval(-3600), value: .scalar(70))
        ]
        let latest = samples[samples.count - 1]
        let resolved = HLDashboardTile.resolveSparklineValues(
            summarySparkline: [70],
            dataState: .ready(latest: latest, samples: samples),
            kind: .pulse
        )
        #expect(resolved.count == 4, "Single-point summary + ready dataState → dataState wins")
    }

    /// **REG-11 5th-attempt regression (v0.5.5.5).** BodyFat-specific —
    /// matches the operator-reported "Körperfett tile renders empty" case
    /// when the server snapshot has a stale `[22.0]` single-point but the
    /// dataState has zero samples (truly no data). The resolver should
    /// return the summary's single point (HLSparkline renders hairline);
    /// the auto-hide policy is the second-stage defence that removes the
    /// tile entirely after the grace window.
    @Test("BodyFat: single-point summary + empty dataState → returns summary single-point as-is")
    func bodyFatSinglePointSummaryWithEmptyDataState() {
        let resolved = HLDashboardTile.resolveSparklineValues(
            summarySparkline: [22.0],
            dataState: .empty(reason: .noData),
            kind: .bodyFat
        )
        // Returns the single-point summary; HLSparkline collapses it to
        // hairline, and `DashboardEmptyTilePolicy.shouldAutoHide` removes
        // the tile entirely once the grace elapses.
        #expect(resolved == [22.0])
    }

    @Test("BP unpaired-DIA artifacts drop out of the projection (legacy HP-2 contract)")
    func bpUnpairedArtifactsDrop() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // Mix paired BP rows with an unpaired-DIA artifact (systolic == 0)
        // that survived the server pair-merge with a millisecond-skew
        // timestamp. The projection must drop it; otherwise the chart's
        // y-domain would crush to the 0...126 range and the actual readings
        // would squeeze into a sliver at the top edge.
        let samples: [DomainMeasurement] = [
            DomainMeasurement(
                id: "b1",
                kind: .bloodPressure,
                recordedAt: now.addingTimeInterval(-86400 * 3),
                value: .bloodPressure(systolic: 122, diastolic: 79)
            ),
            DomainMeasurement(
                id: "b2-unpaired",
                kind: .bloodPressure,
                recordedAt: now.addingTimeInterval(-86400 * 2),
                value: .bloodPressure(systolic: 0, diastolic: 80)
            ),
            DomainMeasurement(
                id: "b3",
                kind: .bloodPressure,
                recordedAt: now.addingTimeInterval(-86400),
                value: .bloodPressure(systolic: 126, diastolic: 83)
            )
        ]
        let resolved = HLDashboardTile.resolveSparklineValues(
            summarySparkline: [],
            dataState: .ready(latest: samples[2], samples: samples),
            kind: .bloodPressure
        )
        #expect(resolved.count == 2, "Unpaired-DIA artifact must drop, leaving the two paired readings")
        for value in resolved {
            #expect(value > 0, "No zero-systolic value should survive the projection")
        }
    }
}

// swiftlint:enable force_unwrapping
