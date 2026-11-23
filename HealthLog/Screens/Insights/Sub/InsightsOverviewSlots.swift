import SwiftUI

// W-PERF-INSIGHTS (perf audit C1) — store-scoped leaf views for the Insights
// overview.
//
// **Why these exist.** Under the Observation framework, every `@Observable`
// property read DURING a view's `body` registers a dependency on THAT view. The
// pre-refactor `InsightsScreen` read 17+ stores into ONE `body`
// (`loadedContent` + `insightsHeader` + `isShowingInitialSkeleton`), so a
// mutation to ANY of them (e.g. a Home-tab `DashboardStore` refresh, or the
// 12-way pull-to-refresh fan-out hitting `DerivedInsightsStore` over and over)
// re-rendered the WHOLE screen — the app's worst over-invalidation hot-spot.
//
// The fix is a pure structure refactor: each `@Observable` store is now read by
// the SMALLEST leaf that uses it, so a mutation invalidates only that leaf.
// **Behaviour is identical** — the slots render the exact same content, in the
// same order, behind the same gates as the inline blocks they replaced. No
// visual or behavioural change; only the invalidation scope shrank.
//
// Mirrors the `InsightsServerDerivedOverview` grouping idiom and the
// `InsightsContainerScreen` / `InsightsPagerModel` decomposition already in the
// tree (the View stays thin, the leaves own their reads).

// MARK: - Header slot (InsightsTargetsStore + AI capability + Backend + gates)

/// Owns the inline Insights header (large title + trailing action circles). Reads
/// `InsightsTargetsStore.targets` (customise-button gate), the `coach` AI capability,
/// `BackendAvailability`, and the `AppContainer` gates here so a targets refresh
/// / consent change invalidates ONLY the header, not the whole overview.
struct InsightsOverviewHeader: View {
    let appContainer: AppContainer?
    /// Pushes `SettingsInsightsCustomizationScreen`. Set by the host's `@State`.
    let onCustomize: () -> Void
    /// Opens `AskCoachSheet` (Quick-Launch to Chat).
    let onAskCoach: () -> Void

    @Environment(InsightsTargetsStore.self) private var insightsTargetsStore

    var body: some View {
        // The canonical `HLTabHeader` with typed actions: one glass group in
        // the fixed order (page setting, coach), like every Insights page.
        HLTabHeader(
            "Insights",
            titleIdentifier: "insights.page.header.title.overview",
            actions: headerActions
        )
    }

    private var headerActions: HLTabHeaderActions {
        var items: [HLTabHeaderAction] = []
        // Customising the overview, only when there are targets to show.
        if !insightsTargetsStore.targets.isEmpty {
            items.append(.settings(label: "Customise insights", identifier: "insights.header.customiseMenu") {
                onCustomize()
            })
        }
        // The coach while its capability offers an entry point; with the
        // coach held back for a missing consent, the same place offers to
        // turn it on, so the surface is never a dead end.
        if aiSurfacesVisible, appContainer.offersCoach {
            items.append(.coach(identifier: "InsightsScreen.askCoachCollapsedCoin.header") {
                onAskCoach()
            })
        } else if coachReengageAvailable {
            items.append(HLTabHeaderAction(
                role: .coach,
                systemImage: "sparkles",
                label: "Enable the coach",
                identifier: "InsightsScreen.enableCoachCoin.header",
                isSelected: false,
                kind: .button { reengageCoach() }
            ))
        }
        return HLTabHeaderActions(items)
    }

    // Gates duplicated here (not shared with the Coach slot) so their
    // `@Observable` reads register on the HEADER leaf specifically.

    private var aiSurfacesVisible: Bool {
        guard let container = appContainer else { return false }
        return container.aiMode != .none || container.onDeviceAICapable
    }

    private var coachReengageAvailable: Bool {
        guard let container = appContainer else { return false }
        _ = container.aiConsentStore.revision
        let provider = container.resolvedAIProvider
        return InsightsScreen.isCoachReengageAvailable(
            aiMode: container.aiMode,
            coachCapability: container.aiCapabilityGate.reportsCapabilities
                ? container.aiCapabilityGate.state(.coach) : nil,
            resolvedProvider: provider,
            hasConsentForProvider: container.aiConsentStore.hasConsent(for: provider),
            isServerManagedAvailable: container.aiProviderStore.config?.usesProviderOpaqueAIConsent == true,
            hasServerManagedConsent: container.aiConsentStore.hasServerManagedConsent(),
            isAIExplicitlyUnavailable: container.aiProviderStore.config?.isAIExplicitlyUnavailable == true
        )
    }

