import SwiftUI

/// v0.11 W28c — the Insights **Mood** special page (web `/insights/mood`).
///
/// A composite page (NOT a single-metric chart): present-state hero → texture
/// (heatmap) → trajectory (trend) → steadiness (stability) → drivers (tags +
/// patterns) → evidence (recent entries). It reuses the exact sub-views the
/// More → Mood analysis surface (`MoodAnalysisScreen`) already ships
/// (`MoodHeroSummary`, `MoodHeatmapSection`, `MoodTrendChart`,
/// `MoodStabilitySection`, `MoodTagInsightSection`, `MoodPatternSection`,
/// `MoodRecentSection`) so the two surfaces stay one design language.
///
/// **Lives inside the Insights pager.** Unlike `MoodAnalysisScreen` it owns NO
/// `NavigationStack` (the container's shared stack does) and pins its period
/// control inline rather than via a `.safeAreaInset` — the pager's strip already
/// owns the top chrome. Its inner `ScrollView` reports its offset to
/// `InsightsStripVisibility` for hide-on-scroll, exactly like the metric pages.
/// The page wrapper in `InsightsContainerScreen` pins it with
/// `.containerRelativeFrame(.horizontal)` ONLY (the W44 contract).
///
/// **Self-suppress:** the page only ever renders when the operator has ≥1 mood
/// entry (gated upstream by `availableSpecials`); the defensive empty branch is a
/// calm `ContentUnavailableView`, never a dead box.
struct InsightsMoodPage: View {
    @Environment(MoodStore.self) private var store
    @Environment(InsightsStripVisibility.self) private var stripVisibility
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// I-1 D — the Mood × blood-pressure correlation card was relocated here off
    /// the Insights overview. Reads the server `comprehensive` digest (the same
    /// source `CorrelationsPanel` uses), so the Mood page needs `InsightsStore`.
    @Environment(InsightsStore.self) private var insightsStore
    @Environment(BackendAvailability.self) private var backend
    /// v0.14.1 — the LIVE mood-relations slices (`GET /api/mood/insights`,
    /// server v1.11.5): tag-influence + the "better days" board. Server-derived
    /// + association-not-cause; self-suppresses below its sample/confidence
    /// floors. The Daylio mood-tag payoff.
    @Environment(MoodRelationsStore.self) private var relationsStore
    /// QoL-4 (A360-4) — routes the empty-state CTA to the mood quick-entry sheet
    /// so a first-time user has a next step instead of a dead-end empty page.
    @Environment(AppRouter.self) private var router

    @State private var period: MoodPeriod = .days30
    @State private var editing: MoodEntry?
    @State private var showFullHistory = false
    /// I-4 Item 3 — the data-span → default-period auto-select runs exactly ONCE
    /// per page lifetime. After it fires (or the operator picks a period via the
    /// floating control) this latches `true` so a later SWR refresh / re-appear
    /// never overrides a value the operator is looking at.
    @State private var didAutoSelectPeriod = false

    private var windowLabel: String {
        switch period {
        case .days30: String(localized: "in 30 days")
        case .days90: String(localized: "in 90 days")
        case .year: String(localized: "in 1 year")
        }
    }

