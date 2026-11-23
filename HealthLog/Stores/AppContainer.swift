// swiftlint:disable type_body_length — irreducible flat composition-root body.
// `file_length` is no longer disabled (the file is under the ceiling). What
// remains over the `type_body_length` warning is the IRREDUCIBLE flat
// stored-property block (~131 decl lines) + the ~114 designated-init assignment
// lines Swift requires to live ON the type: every `let`/`var` must be declared
// + assigned in the primary body, and every PHI store MUST stay a direct,
// single-level stored property so the `Mirror.children` logout sweep
// (`AppContainer+Logout`) enumerates it — nesting one into a sub-container =
// silent cross-user PHI leak (the B187 class). All movable logic (construction
// phases + cross-store wiring) already lives in `make*`/`wire*` helper
// extensions, so the body cannot drop below ~398 lines without nesting stores.
// Rationale + per-property docs: `docs/adr/appcontainer-composition.md`;
// investigation: `.planning/v0157-features/INV-4-appcontainer.md`. Helper
// extensions: `+CoreInfra`, `+Repositories`, `+OutboxReplayFactory`,
// `+MeasurementsMedications`, `+SecondaryStores`, `+IntegrationStores`, `+Cycle`,
// `+ServerStats`, `+HealthKitStats`, `+HealthKitSeamsAttach`, `+LogoutHooks`,
// `+AIConsentGate`, `+Routing`, `+Notifications`, `+AIWiring`, `+Foreground`,
// `+Wiring`.
import Foundation

/// Composition Root. Builds + injects all services and stores. Per-property
/// rationale + the flat-block / Mirror-logout-sweep invariant:
/// `docs/adr/appcontainer-composition.md`.
@MainActor
public final class AppContainer {
    // MARK: Core infrastructure

    public internal(set) var environment: AppEnvironment // `internal(set)` for `reloadEnvironment()`
    public let keychain: KeychainStoring
    public let api: APIClientProtocol
    public let outbox: OutboxQueue
    public let reachability: Reachability
    public let swr: SWRCoordinator
    public let cacheInvalidator: CacheInvalidator
    public let auth: AuthService
    public let refreshCoordinator: RefreshCoordinator
    /// Owner-bound sign-out wipes of the later stores (see `+CoreInfra`).
    let ownerPartitionCleanup: OwnerPartitionCleanup
    let authenticatedSessionRegistry: AuthenticatedSessionLeaseRegistry
    public let measurementsRepo: MeasurementsRepository
    let profileTimeZoneBox = ProfileTimeZoneBox.shared // See ADR; #115 1.5 shared
    /// Persisted "does this server materialise today's dose slots itself?"
    /// verdict; drives `MedicationsStore.derivedIntakeSynthesisEnabledProvider`. See the type
    /// doc for the threshold, the unknown-state default, and what each direction costs.
    let medicationSlotGate = MedicationSlotMaterializationGate()
    let onboardingDraft = OnboardingDraftStore() // Setup draft, memory only; see type doc

    // MARK: Repositories

    public let medicationsRepo: MedicationsRepository
    public let glp1LocalRepo: GLP1LocalRepository
    public let medicationTherapyLogRepo: MedicationTherapyLogRepository
    public let moodRepo: MoodRepository
    public let dashboardRepo: DashboardRepository
    public let insightsRepo: InsightsRepository
    public let analyticsRepo: AnalyticsRepository
    public let metricInsightsRepo: MetricInsightsRepository
    public let achievementsRepo: AchievementsRepository
    public let settingsRepo: SettingsRepository
    public let aiProviderRepo: AIProviderRepository
    public let disclaimerAckRepo: DisclaimerAckRepository
    public let onboardingTourRepo: OnboardingTourRepository
    public let measurementCategoriesRepo: MeasurementCategoriesRepository
    public let moodTagCatalogRepo: MoodTagCatalogRepository
    public let passkeyRepo: PasskeyRepository
    public let accountSecurityRepo: AccountSecurityRepository
    public let sessionsRepo: SessionsRepository // parity 2.2
    public let accountDataResetRepo: AccountDataResetRepository // parity 2.5
    public let mfaEnrollmentRepo: MfaEnrollmentRepository // parity 2.3
    public let withingsRepo: WithingsRepository
    public let whoopRepo: WhoopRepository
    public let ouraRepo: OAuthIntegrationRepository
    public let polarRepo: OAuthIntegrationRepository
    public let fitbitRepo: OAuthIntegrationRepository
    public let stravaRepo: OAuthIntegrationRepository
    public let nightscoutRepo: NightscoutRepository
    public let injectionSitePrefsRepo: InjectionSitePrefsRepository
    public let moduleGateRepo: ModuleGateRepository
    public let avatarRepo: AvatarRepository
    public let sleepNightRepo: SleepNightRepository
    /// Sleep debt / chronotype / average + multi-night stage
    /// composition. Read-only, no outbox; consumed by the sleep metric page.
    public let sleepInsightsRepo: SleepInsightsRepository
    public let serverStatsRepos: ServerStatsRepos
    public let insightsLayoutRepo: InsightsLayoutRepository
    public let cycleRepo: CycleRepository
    public let coachAboutMeRepo: CoachAboutMeRepository
    public let labsRepo: LabsRepository // PHI — shared with outbox replay (see ADR)
    /// User-defined custom metrics. PHI — shared with outbox replay. No module
    /// gate exists server-side (verified: the routes call only `requireAuth()`
    /// and `custom-metrics` is not in `MODULE_KEYS`), so this surface is
    /// unconditionally available to an authenticated account.
    public let customMetricsRepo: CustomMetricsRepository // PHI
    /// Build 7.6 — nutrient READ + water-quick-add repo. Shared with
    /// outbox replay so an offline water quick-add survives a restart. Reads
    /// network-direct (no SWR cache); the store holds the in-memory snapshot.
    public let nutrientReadRepo: NutrientReadRepository
    /// Environmental-context module overview repo (read-only,
    /// network-direct). Module-gated (default-ON) via a `403 module.disabled`.
    public let environmentRepo: EnvironmentRepository
    public let illnessRepo: IllnessRepository // PHI — shared with outbox replay (see ADR)
    public let documentsRepo: DocumentsRepository // PHI — document vault (interactive writes, no outbox)
    public let allergiesRepo: AllergiesRepository // v1.25 PHI — shared with outbox replay
    public let familyHistoryRepo: FamilyHistoryRepository // v1.25 PHI — shared with outbox replay
    public let mentalHealthRepo: MentalHealthRepository // v1.25 PHI — shared with outbox replay
    public let doctorReport: DoctorReportService
    public let measurementReminderRepo: MeasurementReminderRepository
    public let outboxReplay: OutboxReplayService