    private func reengageCoach() {
        appContainer?.aiConsentStore.requestExplicitPrompt()
    }
}

// MARK: - Coach slot (AI capability + Settings + Backend + module gates)

/// Owns the quiet Coach re-engage card + proactive cadence suggestions. Reads
/// the `coach` AI capability, `SettingsStore.coachHeroDismissed`,
/// `BackendAvailability`, and the (non-`@Observable`) `AppContainer` gates here
/// so a feature-flag / dismissal / consent change invalidates ONLY this slot,
/// not the whole overview.
struct InsightsCoachSlot: View {
    let appContainer: AppContainer?

    @Environment(SettingsStore.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if coachReengageAvailable, !settings.coachHeroDismissed {
            // Calm re-engage card when the Coach is suppressed but a
            // server provider exists and consent is missing/declined.
            CoachReengageCard(action: { reengageCoach() })
                .transition(reduceMotion ? .identity : .opacity)
        }

        // ── COACH CADENCE SUGGESTIONS — proactive accept/dismiss cards. ──
        // Calm cards (NOT the colourful hero); the store owns opt-in + module +
        // online gating and self-suppresses when there is nothing to offer.
        if coachModuleEnabled, appContainer.offersCoach, let cadenceStore = appContainer?.coachCadenceSuggestionsStore {
            CoachCadenceSuggestionsSection(store: cadenceStore)
                .transition(reduceMotion ? .identity : .opacity)
        }
    }

    // MARK: Gates (moved from `InsightsScreen` so their `@Observable` reads

    // register on THIS leaf — see file header).

    /// The in-overview Coach affordances respect the `coach` module.
    private var coachModuleEnabled: Bool {
        guard let gate = appContainer?.moduleGate else { return true }
        _ = gate.modules
        return gate.isEnabled(.coach)
    }

    /// Gates the Coach re-engage affordance. Tracks `revision` so it
    /// re-evaluates the moment a grant lands.
    private var coachReengageAvailable: Bool {
        guard let container = appContainer else { return false }
        _ = container.aiConsentStore.revision
        let provider = container.resolvedAIProvider
        return InsightsScreen.isCoachReengageAvailable(
            aiMode: container.aiMode,
            coachCapability: container.aiCapabilityGate.reportsCapabilities
                ? container.aiCapabilityGate.state(.coach) : nil,
            resolvedProvider: provider,
            hasConsentForProvider: container.aiConsentStore.hasConsent(for: provider),
            isServerManagedAvailable: container.aiProviderStore.config?.usesProviderOpaqueAIConsent == true,
            hasServerManagedConsent: container.aiConsentStore.hasServerManagedConsent(),
            isAIExplicitlyUnavailable: container.aiProviderStore.config?.isAIExplicitlyUnavailable == true
        )
    }

    /// Re-opens the consent choice for a suppressed Coach.
    private func reengageCoach() {
        appContainer?.aiConsentStore.requestExplicitPrompt()
    }
}

// MARK: - Wellness + Signals slot (DerivedInsightsStore + Backend)

/// Owns the DEINE GESUNDHEITSWERTE wellness-score rings + the warm-in-flight
/// placeholder + the Tagesbriefing-adjacent SIGNALE DES TAGES section. Reads
/// `DerivedInsightsStore` (`presentable` / `metrics` / `warming`) + `Backend` +
/// ``InsightsOverviewGate`` here so a derived-metrics refresh — which fires
/// repeatedly across the pull-to-refresh fan-out — invalidates ONLY this slot.
///
/// The `generalHealthReportSlot` (Tagesbriefing prose) renders BETWEEN the
/// wellness block and the signals section in the overview, so the host composes
/// `wellness` and `signals` as two separately-mounted children of this type with
/// the prose slot interleaved (see `InsightsScreen.loadedContent`).
struct InsightsWellnessScoresSlot: View {
    let appContainer: AppContainer?
    /// Deep-nav into a metric's Insights page (`router.selectInsightsMetric`).
    let onSelectMetric: (MetricKind) -> Void
    /// Deep-nav into the Mood special Insights page (`router.selectInsightsSpecial`).
    let onSelectMood: () -> Void

    @Environment(DerivedInsightsStore.self) private var derivedInsightsStore

