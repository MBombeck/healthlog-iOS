import Foundation
@testable import HealthLog
import Testing

/// **v0.6.2.2 W-TILE-AUDIT — pin the structural synth-hide contract.**
///
/// Carry-over from v0.6.2.1 W-COLD-LAUNCH-FLICKER, broadened to cover
/// pull-to-refresh (the path the v0.6.2.1 fix missed). Operator on build
/// 71 (2026-05-25, third report): "Dann refreshe ich die Seite, indem ich
/// mit meinem Daumen runterziehe, und dann sehe ich auch so was wie
/// Körperfett, Ruhepuls, Temperatur, wo ich überhaupt keine Daten habe."
///
/// The bug history: three time-based grace-period band-aids stacked on
/// top of one another (W-TILEHOTFIX set-once anchor, W-COLD-LAUNCH-FLICKER
/// cold-launch hide, REG-11 single-point sparkline rule). Each closed a
/// trigger path; the bug shifted to the next. v0.6.2.2 drops the grace
/// window for synth placeholders entirely — visibility-from-data only,
/// no timing — so the bug has no oscillation mechanism left.
///
/// **Contract pinned by this suite:**
/// - Synth-placeholder tile (id prefix `synth-`, no `latestValue`, < 2
///   sparkline pts) is **HIDDEN** unless `state == .ready` — regardless
///   of `fanOutSettledAt`, regardless of `.unknown`/`.loading`/`.empty()`,
///   regardless of which trigger path called.
/// - Server-emitted tile (id NOT prefixed `synth-`) → v0.5.5.2 contract
///   verbatim: always visible during fan-out, grace-window collapse for
///   `.empty(.noData)`.
/// - Tile that carries a server snapshot (`latestValue != nil` or
///   sparkline ≥ 2 pts) → always visible regardless of id (defensive).
/// - `.ready` after fan-out → always visible regardless of id.
@Suite("DashboardEmptyTilePolicy — v0.6.2.2 structural synth-hide contract")
struct DashboardEmptyTilePolicyColdLaunchTests {
    private static func synthMetric(
        kind: MetricKind = .bodyFat,
        latestValue: Double? = nil,
        sparkline: [Double] = []
    ) -> DashboardMetric {
        // Match the id shape produced by `DashboardStore.placeholder(for:order:)`.
        DashboardMetric(
            id: "synth-\(kind.rawValue)-3",
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

    private static func serverMetric(
        kind: MetricKind = .bodyFat,
        latestValue: Double? = nil,
        sparkline: [Double] = []
    ) -> DashboardMetric {
        // Server-emitted tile — id is the server-issued one, NOT prefixed.
        DashboardMetric(
            id: "server-\(kind.rawValue)",
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

    /// **THE BUG-PIN.** Cold launch + synth placeholder + `.unknown` state +
    /// `fanOutSettledAt == nil` ⇒ the tile is HIDDEN. Pre-fix this returned
    /// false (visible) and the operator saw the flicker. Post-fix the tile
    /// never renders during cold launch and only appears if the fan-out
    /// promotes the state to `.ready`.
    @Test("Cold-launch: synth-placeholder + .unknown + fanOutSettledAt nil → HIDDEN")
    func hidesSynthOnColdLaunchUnknown() {
        let states: [MetricKind: MetricDataState] = [.bodyFat: .unknown]
        #expect(DashboardEmptyTilePolicy.shouldAutoHide(
            Self.synthMetric(),
            states: states,
            fanOutSettledAt: nil,
            now: .now
        ))
    }

    /// `.loading` state on cold launch — same as `.unknown`. The store
    /// never produces `.loading` today (transitions go through the staging
    /// dict directly into `.ready`/`.empty`) but the policy must remain
    /// correct if the state model evolves.
    @Test("Cold-launch: synth-placeholder + .loading + fanOutSettledAt nil → HIDDEN")
    func hidesSynthOnColdLaunchLoading() {
        let states: [MetricKind: MetricDataState] = [.bodyFat: .loading]
        #expect(DashboardEmptyTilePolicy.shouldAutoHide(
            Self.synthMetric(),
            states: states,
            fanOutSettledAt: nil,
            now: .now
        ))
    }

