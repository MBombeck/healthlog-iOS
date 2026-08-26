import Foundation
@testable import HealthLog
import Testing

/// **v0.5.5.2 hide-empty-tiles policy.** Operator-feedback on v0.5.4.x
/// reverted the v0.5.4.1 softening: the strip painted em-dash tiles
/// indefinitely for every metric kind the user had no data for, reading
/// as a broken card wall. The new contract restores the hide-on-empty
/// behaviour, gated on a 1.6s post-`fanOutSettledAt` grace so a slow
/// per-kind derivation doesn't flicker the strip.
///
/// Contract:
/// - `.ready` → visible.
/// - `.empty(.outsideRange)` / `.empty(.sourceFiltered)` → visible
///   (sublabel + filter-CTA carry useful signal).
/// - `.unknown` / `.loading` → visible as skeleton.
/// - `.empty(.noData)` with `latestValue` or non-empty `sparkline` →
///   visible (server snapshot still has data).
/// - `.empty(.noData)` thin tile with `fanOutSettledAt == nil` →
///   visible (initial load).
/// - `.empty(.noData)` thin tile within 1.6s grace post-settle →
///   visible.
/// - `.empty(.noData)` thin tile after 1.6s grace → **hidden**.
@Suite("DashboardEmptyTilePolicy.shouldAutoHide — v0.5.5.2 hide-empty contract")
struct DashboardEmptyTilePolicyTests {
    private static func metric(
        kind: MetricKind = .bodyFat,
        latestValue: Double? = nil,
        sparkline: [Double] = []
    ) -> DashboardMetric {
        DashboardMetric(
            id: "test-\(kind.rawValue)",
            kind: kind,
            title: kind.displayName,
            latestValue: latestValue,
            secondaryValue: nil,
            unit: kind.unit,
            trend: .unknown,
            sparkline: sparkline,
            updatedAt: nil
        )
    }

    @Test("Keeps tile when state is .empty(.outsideRange) — user has data, just not in window")
    func keepsOnOutsideRange() {
        let latestAt = Date(timeIntervalSinceNow: -45 * 86400)
        let states: [MetricKind: MetricDataState] = [
            .bodyFat: .empty(reason: .outsideRange(latestAt: latestAt))
        ]
        #expect(!DashboardEmptyTilePolicy.shouldAutoHide(Self.metric(), states: states))
    }

    @Test("Keeps tile when latestValue is non-nil — server still has a value even though state is noData")
    func keepsOnServerValue() {
        let states: [MetricKind: MetricDataState] = [.bodyFat: .empty(reason: .noData)]
        let metric = Self.metric(latestValue: 22.5)
        #expect(!DashboardEmptyTilePolicy.shouldAutoHide(metric, states: states))
    }

    @Test("Keeps tile when sparkline carries values — server snapshot still has data")
    func keepsOnSparkline() {
        let states: [MetricKind: MetricDataState] = [.bodyFat: .empty(reason: .noData)]
        let metric = Self.metric(sparkline: [22.0, 22.3, 22.1])
        #expect(!DashboardEmptyTilePolicy.shouldAutoHide(metric, states: states))
    }

    @Test("Keeps tile when state is .unknown — skeleton paints during fan-out")
    func keepsThinTileOnUnknown() {
        let states: [MetricKind: MetricDataState] = [.bodyFat: .unknown]
        #expect(!DashboardEmptyTilePolicy.shouldAutoHide(Self.metric(), states: states))
    }

    @Test("Keeps tile when state map has no entry for this kind — defaults to .unknown")
    func keepsThinTileOnMissingState() {
        let states: [MetricKind: MetricDataState] = [:]
        #expect(!DashboardEmptyTilePolicy.shouldAutoHide(Self.metric(), states: states))
    }

    @Test("Keeps tile when state is .ready — real data resolved")
    func keepsOnReady() {
        let sample = Measurement(
            id: "m1",
            kind: .bodyFat,
            recordedAt: .now,
            value: .scalar(22.0),
            source: .manual
        )
        let states: [MetricKind: MetricDataState] = [.bodyFat: .ready(latest: sample, samples: [sample])]
        #expect(!DashboardEmptyTilePolicy.shouldAutoHide(Self.metric(), states: states))
    }

    @Test("Keeps thick tile in .loading state — server snapshot paints behind the overlay")
    func keepsThickTileOnLoading() {
        let states: [MetricKind: MetricDataState] = [.bodyFat: .loading]
        let metric = Self.metric(sparkline: [22.0, 22.3])
        #expect(!DashboardEmptyTilePolicy.shouldAutoHide(metric, states: states))
    }

