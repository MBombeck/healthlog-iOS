import SwiftUI

/// Whether a pair of blocks on the metric page may stand side by side. Pure,
/// so the rule is testable without rendering.
enum InsightsMetricColumns {
    /// Two columns only when both sides carry something; with one side empty
    /// the other would stand beside a hole, so the pair stacks.
    static func columns(leading: Bool, trailing: Bool) -> HLPageColumns {
        leading && trailing ? .sideBySide : .single
    }
}

/// The column contents of `InsightsMetricScreen`. Stacked they read in the
/// canonical order of the page; side by side they stand as two columns.
extension InsightsMetricScreen {
    /// Leading column above the chart: the latest reading and the 30 days.
    @ViewBuilder
    var readingColumn: some View {
        // The "Letzte Messung" block (heading + `HeroStrip`), self-suppressing
        // without a latest point.
        lastMeasurementBlock
        // The ONE canonical "30 Tage Durchschnitt" status card, used by every
        // metric; every slot self-suppresses without server signal.
        statusBlock
    }

    /// Whether the leading column above the chart shows anything.
    var hasReadingColumn: Bool {
        store.latestPoint != nil || hasStatusCard
    }

    /// Trailing column above the chart: the assessment and the statistics.
    @ViewBuilder
    var statisticsColumn: some View {
        // **Einschätzung** after the 30-day card, before Min/Ø/Max/Median.
        AssessmentCard(
            assessment: assessment,
            isLoading: assessmentLoading && assessment == nil,
            // QoS-3 — terminal failure caption when the poll gave up while
            // preparing (never while a fetch is still in flight).
            failed: assessmentFailed && !assessmentLoading
        )
        statsBlock
    }

    /// Whether the trailing column above the chart shows anything.
    var hasStatisticsColumn: Bool {
        showsStats || AssessmentCard.resolveState(
            assessment: assessment,
            isLoading: assessmentLoading && assessment == nil,
            failed: assessmentFailed && !assessmentLoading
        ) != .suppressed
    }

    /// Whether the Min/Ø/Max/Median strip shows. Suppressed for event-count
    /// kinds (falls / breathing disturbances), where a sparse single point
    /// makes Min == Ø == Max degenerate, matching the web sub-pages.
    var showsStats: Bool {
        store.stats != nil && store.dataState.hasValue && !kind.suppressesAggregateStats
    }

    @ViewBuilder
    var statsBlock: some View {
        if showsStats {
            if kind == .bloodPressure, store.diastolicStats != nil {
                // BP carries two components. The server `SeriesStats` covers
                // systolic only; diastolic is aggregated on-device. One raster
                // with a systolic row over a diastolic row, each under its
                // heading, matching the web BP sub-page.
                let prefs = settingsStore.unitPreferences
                HLStatGrid(sections: [
                    bloodPressureStatsSection(
                        title: String(localized: "insights.bp.stats.systolic"),
                        stats: store.stats,
                        median: store.median,
                        units: prefs
                    ),
                    bloodPressureStatsSection(
                        title: String(localized: "insights.bp.stats.diastolic"),
                        stats: store.diastolicStats,
                        median: store.diastolicMedian,
                        units: prefs
                    )
                ])
            } else {
                // The stats in the user's chosen unit (kg→lb, mmHg→kPa);
                // glucose stays on the server-converted series unit.
                let prefs = settingsStore.unitPreferences
                StatsRow(stats: store.stats, median: store.median, unit: store.displayUnit(units: prefs), kind: kind, units: prefs)
            }
        }
    }

    /// Trailing column under the relationships: the pointer to the ECG
    /// recordings and the path to the raw readings.
    @ViewBuilder
    var linksColumn: some View {
        // P8 (v0141 parity) — pulse-only cross-link into the ECG recordings;
        // un-mounts entirely without recordings.
        ecgCrossLinkRow
        // The one drill row of every detail page, in a card of its own. The
        // count is the page the list endpoint lands on in this period; an
        // empty period with readings elsewhere says they lie outside it.
        DrillDownRow(
            kind: kind,
            count: store.recentInRange.count,
            hasDataOutsideRange: store.dataState.isOutsideRange
        )
    }
}
