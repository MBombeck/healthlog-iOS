import SwiftUI

/// v0.12 W4-3 — the SINGLE implementation of the Mood "analysis" body.
///
/// **Why this exists:** the seven analysis sub-views (hero → heatmap → trend →
/// stability → tags → patterns → recent) shipped TWICE, once in
/// `MoodAnalysisScreen` (More → Stimmung) and once in `InsightsMoodPage`
/// (Insights → Stimmung), in the same order with separately-maintained period
/// controls, empty states + sheet wiring. That is double-maintenance: a fix to
/// the heatmap-over-full-history decoupling (B18) or a new sub-view had to land
/// in two places or silently drift.
///
/// **Approach (per the W4-3 brief — "both hosts delegate to one shared body"):**
/// both entry points are preserved, but the seven-section sequence lives here
/// once. Each host hands in:
///   - the `period` binding it owns (a floating control vs. an inline control),
///   - an `EditMoodSheet`-driving `editing` binding + a `showFullHistory`
///     binding (both hosts present these identically),
///   - a `section` decorator so the host can wrap each section in its own
///     entrance treatment (`MoodAnalysisScreen`'s staggered zone fade) or render
///     it plain (`InsightsMoodPage`).
///
/// The shared body reads `MoodStore` from the environment (both hosts inject it)
/// and computes the windowed / full-history insights here so the two surfaces
/// can never diverge on the maths.
struct MoodAnalysisContent<Section: View>: View {
    @Environment(MoodStore.self) private var store

    /// The host-owned period selection (drives the windowed slice).
    let period: MoodPeriod
    /// Cell-tap → edit-one-entry binding (host owns the sheet).
    @Binding var editing: MoodEntry?
    /// "Show all" → full-history push binding (host owns the destination).
    @Binding var showFullHistory: Bool
    /// v0.14.4 E1 — when `true`, the pixel grid is driven by the host's `period`
    /// (the page's bottom range control) instead of its own 12-weeks/year toggle,
    /// and reads the WINDOWED daily averages. The Insights Mood page sets this;
    /// the More → Stimmung host keeps the self-owned toggle over full history.
    var heatmapDrivenByPeriod: Bool = false
    /// v0.14.4 E2 — when `false`, the inline "recent entries" section is dropped
    /// (the Insights Mood page replaces it with the standard "Show all" drill-down
    /// at the page bottom). The More → Stimmung host keeps it.
    var showsRecentSection: Bool = true
    /// **Phase 09 Wave 0** — the measured analysis seam. The default is the
    /// live engine, so both hosts construct this view exactly as before and
    /// compute exactly what they computed before; a test injects a counting
    /// engine, and Plan 09-04 swaps the live one for a revision-keyed cache
    /// without touching either host.
    var analysis: MoodAnalysisEngine = .live
    /// Per-section decorator: the host wraps each section in its own entrance
    /// motion (zone stagger) or renders it verbatim. `index` is the section's
    /// position (0…6) so a staggered host can offset its delay.
    @ViewBuilder let section: (_ index: Int, _ content: AnyView) -> Section

    /// **Phase 09 / plan 09-04.** The analysis this body draws, published on the
    /// main actor after it was computed off it. Owned per view instance; the
    /// *cache* behind it is owned by the store, so the two hosts and a
    /// re-entered screen share one answer rather than one copy each.
    @State private var presenter = MoodAnalysisPresenter()

    /// The pair of keys this evaluation is asking about. Reading it is O(1) —
    /// a revision, a period, a day boundary and a calendar — where the thing it
    /// replaces was a full recomputation from `store.entries`.
    private struct RenderKey: Hashable {
        let windowed: MoodAnalysisKey
        /// `nil` for a host that drives the heatmap by the period control and
        /// therefore never reads the full-history spine. That host must not pay
        /// for an analysis it does not render — which is the behaviour the old
        /// `?:` in `body` produced by accident, and this makes explicit.
        let fullHistory: MoodAnalysisKey?
    }