    var body: some View {
        if InsightsOverviewGate.isVisible(.wellnessScores, appContainer) {
            InsightsServerDerivedOverview(
                // Full list (incl. insufficient arms) for the score-ring gate.
                derivedMetricsAll: derivedInsightsStore.metrics,
                onSelectMetric: onSelectMetric,
                onSelectMood: onSelectMood,
                // "Signale des Tages" hoisted OUT — rendered after the Einschätzung.
                showsSignals: false,
                // "Zusammenhänge in deinen Daten" is hoisted OUT too: it now
                // renders after the complete overview section list
                // (`InsightsCorrelationsSlot`), below the health values.
                // CU-33's live `CorrelationsDiscoveryStore` read (and with it the
                // relevance affordance) moved to that slot; this slot no longer
                // reads the store at all, keeping its invalidation scope minimal.
                showsCorrelations: false
            )

            // Warm-in-flight placeholder, self-suppressing the instant a
            // score lands. Never a spinner. The shape of the score tiles
            // instead of a loose grey sentence under the section.
            if derivedInsightsStore.warming, derivedInsightsStore.presentable.isEmpty {
                InsightsScoreCardsSkeleton()
            }
        }
    }
}

/// Owns the SIGNALE DES TAGES section (honest coincident-deviation count). Reads
/// `DerivedInsightsStore.metrics` + `Backend` + ``InsightsOverviewGate``.
struct InsightsSignalsSlot: View {
    let appContainer: AppContainer?

    @Environment(DerivedInsightsStore.self) private var derivedInsightsStore

    var body: some View {
        if InsightsOverviewGate.isVisible(.signals, appContainer) {
            InsightsSignalsOfTheDaySection(metrics: derivedInsightsStore.metrics)
        }
    }
}

// MARK: - Tagesbriefing slot (DailyBriefingStore + NarrativeStore + module gate)

/// Owns the TAGESBRIEFING heading + flowing-grey prose (the overall
/// health-status narrative: AI briefing summary, else the deterministic period
/// narrative fallback). Reads `DailyBriefingStore.summary` + `NarrativeStore` +
/// the `insights` module gate here (the one AI-text slot that keeps it until the
/// `ai` capability model lands), so a briefing/narrative warm invalidates
/// ONLY this slot.
struct InsightsDailyBriefingSlot: View {
    let appContainer: AppContainer?

    @Environment(DailyBriefingStore.self) private var briefingStore
    @Environment(NarrativeStore.self) private var narrativeStore

    var body: some View {
        if InsightsOverviewGate.insightsModuleEnabled(appContainer), let report = generalHealthReportText {
            Group {
                // Flush drops the header inset so the heading shares the prose
                // body's leading edge.
                HLSectionHeader("insights.overview.dailyBriefing.title", rank: .area)
                Text(report)
                    .font(.hlBody)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("insights.overview.generalHealthReport")
            }
        }
    }

    /// The real daily briefing paragraph when present, else the period narrative
    /// (week → month) which carries a deterministic server fallback so it is
    /// populated even for a provider-less account. `nil` → render nothing.
    ///
    /// **2026-07-18 fix:** this slot used `briefingStore.summary` directly, which
    /// skips `briefing?.paragraph` — so the "Tagesbriefing" heading rendered the
    /// weekly narrative (web's "Rückblick diese Woche") instead of the actual
    /// daily briefing ("Guten Abend <Name>, Beobachtungstag"). `paragraphContent`
    /// prefers the strict `dailyBriefing.paragraph` (delivered un-gated via the
    /// dashboard snapshot) and only then falls back to `summary`.
    private var generalHealthReportText: String? {
        if let paragraph = briefingStore.paragraphContent { return paragraph }
        if let week = narrativeStore.narrative(for: .week)?.text { return week }
        return narrativeStore.narrative(for: .month)?.text
    }
}

// MARK: - Overview body (skeleton gate + loaded composition + footer)

/// Owns the skeleton-vs-loaded switch + the loaded-content composition + the
/// sync footer. The skeleton gate aggregates ~6 stores; reading them HERE (not in
/// `InsightsScreen.body`) confines their invalidation to this body view, and the
/// loaded composition delegates each remaining store to its own slot. The host's
/// `body` is left with only the `ScrollViewReader` + scroll/onChange/task glue
/// (closures, which don't register observation dependencies), so a store mutation
/// no longer re-renders the screen's scroll/sheet/toolbar scaffold.
struct InsightsOverviewBody: View {
    let appContainer: AppContainer?
    /// Pushes `SettingsInsightsCustomizationScreen`.
    let onCustomize: () -> Void
    /// Opens `AskCoachSheet`.
    let onAskCoach: () -> Void
    /// Deep-nav into a metric's Insights page.
    let onSelectMetric: (MetricKind) -> Void
    /// Deep-nav into the Mood special Insights page.
    let onSelectMood: () -> Void

