import SwiftUI

/// The Insights **Mood** special page (web `/insights/mood`).
///
/// A composite page (NOT a single-metric chart) in the order of every detail
/// page: header, the analysis from the shared `MoodAnalysisContent` (today,
/// steadiness, course, calendar, tags, patterns), then the relationships, the
/// drill row to all entries and the sync footer.
///
/// **Lives inside the Insights pager.** It owns NO
/// `NavigationStack` (the container's shared stack does) and puts its period
/// choice right above the course chart like the metric pages. The page wrapper in `InsightsContainerScreen` pins it with
/// `.containerRelativeFrame(.horizontal)` ONLY (the W44 contract).
///
/// **Self-suppress:** the page only ever renders when the operator has ≥1 mood
/// entry (gated upstream by `availableSpecials`); the defensive empty branch is a
/// calm `ContentUnavailableView`, never a dead box.
struct InsightsMoodPage: View {
    @Environment(MoodStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// I-1 D — the Mood × blood-pressure correlation card was relocated here off
    /// the Insights overview. Reads the server `comprehensive` digest (the same
    /// source `CorrelationsPanel` uses), so the Mood page needs `InsightsStore`.
    @Environment(InsightsStore.self) private var insightsStore
    /// The LIVE mood-relations slices (`GET /api/mood/insights`,
    /// server v1.11.5): tag-influence + the "better days" board. Server-derived
    /// + association-not-cause; self-suppresses below its sample/confidence
    /// floors. The Daylio mood-tag payoff.
    @Environment(MoodRelationsStore.self) private var relationsStore
    /// Routes the empty-state CTA to the mood quick-entry sheet
    /// so a first-time user has a next step instead of a dead-end empty page.
    @Environment(AppRouter.self) private var router

    @State private var period: MoodPeriod = .month
    @State private var editing: MoodEntry?
    @State private var showFullHistory = false
    /// The data-span → default-period auto-select runs exactly ONCE
    /// per page lifetime. After it fires (or the operator picks a period via the
    /// period choice) this latches `true` so a later SWR refresh / re-appear
    /// never overrides a value the operator is looking at.
    @State private var didAutoSelectPeriod = false

    var body: some View {
        content
            // The period bar of every detail page: the free floating
            // capsule, shown only with entries so the empty
            // state stays clean. `MoodPeriod` is an `HLRangeOption`, so the
            // auto-selected span still flows through `$period`.
            .hlPeriodBar(selection: $period, label: "Time range", isShown: !store.entries.isEmpty)
            .sheet(item: $editing) { entry in
                EditMoodSheet(entry: entry, onDismiss: { editing = nil })
                    .hlSheetPresentation(.form)
            }
            // The `✦` Coach explainer sheet, the SAME `AskCoachSheet`
            // the Insights overview + per-metric Coach circles present, so the Mood
            // page's top-right Coach reads identically to every other page.
            .sheet(isPresented: $presentCoach, onDismiss: {
                coachSeedOverride = nil
                coachScopeOverride = nil
            }, content: {
                // The Mood page Coach hands off the mood scope: a
                // localized opener + `scope { sources: [mood] }` so the first server
                // turn narrows the snapshot to mood instead of opening blank. A
                // correlation card overrides both with the pair-specific seed/scope.
                AskCoachSheet(
                    seed: coachSeedOverride ?? AskCoachSheet.moodSeed,
                    launchScope: coachScopeOverride ?? CoachLaunchScope(metric: .mood)
                )
                .hlZoomTransition(from: HLTabHeaderAction.Role.coach, in: coachZoom)
            })
            .environment(\.hlActionZoomNamespace, coachZoom)
            // The Settings circle pushes the Insights customisation
            // screen (the SAME destination the overview's customise circle opens),
            // giving the Mood header the canonical two-equal-circles trailing slot.
            .navigationDestination(isPresented: $presentSettings) {
                SettingsInsightsCustomizationScreen()
            }
            .navigationDestination(isPresented: $showFullHistory) {
                MoodHistoryScreen()
            }
            // On first appear, pick the default period from the span of
            // the operator's mood history (computed offline from `store.entries`):
            // > ~3 months → "letztes Jahr"; a moderate span → 90d; very little data
            // → 30d. Runs once (`didAutoSelectPeriod` latch) and never overrides an
            // explicit manual choice within the session. Also fires after a load
            // resolves the first batch of entries (the `id:` keys on the count).
            .task(id: store.entries.count) {
                autoSelectPeriodIfNeeded()
            }
    }

    /// `✦` Coach surface, present only when the assistant is on.
    @State private var presentCoach = false
    /// The coach sheet grows out of the coach button in the bar.
    @Namespace private var coachZoom
    /// When a correlation card opens the Coach it overrides the
    /// page's mood seed/scope with the pair-specific one. `nil` → the page mood
    /// handoff. Reset on dismiss.
    @State private var coachSeedOverride: String?
    @State private var coachScopeOverride: CoachLaunchScope?
    /// The Insights-customisation Settings surface.
    @State private var presentSettings = false

    /// Task #53 parity — true when ANY assistant surface should show (the user
    /// chose `.onDevice` or `.online`; `.none` hides everything). Gates the
    /// header `✦` Coach circle exactly like `InsightsMetricScreen`.
    @Environment(\.appContainer) private var appContainer
    private var aiSurfacesVisible: Bool {
        appContainer?.aiMode != AIMode.none && appContainer?.aiMode != nil && appContainer.offersCoach // #115 · 0.2
    }

    /// The header actions in the fixed order: the page's one (i), the
    /// Insights customisation, then the coach while the assistant is on.
    private var headerActions: HLTabHeaderActions {
        // The (i) explains the correlation method only when the mood x
        // blood-pressure card is on the page.
        var items: [HLTabHeaderAction] = [
            .info(
                InsightsSpecialPageInfo.mood(showsCorrelation: moodCorrelationPanel != nil),
                identifier: "insights.mood.info"
            ),
            .settings(label: "Customise insights", identifier: "insights.mood.settings") {
                presentSettings = true
            }
        ]
        if aiSurfacesVisible {
            items.append(.coach(identifier: "insights.mood.explainer") { presentCoach = true })
        }
        return HLTabHeaderActions(items)
    }

    /// In the Insights pager the head is pinned above the strip.
    @Environment(\.insightsInPager) private var inPager

    /// The page's head: pinned above the strip in the pager, at the top
    /// of the content elsewhere.
    private var pageHeader: some View {
        HLTabHeader(
            "Mood",
            titleIdentifier: "insights.page.header.title.mood",
            actions: headerActions
        )
    }

    /// The page stands in every state, so the title does not jump when the
    /// entries arrive; without entries the empty state sits in the free area.
    private var content: some View {
        HLPage {
            // The canonical per-page header, so the top of the page does not
            // jump between a metric page and Mood. The period stands above
            // the course chart, not as a line under the title.
            if !inPager {
                pageHeader
            }
            HLStateContainer(store.entries.isEmpty ? .empty : .loaded) {
                EmptyView()
            } empty: {
                emptyState
            } content: {
                // The seven analysis sub-views now come from the
                // shared `MoodAnalysisContent` (one implementation; the More →
                // Stimmung screen renders the same sections with a staggered
                // entrance). This host renders each section plain (the pager owns
                // the entrance); the period control floats at the bottom
                // safe-area, no longer inline.
                MoodAnalysisContent(
                    period: period,
                    editing: $editing,
                    showFullHistory: $showFullHistory,
                    heatmapDrivenByPeriod: true,
                    showsRecentSection: false
                ) { _, content in
                    content
                }

                // The LIVE mood-relations region (tag-influence +
                // "better days" board) from `GET /api/mood/insights`. The
                // payoff of the Daylio mood tags: what is associated with
                // better-mood days, honestly framed as association-not-cause.
                relationsBlock

                // I-1 D — the Mood × blood-pressure correlation card, relocated
                // off the overview onto the metric it concerns. Self-suppresses
                // when there's no ok pairing (no empty card).
                correlationBlock

                // The canonical bottom-of-page "Show all
                // measurements" drill-down, mirroring `DrillDownRow` on every
                // metric page. Count is range-bound (entries in the selected
                // window); when the window is empty but the operator HAS mood
                // entries elsewhere, the v0.14.4 D2 "outside the period" copy
                // routes them honestly. Tap pushes the shared `MoodHistoryScreen`
                // (the mood entries list) via the existing `showFullHistory`.
                MoodDrillDownRow(
                    count: entriesInRangeCount,
                    hasDataOutsideRange: entriesInRangeCount == 0 && !store.entries.isEmpty,
                    onTap: { showFullHistory = true }
                )

                // Canonical sync-status footer (same
                // primitive as Dashboard/Insights, self-suppressing).
                HLSyncStatusFooter(screenLoading: store.isLoading)
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: period)
        // WHOOP-style pull-to-refresh (custom glyph + checkmark + one
        // success haptic; the handshake driving the checkmark runs in the modifier).
        .hlPullToRefresh {
            await store.load()
            await relationsStore.refresh()
        }
        // In the pager the head stands fixed at the top, over the strip.
        .insightsPageHead(enabled: inPager) { pageHeader }
        // Warm the LIVE mood-relations cards (server-derived).
        // Idempotent — the repo's SWR row single-flights.
        .task {
            await relationsStore.load()
        }
    }

    /// The LIVE mood-relations region: an "Influence on mood" card +
    /// a "Better days" board, under a shared `HLSectionHeader`. Server-
    /// derived; gated on a cloud surface. Never a fabricated correlation.
    ///
    /// The section exists only with rows. Below the server's floors
    /// it used to stand as a "not enough data yet" card for good, for everyone
    /// who does not use tags.
    @ViewBuilder
    private var relationsBlock: some View {
        if relationsStore.hasContent {
            Group {
                // The right-aligned grey caption was removed (the C2
                // cleanup applied elsewhere); the header stands alone, calmer.
                HLSectionHeader("What shapes your mood", rank: .area)
                MoodInfluenceCard(
                    structuredRows: relationsStore.structuredInfluence,
                    flatRows: relationsStore.flatInfluence
                )
                MoodBetterDaysCard(factors: relationsStore.betterDays)
                // The RATED-factor × metric crosstab card (server
                // v1.14.0 `factorCrosstab`): the first iOS surface for the
                // analytical USE of the slider rating values. Self-suppresses
                // when the server returned no significant row.
                MoodFactorCrosstabCard(rows: relationsStore.factorCrosstab)
            }
        }
    }

    /// I-1 D — the relocated Mood × blood-pressure correlation card. Same render
    /// contract as `InsightsMetricScreen.correlationBlock`: a "Relationships"
    /// section header + the single-pair `CorrelationsPanel` (with its safety
    /// disclaimer), shown only when the digest carries an ok pairing.
    @ViewBuilder
    private var correlationBlock: some View {
        if let panel = moodCorrelationPanel {
            Group {
                HLSectionHeader("Relationships", rank: .area)
                panel
            }
        }
    }

    /// The mood x blood-pressure panel, `nil` when it has no card. The (i)
    /// asks too: it explains the correlation only when the card is there.
    private var moodCorrelationPanel: CorrelationsPanel? {
        guard let digest = insightsStore.digest else { return nil }
        // The relocated mood×BP card carries an "Ask the coach
        // about this" link, pre-scoped to both metrics in the pair.
        let panel = CorrelationsPanel(
            digest: digest,
            pairs: [.moodBp],
            onAskCoach: { pair in
                coachSeedOverride = pair.coachSeed
                coachScopeOverride = pair.coachLaunchScope
                presentCoach = true
            }
        )
        return panel.hasAnyCard ? panel : nil
    }

    /// Apply the span-derived default period ONCE, only when there
    /// is data and the operator hasn't already made a choice this session.
    private func autoSelectPeriodIfNeeded() {
        guard !didAutoSelectPeriod, !store.entries.isEmpty else { return }
        didAutoSelectPeriod = true
        period = Self.defaultPeriod(forSpanDays: Self.spanDays(of: store.entries))
    }

    /// Pure span (in days) between the earliest and latest entry. `0` for an
    /// empty / single-day history. Exposed for the unit test.
    nonisolated static func spanDays(of entries: [MoodEntry], calendar: Calendar = .current) -> Int {
        let days = entries.map { calendar.startOfDay(for: $0.recordedAt) }
        guard let earliest = days.min(), let latest = days.max() else { return 0 }
        return calendar.dateComponents([.day], from: earliest, to: latest).day ?? 0
    }

    /// Pure data-span → default-period rule: more than ~3 months of
    /// history opens on the year lens; a moderate span opens on 90 days; very
    /// little data opens on 30 days. Exposed for the unit test.
    nonisolated static func defaultPeriod(forSpanDays span: Int) -> MoodPeriod {
        if span > 90 {
            .year
        } else if span > 30 {
            .sixMonths
        } else {
            .month
        }
    }

    /// Count of mood entries within the selected page range, the
    /// honest range-bound count the drill-down row reports (matches the windowed
    /// slice the rest of the page draws).
    private var entriesInRangeCount: Int {
        period.filter(store.entries).count
    }

    private var emptyState: some View {
        // Title and action; the sentence repeated the button.
        HLEmptyState(icon: "face.smiling", title: "No entries yet") {
            // A next-step CTA so the empty page isn't a dead-end: open
            // the mood quick-entry sheet (the same path the mood reminder uses).
            HLButton(
                "Log mood",
                systemImage: "face.smiling",
                variant: .secondary
            ) {
                router.requestMoodQuickEntry()
            }
            .accessibilityIdentifier("insights.mood.empty.log")
        }
        .accessibilityIdentifier("insights.mood.empty")
    }
}

/// The mood equivalent of `DrillDownRow`: the menu row at the end of the page
/// that opens all entries, with the range-bound count. Mood entries are not a
/// `MetricKind`, so the host pushes the shared `MoodHistoryScreen` through its
/// `showFullHistory` binding.
struct MoodDrillDownRow: View {
    let count: Int
    var hasDataOutsideRange: Bool = false
    let onTap: () -> Void

    var body: some View {
        HLCard(layout: .rows) {
            HLRowButton(action: onTap) {
                // Mood is entered, not measured: entries, like the medications.
                HLDrillRow("insights.mood.showAll", count: count, hasEntriesOutsidePeriod: hasDataOutsideRange)
            }
        }
        .accessibilityIdentifier("insights.mood.showAll")
        .accessibilityHint(Text("insights.mood.showAll.hint"))
    }

    /// What the count means: entries in the period, entries only outside
    /// it (the tap still opens them all), or none at all.
    static func detail(count: Int, hasDataOutsideRange: Bool) -> LocalizedStringResource {
        if count >= 1 {
            return "\(count) entries in the period"
        }
        return hasDataOutsideRange ? "Entries outside the period" : "No entries"
    }
}
