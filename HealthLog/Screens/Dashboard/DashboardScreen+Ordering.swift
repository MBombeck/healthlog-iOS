import SwiftUI

extension DashboardScreen {
    /// v0.15.7 W-RHYTHM-FRONTDOOR — the Home front-door summary for the device-
    /// health-notifications (ECG/AFib rhythm-events) card, or `nil` when the
    /// wearable has flagged nothing (→ the tile self-suppresses). Resolved ONCE
    /// here via the pure `RhythmEventsTileModel.summary` selector and threaded
    /// into the tile, so the placement gate and the rendered subtitle share one
    /// truth. The store's `events` is already empty in standalone / on every
    /// no-data / error arm, so this naturally hides without a server.
    var rhythmEventsSummary: RhythmEventsTileModel.Summary? {
        RhythmEventsTileModel.summary(for: rhythmEventsStore.events)
    }

    /// PA4 + DASHBOARD-TILE-COMPLETENESS — synthesise placeholder tiles for
    /// missing layout entries first, then re-derive per-kind `MetricDataState`
    /// via the same endpoint chart-detail uses (hydrates placeholders too).
    ///
    /// INV-3 (v0157) — stays on `DashboardScreen` because the parent's
    /// `.task` / `.onChange` / `.hlPullToRefresh` closures call it. The
    /// body-render ordering helpers moved to `DashboardMetricOrdering` (a static
    /// namespace the leaf hosts call) so they no longer register on this screen's
    /// body.
    func refreshTileStates() async {
        guard let container else { return }
        store.synthesiseMissingTiles(layout: layoutStore.layout)
        let kinds: [MetricKind] = store.summary?.metrics.map(\.kind) ?? MetricKind.allCases
        // b241 Fix 2 — hand the mood snapshot to the fan-out so the `.mood` tile
        // state derives from `MoodStore.entries` (the real 483-row history served
        // by `/api/mood-entries`) instead of the always-empty `/api/measurements`
        // path. MoodStore is already loaded on the dashboard `.task`.
        await store.refreshMetricStates(
            kinds: kinds,
            measurementsRepo: container.measurementsRepo,
            moodEntries: moodStore.entries
        )
    }
}