    var body: some View {
        Group {
            if store.entries.isEmpty {
                emptyState
            } else {
                content
            }
        }
        .background(HLSurface.primary.ignoresSafeArea())
        // v0.13.1 UX-D1 — the period control now pins to the bottom safe-area as
        // the floating Liquid-Glass capsule, IDENTICAL to `InsightsMetricScreen`
        // (the sibling metric page in the SAME pager) and the standalone
        // `MoodAnalysisScreen`. It was previously the last inline child of the
        // ScrollView, so it scrolled off and was only reachable at the very
        // bottom — the operator-reported felt-bug ("static at the bottom, not
        // floating"). `HLFloatingPeriodControl` has a FIXED size that never
        // changes with scroll, so the bottom inset is pager-resolver-safe (the
        // sibling metric page proves this in the same pager). Gated on having
        // entries so the empty state stays clean.
        .safeAreaInset(edge: .bottom) {
            if !store.entries.isEmpty {
                // DRIFT-4 — the SAME `HLFloatingPeriodControl` the sibling metric
                // page hosts in this bottom slot (was the `MoodPeriodControl`
                // wrapper). `MoodPeriod` conforms to `HLRangeOption`, so the
                // generic control drives it directly + the I-4 auto-select span
                // logic still flows through `$period`. Identical capsule chrome
                // across every Insights pager page.
                HLFloatingPeriodControl(selection: $period, accessibilityLabelText: "Time range")
            }
        }
        .sheet(item: $editing) { entry in
            EditMoodSheet(entry: entry, onDismiss: { editing = nil })
                .hlSheetPresentation(.form)
        }
        // I-4 Item 1 — the `✦` Coach explainer sheet, the SAME `AskCoachSheet`
        // the Insights overview + per-metric Coach circles present, so the Mood
        // page's top-right Coach reads identically to every other page.
        .sheet(isPresented: $presentCoach, onDismiss: {
            coachSeedOverride = nil
            coachScopeOverride = nil
        }, content: {
            // A360 H2 (v0156) — the Mood page Coach hands off the mood scope: a
            // localized opener + `scope { sources: [mood] }` so the first server
            // turn narrows the snapshot to mood instead of opening blank. A
            // correlation card overrides both with the pair-specific seed/scope.
            AskCoachSheet(
                seed: coachSeedOverride ?? AskCoachSheet.moodSeed,
                launchScope: coachScopeOverride ?? CoachLaunchScope(metric: .mood)
            )
        })
        // I-4 Item 1 — the Settings circle pushes the Insights customisation
        // screen (the SAME destination the overview's customise circle opens),
        // giving the Mood header the canonical two-equal-circles trailing slot.
        .navigationDestination(isPresented: $presentSettings) {
            SettingsInsightsCustomizationScreen()
        }
        .navigationDestination(isPresented: $showFullHistory) {
            MoodHistoryScreen()
        }
        // I-4 Item 3 — on first appear, pick the default period from the span of
        // the operator's mood history (computed offline from `store.entries`):
        // > ~3 months → "letztes Jahr"; a moderate span → 90d; very little data
        // → 30d. Runs once (`didAutoSelectPeriod` latch) and never overrides an
        // explicit manual choice within the session. Also fires after a load
        // resolves the first batch of entries (the `id:` keys on the count).
        .task(id: store.entries.count) {
            autoSelectPeriodIfNeeded()
        }
    }

    /// I-4 Item 1 — `✦` Coach surface, present only when the assistant is on.
    @State private var presentCoach = false
    /// A360 H2 (v0156) — when a correlation card opens the Coach it overrides the
    /// page's mood seed/scope with the pair-specific one. `nil` → the page mood
    /// handoff. Reset on dismiss.
    @State private var coachSeedOverride: String?
    @State private var coachScopeOverride: CoachLaunchScope?
    /// I-4 Item 1 — the Insights-customisation Settings surface.
    @State private var presentSettings = false

    /// Task #53 parity — true when ANY assistant surface should show (the user
    /// chose `.onDevice` or `.online`; `.none` hides everything). Gates the
    /// header `✦` Coach circle exactly like `InsightsMetricScreen`.
    @Environment(\.appContainer) private var appContainer
    private var aiSurfacesVisible: Bool {
        appContainer?.aiMode != AIMode.none && appContainer?.aiMode != nil
    }

