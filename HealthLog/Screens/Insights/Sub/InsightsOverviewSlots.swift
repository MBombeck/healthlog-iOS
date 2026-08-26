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

// MARK: - Header slot (InsightsTargetsStore + FeatureFlags + Backend + gates)

/// Owns the inline Insights header (large title + trailing action circles). Reads
/// `InsightsTargetsStore.targets` (customise-button gate), `FeatureFlagsStore`,
/// `BackendAvailability`, and the `AppContainer` gates here so a targets refresh
/// / consent change invalidates ONLY the header, not the whole overview.
struct InsightsOverviewHeader: View {
    let appContainer: AppContainer?
    /// Pushes `SettingsInsightsCustomizationScreen`. Set by the host's `@State`.
    let onCustomize: () -> Void
    /// Opens `AskCoachSheet` (Quick-Launch to Chat).
    let onAskCoach: () -> Void

    @Environment(InsightsTargetsStore.self) private var insightsTargetsStore
    @Environment(FeatureFlagsStore.self) private var featureFlags
    @Environment(BackendAvailability.self) private var backend
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // DRIFT-2 — route through the canonical `InsightsPageHeader` so the
        // overview shares ONE header primitive with the metric / Mood pages.
        InsightsPageHeader(
            "Insights",
            accessibilityIdentifierSuffix: "overview"
        ) {
            // W-NATIVE-REORDER — single always-on customise button, the SHARED
            // equal-sized header circle. Shown only when there are targets.
            if !insightsTargetsStore.targets.isEmpty {
                InsightsHeaderActionCircle(
                    systemImage: "slider.horizontal.3",
                    accessibilityLabelText: String(localized: "Customise insights"),
                    accessibilityHintText: String(localized: "Reorder, add, or remove tiles"),
                    accessibilityIdentifier: "insights.header.customiseMenu"
                ) {
                    onCustomize()
                }
            }

            // DRIFT-3 — the Coach affordance is the SAME monochrome, STATIC
            // `InsightsHeaderActionCircle(sparkles)` used on every other Insights
            // header. Task #53 — shown in `.onDevice` + `.online`.
            if aiSurfacesVisible, featureFlags.isEnabled(.assistantCoach) {
                InsightsHeaderActionCircle(
                    systemImage: "sparkles",
                    accessibilityLabelText: String(localized: "Ask the coach"),
                    accessibilityIdentifier: "InsightsScreen.askCoachCollapsedCoin.header"
                ) {
                    // Y9-E — Quick-Launch to Chat.
                    onAskCoach()
                }
                .transition(reduceMotion ? .identity : .opacity)
            } else if coachReengageAvailable {
                // b182 (F1) — Coach suppressed but a server provider exists and
                // consent is missing/declined. Offer a re-engage entry in the SAME
                // header slot so the surface is never a silent dead end.
                InsightsHeaderActionCircle(
                    systemImage: "sparkles",
                    accessibilityLabelText: String(localized: "Enable the coach"),
                    accessibilityHintText: String(localized: "Opens the assistant consent choice"),
                    accessibilityIdentifier: "InsightsScreen.enableCoachCoin.header"
                ) {
                    reengageCoach()
                }
                .transition(reduceMotion ? .identity : .opacity)
            }
        }
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
            coachFlagEnabled: featureFlags.isEnabled(.assistantCoach),
            hasServer: backend.hasServer,
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

// MARK: - Coach slot (FeatureFlags + Settings + Backend + module gates)

/// Owns the quiet Coach re-engage card + proactive cadence suggestions. Reads
/// `FeatureFlagsStore`, `SettingsStore.coachHeroDismissed`,
/// `BackendAvailability`, and the (non-`@Observable`) `AppContainer` gates here
/// so a feature-flag / dismissal / consent change invalidates ONLY this slot,
/// not the whole overview.
struct InsightsCoachSlot: View {
    let appContainer: AppContainer?

    @Environment(FeatureFlagsStore.self) private var featureFlags
    @Environment(SettingsStore.self) private var settings
    @Environment(BackendAvailability.self) private var backend
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if coachReengageAvailable, !settings.coachHeroDismissed {
            // b182 (F1) — calm re-engage card when the Coach is suppressed but a
            // server provider exists and consent is missing/declined.
            CoachReengageCard(action: { reengageCoach() })
                .transition(reduceMotion ? .identity : .opacity)
        }

        // ── COACH CADENCE SUGGESTIONS — proactive accept/dismiss cards (#30). ──
        // Calm cards (NOT the colourful hero); the store owns opt-in + module +
        // online gating and self-suppresses when there is nothing to offer.
        if coachModuleEnabled, let cadenceStore = appContainer?.coachCadenceSuggestionsStore {
            CoachCadenceSuggestionsSection(store: cadenceStore)
                .transition(reduceMotion ? .identity : .opacity)
        }
    }

