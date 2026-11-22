import SwiftUI

/// The SINGLE implementation of the Mood "analysis" body.
///
/// **Why this exists:** the seven analysis sub-views (hero, stability, trend,
/// heatmap, tags, patterns, recent) shipped TWICE, once in
/// `MoodAnalysisScreen` (More → Stimmung) and once in `InsightsMoodPage`
/// (Insights → Stimmung), in the same order with separately-maintained period
/// controls, empty states + sheet wiring. That is double-maintenance: a fix to
/// the heatmap-over-full-history decoupling or a new sub-view had to land
/// in two places or silently drift.
///
/// **Approach (per the W4-3 brief — "both hosts delegate to one shared body"):**
/// the seven-section sequence lives here once. A host hands in:
///   - the `period` binding it owns,
///   - an `EditMoodSheet`-driving `editing` binding + a `showFullHistory`
///     binding,
///   - a `section` decorator so the host can wrap each section in its own
///     entrance treatment or render it plain (`InsightsMoodPage`).
///
/// The second host, `MoodAnalysisScreen`, had no call site since the
/// v0.11 IA removed its More row and was deleted; the seams stay so the body
/// remains testable on its own (`MoodAnalysisContentTests`).
///
/// The shared body reads `MoodStore` from the environment (both hosts inject it)
/// and computes the windowed / full-history insights here so the two surfaces
/// can never diverge on the maths.
struct MoodAnalysisContent<Section: View>: View {
    @Environment(MoodStore.self) private var store
    /// The server's stability rides the relations payload
    /// (`GET /api/mood/insights`, SWR-cached, already loaded by the Insights
    /// host; the More → Stimmung host loads it here).
    /// Optional so a host without the store (previews, render tests) still
    /// draws; the section then shows no stability, never a computed one.
    @Environment(MoodRelationsStore.self) private var relationsStore: MoodRelationsStore?
    /// The dashboard snapshot carries the server's mood verdict
    /// (`tiles.directions["MOOD"]`). Optional for the same reason as above.
    @Environment(DailyBriefingStore.self) private var briefingStore: DailyBriefingStore?

    /// The host-owned period selection (drives the windowed slice).
    let period: MoodPeriod
    /// Cell-tap → edit-one-entry binding (host owns the sheet).
    @Binding var editing: MoodEntry?
    /// "Show all" → full-history push binding (host owns the destination).
    @Binding var showFullHistory: Bool
    /// When `true`, the pixel grid is driven by the host's `period`
    /// (the page's bottom range control) instead of its own 12-weeks/year toggle,
    /// and reads the WINDOWED daily averages. The Insights Mood page sets this;
    /// the More → Stimmung host keeps the self-owned toggle over full history.
    var heatmapDrivenByPeriod: Bool = false
    /// When `false`, the inline "recent entries" section is dropped
    /// (the Insights Mood page replaces it with the standard "Show all" drill-down
    /// at the page bottom). The More → Stimmung host keeps it.
    var showsRecentSection: Bool = true
    /// The measured analysis seam. The default is the
    /// live engine, so both hosts construct this view exactly as before and
    /// compute exactly what they computed before; a test injects a counting
    /// engine, and Plan 09-04 swaps the live one for a revision-keyed cache
    /// without touching either host.
    var analysis: MoodAnalysisEngine = .live
    /// Per-section decorator: the host wraps each section in its own entrance
    /// motion (zone stagger) or renders it verbatim. `index` is the section's
    /// position in ``MoodAnalysisSection/order`` so a staggered host can offset
    /// its delay.
    @ViewBuilder let section: (_ index: Int, _ content: AnyView) -> Section