    /// I-4 Item 3 — the two equal trailing header circles (Settings + `✦`
    /// Coach), matching `InsightsMetricScreen.metricHeader`. Coach self-hides
    /// when the assistant is off, so there is never a dead button.
    @ViewBuilder
    private var headerActions: some View {
        InsightsHeaderActionCircle(
            systemImage: "slider.horizontal.3",
            accessibilityLabelText: String(localized: "Customise insights"),
            accessibilityIdentifier: "insights.mood.settings"
        ) {
            presentSettings = true
        }
        if aiSurfacesVisible {
            InsightsHeaderActionCircle(
                systemImage: "sparkles",
                accessibilityLabelText: String(localized: "Ask the coach"),
                accessibilityIdentifier: "insights.mood.explainer"
            ) {
                presentCoach = true
            }
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HLSpace.lg) {
                // v0.13.1 UX-D8/D2 + I-4 Item 1 — the canonical per-page header
                // (large title + sub-line + equal-circle trailing slot),
                // IDENTICAL anatomy to `InsightsMetricScreen.metricHeader`, so the
                // top-of-page region no longer jumps when the operator swipes
                // between a metric page and Mood in the same pager. The trailing
                // slot now carries the canonical two equal circles — a Settings
                // (Insights-customise) circle + the `✦` Coach circle — exactly
                // like the metric pages (I-4 Item 1).
                InsightsPageHeader(
                    "Mood",
                    subtitle: LocalizedStringKey(windowLabel),
                    accessibilityIdentifierSuffix: "mood"
                ) {
                    headerActions
                }

                // I-0 Item 3 — the server-mirrored intro paragraph, IDENTICAL to
                // the `InsightsMetricScreen.descriptionSlot` the charted pages
                // carry. Previously the Mood page showed only the "in 30 days"
                // subtitle and read broken next to every other metric page; now
                // it opens with the same explainer body (`mood` slug).
                InsightsExplainerIntro(slug: "mood")

                // v0.12 W4-3 — the seven analysis sub-views now come from the
                // shared `MoodAnalysisContent` (one implementation; the More →
                // Stimmung screen renders the same sections with a staggered
                // entrance). This host renders each section plain (the pager owns
                // the entrance); the period control floats at the bottom
                // safe-area (UX-D1), no longer inline.
                MoodAnalysisContent(
                    period: period,
                    editing: $editing,
                    showFullHistory: $showFullHistory,
                    heatmapDrivenByPeriod: true,
                    showsRecentSection: false
                ) { _, content in
                    content
                }

                // v0.14.1 — the LIVE mood-relations region (tag-influence +
                // "better days" board) from `GET /api/mood/insights`. The
                // payoff of the Daylio mood tags: what is associated with
                // better-mood days, honestly framed as association-not-cause.
                relationsBlock

                // I-1 D — the Mood × blood-pressure correlation card, relocated
                // off the overview onto the metric it concerns. Self-suppresses
                // when there's no ok pairing (no empty card).
                correlationBlock

                // v0.14.4 E3 — the canonical bottom-of-page "Show all
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

                // v0.14.8 W2-SYNCUX — canonical sync-status footer (same
                // primitive as Dashboard/Insights, self-suppressing).
                HLSyncStatusFooter(screenLoading: store.isLoading)
            }
            .padding(.horizontal, HLSpace.lg)
            .padding(.top, HLSpace.lg)
            .padding(.bottom, HLSpace.xxxl)
            .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: period)
        }
        // Report THIS page's own inner vertical scroll offset up to the strip
        // hide-on-scroll model — never the horizontal pager (W44 contract).
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y
        } action: { _, newOffset in
            stripVisibility.report(offset: newOffset)
        }
        .hlScrollEdgeSoft()
        // W-B184 — WHOOP-style pull-to-refresh (custom glyph + checkmark + one
        // success haptic; the handshake driving the checkmark runs in the modifier).
        .hlPullToRefresh {
            await store.load()
            await relationsStore.refresh()
        }
        // v0.14.1 — warm the LIVE mood-relations cards (server-derived). Gated
        // on a cloud surface being available (standalone / no-server hides the
        // whole region). Idempotent — the repo's SWR row single-flights.
        .task {
            if backend.canShowCloudInsights {
                await relationsStore.load()
            }
        }
    }

    /// v0.14.1 — the LIVE mood-relations region: an "Influence on mood" card +
    /// a "Better days" board, under a shared `InsightsSectionHeader`. Server-
    /// derived; gated on a cloud surface. When the surface is on but the data is
    /// below its sample/confidence floors (settled + empty), a calm empty state
    /// stands in — never a fabricated correlation.
    @ViewBuilder
    private var relationsBlock: some View {
        if backend.canShowCloudInsights {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                // v0.14.4 E4 — the right-aligned grey caption was removed (the C2
                // cleanup applied elsewhere); the header stands alone, calmer.
                InsightsSectionHeader("What shapes your mood")
                if relationsStore.hasContent {
                    MoodInfluenceCard(
                        structuredRows: relationsStore.structuredInfluence,
                        flatRows: relationsStore.flatInfluence
                    )
                    MoodBetterDaysCard(factors: relationsStore.betterDays)
                    // v0.14.8 — the RATED-factor × metric crosstab card (server
                    // v1.14.0 `factorCrosstab`): the first iOS surface for the
                    // analytical USE of the slider rating values. Self-suppresses
                    // when the server returned no significant row.
                    MoodFactorCrosstabCard(rows: relationsStore.factorCrosstab)
                } else if relationsStore.hasSettledOnce {
                    moodRelationsEmptyState
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
        }
    }

    /// Calm empty state for the relations region — shown only once the load has
    /// settled with no rows clearing the server's ≥5-day / Welch floor. Never a
    /// dead box, never an invented correlation.
    private var moodRelationsEmptyState: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.xs) {
                Text("Not enough data for connections yet")
                    .font(.hlHeadline)
                    .foregroundStyle(HLText.primary)
                Text(
                    "Keep logging your mood with tags. Once a tag has enough days both with and without it, you'll see how it tracks with your mood here."
                )
                .font(.hlBody)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("insights.mood.relations.empty")
    }

    /// I-1 D — the relocated Mood × blood-pressure correlation card. Same render
    /// contract as `InsightsMetricScreen.correlationBlock`: a "Relationships"
    /// section header + the single-pair `CorrelationsPanel` (with its safety
    /// disclaimer), shown only when the digest carries an ok pairing.
    @ViewBuilder
    private var correlationBlock: some View {
        if backend.canShowCloudInsights, let digest = insightsStore.digest {
            // A360 H2 — the relocated mood×BP card carries an "Ask the coach
            // about this" link, pre-scoped to both metrics in the pair.
            let panel = CorrelationsPanel(
                digest: digest,
                pairs: [.moodBp],
                showsDisclaimer: false,
                onAskCoach: { pair in
                    coachSeedOverride = pair.coachSeed
                    coachScopeOverride = pair.coachLaunchScope
                    presentCoach = true
                }
            )
            if panel.hasAnyCard {
                VStack(alignment: .leading, spacing: HLSpace.sm) {
                    InsightsSectionHeader("Relationships")
                    panel
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .contain)
            }
        }
    }

    /// I-4 Item 3 — apply the span-derived default period ONCE, only when there
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

    /// Pure data-span → default-period rule (I-4 Item 3): more than ~3 months of
    /// history opens on the year lens; a moderate span opens on 90 days; very
    /// little data opens on 30 days. Exposed for the unit test.
    nonisolated static func defaultPeriod(forSpanDays span: Int) -> MoodPeriod {
        if span > 90 {
            .year
        } else if span > 30 {
            .days90
        } else {
            .days30
        }
    }

    /// v0.14.4 E3 — count of mood entries within the selected page range, the
    /// honest range-bound count the drill-down row reports (matches the windowed
    /// slice the rest of the page draws).
    private var entriesInRangeCount: Int {
        period.filter(store.entries).count
    }

    private var emptyState: some View {
        HLEmptyState(
            icon: "face.smiling",
            title: "No entries yet",
            message: "Log your first mood to see your history."
        ) {
            // QoL-4 — a next-step CTA so the empty page isn't a dead-end: open
            // the mood quick-entry sheet (the same path the mood reminder uses).
            HLButton(
                String(localized: "Log mood"),
                icon: "face.smiling",
                variant: .restrained
            ) {
                router.requestMoodQuickEntry()
            }
            .accessibilityIdentifier("insights.mood.empty.log")
        }
        .accessibilityIdentifier("insights.mood.empty")
        .containerCentered()
    }
}