    private var renderKey: RenderKey {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: .now)
        let revision = store.entriesRevision
        return RenderKey(
            windowed: MoodAnalysisKey(
                revision: revision,
                scope: .windowed,
                periodDays: period.rawValue,
                dayStart: dayStart,
                calendar: calendar,
                enrichment: nil
            ),
            fullHistory: heatmapDrivenByPeriod ? nil : MoodAnalysisKey(
                revision: revision,
                scope: .fullHistory,
                periodDays: nil,
                dayStart: dayStart,
                calendar: calendar,
                enrichment: nil
            )
        )
    }

    /// Client-computed insights over the windowed slice.
    ///
    /// Five sub-views read this and one reads ``fullInsights``; before 09-04
    /// each read was a fresh call into `MoodInsights.compute`, so one body
    /// evaluation ran the whole engine six times over. Now every read is a
    /// property access on a value that was computed once, off this thread.
    /// `.empty` is what an empty history has always produced, so a body that is
    /// still waiting draws the state it already knows how to draw.
    private var insights: MoodInsights {
        presenter.windowed?.insights ?? .empty
    }

    /// **B18 (Walkthrough-4)** — heatmap insights over the FULL history,
    /// decoupled from the period control so its own 12-Wochen / Jahr toggle has
    /// data without first flipping the bottom period control to a year.
    private var fullInsights: MoodInsights {
        presenter.fullHistory?.insights ?? .empty
    }

    private var trendEntries: [MoodTrendChart.Entry] {
        presenter.windowed?.trend ?? []
    }

    /// Adopt this evaluation's keys and publish whatever is still current when
    /// the answer lands. `.task(id:)` cancels the previous one when the key
    /// moves, and the presenter refuses anything that arrives late anyway.
    private func loadAnalysis(_ key: RenderKey) async {
        await presenter.load(
            windowed: key.windowed,
            fullHistory: key.fullHistory,
            entries: store.entries,
            engine: analysis,
            cache: store.analysisCache
        )
    }

    private var windowLabel: String {
        switch period {
        case .days30: String(localized: "in 30 days")
        case .days90: String(localized: "in 90 days")
        case .year: String(localized: "in 1 year")
        }
    }

    var body: some View {
        let key = renderKey
        section(0, AnyView(heroSection(key)))
        section(1, AnyView(heatmapSection))
        section(2, AnyView(trendSection))
        section(3, AnyView(stabilitySection))
        section(4, AnyView(MoodTagInsightSection(deltas: insights.tagDeltas)))
        section(5, AnyView(MoodPatternSection(patterns: insights.patterns)))
        if showsRecentSection {
            section(6, AnyView(recentSection))
        }
    }

    /// v0.14.7 B5 — "Stimmung heute" renders as a section heading ABOVE the
    /// tile (the heading-above-card pattern the Trend / metric pages use), not
    /// as an in-card title. The header lives here so both hosts (Insights →
    /// Stimmung + More → Stimmung) stay in lockstep.
    ///
    /// The analysis task hangs off this section rather than off the whole body:
    /// a modifier applied to a `Group` is applied to *each* of its children, so
    /// wrapping the seven sections to carry one `.task` would have started
    /// seven of them.
    private func heroSection(_ key: RenderKey) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            InsightsSectionHeader("Mood today", flush: true)
            MoodHeroSummary(insights: insights)
        }
        .task(id: key) { await loadAnalysis(key) }
    }

    private var heatmapSection: some View {
        MoodHeatmapSection(
            dailyAverages: heatmapDrivenByPeriod ? insights.dailyAverages : fullInsights.dailyAverages,
            onSelectDay: selectDay,
            period: heatmapDrivenByPeriod ? period : nil
        )
    }

    /// v0.14.6 N5 — the "Verlauf" title is now a section heading ABOVE the card
    /// (matching the metric pages' heading-outside-card pattern), not a
    /// hard-to-read in-card title. Same "Trend" key (renders "Verlauf" in DE).
    private var trendSection: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            InsightsSectionHeader("Trend", flush: true)
            HLCard {
                MoodTrendChart(entries: trendEntries)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var stabilitySection: some View {
        MoodStabilitySection(
            stability: insights.stability,
            entryCount: insights.entryCount,
            windowLabel: windowLabel
        )
    }

    private var recentSection: some View {
        MoodRecentSection(
            entries: store.recents(limit: 7),
            totalCount: store.totalCount,
            onEdit: { editing = $0 },
            onShowAll: { showFullHistory = true }
        )
    }

    /// Heatmap cell tap → open that day's single entry for editing if there is
    /// exactly one; multi-entry days fall through to the full history. Shared by
    /// both hosts so the cell-tap behaviour can never diverge.
    private func selectDay(_ day: Date) {
        let calendar = Calendar.current
        let dayEntries = store.entries.filter { calendar.isDate($0.recordedAt, inSameDayAs: day) }
        if dayEntries.count == 1, let only = dayEntries.first {
            editing = only
        } else if !dayEntries.isEmpty {
            showFullHistory = true
        }
    }
}
