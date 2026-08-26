import Foundation

// MARK: - v0.7.3 repositories bundle (cluster C3)

public extension AppContainer {
    /// Bundle of the core feature repositories the composition-root owns
    /// (cluster C3). Each is a thin `Repo(api:…)` actor over the shared
    /// `APIClient` / `OutboxQueue` / `SWRCoordinator` — pure construction,
    /// no side effects, no `Task.detached`, no main-actor work.
    ///
    /// Mirrors `ServerStatsRepos` (V052-A7): the bundle exists so the
    /// `AppContainer.init` body stays inside its lint budget. The individual
    /// `public let` handles stay on `AppContainer` itself (this just feeds
    /// them) so the ~50 external call-sites + the logout cache-invalidation
    /// reach are byte-for-byte unchanged.
    ///
    /// `metricInsightsRepo` is deliberately NOT in this bundle: it is
    /// constructed later in `init`, after `aiConsentStore` + `aiProviderStore`
    /// exist, so it can capture the shared async consent gate (PB1 H1). The
    /// `outboxReplay` aggregator + `healthKitUploader` are likewise out — they
    /// depend on these repos and on the server-stats bundle, so they keep
    /// their existing position in the init sequence.
    struct RepositoriesBundle: Sendable {
        public let measurements: MeasurementsRepository
        public let medications: MedicationsRepository
        public let featureFlags: FeatureFlagsRepository
        public let glp1Local: GLP1LocalRepository
        /// v0.12 SP3+SP4 — server round-trip for the GLP-1 side-effect logbook
        /// + pen/vial inventory CRUD (Outbox-backed optimistic writes). Used in
        /// paired mode; standalone callers stay on `glp1Local`.
        public let medicationTherapyLog: MedicationTherapyLogRepository
        /// v0.11 W1 (KEYSTONE) — local-canonical SwiftData mirror for manual
        /// Measurement / Mood / MedicationIntake rows. DORMANT in paired mode
        /// (registered but unread); read-union (W2), Release door (W5), and
        /// adopt-on-pair upload (W4) light it up later. Recovery-wrapped the
        /// same way as the GLP-1 + Outbox stores, but the SwiftData open is
        /// DEFERRED off the cold-launch tick (audit P-1 — `makeWithRecoveryTask`):
        /// dormant in paired mode, so the container opens lazily on first use.
        public let local: LocalRepository
        public let mood: MoodRepository
        public let dashboard: DashboardRepository
        public let insights: InsightsRepository
        public let analytics: AnalyticsRepository
        public let achievements: AchievementsRepository
        public let settings: SettingsRepository
        public let aiProvider: AIProviderRepository
        /// v1.18.6 (DISC-02) — one-time medical-disclaimer acknowledgment
        /// (`GET /api/auth/me` read + `POST /api/onboarding/disclaimer` write).
        public let disclaimerAck: DisclaimerAckRepository
        /// #32 — server-owned onboarding-tour / setup-completion state
        /// (`GET /api/auth/me` read + `POST /api/onboarding/tour` write).
        public let onboardingTour: OnboardingTourRepository
        public let measurementCategories: MeasurementCategoriesRepository
        /// v0.14 — structured mood-tag taxonomy catalog (`GET /api/mood/tags`,
        /// server v1.8.5). Daily-SWR cached; drives the Daylio-style tagging grid.
        public let moodTagCatalog: MoodTagCatalogRepository
        public let doctorReport: DoctorReportService
        /// v0.8.0 W6 — Settings-surface repos lifted out of the Views
        /// (passkey-management / Withings). Each is a thin
        /// `Repo(api:)` actor that owns its endpoint paths so they are
        /// contract-testable rather than hand-rolled inline.
        public let passkey: PasskeyRepository
        /// Bearer-reachable account-security verbs (password change). The MFA
        /// management routes are cookie-only server-side and deliberately have
        /// no repo — see ``AccountSecurityRepository``.
        public let accountSecurity: AccountSecurityRepository
        /// Parity 2.2 — active-session list + revoke (`/api/auth/me/sessions`).
        public let sessions: SessionsRepository
        /// Parity 2.5 — "reset my health data, keep my account"
        /// (`DELETE /api/settings/data`).
        public let accountDataReset: AccountDataResetRepository
        /// Parity 2.3 — forced second-factor enrolment signal (`/api/auth/me`
        /// plus the server's `hl_mfa_enroll` UX-hint cookie).
        public let mfaEnrollment: MfaEnrollmentRepository
        public let withings: WithingsRepository
        /// v0.14.1 — WHOOP integration (server-brokered OAuth + BYO-key).
        public let whoop: WhoopRepository
        // v1.18.7 web-parity (❌-7) — Oura / Polar / Fitbit (server-OAuth) +
        // Nightscout (URL+token self-hoster). Data already flows server-side;
        // these surface the missing iOS manage card.
        public let oura: OAuthIntegrationRepository
        public let polar: OAuthIntegrationRepository
        public let fitbit: OAuthIntegrationRepository
        /// v1.28.11 (#46) — Strava workout/activity ingest (same OAuth shape).
        public let strava: OAuthIntegrationRepository
        public let nightscout: NightscoutRepository
        /// v0.11 — user-level injection-site global deny-list
        /// (`/api/auth/me/injection-site-prefs`, server v1.8.5).
        public let injectionSitePrefs: InjectionSitePrefsRepository
        /// #30 (v1.18.0) — server-authoritative per-user feature-module map
        /// (`GET /api/auth/me` `modules`, `PATCH /api/auth/me/modules`).
        public let moduleGate: ModuleGateRepository
    }