/// v0.14.4 E3 — the mood equivalent of `DrillDownRow`: the bottom-of-page "Show
/// all measurements" → entries-list affordance every metric page ends with.
/// Mood entries are not a `MetricKind`, so the destination is the shared
/// `MoodHistoryScreen` (the host pushes it via its `showFullHistory` binding);
/// the chrome, copy and the v0.14.4 D2 "outside the period" handling are
/// identical to `DrillDownRow` so the two surfaces read as one pattern.
struct MoodDrillDownRow: View {
    let count: Int
    var hasDataOutsideRange: Bool = false
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HLCard {
                HStack(spacing: HLSpace.md) {
                    VStack(alignment: .leading, spacing: HLSpace.xxs) {
                        Text("Show all measurements")
                            .font(.hlHeadline)
                            .foregroundStyle(HLText.primary)
                        Text(subtitle)
                            .font(.hlCaption)
                            .foregroundStyle(HLText.secondary)
                    }
                    Spacer()
                    HLDisclosureChevron()
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("insights.mood.showAll")
        .accessibilityLabel(Text("Show all measurements, \(count) entries"))
        .accessibilityHint(Text("Opens a list of all measurements of this type"))
    }

    private var subtitle: LocalizedStringKey {
        if count >= 1 {
            return "\(count) entries in the period"
        }
        return hasDataOutsideRange ? "Entries outside the period" : "No entries"
    }
}
