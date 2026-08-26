import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable file_length

/// **v0.6.2.2 W-TILE-AUDIT — trigger-path invariant suite.**
///
/// Operator on build 71 (2026-05-25, third report): "Dann refreshe ich
/// die Seite, indem ich mit meinem Daumen runterziehe, und dann sehe ich
/// auch so was wie Körperfett, Ruhepuls, Temperatur, wo ich überhaupt
/// keine Daten habe. Das nervt super doll." Pull-to-refresh re-introduces
/// ghost tiles for metrics with no data.
///
/// Bug-mutation history shows the same flicker class has shipped THREE
/// hotfixes:
/// - v0.6.1.28 (`a54831cb`): SWR cache + layout-merge GET-path drift.
/// - v0.6.2.0 (`ca125f0f`): nav-pop `.task` re-fire re-stamped anchor.
/// - v0.6.2.1 (`12c6fa06`): cold-launch synth `.unknown` flicker.
///
/// All three were time-based band-aids on the SAME predicate. This suite
/// pins EVERY trigger path that can cause the synth-tile visibility set
/// to mutate. Each test maps to one of the trigger paths in the audit
/// table — if any future fix introduces a regression on any path, the
/// matching test fails. No more whack-a-mole.
///
/// **The invariant pinned here:** for a synth placeholder (id prefix
/// `synth-`, no `latestValue`, sparkline < 2), the tile is HIDDEN unless
/// `state == .ready`. INDEPENDENT OF `fanOutSettledAt` AND `now`. The
/// time-based grace window cannot oscillate the visibility because there
/// is no time-dependent branch in the synth path.
@Suite("DashboardEmptyTilePolicy — v0.6.2.2 trigger-path invariant matrix")
struct DashboardEmptyTilePolicyTriggerPathTests {
    private static func synthMetric(
        kind: MetricKind = .bodyFat,
        latestValue: Double? = nil,
        sparkline: [Double] = []
    ) -> DashboardMetric {
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

    // MARK: - Trigger-path matrix (synth tiles)

    /// **TRIGGER 1 — Cold launch.** First `.task` fire, no prior anchor.
    /// Synth tile starts in `.unknown` (missing from `metricStates`).
    /// Hidden. Pre-v0.6.2.1 this was visible; v0.6.2.1 fix made it hidden.
    @Test("TRIGGER cold-launch: synth + missing state + anchor nil → HIDDEN")
    func trigger1_coldLaunch() {
        let states: [MetricKind: MetricDataState] = [:]
        #expect(DashboardEmptyTilePolicy.shouldAutoHide(
            Self.synthMetric(),
            states: states,
            fanOutSettledAt: nil,
            now: .now
        ))
    }

    /// **TRIGGER 2 — Pull-to-refresh during fan-out.** Operator's current
    /// report. `resetMetricStatesForRefresh()` cleared state + anchor.
    /// Synth tile is `.unknown` momentarily, then `.empty(.noData)` after
    /// the derive lands. Anchor re-stamps at fan-out completion (~50–500ms
    /// after reset). Pre-v0.6.2.2 the synth-`.empty(.noData)` window was
    /// visible 0–1600ms. Post-v0.6.2.2 hidden the moment state lands.
    @Test("TRIGGER pull-to-refresh: synth + .empty(.noData) + fresh anchor → HIDDEN")
    func trigger2_pullToRefresh() {
        let settled = Date(timeIntervalSince1970: 1_700_000_000)
        // Fan-out just completed (0.1s elapsed) — pre-fix mid-grace, still flicker.
        let now = settled.addingTimeInterval(0.1)
        let states: [MetricKind: MetricDataState] = [.bodyFat: .empty(reason: .noData)]
        #expect(DashboardEmptyTilePolicy.shouldAutoHide(
            Self.synthMetric(),
            states: states,
            fanOutSettledAt: settled,
            now: now
        ))
    }

    /// **TRIGGER 3 — Nav-pop from detail screen.** `.task` re-fires when the
    /// user pops back from `ChartDetailScreen`. The W-TILEHOTFIX set-once
    /// anchor keeps `fanOutSettledAt` unchanged; the prior verdicts are
    /// preserved. Synth tile that was `.empty(.noData)` stays so. Hidden.
    @Test("TRIGGER nav-pop: synth + .empty(.noData) + old anchor → HIDDEN")
    func trigger3_navPop() {
        let settled = Date(timeIntervalSince1970: 1_700_000_000)
        let now = settled.addingTimeInterval(45) // long since the original settle
        let states: [MetricKind: MetricDataState] = [.bodyFat: .empty(reason: .noData)]
        #expect(DashboardEmptyTilePolicy.shouldAutoHide(
            Self.synthMetric(),
            states: states,
            fanOutSettledAt: settled,
            now: now
        ))
    }

    /// **TRIGGER 4 — scenePhase foreground.** Background → active re-fires
    /// `store.refresh()` + `refreshTileStates()`. Anchor is set-once
    /// (W-TILEHOTFIX) and the new synth contract is invariant of timing
    /// regardless. Same as nav-pop.
    @Test("TRIGGER scenePhase-foreground: synth + .empty(.noData) → HIDDEN")
    func trigger4_scenePhaseForeground() {
        let settled = Date(timeIntervalSince1970: 1_700_000_000)
        let now = settled.addingTimeInterval(120) // user backgrounded for 2min
        let states: [MetricKind: MetricDataState] = [.bodyFat: .empty(reason: .noData)]
        #expect(DashboardEmptyTilePolicy.shouldAutoHide(
            Self.synthMetric(),
            states: states,
            fanOutSettledAt: settled,
            now: now
        ))
    }

    /// **TRIGGER 5 — Tab switch (Home → Insights → Home).** SwiftUI cancels
    /// the Home `.task` when the view leaves the visible hierarchy and
    /// re-fires on return. Same observable surface as nav-pop. Anchor
    /// preserved + timing-invariant predicate.
    @Test("TRIGGER tab-switch: synth + .empty(.noData) + old anchor → HIDDEN")
    func trigger5_tabSwitch() {
        let settled = Date(timeIntervalSince1970: 1_700_000_000)
        let now = settled.addingTimeInterval(8) // brief tab visit
        let states: [MetricKind: MetricDataState] = [.bodyFat: .empty(reason: .noData)]
        #expect(DashboardEmptyTilePolicy.shouldAutoHide(
            Self.synthMetric(),
            states: states,
            fanOutSettledAt: settled,
            now: now
        ))
    }

    /// **TRIGGER 6 — Pull-to-refresh during prior fan-out (race).** User
    /// pulls before the previous fan-out completes. The reset clears the
    /// in-flight verdict, the new fan-out re-derives, the synth tile lands
    /// `.empty(.noData)` with a fresh anchor. Mid-grace would have shown
    /// the tile pre-fix. Hidden post-fix.
    @Test("TRIGGER pull-during-fanout: synth + .empty(.noData) + anchor at t=0 → HIDDEN")
    func trigger6_pullDuringFanout() {
        let settled = Date(timeIntervalSince1970: 1_700_000_000)
        let now = settled // exactly at the settle moment — worst-case mid-grace
        let states: [MetricKind: MetricDataState] = [.bodyFat: .empty(reason: .noData)]
        #expect(DashboardEmptyTilePolicy.shouldAutoHide(
            Self.synthMetric(),
            states: states,
            fanOutSettledAt: settled,
            now: now
        ))
    }

    /// **TRIGGER 7 — Server config / layout push.** Server pushes a layout
    /// update mid-session (operator adds a new widget on the web frontend).
    /// The new widget id might land in the synth-placeholder set if no
    /// data; the tile would mount in `.unknown`. Hidden the moment it
    /// appears.
    @Test("TRIGGER layout-push: synth + .unknown + arbitrary anchor → HIDDEN")
    func trigger7_layoutPush() {
        let settled = Date(timeIntervalSince1970: 1_700_000_000)
        let now = settled.addingTimeInterval(15)
        let states: [MetricKind: MetricDataState] = [.bodyFat: .unknown]
        #expect(DashboardEmptyTilePolicy.shouldAutoHide(
            Self.synthMetric(),
            states: states,
            fanOutSettledAt: settled,
            now: now
        ))
    }

    /// **TRIGGER 8 — User toggle in Dashboard customisation.** User flips
    /// a widget visibility in `DashboardLayoutScreen`. The synth tile is
    /// re-evaluated against a state map that may not have an entry for
    /// the kind yet. Hidden.
    @Test("TRIGGER customisation-toggle: synth + missing state → HIDDEN")
    func trigger8_customisationToggle() {
        let states: [MetricKind: MetricDataState] = [:]
        let settled = Date(timeIntervalSince1970: 1_700_000_000)
        let now = settled.addingTimeInterval(5)
        #expect(DashboardEmptyTilePolicy.shouldAutoHide(
            Self.synthMetric(),
            states: states,
            fanOutSettledAt: settled,
            now: now
        ))
    }

    /// **TRIGGER 9 — Logout / re-login race.** `clearOnLogout` resets all
    /// state. Post-login the synth pass runs again. Hidden as a cold launch.
    @Test("TRIGGER logout-relogin: synth + missing state + nil anchor → HIDDEN")
    func trigger9_logoutRelogin() {
        let states: [MetricKind: MetricDataState] = [:]
        #expect(DashboardEmptyTilePolicy.shouldAutoHide(
            Self.synthMetric(),
            states: states,
            fanOutSettledAt: nil,
            now: .now
        ))
    }

    /// **TRIGGER 10 — Series fallback resolves `.empty(.outsideRange)`.**
    /// The user HAS data but older than the queried window. For server
    /// tiles this keeps the "Letzte Messung vor X Tagen" sublabel; for
    /// synth tiles we collapse — the server itself elided the kind, so
    /// surfacing a stale sublabel would contradict the server snapshot.
    @Test("TRIGGER outsideRange-fallback: synth + .empty(.outsideRange) → HIDDEN")
    func trigger10_outsideRangeFallback() {
        let states: [MetricKind: MetricDataState] = [
            .bodyFat: .empty(reason: .outsideRange(latestAt: .now))
        ]
        let settled = Date(timeIntervalSince1970: 1_700_000_000)
        let now = settled.addingTimeInterval(5)
        #expect(DashboardEmptyTilePolicy.shouldAutoHide(
            Self.synthMetric(),
            states: states,
            fanOutSettledAt: settled,
            now: now
        ))
    }

    /// **TRIGGER 11 — `.empty(.sourceFiltered)`.** The user has a manual-
    /// only / Apple-Health-only filter applied. Synth tiles are still
    /// collapsed under the new contract — server elided the kind, the
    /// filter signal is downstream of "server says nothing here".
    @Test("TRIGGER sourceFiltered: synth + .empty(.sourceFiltered) → HIDDEN")
    func trigger11_sourceFiltered() {
        let states: [MetricKind: MetricDataState] = [.bodyFat: .empty(reason: .sourceFiltered)]
        let settled = Date(timeIntervalSince1970: 1_700_000_000)
        let now = settled.addingTimeInterval(5)
        #expect(DashboardEmptyTilePolicy.shouldAutoHide(
            Self.synthMetric(),
            states: states,
            fanOutSettledAt: settled,
            now: now
        ))
    }

    // MARK: - Promotion path — synth tile DOES have data

    /// **TRIGGER 12 — Series fallback promotes to `.ready`.** The synth
    /// tile's per-kind fan-out resolves to `.ready` (data exists in the
    /// queried window). Visible immediately, regardless of anchor.
    @Test("PROMOTION fan-out-ready: synth + .ready → VISIBLE")
    func trigger12_fanOutReady() {
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

    /// **TRIGGER 13 — Post-creation hydration: latestValue.** Rare path
    /// where a synth tile inherits a `latestValue` from a later hydration
    /// pass (e.g. universal sparkline / `hydrateSparkline`). Visible.
    @Test("PROMOTION post-hydrate latestValue: synth carrying value → VISIBLE")
    func trigger13_postHydrateLatestValue() {
        let states: [MetricKind: MetricDataState] = [.bodyFat: .empty(reason: .noData)]
        #expect(!DashboardEmptyTilePolicy.shouldAutoHide(
            Self.synthMetric(latestValue: 22.5),
            states: states,
            fanOutSettledAt: nil,
            now: .now
        ))
    }

    /// **TRIGGER 14 — Post-creation hydration: multi-point sparkline.**
    /// Same as TRIGGER 13 via the sparkline path. Visible.
    @Test("PROMOTION post-hydrate sparkline: synth with 3-point sparkline → VISIBLE")
    func trigger14_postHydrateSparkline() {
        let states: [MetricKind: MetricDataState] = [.bodyFat: .empty(reason: .noData)]
        #expect(!DashboardEmptyTilePolicy.shouldAutoHide(
            Self.synthMetric(sparkline: [22.0, 22.3, 22.1]),
            states: states,
            fanOutSettledAt: nil,
            now: .now
        ))
    }

    // MARK: - Server-emitted tiles — unchanged contract

    /// Server-emitted tile in `.unknown` during fan-out — VISIBLE.
    /// The skeleton paints while data is en route; collapsing during
    /// fan-out is the v0.5.4.1 regression we explicitly do NOT want.
    @Test("SERVER fan-out: server + .unknown + anchor nil → VISIBLE")
    func server_coldLaunch() {
        let states: [MetricKind: MetricDataState] = [.bodyFat: .unknown]
        #expect(!DashboardEmptyTilePolicy.shouldAutoHide(
            Self.serverMetric(),
            states: states,
            fanOutSettledAt: nil,
            now: .now
        ))
    }

    /// Server-emitted tile in `.empty(.noData)` within grace — VISIBLE.
    /// The 1.6 s grace window allows the per-kind fan-out to land.
    @Test("SERVER pre-grace: server + .empty(.noData) + within 1.6s → VISIBLE")
    func server_preGrace() {
        let settled = Date(timeIntervalSince1970: 1_700_000_000)
        let now = settled.addingTimeInterval(1.0)
        let states: [MetricKind: MetricDataState] = [.bodyFat: .empty(reason: .noData)]
        #expect(!DashboardEmptyTilePolicy.shouldAutoHide(
            Self.serverMetric(),
            states: states,
            fanOutSettledAt: settled,
            now: now
        ))
    }

    /// Server-emitted tile in `.empty(.noData)` past grace — HIDDEN.
    /// Same as the v0.5.5.2 contract verbatim.
    @Test("SERVER post-grace: server + .empty(.noData) + past 1.6s → HIDDEN")
    func server_postGrace() {
        let settled = Date(timeIntervalSince1970: 1_700_000_000)
        let now = settled.addingTimeInterval(2.0)
        let states: [MetricKind: MetricDataState] = [.bodyFat: .empty(reason: .noData)]
        #expect(DashboardEmptyTilePolicy.shouldAutoHide(
            Self.serverMetric(),
            states: states,
            fanOutSettledAt: settled,
            now: now
        ))
    }

    /// Server-emitted `.empty(.outsideRange)` — VISIBLE (sublabel signal).
    @Test("SERVER outsideRange: server + .empty(.outsideRange) → VISIBLE")
    func server_outsideRange() {
        let states: [MetricKind: MetricDataState] = [
            .bodyFat: .empty(reason: .outsideRange(latestAt: .now))
        ]
        #expect(!DashboardEmptyTilePolicy.shouldAutoHide(
            Self.serverMetric(),
            states: states,
            fanOutSettledAt: nil,
            now: .now
        ))
    }

    /// Server-emitted `.empty(.sourceFiltered)` — VISIBLE (filter-CTA).
    @Test("SERVER sourceFiltered: server + .empty(.sourceFiltered) → VISIBLE")
    func server_sourceFiltered() {
        let states: [MetricKind: MetricDataState] = [.bodyFat: .empty(reason: .sourceFiltered)]
        #expect(!DashboardEmptyTilePolicy.shouldAutoHide(
            Self.serverMetric(),
            states: states,
            fanOutSettledAt: nil,
            now: .now
        ))
    }

    /// Server-emitted `.empty(.noData)` with latestValue past grace —
    /// VISIBLE. Server snapshot still has data even though local fan-out
    /// came back empty (e.g. paging-window slice).
    @Test("SERVER snapshot wins: server + .empty(.noData) + latestValue + past grace → VISIBLE")
    func server_snapshotWinsLatestValue() {
        let settled = Date(timeIntervalSince1970: 1_700_000_000)
        let now = settled.addingTimeInterval(2.0)
        let states: [MetricKind: MetricDataState] = [.bodyFat: .empty(reason: .noData)]
        #expect(!DashboardEmptyTilePolicy.shouldAutoHide(
            Self.serverMetric(latestValue: 22.5),
            states: states,
            fanOutSettledAt: settled,
            now: now
        ))
    }

    /// Server-emitted `.empty(.noData)` with multi-point sparkline past
    /// grace — VISIBLE. Server-emitted chart wins.
    @Test("SERVER snapshot wins: server + .empty(.noData) + 3pt sparkline + past grace → VISIBLE")
    func server_snapshotWinsSparkline() {
        let settled = Date(timeIntervalSince1970: 1_700_000_000)
        let now = settled.addingTimeInterval(2.0)
        let states: [MetricKind: MetricDataState] = [.bodyFat: .empty(reason: .noData)]
        #expect(!DashboardEmptyTilePolicy.shouldAutoHide(
            Self.serverMetric(sparkline: [22.0, 22.3, 22.1]),
            states: states,
            fanOutSettledAt: settled,
            now: now
        ))
    }
}

// swiftlint:enable file_length