    // MARK: Gates (moved from `InsightsScreen` so their `@Observable` reads

    // register on THIS leaf — see file header).

    /// #30 — the in-overview Coach affordances respect the `coach` module.
    private var coachModuleEnabled: Bool {
        guard let gate = appContainer?.moduleGate else { return true }
        _ = gate.modules
        return gate.isEnabled(.coach)
    }

    /// b182 (F1) — gates the Coach re-engage affordance. Tracks `revision` so it
    /// re-evaluates the moment a grant lands.
    private var coachReengageAvailable: Bool {
        guard let container = appContainer else { return false }
        _ = container.aiConsentStore.revision
        let provider = container.resolvedAIProvider
        return InsightsScreen.isCoachReengageAvailable(
            aiMode: container.aiMode,
            coachFlagEnabled: featureFlags.isEnabled(.assistantCoach),
            hasServer: backend.hasServer,
            resolvedProvider: provider,
            hasConsentForProvider: container.aiConsentStore.hasConsent(for: provider),
            isServerManagedAvailable: container.aiProviderStore.config?.usesProviderOpaqueAIConsent == true,
            hasServerManagedConsent: container.aiConsentStore.hasServerManagedConsent(),
            isAIExplicitlyUnavailable: container.aiProviderStore.config?.isAIExplicitlyUnavailable == true
        )
    }

    /// b182 (F1) — re-opens the consent choice for a suppressed Coach.
    private func reengageCoach() {
        appContainer?.aiConsentStore.requestExplicitPrompt()
    }
}

// MARK: - Wellness + Signals slot (DerivedInsightsStore + Backend + module gate)