    /// The analysis this body draws, published on the
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
                enrichment: store.dailySeries
            ),
            fullHistory: heatmapDrivenByPeriod ? nil : MoodAnalysisKey(
                revision: revision,
                scope: .fullHistory,
                periodDays: nil,
                dayStart: dayStart,
                calendar: calendar,
                enrichment: store.dailySeries
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
        MoodAnalysisSection.windowLabel(for: period)
    }

    /// The sections in the order of every detail page: the figure, the
    /// statistic, the chart, then the deeper blocks and the entries. Each
    /// index comes from ``MoodAnalysisSection/order(hasPatterns:showsRecent:)``,
    /// so the drawn order and the tested order are one list.
    var body: some View {
        let key = renderKey
        // The patterns of the chosen period (`?days`), never the year's; an
        // older server sends none and the section is absent.
        let patterns = relationsStore?.patterns(forDays: period.rawValue)
        let order = MoodAnalysisSection.order(hasPatterns: patterns != nil, showsRecent: showsRecentSection)
        section(order.position(of: .hero), AnyView(heroSection(key)))
        section(order.position(of: .stability), AnyView(stabilitySection))
        section(order.position(of: .trend), AnyView(trendSection))
        section(order.position(of: .heatmap), AnyView(heatmapSection))
        section(order.position(of: .tags), AnyView(MoodTagInsightSection(deltas: insights.tagDeltas)))
        if let patterns {
            section(order.position(of: .patterns), AnyView(MoodPatternSection(patterns: patterns)))
        }
        if showsRecentSection {
            section(order.position(of: .recent), AnyView(recentSection))
        }
    }

    /// "Stimmung heute" renders as a section heading ABOVE the
    /// tile (the heading-above-card pattern the Trend / metric pages use), not
    /// as an in-card title. The header lives here so both hosts (Insights →
    /// Stimmung + More → Stimmung) stay in lockstep.
    ///
    /// The analysis task hangs off this section rather than off the whole body:
    /// a modifier applied to a `Group` is applied to *each* of its children, so
    /// wrapping the seven sections to carry one `.task` would have started
    /// seven of them.
    private func heroSection(_ key: RenderKey) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HLSectionHeader("Mood today", rank: .area)
            MoodHeroSummary(insights: insights, verdict: briefingStore?.snapshotBriefing?.directions["MOOD"]?.direction)
        }
        .moodSectionGap()
        .task(id: key) { await loadAnalysis(key) }
        // The server's day means and stability. Re-read when the
        // entries move (a write drops the series' SWR row); not on launch.
        .task(id: store.entriesRevision) {
            await store.loadDailySeries()
            if let relationsStore, relationsStore.response == nil { await relationsStore.load() }
        }
        // Stability follows the chosen period (`?days=`).
        .task(id: period) { await relationsStore?.loadStability(days: period.rawValue) }
    }

    private var heatmapSection: some View {
        MoodHeatmapSection(
            dailyAverages: heatmapDrivenByPeriod ? insights.dailyAverages : fullInsights.dailyAverages,
            onSelectDay: selectDay,
            period: heatmapDrivenByPeriod ? period : nil
        )
    }

    /// The "Verlauf" title is now a section heading ABOVE the card
    /// (matching the metric pages' heading-outside-card pattern), not a
    /// hard-to-read in-card title. Same "Trend" key (renders "Verlauf" in DE).
    ///
    /// With fewer than two days there is no line to draw, and the card
    /// is absent rather than a heading over "not enough entries".
    @ViewBuilder
    private var trendSection: some View {
        if MoodTrendPresence.isShown(trendEntries) {
            VStack(alignment: .leading, spacing: 0) {
                HLSectionHeader("Trend", rank: .area)
                HLCard {
                    MoodTrendChart(series: presenter.windowed?.trendSeries ?? .empty)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .moodSectionGap()
        }
    }

    private var stabilitySection: some View {
        MoodStabilitySection(
            stability: relationsStore?.stability(forDays: period.rawValue),
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

/// The sections of the mood analysis in page order (figure, statistic,
/// chart, deeper blocks, entries). Data, so a test can read the order the
/// body draws without rendering it.
enum MoodAnalysisSection: Hashable, CaseIterable {
    case hero
    case stability
    case trend
    case heatmap
    case tags
    case patterns
    case recent

    /// The sections a body draws; a missing one moves the next one up, so the
    /// indices stay contiguous.
    static func order(hasPatterns: Bool, showsRecent: Bool) -> [MoodAnalysisSection] {
        allCases.filter { kind in
            switch kind {
            case .patterns: hasPatterns
            case .recent: showsRecent
            default: true
            }
        }
    }

    /// The analysis body's index for the recent-entries section.
    static func recentIndex(hasPatterns: Bool) -> Int {
        order(hasPatterns: hasPatterns, showsRecent: true).position(of: .recent)
    }

    /// The window under the entry count, named after the page's period.
    static func windowLabel(for period: MoodPeriod) -> String {
        switch period {
        case .day: String(localized: "Today")
        case .week: String(localized: "mood.window.week")
        case .month: String(localized: "in 30 days")
        case .sixMonths: String(localized: "mood.window.sixMonths")
        case .year: String(localized: "in 1 year")
        case .all: String(localized: "All data")
        }
    }
}

extension [MoodAnalysisSection] {
    /// The index a section is drawn at; past the end when it is not drawn.
    func position(of kind: MoodAnalysisSection) -> Int {
        firstIndex(of: kind) ?? count
    }
}

/// **When the mood trend card is there at all.** The trend needs two
/// different days, the threshold below which `MoodTrendChart` itself would only
/// draw its sparse state. Outside the generic host so a test can ask it.
enum MoodTrendPresence {
    static func isShown(_ entries: [MoodTrendChart.Entry], calendar: Calendar = .current) -> Bool {
        Set(entries.map { calendar.startOfDay(for: $0.date) }).count >= 2
    }
}

extension View {
    /// A mood section hands its header and card to the host page as one view.
    /// The header then stands in this stack rather than in the page's, so the
    /// stack says that the page's gap is above it and its own gap below.
    func moodSectionGap(after spacing: CGFloat = 0) -> some View {
        environment(\.hlContainerGap, HLContainerGap(before: HLLayout.cardGap, after: spacing))
    }
}
