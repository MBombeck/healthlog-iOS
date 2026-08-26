import SwiftUI

// MARK: - AUD-2 H4 — memoized context line

/// The tile's secondary "context line" ("Last measurement X days ago" /
/// "No data yet" / source-filtered) is derived through `MetricDisplay`,
/// which runs `Calendar.current.dateComponents(...)` date math + unit
/// conversion + localized formatting. Computing it inside `var body` meant
/// 10-15 tiles each re-ran that work on EVERY dashboard body invalidation
/// (and every scenePhase=.active return). These helpers memoize the result
/// into `@State`, recomputed only when the tile's inputs change (`.task(id:)`
/// keyed on `contextLineKey`). Hosted in this extension so the additions
/// don't inflate `HLDashboardTile.swift` past its `file_length` budget.
extension HLDashboardTile {
    /// Identity over the inputs of `MetricDisplay.secondaryLine` so the
    /// tile's `.task(id:)` re-derives the cached context line only when its
    /// data actually changes — not on every unrelated store mutation that
    /// re-invalidates the dashboard body.
    var contextLineKey: ContextLineKey {
        ContextLineKey(
            metric: metric,
            dataState: dataState,
            liveTodayStepsOverride: liveTodayStepsOverride,
            units: unitPreferences,
            // BH-final-diff M2 — fold the current day boundary into the key so a
            // relative "X days ago" caption refreshes across midnight / a long
            // foreground session even when the tile's own data is unchanged.
            // Without this, `MetricDisplay`'s default `now: .now` is read once at
            // first compute and the memoized line ages forever.
            dayAnchor: Calendar.current.startOfDay(for: .now)
        )
    }

    /// Build the secondary context line through the shared `MetricDisplay`
    /// projection — identical output to the old `contextLine` computed
    /// property; only the call site (memoized `.task`) changed. The explicit
    /// `now` keeps the rendered line consistent with the `dayAnchor` baked into
    /// `contextLineKey` (BH-final-diff M2).
    func computeContextLine() -> String? {
        MetricDisplay(
            metric: metric,
            dataState: dataState,
            now: .now,
            liveTodayStepsOverride: liveTodayStepsOverride,
            units: unitPreferences
        ).secondaryLine
    }
}

/// Memo key for the tile context line. `Equatable` so `.task(id:)` only
/// re-fires when a field actually changes.
struct ContextLineKey: Equatable {
    let metric: DashboardMetric
    let dataState: MetricDataState
    let liveTodayStepsOverride: Double?
    let units: UnitPreferences
    /// Start-of-day for the current wall clock — discriminator so the memoized
    /// relative-date caption invalidates at the next midnight (BH-final-diff M2).
    let dayAnchor: Date
}