    @Environment(InsightsStore.self) private var store
    @Environment(MeasurementsStore.self) private var measurementsStore
    @Environment(HealthScoreStore.self) private var healthScoreStore
    @Environment(InsightsTargetsStore.self) private var insightsTargetsStore
    @Environment(MoodStore.self) private var moodStore
    /// The server-first overview SECTION arrangement
    /// (which blocks show, in what order). Read here, on the composition owner,
    /// so a section edit re-lays-out the column and nothing else.
    @Environment(InsightsLayoutStore.self) private var layoutStore

    var body: some View {
        // First paint, nothing recorded at all, or the overview: the empty
        // state stands in the free area like on every page of the pager.
        HLStateContainer(phase) {
            // First-paint shape-aware placeholder.
            InsightsSkeletonContent()
        } empty: {
            HLEmptyState(
                icon: "sparkles",
                title: "No insights yet",
                message: "Insights appear once enough data is logged — capture more measurements."
            )
            .accessibilityIdentifier("insights.empty")
        } content: {
            loadedContent
        }
        // A failed refresh is the shared banner above the overview, which
        // stays in place below it.
        .hlErrorBannerOverlay(error: store.error) {
            Task { await store.refresh() }
        }
        // The shared sync footer: real states only (1.4 decision 3). The
        // first-login hint is the `FirstLoginSyncBanner`'s, not a second line.
        HLSyncStatusFooter(screenLoading: store.isLoading)
    }

    private var phase: HLLoadPhase {
        if isShowingInitialSkeleton { return .loading }
        let serverCount = store.comprehensive?.digest?.totalMeasurements ?? 0
        let empty = InsightsEmptyState.resolve(
            hasDeliveredCards: store.hasDeliveredCards,
            cardsEmpty: store.cards.isEmpty,
            isLoading: store.isLoading,
            hasError: store.error != nil,
            hasRecordedData: serverCount > 0 || !measurementsStore.recent.isEmpty
        )
        return empty == .needsData ? .empty : .loaded
    }

    /// The ordered zones, each a store-scoped leaf so a mutation invalidates
    /// only that zone (see file header).
    ///
    /// **The order and the membership are now the
    /// operator's**, read from the server-first `sections` slice instead of
    /// being hardcoded here. Web has had this since v1.15.11; iOS had no
    /// `sections` concept at all, so the whole arrangement surface was
    /// unreachable from the phone (the cluster's only P0).
    ///
    /// The quiet Coach block is deliberately outside the customizable region.
    /// Correlations are also anchored: they follow the complete server-owned
    /// section list so they always sit below Vitalwerte. A failed load is the
    /// banner above the column, not a slot in it.
    ///
    /// Every section still self-gates on its own data, so an enabled section
    /// with nothing to say renders nothing — visibility here is permission, not
    /// obligation.
    @ViewBuilder
    private var loadedContent: some View {
        // ── Quiet Coach re-engagement + cadence suggestions. ──
        InsightsCoachSlot(appContainer: appContainer)

        ForEach(layoutStore.layout.visibleSectionIds, id: \.self) { id in
            section(id)
        }

        // Available without competing with the primary health hierarchy. The
        // block itself owns a collapsed-by-default disclosure.
        InsightsCorrelationsSlot(appContainer: appContainer, onSelectMetric: onSelectMetric)
    }

    /// One overview section by its server id. The case order below is the
    /// server's default section order, so reading this function top-to-bottom
    /// still describes the default column.
    ///
    /// `period-review` is deliberately unimplemented: the retrospective card was
    /// removed from the iOS overview in v0.14.9 on an operator call ("doesn't
    /// fit, too much") and that stays a documented divergence — the section row
    /// still round-trips and still governs the WEB block. `ecg` likewise has no
    /// iOS surface yet (`02-insights.md` §B); its row is editable from the phone
    /// so the operator can arrange the web overview, but iOS renders nothing.
    ///
    /// `trends` joined them in 1.4 B4. Its cards repeated Vitalwerte (weight
    /// twice) and the Heute tiles (blood pressure, pulse) with the same line
    /// and no sentence; each metric keeps its Vitalwerte card, its Heute tile
    /// and its page in the strip.
    @ViewBuilder
    private func section(_ id: String) -> some View {
        switch id {
        case InsightsLayoutSectionId.wellnessScores:
            InsightsWellnessScoresSlot(
                appContainer: appContainer,
                onSelectMetric: onSelectMetric,
                onSelectMood: onSelectMood
            )
        case InsightsLayoutSectionId.dailyBriefing:
            InsightsDailyBriefingSlot(appContainer: appContainer)
        case InsightsLayoutSectionId.vitals:
            InsightsVitalsSlot(appContainer: appContainer, onSelect: onSelectMetric)
        case InsightsLayoutSectionId.cycleSummary:
            InsightsCycleTile(
                store: appContainer?.cycleStore,
                isAvailable: appContainer?.cycleGate.isCycleTrackingAvailable ?? false
            )
        case InsightsLayoutSectionId.signals:
            InsightsSignalsSlot(appContainer: appContainer)
        case InsightsLayoutSectionId.rhythmEvents:
            InsightsRhythmEventsSlot(appContainer: appContainer)
        case InsightsLayoutSectionId.healthStatus:
            InsightsHealthStatusSlot(appContainer: appContainer)
        case InsightsLayoutSectionId.breathing:
            InsightsBreathingSlot(appContainer: appContainer)
        case InsightsLayoutSectionId.labsChanges:
            InsightsLabsChangesSlot(appContainer: appContainer)
        default:
            EmptyView()
        }
    }