    @Test("Two-arg legacy form never hides — fanOutSettledAt unavailable defaults to safe-keep")
    func twoArgLegacyAlwaysVisible() {
        let states: [MetricKind: MetricDataState] = [.bodyFat: .empty(reason: .noData)]
        #expect(!DashboardEmptyTilePolicy.shouldAutoHide(Self.metric(), states: states))
    }
}

/// Four-arg form — `fanOutSettledAt` + grace-window driven hide decisions.
@Suite("DashboardEmptyTilePolicy — v0.5.5.2 fanOutSettledAt grace window")
struct DashboardEmptyTilePolicyLoadingTimeoutTests {
    private static func metric(
        kind: MetricKind = .bodyFat,
        latestValue: Double? = nil,
        sparkline: [Double] = []
    ) -> DashboardMetric {
        DashboardMetric(
            id: "test-\(kind.rawValue)",
            kind: kind,
            title: kind.displayName,
            latestValue: latestValue,
            secondaryValue: nil,
            unit: kind.unit,
            trend: .unknown,
            sparkline: sparkline,
            updatedAt: nil
        )
    }

    @Test(".empty(.noData) thin tile is HIDDEN after 1.6s grace — operator-mandated empty-tile policy")
    func hidesEmptyAfterGrace() {
        let settled = Date(timeIntervalSince1970: 1_700_000_000)
        let now = settled.addingTimeInterval(1.6)
        let states: [MetricKind: MetricDataState] = [.bodyFat: .empty(reason: .noData)]
        #expect(DashboardEmptyTilePolicy.shouldAutoHide(
            Self.metric(),
            states: states,
            fanOutSettledAt: settled,
            now: now
        ))
    }

    @Test(".empty(.noData) thin tile is still VISIBLE at exactly 1.0s post-settle — debounce")
    func keepsEmptyDuringGrace() {
        let settled = Date(timeIntervalSince1970: 1_700_000_000)
        let now = settled.addingTimeInterval(1.0)
        let states: [MetricKind: MetricDataState] = [.bodyFat: .empty(reason: .noData)]
        #expect(!DashboardEmptyTilePolicy.shouldAutoHide(
            Self.metric(),
            states: states,
            fanOutSettledAt: settled,
            now: now
        ))
    }

    @Test(".loading thin tile is NEVER hidden regardless of settled timestamp — skeleton paints")
    func keepsLoadingThinTile() {
        let settled = Date(timeIntervalSince1970: 1_700_000_000)
        let later = settled.addingTimeInterval(60)
        let states: [MetricKind: MetricDataState] = [.bodyFat: .loading]
        #expect(!DashboardEmptyTilePolicy.shouldAutoHide(
            Self.metric(),
            states: states,
            fanOutSettledAt: settled,
            now: later
        ))
    }

    @Test(".unknown thin tile is NEVER hidden regardless of settled timestamp")
    func keepsUnknownThinTile() {
        let settled = Date(timeIntervalSince1970: 1_700_000_000)
        let later = settled.addingTimeInterval(60)
        let states: [MetricKind: MetricDataState] = [.bodyFat: .unknown]
        #expect(!DashboardEmptyTilePolicy.shouldAutoHide(
            Self.metric(),
            states: states,
            fanOutSettledAt: settled,
            now: later
        ))
    }

    @Test(".ready tile with non-empty data is NEVER hidden — same long-after-settle")
    func readyNeverHidden() {
        let settled = Date(timeIntervalSince1970: 1_700_000_000)
        let later = settled.addingTimeInterval(60)
        let sample = Measurement(
            id: "m1",
            kind: .bodyFat,
            recordedAt: settled,
            value: .scalar(22.0),
            source: .manual
        )
        let states: [MetricKind: MetricDataState] = [
            .bodyFat: .ready(latest: sample, samples: [sample])
        ]
        #expect(!DashboardEmptyTilePolicy.shouldAutoHide(
            Self.metric(),
            states: states,
            fanOutSettledAt: settled,
            now: later
        ))
    }

    @Test(".empty(.noData) thin tile is VISIBLE when fanOutSettledAt == nil — initial load")
    func keepsEmptyBeforeFanOutSettled() {
        let states: [MetricKind: MetricDataState] = [.bodyFat: .empty(reason: .noData)]
        #expect(!DashboardEmptyTilePolicy.shouldAutoHide(
            Self.metric(),
            states: states,
            fanOutSettledAt: nil,
            now: .now
        ))
    }

    @Test(".empty(.noData) thick tile (with latestValue) is VISIBLE after grace — server snapshot wins")
    func keepsThickEmptyAfterGrace() {
        let settled = Date(timeIntervalSince1970: 1_700_000_000)
        let later = settled.addingTimeInterval(60)
        let states: [MetricKind: MetricDataState] = [.bodyFat: .empty(reason: .noData)]
        let metric = Self.metric(latestValue: 22.5)
        #expect(!DashboardEmptyTilePolicy.shouldAutoHide(
            metric,
            states: states,
            fanOutSettledAt: settled,
            now: later
        ))
    }

    @Test(".empty(.noData) thick tile (with sparkline) is VISIBLE after grace — server snapshot wins")
    func keepsSparklineEmptyAfterGrace() {
        let settled = Date(timeIntervalSince1970: 1_700_000_000)
        let later = settled.addingTimeInterval(60)
        let states: [MetricKind: MetricDataState] = [.bodyFat: .empty(reason: .noData)]
        let metric = Self.metric(sparkline: [22.0, 22.3, 22.1])
        #expect(!DashboardEmptyTilePolicy.shouldAutoHide(
            metric,
            states: states,
            fanOutSettledAt: settled,
            now: later
        ))
    }

    @Test("Keeps tile in .empty(.outsideRange) — useful sublabel signal regardless of grace")
    func keepsOnOutsideRange() {
        let settled = Date(timeIntervalSince1970: 1_700_000_000)
        let later = settled.addingTimeInterval(60)
        let latestAt = Date(timeIntervalSinceNow: -45 * 86400)
        let states: [MetricKind: MetricDataState] = [
            .bodyFat: .empty(reason: .outsideRange(latestAt: latestAt))
        ]
        #expect(!DashboardEmptyTilePolicy.shouldAutoHide(
            Self.metric(),
            states: states,
            fanOutSettledAt: settled,
            now: later
        ))
    }

    @Test("Keeps tile in .empty(.sourceFiltered) — filter-clear CTA signal regardless of grace")
    func keepsOnSourceFiltered() {
        let settled = Date(timeIntervalSince1970: 1_700_000_000)
        let later = settled.addingTimeInterval(60)
        let states: [MetricKind: MetricDataState] = [.bodyFat: .empty(reason: .sourceFiltered)]
        #expect(!DashboardEmptyTilePolicy.shouldAutoHide(
            Self.metric(),
            states: states,
            fanOutSettledAt: settled,
            now: later
        ))
    }

    @Test("loadingTimeoutSeconds is exactly 1.6s — operator-Volt-feedback v0.5.2-R3 A-H1")
    func threshold() {
        #expect(DashboardEmptyTilePolicy.loadingTimeoutSeconds == 1.6)
    }

    /// **REG-11 5th-attempt regression (v0.5.5.5).** Operator on 2026-05-21:
    /// "Körperfett haben wir nicht. Es ist sowieso blöd, dass das angezeigt
    /// wird dann." Pre-fix a stale single-point server sparkline (`[22.0]`
    /// — a residue from a since-deleted measurement, common when the server
    /// snapshot is cached past a delete) was enough to keep the tile
    /// visible even when the canonical `.empty(.noData)` signal from the
    /// recent-page + series fan-out said the user has no data. The new
    /// rule mirrors the tile resolver's `≥ 2` threshold: a single-point
    /// summary residue is no longer a thick-snapshot signal.
    @Test(".empty(.noData) tile with single-point stale sparkline IS hidden after grace (REG-11 v0.5.5.5)")
    func hidesSinglePointSparklineAfterGrace() {
        let settled = Date(timeIntervalSince1970: 1_700_000_000)
        let now = settled.addingTimeInterval(60)
        let states: [MetricKind: MetricDataState] = [.bodyFat: .empty(reason: .noData)]
        let metric = Self.metric(sparkline: [22.0])
        #expect(DashboardEmptyTilePolicy.shouldAutoHide(
            metric,
            states: states,
            fanOutSettledAt: settled,
            now: now
        ))
    }

    /// Multi-point summary sparkline still keeps the tile visible — server
    /// is the source of truth when it ships a renderable series, even when
    /// the local fan-out came back empty (e.g. recent-page paging window
    /// pushed manual entries out of the 400-row slice).
    @Test(".empty(.noData) tile with multi-point sparkline stays visible after grace")
    func keepsMultiPointSparklineAfterGrace() {
        let settled = Date(timeIntervalSince1970: 1_700_000_000)
        let now = settled.addingTimeInterval(60)
        let states: [MetricKind: MetricDataState] = [.bodyFat: .empty(reason: .noData)]
        let metric = Self.metric(sparkline: [22.0, 22.3, 22.1])
        #expect(!DashboardEmptyTilePolicy.shouldAutoHide(
            metric,
            states: states,
            fanOutSettledAt: settled,
            now: now
        ))
    }
}