/// Owns the DEINE GESUNDHEITSWERTE wellness-score rings + the warm-in-flight
/// placeholder + the Tagesbriefing-adjacent SIGNALE DES TAGES section. Reads
/// `DerivedInsightsStore` (`presentable` / `metrics` / `warming`) + `Backend` +
/// the `insights` module gate here so a derived-metrics refresh — which fires
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
    @Environment(BackendAvailability.self) private var backend

    var body: some View {
        if backend.hasServer, insightsModuleEnabled {
            InsightsServerDerivedOverview(
                derivedMetrics: derivedInsightsStore.presentable,
                // I-2 — full list (incl. insufficient arms) for the score-ring gate.
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

            // v0.14.1 — warm-in-flight placeholder. Self-suppresses the instant a
            // score lands. Never a spinner.
            if derivedInsightsStore.warming, derivedInsightsStore.presentable.isEmpty {
                Text("insights.overview.derived.preparing")
                    .font(.hlBody)
                    .foregroundStyle(HLText.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("insights.overview.derived.preparing")
            }
        }
    }

    /// #30 — the `insights` module gates the AI/derived overview block. Fail-open
    /// when the map is absent.
    private var insightsModuleEnabled: Bool {
        InsightsOverviewGate.insightsModuleEnabled(appContainer)
    }
}

/// Owns the SIGNALE DES TAGES section (honest coincident-deviation count). Reads
/// `DerivedInsightsStore.metrics` + `Backend` + the `insights` module gate.
struct InsightsSignalsSlot: View {
    let appContainer: AppContainer?

    @Environment(DerivedInsightsStore.self) private var derivedInsightsStore
    @Environment(BackendAvailability.self) private var backend

    var body: some View {
        if backend.hasServer, InsightsOverviewGate.insightsModuleEnabled(appContainer) {
            InsightsSignalsOfTheDaySection(metrics: derivedInsightsStore.metrics)
        }
    }
}

// MARK: - Tagesbriefing slot (DailyBriefingStore + NarrativeStore + module gate)

/// Owns the TAGESBRIEFING heading + flowing-grey prose (the overall
/// health-status narrative: AI briefing summary, else the deterministic period
/// narrative fallback). Reads `DailyBriefingStore.summary` + `NarrativeStore` +
/// the `insights` module gate here, so a briefing/narrative warm invalidates
/// ONLY this slot.
struct InsightsDailyBriefingSlot: View {
    let appContainer: AppContainer?

    @Environment(DailyBriefingStore.self) private var briefingStore
    @Environment(NarrativeStore.self) private var narrativeStore

    var body: some View {
        if InsightsOverviewGate.insightsModuleEnabled(appContainer), let report = generalHealthReportText {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                // Flush drops the header inset so the heading shares the prose
                // body's leading edge.
                InsightsSectionHeader("insights.overview.dailyBriefing.title", flush: true)
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

// MARK: - Trends slot (DailyBriefingStore + MeasurementsStore)

/// Owns the TRENDS row (mini charts driven by the briefing's flagged metrics,
/// falling back to the bp/weight/pulse triple). Reads
/// `DailyBriefingStore.briefing` + `MeasurementsStore.recent` here so a new
/// measurement / briefing warm invalidates ONLY this slot.
struct InsightsTrendsSlot: View {
    /// True while the screen is in its cold-launch skeleton window (passed from
    /// the host's latched `isShowingInitialSkeleton`, so we never add a 2nd gate).
    let isLoading: Bool
    let onSelect: (MetricKind) -> Void

    @Environment(DailyBriefingStore.self) private var briefingStore
    @Environment(MeasurementsStore.self) private var measurementsStore

    var body: some View {
        InsightsTrendsRow(
            kinds: InsightsTrendChartSelector.select(
                keyFindings: briefingStore.briefing?.keyFindings ?? []
            ),
            measurements: measurementsStore.recent,
            isLoading: isLoading,
            onSelect: onSelect
        )
    }
}

// MARK: - Empty / error slot (InsightsStore + Backend)

/// Owns the standalone cloud-derived placeholder + the empty / error states.
/// Reads `InsightsStore` + `Backend` (+ `AuthStore` for the connect CTA) here so
/// a digest refresh invalidates ONLY this slot.
struct InsightsEmptyErrorSlot: View {
    @Environment(InsightsStore.self) private var store
    @Environment(BackendAvailability.self) private var backend
    @Environment(AuthStore.self) private var authStore

    var body: some View {
        // Standalone: the server-generated insight layer has no on-device
        // equivalent. One calm placeholder with the shared "Server verbinden" CTA.
        if !backend.canShowCloudInsights {
            HLCloudDerivedPlaceholder(
                surfaceName: String(localized: "cloud_derived.surface.insights"),
                onConnect: { authStore.beginServerPairing() }
            )
        }

        // Empty + Error states. Server-derived → paired only; in standalone the
        // placeholder already represents the absent server layer.
        if backend.canShowCloudInsights {
            if store.comprehensive == nil,
               store.cards.isEmpty,
               !store.isLoading,
               store.error == nil
            {
                InsightsEmptyStateCard()
            }
            if let error = store.error {
                InsightsErrorCard(error: error) {
                    Task { await store.refresh() }
                }
            }
        }
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
    @Environment(SettingsStore.self) private var settings
    /// Parity Build 4 · 4.5 — the server-first overview SECTION arrangement
    /// (which blocks show, in what order). Read here, on the composition owner,
    /// so a section edit re-lays-out the column and nothing else.
    @Environment(InsightsLayoutStore.self) private var layoutStore

    var body: some View {
        let skeleton = isShowingInitialSkeleton
        if skeleton {
            // First-paint shape-aware placeholder.
            InsightsSkeletonContent()
        } else {
            loadedContent
        }
        // Discreet last-synced caption via the shared footer.
        HLSyncStatusFooter(
            screenLoading: store.isLoading,
            firstLoginPreparing: settings.profile == nil && store.comprehensive == nil
        )
    }

    /// The ordered zones, each a store-scoped leaf so a mutation invalidates
    /// only that zone (see file header).
    ///
    /// **Parity Build 4 · 4.5 — the order and the membership are now the
    /// operator's**, read from the server-first `sections` slice instead of
    /// being hardcoded here. Web has had this since v1.15.11; iOS had no
    /// `sections` concept at all, so the whole arrangement surface was
    /// unreachable from the phone (the cluster's only P0).
    ///
    /// The quiet Coach block is deliberately outside the customizable region.
    /// Correlations are also anchored: they follow the complete server-owned
    /// section list so they always sit below Vitalwerte. The empty/error slot
    /// likewise always trails.
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

        // ── Standalone placeholder + empty / error states (anchored last). ──
        InsightsEmptyErrorSlot()
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
        case InsightsLayoutSectionId.trends:
            InsightsTrendsSlot(isLoading: isShowingInitialSkeleton, onSelect: onSelectMetric)
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

/// The `insights` module gate, shared by the slots above. Pure read over the
/// (non-`@Observable`) `AppContainer.moduleGate` (`moduleGate` IS `@Observable`,
/// so reading `.modules` inside a slot's `body` tracks it on THAT slot).
enum InsightsOverviewGate {
    /// #30 — fail-open when the map is absent.
    @MainActor
    static func insightsModuleEnabled(_ appContainer: AppContainer?) -> Bool {
        guard let gate = appContainer?.moduleGate else { return true }
        _ = gate.modules
        return gate.isEnabled(.insights)
    }
}