    // MARK: HealthKit infra

    public let healthKitUploader: MeasurementBatchUploader // container-bound for test isolation
    public let healthKit: AnyHealthKitWriter? // optional during tests / macOS
    /// The device this process runs on, read once at the app boundary
    /// (``DeviceProfile/current()``) and injected. Device logic asks it;
    /// layout never does.
    public let deviceProfile: DeviceProfile
    public let backgroundSync: BackgroundSyncCoordinator // public so onboarding / re-entry can trigger
    public let healthKitDailyStatsSync: HealthKitDailyStatsSyncing? // See +HealthKitStats
    public let healthKitHRBucketSync: HealthKitHRBucketSyncing? // W-HR-BUCKET-UPLOAD / GH #34

    // MARK: Routing / notifications

    let appRouter: AppRouter // internal: `AuthenticatedShell.TabIdentifier` is internal
    let deepLinks: DeepLinkRouter

    #if canImport(UserNotifications) && canImport(UIKit)
        let notifications: NotificationService
        /// #190 — the push relay (opt-in, keys, binding, opt-out).
        let pushRelay: PushRelayStore
        /// Single-slot coalescer for per-mutation badge refreshes (see ADR).
        /// Internal (not `private`) so `AppContainer+Wiring` can read it.
        let badgeRefreshCoalescer = BadgeRefreshCoalescer()
    #endif

    /// Closure seam (so tests can spy) for clearing delivered +
    /// pending notifications + badge on sign-out. Defaulted in `init`. See ADR.
    var notificationClearOnLogoutHook: (@MainActor () async -> Void)?
    /// Where the records of the retired offline mode live, and the defaults
    /// that carry the note about them. Tests point both at their own copies;
    /// `nil` is the real Application Support folder.
    var legacyStandaloneStoreBase: URL?
    var legacyStandaloneDefaults: UserDefaults = .standard

    // MARK: Foreground throttles (see ADR for per-throttle rationale)

    var dailyStatsForegroundThrottle = ForegroundRefreshThrottle(window: 10) // W8-A1
    var foregroundNetworkThrottle = ForegroundRefreshThrottle(window: 8) // W8-8
    var foregroundCheapThrottle = ForegroundRefreshThrottle(window: 8) // A7-M1
    var swrCacheSweepThrottle = ForegroundRefreshThrottle(window: 60 * 60) // AUD-8 H-1

    // MARK: Stores (PHI-bearing slice — kept flat for the Mirror logout sweep; see ADR)

