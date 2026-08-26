import Foundation

/// **v0.5.5.2 hide-empty-tiles policy.** Operator-feedback on v0.5.4.x:
/// "guck wie wir es schaffen dass nur Kacheln angezeigt werden, die auch
/// Daten haben." The previous v0.5.4.1 softening (every branch returned
/// `false` → empty placeholders stayed painted forever as em-dash tiles)
/// inverted the operator's mental model: the dashboard advertised metric
/// kinds the user has no data for, with no clear affordance to do
/// anything about it. The 8-tile strip on a fresh device read as
/// "broken card wall," not "Apple-Health-style coverage."
///
/// **New contract (v0.5.5.2):**
/// - `state == .ready` → tile visible.
/// - `state == .empty(.outsideRange)` → tile visible (carries the
///   "Letzte Messung vor X Tagen" sublabel signal).
/// - `state == .empty(.sourceFiltered)` → tile visible (carries the
///   filter-clear CTA copy).
/// - `state == .unknown` / `.loading` → tile visible (skeleton-rendered by
///   the tile itself while the fan-out is in flight — collapsing the strip
///   mid-load reads as broken).
/// - `state == .empty(.noData)`:
///   - If the metric carries a `latestValue` OR a non-empty sparkline →
///     visible (server snapshot still has data).
///   - Else, before the 1.6s post-`fanOutSettledAt` grace has expired →
///     visible (give the per-kind derivation a chance to land).
///   - Else → **HIDDEN**.
///
/// **Why 1.6s?** Operator real-device walkthrough on v0.5.2-R3 A-H1
/// established the same threshold for the policyTick observer: covers
/// the worst-case "summary cached but per-kind series fan-out still in
/// flight" window without leaving a placeholder painted long enough
/// that the user thinks the tile is real. Sub-1s flickers on warm-
/// launches; >2s lets em-dash tiles read as steady-state.
///
/// When `fanOutSettledAt == nil` the policy holds the tile visible —
/// the dashboard is still in its initial load and hiding tiles before
/// any fan-out result has landed is indistinguishable from "broken."
///
/// **v0.6.2.2 W-TILE-AUDIT — structural fix.** Operator on build 71
/// (2026-05-25, third report): "Dann refreshe ich die Seite, indem ich
/// mit meinem Daumen runterziehe, und dann sehe ich auch so was wie
/// Körperfett, Ruhepuls, Temperatur, wo ich überhaupt keine Daten habe."
///
/// Three prior fixes (W-TILEHOTFIX v0.6.2, W-COLD-LAUNCH-FLICKER v0.6.2.1
/// and v0.5.5.5 REG-11) all patched specific trigger paths on top of a
/// time-based grace window. Each fix closed one path; the bug shifted to
/// the next. Pull-to-refresh re-opened it because it clears
/// `fanOutSettledAt` and `metricStates`, then the new fan-out re-stamps
/// the anchor — and any synth tile that ends up `.empty(.noData)` reopens
/// the same 1.6 s grace flicker the cold-launch fix tried to kill.
///
/// **Structural diagnosis.** The grace window is the wrong tool for
/// synth placeholders. A synth placeholder exists precisely because the
/// server did NOT surface the kind in its summary fast-path — the prior
/// is "no data". There is no late-arriving server snapshot to wait for.
/// The only data source that can promote a synth tile is the per-kind
/// `series` fan-out, and that resolution is observed via the
/// `metricStates` map change itself, not via a timer. A time-based grace
/// for synth tiles is unconditional flicker waiting to happen.
///
/// **New rule (v0.6.2.2).** Synth tiles (`id.hasPrefix("synth-")`) are
/// visibility-from-data only, NO TIMING. A synth tile is visible iff:
///   - state == `.ready` (fan-out promoted it), OR
///   - it carries server-snapshot data (`latestValue != nil` OR sparkline
///     ≥ 2 — paranoid defence against future hydration ordering).
/// All other synth states (`.unknown`, `.loading`, `.empty(...)`) collapse
/// the tile immediately, independent of `fanOutSettledAt`. Cannot
/// oscillate because there is no time-based predicate left to oscillate
/// on. Server-emitted tiles (non-synth ids) keep the v0.5.5.2 contract
/// verbatim: skeleton-paint during fan-out, grace-window collapse for
/// `.empty(.noData)`, sublabel sticky for `.outsideRange`/`.sourceFiltered`.
///
/// Why not "drop the grace globally": server-emitted tiles encode the
/// "server says you have data" signal — collapsing them mid-fan-out
/// reads as broken card wall (the regression that motivated v0.5.5.2
/// in the first place). Synth tiles encode the opposite ("server says
/// no data") so they deserve the opposite default.
public enum DashboardEmptyTilePolicy {
    /// Grace window between `fanOutSettledAt` being recorded and the
    /// `.empty(.noData)` thin tile collapsing. See type doc-comment for
    /// rationale.
    public static let loadingTimeoutSeconds: TimeInterval = 1.6