    /// Missing state map entry defaults to `.unknown` — same contract as
    /// the explicit `.unknown` case. Mirrors the real cold-launch shape
    /// where `metricStates` starts empty `{}` before the fan-out lands.
    @Test("Cold-launch: synth-placeholder + missing state entry → HIDDEN")
    func hidesSynthOnColdLaunchMissingState() {
        let states: [MetricKind: MetricDataState] = [:]
        #expect(DashboardEmptyTilePolicy.shouldAutoHide(
            Self.synthMetric(),
            states: states,
            fanOutSettledAt: nil,
            now: .now
        ))
    }

    /// Server-emitted tile (non-synth id) must stay visible during cold
    /// launch — the server explicitly surfaced this kind in its summary
    /// fast-path so the prior is "there IS data, just keep the skeleton
    /// while the chart hydrates." Hiding it would be a regression of the
    /// v0.5.5.2 "skeleton-paint during fan-out" contract.
    @Test("Cold-launch: server-emitted tile + .unknown + fanOutSettledAt nil → VISIBLE")
    func keepsServerTileOnColdLaunchUnknown() {
        let states: [MetricKind: MetricDataState] = [.bodyFat: .unknown]
        #expect(!DashboardEmptyTilePolicy.shouldAutoHide(
            Self.serverMetric(),
            states: states,
            fanOutSettledAt: nil,
            now: .now
        ))
    }

    /// Synth tile carrying a server-snapshot `latestValue` (rare — would
    /// mean the synth pass ran AFTER a per-kind hydrate, which doesn't
    /// happen today, but the predicate must be defensive). Snapshot wins.
    @Test("Cold-launch: synth tile with latestValue → VISIBLE (snapshot wins)")
    func keepsSynthWithLatestValueOnColdLaunch() {
        let states: [MetricKind: MetricDataState] = [.bodyFat: .unknown]
        let metric = Self.synthMetric(latestValue: 22.5)
        #expect(!DashboardEmptyTilePolicy.shouldAutoHide(
            metric,
            states: states,
            fanOutSettledAt: nil,
            now: .now
        ))
    }

    /// Synth tile carrying a multi-point sparkline — server hydrated it
    /// post-creation (universal-sparkline hydration path). The renderable
    /// chart is real data, keep the tile.
    @Test("Cold-launch: synth tile with multi-point sparkline → VISIBLE")
    func keepsSynthWithSparklineOnColdLaunch() {
        let states: [MetricKind: MetricDataState] = [.bodyFat: .unknown]
        let metric = Self.synthMetric(sparkline: [22.0, 22.3, 22.1])
        #expect(!DashboardEmptyTilePolicy.shouldAutoHide(
            metric,
            states: states,
            fanOutSettledAt: nil,
            now: .now
        ))
    }

    /// **v0.6.2.2 W-TILE-AUDIT — replaces the v0.6.2.1 contract.** A synth
    /// tile in `.unknown` is HIDDEN regardless of `fanOutSettledAt`. The
    /// v0.6.2.1 contract kept it visible post-settle ("skeleton paint
    /// during pull-to-refresh"); that's exactly the pull-to-refresh
    /// flicker the operator reported on build 71. New rule: synth tiles
    /// have no skeleton-paint phase — they only render once `.ready`
    /// (or a hydrated server snapshot lands).
    @Test("Post-settle: synth tile + .unknown is HIDDEN (no skeleton paint for synth)")
    func hidesSynthAfterSettle() {
        let settled = Date(timeIntervalSince1970: 1_700_000_000)
        let now = settled.addingTimeInterval(0.5)
        let states: [MetricKind: MetricDataState] = [.bodyFat: .unknown]
        #expect(DashboardEmptyTilePolicy.shouldAutoHide(
            Self.synthMetric(),
            states: states,
            fanOutSettledAt: settled,
            now: now
        ))
    }

    /// **v0.6.2.2 pull-to-refresh trigger-path pin.** Operator on build 71:
    /// pull-to-refresh re-introduces ghost tiles (Körperfett, Ruhepuls,
    /// Temperatur). The path: `resetMetricStatesForRefresh()` clears the
    /// anchor + states. `refreshMetricStates` then derives empty kinds to
    /// `.empty(.noData)` and re-stamps the anchor at the end. Pre-fix the
    /// synth tile lived in a 1.6 s visible window because the new fan-out
    /// settle re-opened the grace. Post-fix synth + `.empty(.noData)` is
    /// HIDDEN immediately, regardless of how recent the anchor stamp is.
    @Test("Pull-to-refresh: synth + .empty(.noData) + fresh anchor → HIDDEN immediately")
    func hidesSynthAfterPullToRefreshSettle() {
        let settled = Date(timeIntervalSince1970: 1_700_000_000)
        // Within the v0.5.5.2 grace window — pre-fix this kept the tile
        // visible for ~1.6 s and produced the flicker. Now HIDDEN at t=0.
        let now = settled.addingTimeInterval(0.1)
        let states: [MetricKind: MetricDataState] = [.bodyFat: .empty(reason: .noData)]
        #expect(DashboardEmptyTilePolicy.shouldAutoHide(
            Self.synthMetric(),
            states: states,
            fanOutSettledAt: settled,
            now: now
        ))
    }

    /// **v0.6.2.2 nav-pop trigger-path pin.** Re-entering Dashboard from a
    /// pushed detail screen re-fires `.task` → `refreshTileStates`. With
    /// W-TILEHOTFIX (set-once anchor) the anchor stays at the original
    /// stamp; with W-TILE-AUDIT the synth tile is HIDDEN regardless. Both
    /// fixes layer so the behaviour is double-pinned.
    @Test("Nav-pop: synth + .empty(.noData) + long-elapsed anchor → HIDDEN")
    func hidesSynthAfterNavPopLongElapsed() {
        let settled = Date(timeIntervalSince1970: 1_700_000_000)
        let now = settled.addingTimeInterval(60)
        let states: [MetricKind: MetricDataState] = [.bodyFat: .empty(reason: .noData)]
        #expect(DashboardEmptyTilePolicy.shouldAutoHide(
            Self.synthMetric(),
            states: states,
            fanOutSettledAt: settled,
            now: now
        ))
    }

    /// **v0.6.2.2 outsideRange trigger-path pin.** A synth tile that
    /// resolves to `.empty(.outsideRange)` via the series fallback (data
    /// exists but is older than the queried 30-day window) — pre-fix this
    /// stayed visible because `.outsideRange` carries the sublabel signal.
    /// For synth tiles the operator-mental-model is "the server doesn't
    /// surface this kind, hiding it is what I want" — so we collapse it
    /// rather than show "Letzte Messung vor X Tagen" for a tile the server
    /// itself elided. Server-emitted tiles keep the sublabel signal.
    @Test("Synth + .empty(.outsideRange) → HIDDEN (server elided the kind)")
    func hidesSynthOnOutsideRange() {
        let states: [MetricKind: MetricDataState] = [
            .bodyFat: .empty(reason: .outsideRange(latestAt: .now))
        ]
        #expect(DashboardEmptyTilePolicy.shouldAutoHide(
            Self.synthMetric(),
            states: states,
            fanOutSettledAt: nil,
            now: .now
        ))
    }

    /// **v0.6.2.2 scenePhase / tab-switch trigger-path pin.** Foreground
    /// transition re-runs `store.refresh()` + `refreshTileStates()`. The
    /// anchor is set-once (W-TILEHOTFIX) so the timing is irrelevant —
    /// AND the new contract drops the timing dependency for synth tiles
    /// regardless. Pinned across both invariants.
    @Test("scenePhase foreground: synth + .empty(.noData) → HIDDEN")
    func hidesSynthAfterScenePhaseForeground() {
        let settled = Date(timeIntervalSince1970: 1_700_000_000)
        let now = settled.addingTimeInterval(300)
        let states: [MetricKind: MetricDataState] = [.bodyFat: .empty(reason: .noData)]
        #expect(DashboardEmptyTilePolicy.shouldAutoHide(
            Self.synthMetric(),
            states: states,
            fanOutSettledAt: settled,
            now: now
        ))
    }

    /// **v0.6.2.2 — synth + post-settle hydration race.** If a synth tile's
    /// fan-out promotes it to `.ready` AFTER the anchor was stamped, the
    /// tile must show immediately. Mirrors the case where series fallback
    /// resolves slower than the wide-page derive.
    @Test("Post-settle promotion: synth + .ready → VISIBLE")
    func keepsSynthOnPostSettleReady() {
        let settled = Date(timeIntervalSince1970: 1_700_000_000)
        let now = settled.addingTimeInterval(2.5)
        let sample = Measurement(
            id: "m1",
            kind: .bodyFat,
            recordedAt: now,
            value: .scalar(22.0),
            source: .manual
        )
        let states: [MetricKind: MetricDataState] = [.bodyFat: .ready(latest: sample, samples: [sample])]
        #expect(!DashboardEmptyTilePolicy.shouldAutoHide(
            Self.synthMetric(),
            states: states,
            fanOutSettledAt: settled,
            now: now
        ))
    }

    /// After fan-out promoted the synth tile to `.ready` — visible. Real
    /// data renders; the cold-launch hide is purely a pre-fan-out gate.
    @Test("Synth tile + .ready → VISIBLE regardless of cold-launch flag")
    func keepsSynthOnReady() {
        let sample = Measurement(
            id: "m1",
            kind: .bodyFat,
            recordedAt: .now,
            value: .scalar(22.0),
            source: .manual
        )
        let states: [MetricKind: MetricDataState] = [.bodyFat: .ready(latest: sample, samples: [sample])]
        #expect(!DashboardEmptyTilePolicy.shouldAutoHide(
            Self.synthMetric(),
            states: states,
            fanOutSettledAt: nil,
            now: .now
        ))
    }

    /// The `isSynthPlaceholder` predicate is pinned independently — id
    /// prefix `synth-` is the canonical signal. Mirrors the shape produced
    /// by `DashboardStore.placeholder(for:order:)`.
    @Test("isSynthPlaceholder discriminates synth-prefixed ids from server ids")
    func isSynthPlaceholderDiscriminates() {
        #expect(DashboardEmptyTilePolicy.isSynthPlaceholder(Self.synthMetric()))
        #expect(!DashboardEmptyTilePolicy.isSynthPlaceholder(Self.serverMetric()))
    }
}