    /// First-paint skeleton gate — routes through the pure
    /// `InsightsStore.isInitialSkeletonVisible(...)` aggregator so the screen
    /// shows ONE coherent silhouette and latches on first settle.
    private var isShowingInitialSkeleton: Bool {
        InsightsStore.isInitialSkeletonVisible(
            hasSettledOnce: store.hasSettledOnce,
            isLoading: store.isLoading,
            hasComprehensive: store.comprehensive != nil,
            hasCards: !store.cards.isEmpty,
            hasMeasurements: !measurementsStore.recent.isEmpty,
            hasHealthScore: healthScoreStore.score != nil,
            hasTargets: !insightsTargetsStore.targets.isEmpty,
            hasMood: store.digest?.moodSummary != nil || !moodStore.entries.isEmpty
        )
    }
}

// MARK: - Shared module gate

/// The overview slots that render server DATA (scores, statistics, device
/// records, lab deltas). Each one follows the module that owns its data, exactly
/// as the server route that feeds it does.
enum InsightsOverviewDataSlot: CaseIterable {
    case wellnessScores
    case signals
    case rhythmEvents
    case healthStatus
    case breathing
    case labsChanges
    case correlations

    /// The module that owns this slot's data, or `nil` when the data belongs to
    /// no toggleable module.
    ///
    /// **Server v1.39 (migration 0343).** `insights` means "AI analysis" and
    /// nothing else, and it is off for every account that had "Hide Coach" on.
    /// None of these slots is AI-written, so none of them may hang on it. The
    /// mapping mirrors the v1.39.0 routes one by one:
    /// - `breathing-screening` → `requireModuleEnabled(…, "sleep")`
    /// - `labs-changes` → `requireModuleEnabled(…, "labs")`
    /// - `rhythm-events`, `health-status` → no module gate
    /// - `derived/batch` (scores, signals) → no slot-level gate; per-metric
    ///   ownership is applied server-side through `DERIVED_MODULE`
    /// - `correlations` → no slot-level gate; channels whose module is off are
    ///   filtered server-side
    var owningModule: ModuleKey? {
        switch self {
        case .breathing: .sleep
        case .labsChanges: .labs
        case .wellnessScores, .signals, .rhythmEvents, .healthStatus, .correlations: nil
        }
    }
}

/// Module gates for the overview slots. Pure reads over the (non-`@Observable`)
/// `AppContainer.moduleGate` (`moduleGate` IS `@Observable`, so reading
/// `.modules` inside a slot's `body` tracks it on THAT slot).
enum InsightsOverviewGate {
    /// Whether a data slot may render: its owning module is on, or it has none.
    /// Fail-open when no gate is wired or the map is absent.
    @MainActor
    static func isVisible(_ slot: InsightsOverviewDataSlot, gate: ModuleGate?) -> Bool {
        guard let key = slot.owningModule, let gate else { return true }
        _ = gate.modules
        return gate.isEnabled(key)
    }

    @MainActor
    static func isVisible(_ slot: InsightsOverviewDataSlot, _ appContainer: AppContainer?) -> Bool {
        isVisible(slot, gate: appContainer?.moduleGate)
    }

    /// The `insights` module, read ONLY by the Tagesbriefing slot — the one
    /// overview slot that shows AI-written text. It keeps its 1.0.3 gate until
    /// the `ai` capability model (`/api/auth/me` `ai.capabilities.briefing`)
    /// replaces it. Never gate a data slot on this; use ``isVisible(_:gate:)``.
    /// Fail-open when the map is absent.
    @MainActor
    static func insightsModuleEnabled(_ appContainer: AppContainer?) -> Bool {
        guard let gate = appContainer?.moduleGate else { return true }
        _ = gate.modules
        return gate.isEnabled(.insights)
    }
}