    /// Factory — constructs the C3 repos against the shared `APIClient`,
    /// `OutboxQueue`, and `SWRCoordinator`. Static so `AppContainer.init`
    /// can call it before `self` is fully initialised. The construction is
    /// VERBATIM from the prior inline init block — same args, same order — so
    /// the move is behaviour-identical.
    /// - Parameter baseURL: the paired server's origin, oder `nil`, solange
    ///   keiner eingerichtet ist. Only
    ///   `MfaEnrollmentRepository` needs it — it reads the server's
    ///   `hl_mfa_enroll` UX-hint cookie out of the shared cookie jar, which is
    ///   scoped by URL. Every other repo addresses the server through
    ///   `APIClient`'s own environment.
    static func makeRepositories(
        apiClient: APIClient,
        outbox: OutboxQueue,
        swr: SWRCoordinator,
        local: LocalRepository,
        standalone: StandaloneGate,
        baseURL: URL?
    ) -> RepositoriesBundle {
        RepositoriesBundle(
            // W1-1: route MeasurementsRepository reads through the shared SWR
            // coordinator. Closes the largest tap-trägheit gap — every chart
            // detail tap + dashboard `refreshTileStates` used to fire a cold
            // /api/measurements round-trip on every call. Writes still bypass
            // the cache and invalidate after-the-fact (read-only cache
            // mitigation, see repo doc-comment).
            // v0.11 W2 — the standalone read-union gate is threaded into the four
            // user-data repos. With the runtime mode paired the gate is inert
            // (every branch checks `isActive`), so the server/SWR path is the
            // unchanged default.
            measurements: MeasurementsRepository(api: apiClient, outbox: outbox, swr: swr, standalone: standalone),
            // audit-v0162 M-5: thread the SWR coordinator so the medication
            // outbox-replay path invalidates the medication/compliance/dashboard
            // cache keys after a deferred dose/med write lands (symmetric with
            // MeasurementsRepository). Without it the repo-held `swr` is nil and
            // `invalidateAfterIntakeReplay()` silently no-ops.
            medications: MedicationsRepository(api: apiClient, outbox: outbox, standalone: standalone, swr: swr),
            featureFlags: FeatureFlagsRepository(api: apiClient),
            // T-5 GLP-1 Detail Stack — local SwiftData store, recovery-wrapped
            // the same way as the Outbox (`OutboxQueue.makeWithRecovery`).
            // audit P-1 — the SwiftData open is DEFERRED (`makeWithRecoveryTask`):
            // nothing reads it until a GLP-1 detail screen lights up, so the
            // container opens lazily on first use, off the cold-launch tick.
            glp1Local: GLP1LocalRepository.makeWithRecoveryTask(),
            // v0.12 SP3+SP4 — therapy-log server seam (side-effects + inventory).
            medicationTherapyLog: MedicationTherapyLogRepository(api: apiClient, outbox: outbox),
            // v0.11 W1 (KEYSTONE) — standalone local mirror. Built once in
            // `AppContainer.init` so the read-union gate + the repos share the
            // SAME instance; passed in here.
            local: local,
            mood: MoodRepository(api: apiClient, outbox: outbox, standalone: standalone, swr: swr),
            dashboard: DashboardRepository(api: apiClient, standalone: standalone),
            insights: InsightsRepository(api: apiClient),
            analytics: AnalyticsRepository(api: apiClient),
            achievements: AchievementsRepository(api: apiClient),
            settings: SettingsRepository(api: apiClient),
            aiProvider: AIProviderRepository(api: apiClient),
            disclaimerAck: DisclaimerAckRepository(api: apiClient),
            onboardingTour: OnboardingTourRepository(api: apiClient),
            measurementCategories: MeasurementCategoriesRepository(api: apiClient),
            moodTagCatalog: MoodTagCatalogRepository(api: apiClient),
            doctorReport: DoctorReportService(api: apiClient),
            passkey: PasskeyRepository(api: apiClient),
            accountSecurity: AccountSecurityRepository(api: apiClient),
            sessions: SessionsRepository(api: apiClient),
            accountDataReset: AccountDataResetRepository(api: apiClient),
            mfaEnrollment: MfaEnrollmentRepository(api: apiClient, baseURL: baseURL),
            withings: WithingsRepository(api: apiClient),
            whoop: WhoopRepository(api: apiClient),
            oura: OAuthIntegrationRepository(api: apiClient, provider: .oura),
            polar: OAuthIntegrationRepository(api: apiClient, provider: .polar),
            fitbit: OAuthIntegrationRepository(api: apiClient, provider: .fitbit),
            strava: OAuthIntegrationRepository(api: apiClient, provider: .strava),
            nightscout: NightscoutRepository(api: apiClient),
            injectionSitePrefs: InjectionSitePrefsRepository(api: apiClient),
            moduleGate: ModuleGateRepository(api: apiClient)
        )
    }

    /// v0.11 W2 — assemble the standalone read-union gate. Pairs the local mirror
    /// with the HealthKit-direct adapter (the empty-returning variant on the
    /// non-HealthKit test host) and an `isStandalone` predicate that reads the
    /// persisted sync-mode straight from UserDefaults — the same key
    /// `SyncModeStore` writes, so a Settings-driven standalone↔paired flip is
    /// observed live without rebuilding the repos. Sendable + no actor hop.
    static func makeStandaloneGate(local: LocalRepository) -> StandaloneGate {
        StandaloneGate(
            local: local,
            healthKit: HealthKitReadAdapter(),
            isStandalone: standaloneModePredicate()
        )
    }

    /// `@Sendable` predicate that reads the persisted sync-mode straight from
    /// UserDefaults — the same key `SyncModeStore` writes — so a Settings-driven
    /// standalone↔paired flip is observed live, off the main actor, no actor hop.
    static func standaloneModePredicate() -> @Sendable () -> Bool {
        {
            UserDefaults.standard.string(forKey: SyncModeStore.storageKey) == SyncMode.standalone.rawValue
        }
    }
}