    public let authStore: AuthStore
    public let backendAvailability: BackendAvailability // R4 §3.1 capability surface
    public let dashboardStore: DashboardStore
    public let dashboardLayoutStore: DashboardLayoutStore
    public let insightsLayoutStore: InsightsLayoutStore
    public let measurementsStore: MeasurementsStore
    public let medicationsStore: MedicationsStore
    public let deliveryPreferencesStore: DeliveryPreferencesStore // v0.9.0 RA3
    #if canImport(ActivityKit)
        let medicationLiveActivityController: MedicationLiveActivityController // WWIDGET-1
    #endif
    let widgetSnapshotWriter: WidgetSnapshotWriter // WWIDGET-2
    let spotlightCoordinator: SpotlightCoordinator // W-B187 QOL-2
    let watchSession: WatchSessionCoordinator // v0.12 P2 watchOS companion
    public let moodStore: MoodStore
    public let cycleGate: CycleGate // who is offered cycle tracking (module map, gender, opt-in)
    public let cycleStore: CycleStore // inert until `cycleGate` admits the user
    public let moodTagCatalogStore: MoodTagCatalogStore
    public let moodTagManagementStore: MoodTagManagementStore
    public let moodHealthSyncStore: MoodHealthSyncStore
    /// Apple Health medications mirror toggle (iOS 26+, OFF by default).
    public let medicationHealthSyncStore: MedicationHealthSyncStore
    /// Lab results from Health Records (#180): the Labs offer and the
    /// importer the sync runs. Lazy so the composition block stays as it is;
    /// first read by `installHealthSyncOrchestration` at the end of `init`.
    lazy var clinicalLabRecordsStore = Self.makeClinicalLabRecordsStore(api: api, keychain: keychain, idiom: deviceProfile.idiom)
    public let insightsStore: InsightsStore
    public let dailyBriefingStore: DailyBriefingStore
    public let insightsPrefetch: InsightsPrefetchService // W3 daily cache-warmer
    public let healthScoreStore: HealthScoreStore
    public let achievementsStore: AchievementsStore
    public let settingsStore: SettingsStore
    /// Keeps `notificationPrefs.medication.clientManaged` true to this
    /// device (wired in `AppContainer+MedicationReminderDelivery`).
    let medicationReminderDelivery: MedicationReminderDeliveryCoordinator
    /// Decides whether this device plans the local reminders (an iPad next to
    /// an active iPhone does not). Wired in `AppContainer+ReminderPlanning`.
    let reminderPlanning: ReminderPlanningCoordinator
    public let measurementRemindersStore: MeasurementRemindersStore // W-FRONTDOORS (PHI)
    public let labsStore: LabsStore // PHI
    public let customMetricsStore: CustomMetricsStore // PHI
    public let nutrientStore: NutrientStore // Build 7.6 — nutrient read/display
    public let environmentStore: EnvironmentStore // Environmental-context display
    public let illnessStore: IllnessStore // PHI
    public let seizuresStore: SeizuresStore // PHI — seizure diary (server v1.48.0), holds the quick-log timer
    public let documentsStore: DocumentsStore // PHI — document vault
    public let allergiesStore: AllergiesStore // v1.25 PHI
    public let familyHistoryStore: FamilyHistoryStore // v1.25 PHI
    public let mentalHealthStore: MentalHealthStore // v1.25 PHI — PHQ-9 / GAD-7 screener
    public let aiProviderStore: AIProviderStore
    public let aiConsentStore: AIConsentStore // S7 / Apple Guideline 5.1.2(i)
    public let chartsStore: ChartsStore
    public let doctorReportStore: DoctorReportStore // server-rendered
    public let localDoctorReportStore: LocalDoctorReportStore // T-7 local
    public let disclaimerAckStore: DisclaimerAckStore // DISC-02
    public let onboardingTourStore: OnboardingTourStore // #32
    public let diabetesStore: DiabetesStore
    public let injectionSitePrefsStore: InjectionSitePrefsStore
    public let moduleGate: ModuleGate // #30 server-authoritative module gate
    public let coachNudgeStore: CoachNudgeStore // CCH-03
    public let coachCadenceSuggestionsStore: CoachCadenceSuggestionsStore // W-COACH-CADENCE (PHI)
    public let passkeyManagementStore: PasskeyManagementStore
    /// Settings → Security password-change surface.
    public let accountSecurityStore: AccountSecurityStore
    public let sessionsStore: SessionsStore // parity 2.2
    public let mfaEnrollmentGateStore: MfaEnrollmentGateStore // parity 2.3
    public let withingsIntegrationStore: WithingsIntegrationStore
    public let whoopIntegrationStore: WhoopIntegrationStore
    public let ouraIntegrationStore: OuraIntegrationStore
    public let polarIntegrationStore: PolarIntegrationStore
    public let fitbitIntegrationStore: FitbitIntegrationStore
    public let stravaIntegrationStore: StravaIntegrationStore
    public let nightscoutIntegrationStore: NightscoutIntegrationStore
    public let avatarStore: AvatarStore
    public let hkReadinessStore: HKReadinessStore // F7
    public let wellnessCardVisibilityStore: WellnessCardVisibilityStore // per-card Insights score-card hide (UI-pref)
    public let medicationVisibilityStore: MedicationVisibilityStore // medications hidden from the tab list, per account (UI-pref)
    public let aiCapabilityGate: AICapabilityGate // `/api/auth/me` `ai`, loaded by ModuleGate
    public let serverStatsStores: ServerStatsStores // V052-A7
    public let onDeviceBriefingService: OnDeviceBriefingService
    public let trendObservationsService: TrendObservationsService
    public let smartReminderPhraseService: SmartReminderPhraseService
    public let undoCoordinator: UndoCoordinator // shared Rückgängig-pill slot
    public let celebrationCoordinator: CelebrationCoordinator // RECONCILE-CELEBRATE
    public let liveHealthKitTodayStore: LiveHealthKitTodayStore // bug-c10-ios-direct
    public let nutrientDailySync: NutrientDailySyncing? // Nutrient day-totals sync
    public let ecgSync: (any EcgSyncing)? // Apple-Health ECG upload
    public let ecgHealthSyncStore: EcgHealthSyncStore // The device-local opt-in switch

    // Accessed from `AppContainer+Logout.swift` extension — needs internal visibility.
    let unauthorizedRef = UnauthorizedHandlerRef()
    private var replayLoopTask: Task<Void, Never>?