    /// Legacy two-arg entry point — kept for source-compat with call
    /// sites that don't yet thread the fan-out-settled timestamp through.
    /// Without the timestamp the policy assumes the fan-out has not
    /// settled and therefore never hides (the safe, never-collapse
    /// default).
    public static func shouldAutoHide(
        _ metric: DashboardMetric,
        states: [MetricKind: MetricDataState]
    ) -> Bool {
        shouldAutoHide(metric, states: states, fanOutSettledAt: nil, now: .now)
    }

    /// **v0.6.2.2 W-TILE-AUDIT entry point.** Synth tiles are visibility-
    /// from-data only; server-emitted tiles keep the v0.5.5.2 grace-window
    /// behaviour. See type doc-comment for full rationale.
    public static func shouldAutoHide(
        _ metric: DashboardMetric,
        states: [MetricKind: MetricDataState],
        fanOutSettledAt: Date?,
        now: Date = .now
    ) -> Bool {
        // **v0.6.2.2 structural rule.** Synth placeholders branch off the
        // shared predicate entirely — they have no server snapshot to wait
        // for, so a time-based grace window is unconditional flicker. Pure
        // data-presence check: visible iff `.ready` or carries a hydrated
        // server snapshot (`latestValue` / multi-point sparkline). All
        // other states collapse instantly. This is invariant against
        // `fanOutSettledAt` mutation, which closes every flicker-trigger
        // path identified by the v0.6.2.2 audit (cold launch, pull-to-
        // refresh, nav-pop, tab-return, scenePhase foreground, server
        // config push, layout toggle, logout/login race).
        if isSynthPlaceholder(metric) {
            return shouldAutoHideSynth(metric, states: states)
        }
        // Server-emitted path — v0.5.5.2 + REG-11 (v0.5.5.5) verbatim.
        return shouldAutoHideServerEmitted(
            metric,
            states: states,
            fanOutSettledAt: fanOutSettledAt,
            now: now
        )
    }

    /// **v0.6.2.2 synth-tile visibility predicate — DATA-ONLY, NO TIMING.**
    /// A synth placeholder exists because the server did NOT surface the
    /// kind in its summary fast-path. The only legitimate promotion path
    /// is the per-kind `series` fan-out resolving to `.ready` (or, very
    /// rarely, post-creation hydration writing a `latestValue`/sparkline
    /// onto the synth metric). Everything else collapses the tile.
    /// Independent of `fanOutSettledAt` so this branch cannot oscillate.
    private static func shouldAutoHideSynth(
        _ metric: DashboardMetric,
        states: [MetricKind: MetricDataState]
    ) -> Bool {
        let state = states[metric.kind] ?? .unknown
        if case .ready = state { return false }
        if metric.latestValue != nil { return false }
        if metric.sparkline.count >= 2 { return false }
        // `.unknown`, `.loading`, every `.empty(...)` reason — hide.
        return true
    }

    /// Server-emitted tile predicate — preserves v0.5.5.2 + REG-11 v0.5.5.5
    /// behaviour verbatim so the "skeleton paint during fan-out" UX stays
    /// intact for kinds the server DID surface.
    private static func shouldAutoHideServerEmitted(
        _ metric: DashboardMetric,
        states: [MetricKind: MetricDataState],
        fanOutSettledAt: Date?,
        now: Date
    ) -> Bool {
        let state = states[metric.kind] ?? .unknown
        switch state {
        case .ready:
            return false
        case .empty(.outsideRange), .empty(.sourceFiltered):
            // Data exists, just not in scope or hidden by filter — keep
            // the tile so the UI can surface the sublabel or filter-CTA.
            return false
        case .unknown, .loading:
            // Server explicitly surfaced this kind — skeleton paints until
            // the per-kind derivation lands. Never hide during fan-out.
            return false
        case .empty(.noData):
            // **REG-11 v0.5.5.5.** Multi-point server sparkline keeps the
            // tile; single-point residue does not (renders as a hairline
            // that the operator reads as broken).
            if metric.latestValue != nil { return false }
            if metric.sparkline.count >= 2 { return false }
            // Pre-grace window — hold visible so a slow fan-out doesn't
            // flicker the strip. After the grace, collapse.
            guard let settled = fanOutSettledAt else { return false }
            let elapsed = now.timeIntervalSince(settled)
            return elapsed >= Self.loadingTimeoutSeconds
        }
    }

    /// **v0.6.2.1 cold-launch flicker fix.** Detects placeholder tiles
    /// produced by `DashboardStore.synthesiseMissingTiles`. The synth
    /// generator stamps `id = "synth-<kind>-<order>"` (see
    /// `DashboardStore.placeholder(for:order:)`) — the prefix is the
    /// canonical "this tile came from the layout fallback, not the
    /// server summary" signal. Server-emitted tiles never carry this
    /// prefix.
    static func isSynthPlaceholder(_ metric: DashboardMetric) -> Bool {
        metric.id.hasPrefix("synth-")
    }
}