    // The designated initializer. Swift requires every stored property
    // of this container to be assigned here, and there are that many stores;
    // the runtime hooks that *could* leave already did (see
    // `AppContainer+Wiring.configureRuntimeWiring`). What is left is the part
    // the language will not let move.
    // function_body_length exception (owner: 09-08): designated init; stored-property assignment cannot move.
    // swiftlint:disable function_body_length
    public init(
        environment: AppEnvironment = .loadFromBundle(),
        keychain: KeychainStoring = KeychainStore(),
        passkey: PasskeyServiceProtocol,
        healthKit: AnyHealthKitWriter? = nil,
        // Test seam for the composition's own APIClient transport; `nil` = `.default`.
        apiSessionConfiguration: URLSessionConfiguration? = nil,
        // Test seam for the notification-permission read; `nil` = the system's.
        notificationsAuthorized: (@Sendable () async -> Bool)? = nil,
        deviceProfile: DeviceProfile = .phone
    ) {
        self.environment = environment
        self.keychain = keychain
        self.deviceProfile = deviceProfile

        // Core infrastructure phase — pinned APIClient, Outbox, Reachability,
        // SWR coordinator/invalidator, auth + refresh. Construction (incl. the
        // production-pin precondition + the detached probe / logout-cleanup /
        // refresh-handler wiring) lives VERBATIM in
        // `AppContainer+CoreInfra.makeCoreInfra`; the `let` handles below stay
        // on `AppContainer` so call-sites + logout reach are unchanged.
        let infra = Self.makeCoreInfra(
            environment: environment,
            keychain: keychain,
            passkey: passkey,
            unauthorizedRef: unauthorizedRef,
            apiSessionConfiguration: apiSessionConfiguration
        )
        let apiClient = infra.api
        api = apiClient
        outbox = infra.outbox
        reachability = infra.reachability
        let coordinator = infra.swr
        swr = coordinator
        cacheInvalidator = infra.cacheInvalidator
        auth = infra.auth
        refreshCoordinator = infra.refreshCoordinator
        ownerPartitionCleanup = infra.ownerPartitionCleanup
        // Repositories bundle — construction in
        // `AppContainer+Repositories.makeRepositories`; the `public let` handles
        // below stay on `AppContainer` (call-sites + logout reach unchanged).
        // `metricInsightsRepo` is built later (after the consent stores).
        let repos = Self.makeRepositories(
            apiClient: apiClient,
            outbox: outbox,
            swr: coordinator,
            baseURL: environment.baseURL
        )
        measurementsRepo = repos.measurements
        medicationsRepo = repos.medications
        glp1LocalRepo = repos.glp1Local
        medicationTherapyLogRepo = repos.medicationTherapyLog
        moodRepo = repos.mood
        dashboardRepo = repos.dashboard
        insightsRepo = repos.insights
        analyticsRepo = repos.analytics
        // metricInsightsRepo is constructed AFTER aiConsentStore + aiProviderStore
        // exist so it can capture the shared consent gate.
        achievementsRepo = repos.achievements
        settingsRepo = repos.settings
        aiProviderRepo = repos.aiProvider
        // Built early because the document repository's transport-near consent
        // lease captures these exact shared instances. Their network lifecycle
        // still starts later with the rest of the stores.
        let sharedAIProviderStore = AIProviderStore(repo: repos.aiProvider, swr: coordinator)
        let sharedAIConsentStore = AIConsentStore(keychain: keychain)
        aiProviderStore = sharedAIProviderStore
        aiConsentStore = sharedAIConsentStore
        disclaimerAckRepo = repos.disclaimerAck
        onboardingTourRepo = repos.onboardingTour
        measurementCategoriesRepo = repos.measurementCategories
        moodTagCatalogRepo = repos.moodTagCatalog
        passkeyRepo = repos.passkey
        accountSecurityRepo = repos.accountSecurity
        sessionsRepo = repos.sessions
        accountDataResetRepo = repos.accountDataReset
        mfaEnrollmentRepo = repos.mfaEnrollment
        withingsRepo = repos.withings
        whoopRepo = repos.whoop
        ouraRepo = repos.oura
        polarRepo = repos.polar
        fitbitRepo = repos.fitbit
        stravaRepo = repos.strava
        nightscoutRepo = repos.nightscout
        injectionSitePrefsRepo = repos.injectionSitePrefs
        moduleGateRepo = repos.moduleGate // #30
        avatarRepo = AvatarRepository(api: apiClient) // v0.8.0 W11
        sleepNightRepo = SleepNightRepository(api: apiClient) // Sleep hypnogram detail
        sleepInsightsRepo = SleepInsightsRepository(api: apiClient) // Rhythm + stage composition
        serverStatsRepos = Self.makeServerStatsRepos(apiClient: apiClient, outbox: outbox, swr: coordinator) // V052-A7
        // Outbox-backed so an offline Insights reorder/visibility edit survives a restart.
        insightsLayoutRepo = InsightsLayoutRepository(api: apiClient, outbox: outbox)
        doctorReport = repos.doctorReport
        // v0.14.8 cycle marathon — built before outbox-replay so it can drain the
        // cycle kinds.
        cycleRepo = CycleRepository(api: apiClient, outbox: outbox, swr: coordinator)
        // Outbox-backed so an offline adopt/dismiss survives a
        // restart (the server dedupes the replayed adoption against stored prose).
        coachAboutMeRepo = CoachAboutMeRepository(api: apiClient, outbox: outbox)
        // v1.18.6 PHI — labs + illness repos, built before outbox-replay so it can
        // drain their write kinds (offline lab/biomarker/episode/day-log writes
        // survive a restart). Both read network-direct (no SWR cache) — the store
        // holds the in-memory snapshot (v0150 arch-L1).
        labsRepo = LabsRepository(api: apiClient, outbox: outbox, swr: coordinator)
        // User-defined custom metrics, built before outbox-replay so it can drain
        // the six definition + logged-value write kinds. Catalog read is SWR
        // cache-first (`.customMetrics`); the per-metric entry feed is
        // network-direct (paged + sort-directional — see the repo doc).
        customMetricsRepo = CustomMetricsRepository(api: apiClient, outbox: outbox, swr: coordinator)
        // Build 7.6 — nutrient read/water-quick-add repo, built before
        // outbox-replay so it can drain the `logNutrientWater` kind (an offline
        // water quick-add survives a restart). Reads network-direct.
        nutrientReadRepo = NutrientReadRepository(api: apiClient, outbox: outbox)
        // Environmental-context overview repo. Read-only,
        // network-direct; no outbox (no write path yet), so it is not in the
        // replay aggregator. Module-gated (default-ON) via `403 module.disabled`.
        environmentRepo = EnvironmentRepository(api: apiClient)
        illnessRepo = IllnessRepository(api: apiClient, outbox: outbox)
        // Document vault (opt-in `inboundDocuments`). Interactive writes, no outbox
        // (see `DocumentsRepository`), so it's not in the replay aggregator below.
        documentsRepo = DocumentsRepository(
            api: apiClient,
            externalAIConsent: Self.makeDocumentAIConsentLeaseProvider(
                keychain: keychain,
                consentStore: sharedAIConsentStore,
                providerStore: sharedAIProviderStore
            )
        )
        // v1.25 PHI — structured-records (allergy + family-history) repos, built
        // before outbox-replay so it can drain their write kinds (offline writes
        // survive a restart). Both read network-direct (no SWR cache) — the store
        // holds the in-memory snapshot.
        allergiesRepo = AllergiesRepository(api: apiClient, outbox: outbox, swr: coordinator)
        familyHistoryRepo = FamilyHistoryRepository(api: apiClient, outbox: outbox, swr: coordinator)
        // v1.25 PHI — opt-in mental-health screener (PHQ-9 / GAD-7) repo, built
        // before outbox-replay so it can drain the offline submit kind. Reads
        // network-direct (no SWR cache); the store holds the in-memory history.
        mentalHealthRepo = MentalHealthRepository(api: apiClient, outbox: outbox, swr: coordinator)
        // Vorsorge reminder repo (interactive CRUD, no outbox
        // by design — see repo doc). Built here so the store below can capture it.
        measurementReminderRepo = MeasurementReminderRepository(api: apiClient)
        // Cross-repo replay aggregator — construction (incl. the best-effort
        // Mood→HealthKit mirror closures) lives VERBATIM in
        // `AppContainer+OutboxReplayFactory.makeOutboxReplay`.
        outboxReplay = Self.makeOutboxReplay(
            outbox: outbox,
            measurementsRepo: measurementsRepo,
            moodRepo: moodRepo,
            medicationsRepo: medicationsRepo,
            userThresholdsRepo: serverStatsRepos.userThresholds,
            insightsLayoutRepo: insightsLayoutRepo,
            therapyLogRepo: medicationTherapyLogRepo,
            cycleRepo: cycleRepo,
            workoutsRepo: serverStatsRepos.workouts,
            coachAboutMeRepo: coachAboutMeRepo,
            labsRepo: labsRepo,
            customMetricsRepo: customMetricsRepo,
            illnessRepo: illnessRepo,
            allergiesRepo: allergiesRepo,
            familyHistoryRepo: familyHistoryRepo,
            mentalHealthRepo: mentalHealthRepo,
            nutrientReadRepo: nutrientReadRepo,
            healthKit: healthKit,
            // audit-v0162 H1 (Opt 3) — degraded-server signal (attempt-suppression).
            serverHealth: infra.serverHealth,
            keychain: keychain,
            refreshCoordinator: infra.refreshCoordinator
        )
        self.healthKit = healthKit
        // HK-Batch-Uploader + BG-Sync-Coordinator — construction (incl. the
        // detached uploader/deletion-reconciler attach + the synchronous
        // `BGTaskScheduler.register`, which MUST run inside the launch tick)
        // lives VERBATIM in `AppContainer+HealthKitLifecycle.makeHealthKitInfra`.
        let hkInfra = Self.makeHealthKitInfra(
            apiClient: apiClient,
            healthKit: healthKit,
            measurementsRepo: measurementsRepo, keychain: keychain,
            registersHealthKitTask: HealthKitAvailabilityPolicy(idiom: deviceProfile.idiom).registersHealthKitBackgroundTask
        )
        let uploader = hkInfra.uploader
        healthKitUploader = uploader
        let bgSync = hkInfra.backgroundSync
        backgroundSync = bgSync
        // An install from the offline-mode era starts signed out; its stored
        // mode is dropped so every later launch reads the same.
        StandaloneRetirement.retireStoredMode(in: .standard)
        authenticatedSessionRegistry = AuthenticatedSessionLeaseRegistry()
        authStore = AuthStore(auth: auth, keychain: keychain, sessionRegistry: authenticatedSessionRegistry)
        // #49 / v1.30.11 — wire the native OIDC SSO driver so the login screen's
        // "Sign in with SSO" affordance can open an `ASWebAuthenticationSession`.
        #if canImport(AuthenticationServices)
            authStore.oidcAuthenticator = Self.webAuthenticationDriver()
        #endif
        // Capability surface. Folds the just-built auth store; the
        // reachability stream is wired below (`start(reachability:)`) so the
        // online flag tracks interface edges. Holds a weak ref to the store, so
        // no retain cycle with the composition root.
        let availability = BackendAvailability(
            authStore: authStore,
            // Die Adressfrage wird ab hier beobachtbar beantwortet, damit
            // eine Installation ohne hinterlegte Adresse zum Adress-Schritt
            // geführt wird statt in ein Anmeldeformular, das scheitern muss.
            hasServerAddress: environment.isServerConfigured
        )
        availability.start(reachability: reachability)
        backendAvailability = availability

        // AppRouter + DeepLinkRouter zuerst — NotificationService braucht beide.
        // Construction moved verbatim into `AppContainer+Routing.makeRouting`
        // (v0.7.3); the `isAuthenticated` gate still reads `authStore.phase`
        // at call time, so cold-start-from-tap parks the route in
        // `pendingRoute`. The local `deepLinkRouter` is retained because the
        // NotificationService below needs it.
        let routing = Self.makeRouting(authStore: authStore)
        appRouter = routing.router
        let deepLinkRouter = routing.deepLinks
        deepLinks = deepLinkRouter

        #if canImport(UserNotifications) && canImport(UIKit)
            // NotificationService konformiert AppDelegateBridge — der Helper
            // setzt `AppDelegate.bridge` (rechtzeitig vor dem ersten
            // Token-Callback) + kickt den Legacy-Backup-Purge. Construction
            // moved verbatim into `AppContainer+Notifications`.
            notifications = Self.makeNotificationService(
                api: apiClient,
                environment: environment,
                keychain: keychain,
                deepLinks: deepLinkRouter,
                backgroundSync: bgSync,
                medicationsRepo: medicationsRepo
            )
            pushRelay = Self.makePushRelay(api: apiClient, keychain: keychain, notifications: notifications)
        #endif
        dashboardStore = DashboardStore(
            repo: dashboardRepo,
            swr: coordinator,
            authenticatedSessionRegistry: authenticatedSessionRegistry,
            userIDProvider: { [keychain] in keychain.getString(forKey: KeychainKey.userID) }
        )
        dashboardLayoutStore = DashboardLayoutStore(repo: dashboardRepo, swr: coordinator)
        // Server-first Insights tile layout (order + visibility).
        insightsLayoutStore = InsightsLayoutStore(repo: insightsLayoutRepo)
        let undo = UndoCoordinator()
        undoCoordinator = undo
        // Shared PR celebration slot; built before
        // MeasurementsStore so the constructor can capture it. The
        // personal-records snapshot is wired post-construction below
        // because `serverStatsStores` is built later in this init.
        let celebration = CelebrationCoordinator()
        celebrationCoordinator = celebration
        // The LOINC physician-review registry was constructed here and
        // is gone; nothing took its slot. A locally typed reviewer name is not
        // clinical review, so the composition root has no business owning a
        // store whose only job was to manufacture that claim. Its persisted
        // state (a UserDefaults audit blob plus a Keychain name slot) is never
        // read again; no migrator revives it and no replacement key is written.
        // Personal-records snapshot box — populated after
        // `serverStatsStores` exists. The closure read by MeasurementsStore
        // peeks into this box at PR-detection time, so the late wiring is
        // fine: PR detection only fires on a successful commit, well
        // after the AppContainer.init MainActor pass has returned.
        let personalRecordsSnapshotBox = PersonalRecordsSnapshotBox()
        // MeasurementsStore + MedicationsStore — construction VERBATIM in
        // `AppContainer+MeasurementsMedications.makeMeasurementsAndMedications`;
        // the post-construction wiring (badge / delivery-prefs / spotlight)
        // stays inline below.
        let core = Self.makeMeasurementsAndMedications(
            measurementsRepo: measurementsRepo,
            medicationsRepo: medicationsRepo,
            healthKit: healthKit,
            undo: undo,
            celebration: celebration,
            personalRecordsSnapshotBox: personalRecordsSnapshotBox,
            swr: coordinator,
            keychain: keychain,
            authenticatedSessionRegistry: authenticatedSessionRegistry
        )
        measurementsStore = core.measurements
        medicationsStore = core.medications
        medicationsStore.bindAuthenticatedSessionRegistry(
            authenticatedSessionRegistry,
            ownerIDProvider: { [keychain] in keychain.getString(forKey: KeychainKey.userID) }
        )
        // Unified delivery-preferences store (Live Activity +
        // AlarmKit critical alarm). Server-default layer is the
        // NoServerDeliveryDefaults stub; behaves exactly like today's
        // device-local prefs. Stood up unconditionally (cheap UserDefaults
        // wrapper) so the edit sheet's toggles work even without ActivityKit /
        // AlarmKit. The hook wiring lives in `configureRuntimeWiring`.
        deliveryPreferencesStore = DeliveryPreferencesStore(provider: NoServerDeliveryDefaults())
        #if canImport(ActivityKit)
            // Live Activity controller; `NotificationService`
            // is the push-token sink. Hooked onto the intake-change path in
            // `configureRuntimeWiring`.
            #if canImport(UserNotifications) && canImport(UIKit)
                medicationLiveActivityController = MedicationLiveActivityController(
                    tokenSink: notifications
                )
            #else
                medicationLiveActivityController = MedicationLiveActivityController()
            #endif
        #endif
        widgetSnapshotWriter = WidgetSnapshotWriter() // Hooks in configureRuntimeWiring
        spotlightCoordinator = SpotlightCoordinator() // Hooks in configureRuntimeWiring
        aiCapabilityGate = AICapabilityGate() // Before MoodStore: its on-device tagger reads it
        moodStore = Self.makeMoodStore(
            repo: moodRepo,
            healthKit: healthKit,
            aiCapabilities: aiCapabilityGate.reader,
            undoCoordinator: undo
        )
        moodTagCatalogStore = MoodTagCatalogStore(repo: moodTagCatalogRepo) // v0.14 Daylio picker
        moodTagManagementStore = MoodTagManagementStore(repo: moodTagCatalogRepo) // v1.13.0 management
        watchSession = WatchSessionCoordinator() // Hooks in configureRuntimeWiring
        // Apple-Health State-of-Mind sync toggle (OFF by default).
        moodHealthSyncStore = MoodHealthSyncStore(
            healthKit: healthKit,
            moodRepo: moodRepo,
            keychain: keychain
        )
        // Apple Health medications mirror (device-local opt-in, OFF by
        // default). The reader is nil on non-HK builds, so the store reports
        // `isAvailable == false` and hides the toggle.
        medicationHealthSyncStore = MedicationHealthSyncStore(
            repo: medicationsRepo,
            keychain: keychain,
            reader: Self.makeAppleHealthMedicationReader()
        )
        // The account every mirror sweep is admitted
        // under. Bound rather than injected because this store's initializer is
        // `public` and the Phase-06 lease vocabulary is module-internal.
        medicationHealthSyncStore.bindHealthSyncAdmission(
            .keychainBound(keychain: keychain, registry: authenticatedSessionRegistry)
        )
        insightsStore = InsightsStore(repo: insightsRepo, swr: coordinator)
        dailyBriefingStore = DailyBriefingStore(repo: insightsRepo, swr: coordinator)
        healthScoreStore = HealthScoreStore(repo: analyticsRepo, swr: coordinator)
        achievementsStore = AchievementsStore(repo: achievementsRepo)
        // The PersonalRecords
        // derived-source + sparkline provider are now built inside the factory
        // (both depend only on `measurementsRepo`).
        serverStatsStores = Self.makeServerStatsStores(
            repos: serverStatsRepos,
            measurementsRepo: measurementsRepo
        )
        // Inject `cycleRepo` so the cycle opt-in can be
        // server-synced (explicit toggle PATCH + the one migration).
        settingsStore = SettingsStore(
            repo: settingsRepo,
            swr: coordinator,
            cycleRepo: cycleRepo,
            authenticatedSessionRegistry: authenticatedSessionRegistry,
            userIDProvider: { [keychain] in keychain.getString(forKey: KeychainKey.userID) }
        )
        // App-wide Vorsorge reminder store (SWR-deduped),
        // shared by the Home next-due tile + the manage screen.
        measurementRemindersStore = MeasurementRemindersStore(
            repo: measurementReminderRepo,
            swr: coordinator
        )
        // v1.18.6 PHI — container-owned labs + illness stores (promoted from the
        // view-local `@State` factories). The repos above are shared with the
        // outbox-replay service; the stores capture the same instance + the shared
        // undo coordinator so deletes raise the app-wide undo pill.
        labsStore = LabsStore(repository: labsRepo, undo: undo)
        labsStore.bindAuthenticatedSessionRegistry(
            authenticatedSessionRegistry,
            ownerIDProvider: { [keychain] in keychain.getString(forKey: KeychainKey.userID) }
        )
        customMetricsStore = CustomMetricsStore(repository: customMetricsRepo, undo: undo)
        // Environmental-context display store. Holds the
        // in-memory overview snapshot; module-gated (default-ON) via a
        // `403 module.disabled`. Conforms to LogoutClearable (auto-cleared).
        environmentStore = EnvironmentStore(repository: environmentRepo)
        illnessStore = IllnessStore(repository: illnessRepo, undo: undo)
        seizuresStore = SeizuresStore(repository: SeizuresRepository(api: apiClient))
        documentsStore = DocumentsStore(repository: documentsRepo, undo: undo) // shared undo pill
        documentsStore.bindAuthenticatedSessionRegistry(
            authenticatedSessionRegistry,
            ownerIDProvider: { [keychain] in keychain.getString(forKey: KeychainKey.userID) }
        )

        // v1.25 PHI — container-owned allergy + family-history stores. The repos
        // above are shared with the outbox-replay service; the stores capture the
        // same instance + the shared undo coordinator so deletes raise the app-wide
        // undo pill (deferred-delete pattern — no restore endpoint).
        allergiesStore = AllergiesStore(repository: allergiesRepo, undo: undo)
        familyHistoryStore = FamilyHistoryStore(repository: familyHistoryRepo, undo: undo)
        // v1.25 PHI — opt-in mental-health screener store (PHQ-9 / GAD-7). Holds
        // the derived history + the in-flight (PHI) answers until a submit
        // resolves; conforms to LogoutClearable so the cascade wipes it.
        mentalHealthStore = MentalHealthStore(repository: mentalHealthRepo)
        // Apply the AI-consent gate to the briefing, wire the tolerant
        // dashboard-snapshot briefing fetch, and bind the PR snapshot box —
        // impl in `AppContainer+AIConsentGate.configureInsightsConsentAndPRBox`.
        // Returns the async gate threaded into `metricInsightsRepo` below.
        let asyncGate = Self.configureInsightsConsentAndPRBox(
            personalRecordsSnapshotBox: personalRecordsSnapshotBox,
            personalRecordsStore: serverStatsStores.personalRecords,
            dailyBriefingStore: dailyBriefingStore,
            dashboardRepo: dashboardRepo,
            consentStore: aiConsentStore,
            providerStore: aiProviderStore
        )
        (metricInsightsRepo, insightsPrefetch) = Self.makeMetricInsights( // Daily assessment cache + warmer
            apiClient: apiClient, consentGate: asyncGate, swr: coordinator, targetsRepo: serverStatsRepos.insightsTargets,
            insightsRepo: insightsRepo, availability: availability, aiCapabilities: aiCapabilityGate.reader
        )
        // Secondary store cluster (charts / trends / doctor-report / research /
        // disclaimer / onboarding-tour / diabetes / injection-prefs /
        // module-gate / coach) — construction in
        // `AppContainer+SecondaryStores.makeSecondaryStores`. Built here so
        // `moduleGate` exists before `makeCycle` consults it below.
        let secondary = Self.makeSecondaryStores(
            apiClient: apiClient,
            swr: coordinator,
            measurementsRepo: measurementsRepo,
            disclaimerAckRepo: disclaimerAckRepo,
            onboardingTourRepo: onboardingTourRepo,
            injectionSitePrefsRepo: injectionSitePrefsRepo,
            moduleGateRepo: moduleGateRepo,
            doctorReport: doctorReport,
            measurementRemindersStore: measurementRemindersStore,
            measurementsStore: measurementsStore,
            medicationsStore: medicationsStore,
            moodStore: moodStore,
            settingsStore: settingsStore
        )
        chartsStore = secondary.charts
        doctorReportStore = secondary.doctorReport
        localDoctorReportStore = secondary.localDoctorReport
        disclaimerAckStore = secondary.disclaimerAck
        onboardingTourStore = secondary.onboardingTour
        diabetesStore = secondary.diabetes
        injectionSitePrefsStore = secondary.injectionSitePrefs
        moduleGate = secondary.moduleGate
        coachNudgeStore = secondary.coachNudge
        coachCadenceSuggestionsStore = secondary.coachCadence
        // Settings-surface third-party integration stores — construction
        // VERBATIM in `AppContainer+IntegrationStores.makeIntegrationStores`.
        // `whoopBaseURL` value-captured (safe: `reloadEnvironment()` only fires
        // at onboarding, before the connect surface is reachable).
        let integrations = Self.makeIntegrationStores(
            passkeyRepo: passkeyRepo,
            sessionsRepo: sessionsRepo,
            accountSecurityRepo: accountSecurityRepo,
            mfaEnrollmentRepo: mfaEnrollmentRepo,
            withingsRepo: withingsRepo,
            whoopRepo: whoopRepo,
            whoopBaseURL: environment.baseURL,
            authenticatedSessionRegistry: authenticatedSessionRegistry,
            userIDProvider: { [keychain] in keychain.getString(forKey: KeychainKey.userID) },
            ouraRepo: ouraRepo,
            polarRepo: polarRepo,
            fitbitRepo: fitbitRepo,
            stravaRepo: stravaRepo,
            nightscoutRepo: nightscoutRepo,
            avatarRepo: avatarRepo,
            settingsStore: settingsStore
        )
        passkeyManagementStore = integrations.passkeyManagement
        accountSecurityStore = AccountSecurityStore(
            repo: accountSecurityRepo,
            stepUp: StepUpElevationService(repo: accountSecurityRepo, passkey: passkey)
        )
        sessionsStore = integrations.sessions
        mfaEnrollmentGateStore = integrations.mfaEnrollmentGate
        withingsIntegrationStore = integrations.withings
        whoopIntegrationStore = integrations.whoop
        ouraIntegrationStore = integrations.oura
        polarIntegrationStore = integrations.polar
        fitbitIntegrationStore = integrations.fitbit
        stravaIntegrationStore = integrations.strava
        nightscoutIntegrationStore = integrations.nightscout
        avatarStore = integrations.avatar
        hkReadinessStore = HKReadinessStore(healthKit: healthKit, backgroundSync: bgSync, keychain: keychain)
        // Local UI-pref store for per-card Insights score-card visibility (no
        // repo — pure UserDefaults, cleared on logout via the Mirror registry).
        wellnessCardVisibilityStore = WellnessCardVisibilityStore()
        medicationVisibilityStore = MedicationVisibilityStore { [keychain] in keychain.getString(forKey: KeychainKey.userID) }
        // v0.14.8 cycle marathon — gate + store for the cycle data layer.
        // Construction in `AppContainer+Cycle.makeCycle`.
        let cycle = Self.makeCycle(
            settingsStore: settingsStore,
            moduleGate: moduleGate,
            cycleRepo: cycleRepo,
            availability: availability,
            healthKit: healthKit,
            keychain: keychain
        )
        cycleGate = cycle.gate
        cycleStore = cycle.store
        // HK-stats cluster (HR-bucket + daily-stats + live-today). Construction and
        // the anchor-sweep / cache-sweep wiring live in `makeHealthKitStatsCluster`
        // (AppContainer+HealthKitStats): HR-bucket first, so it rides the sweep hook.
        let hkStats = Self.makeHealthKitStatsCluster(
            healthKit: healthKit,
            api: apiClient,
            uploader: uploader,
            backgroundSync: bgSync,
            swr: coordinator,
            keychain: keychain,
            registry: authenticatedSessionRegistry,
            retryQueue: outbox, // A non-terminal stats chunk becomes a durable row
            moduleGate: moduleGate, // Nutrient sync gates on the module map
            profileTimeZoneBox: profileTimeZoneBox // HK day totals on the profile zone
        )
        healthKitHRBucketSync = hkStats.hrBucket
        healthKitDailyStatsSync = hkStats.dailyStats
        liveHealthKitTodayStore = hkStats.liveToday
        nutrientDailySync = hkStats.nutrient // GH #48
        // Build 7.6 — nutrient read/display store. Shares the repo with
        // outbox-replay.
        //
        // Constructed HERE rather than next to the other PHI stores
        // above, because it now also owns the state-driven HealthKit
        // read-authorization for the dietary catalog and therefore needs the
        // module gate, the HK writer and the day-totals coordinator — and the
        // last of those only exists on this line. The move is an ordering
        // change, nothing else; no other member reads `nutrientStore`.
        nutrientStore = NutrientStore(
            repository: nutrientReadRepo,
            moduleGate: moduleGate,
            healthKit: healthKit,
            dailySync: nutrientDailySync
        )
        // The Apple-Health ECG upload pair (coordinator + opt-in
        // switch). No module gate: server v1.39 serves and accepts ECG
        // recordings whatever the `insights` (AI analysis) module says, so the
        // module map plays no part in building it (work order #115 · 0.1).
        let ecg = Self.makeEcgCluster(
            healthKit: healthKit,
            repo: serverStatsRepos.ecg,
            keychain: keychain,
            authenticatedSessionRegistry: authenticatedSessionRegistry
        )
        ecgSync = ecg.sync
        ecgHealthSyncStore = ecg.store
        let assistants = Self.makeAssistantServices(aiCapabilities: aiCapabilityGate.reader) // D-1 bundle
        // swiftformat:disable:next wrap wrapArguments
        (onDeviceBriefingService, trendObservationsService, smartReminderPhraseService) = (assistants.briefing, assistants.trend, assistants.smartReminder)

        // Cross-store runtime hooks whose inputs are all built stored properties
        // — extracted into `AppContainer+Wiring.configureRuntimeWiring` (same
        // relative order, behaviour-identical: the closures fire later, never
        // during init). Runs BEFORE `wireLogoutHooks` so the logout cascade
        // hooks stay last (they weakly capture a fully initialised `self`).
        let devicesRepo = DevicesRepository(api: apiClient)
        let planning = ReminderPlanningCoordinator(idiom: deviceProfile.idiom) { try await devicesRepo.list() }
        reminderPlanning = planning
        medicationReminderDelivery = Self.makeMedicationReminderDelivery(
            api: apiClient,
            notificationsAuthorized: notificationsAuthorized,
            plansLocally: { [planning] in planning.plansLocally },
            otherPhoneIsActive: { [planning] in planning.otherPhoneIsActive }
        )
        configureRuntimeWiring(apiClient: apiClient, bgSync: bgSync)
        // Logout / 401 / account-delete hooks — wiring lives in
        // `AppContainer+LogoutHooks.wireLogoutHooks`. Called here (not earlier)
        // because the three cascade hooks weakly capture `self`, which is fully
        // initialised at this point.
        wireLogoutHooks(apiClient: apiClient)
        // Install the one capability-complete pass every
        // trigger runs. Last, because it reads eleven finished services; behind
        // `AppOwnedHealthCollection`, so it edits no trigger call site.
        installHealthSyncOrchestration()
        // Outbox-Replay-Loop: arms on online edges + initial auth-bootstrap.
        // Impl in `AppContainer+Wiring.startOutboxReplayLoop`.
        replayLoopTask = startOutboxReplayLoop()
    }

    // swiftlint:enable function_body_length

    deinit {
        replayLoopTask?.cancel()
    }

    // `handleLocalLogout()`, `makeAIConsentGate()`, `buildLocalDoctorReport(_:_:_:_:)`,
    // `makeMoodStore(...)`, HK-STATS-Wiring live in `AppContainer+*.swift` extensions
    // so the main file stays under the swiftlint 600-line + 350-body ceilings.
}
