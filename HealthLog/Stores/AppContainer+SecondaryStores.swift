import Foundation

// MARK: - Secondary store cluster (extracted from `AppContainer.init`)

extension AppContainer {
    /// Holds the secondary store cluster — charts / trends / doctor-report /
    /// research / disclaimer / onboarding-tour / diabetes / injection-prefs /
    /// module-gate / coach. All build from already-constructed repos + the
    /// measurement / medications / mood / settings stores + the shared reminders
    /// store, with no late cross-wiring. Pure move of the inline init block.
    struct SecondaryStoresBundle {
        let charts: ChartsStore
        let trendsOverlay: TrendsOverlayStore
        let doctorReport: DoctorReportStore
        let localDoctorReport: LocalDoctorReportStore
        let disclaimerAck: DisclaimerAckStore
        let onboardingTour: OnboardingTourStore
        let diabetes: DiabetesStore
        let injectionSitePrefs: InjectionSitePrefsStore
        let moduleGate: ModuleGate
        let coachNudge: CoachNudgeStore
        let coachCadence: CoachCadenceSuggestionsStore
    }

    /// Builds the secondary store cluster. Behaviour-identical to the prior
    /// inline init block (same constructors, same arguments).
    static func makeSecondaryStores(
        apiClient: APIClientProtocol,
        swr: SWRCoordinator,
        measurementsRepo: MeasurementsRepository,
        disclaimerAckRepo: DisclaimerAckRepository,
        onboardingTourRepo: OnboardingTourRepository,
        injectionSitePrefsRepo: InjectionSitePrefsRepository,
        moduleGateRepo: ModuleGateRepository,
        doctorReport: DoctorReportService,
        measurementRemindersStore: MeasurementRemindersStore,
        measurementsStore: MeasurementsStore,
        medicationsStore: MedicationsStore,
        moodStore: MoodStore,
        settingsStore: SettingsStore
    ) -> SecondaryStoresBundle {
        let moduleGate = ModuleGate(repo: moduleGateRepo) // #30 — defaults all-on until /api/auth/me resolves the per-user map
        return SecondaryStoresBundle(
            charts: ChartsStore(repo: measurementsRepo, swr: swr),
            // F2-CHARTLAG — hoisted out of ChartsScreen.@State so metric-toggle + range survive re-mount.
            trendsOverlay: TrendsOverlayStore(repo: measurementsRepo),
            doctorReport: DoctorReportStore(service: doctorReport),
            localDoctorReport: buildLocalDoctorReport(measurementsStore, medicationsStore, moodStore, settingsStore),
            disclaimerAck: DisclaimerAckStore(repo: disclaimerAckRepo),
            // #32 — seeds from the local cache synchronously; reconciles to the server on launch (RootView).
            onboardingTour: OnboardingTourStore(repo: onboardingTourRepo),
            // v1.18.6 — per-user diabetes opt-in (server resolves the ADA glucose bands).
            diabetes: DiabetesStore(repo: DiabetesRepository(api: apiClient)),
            injectionSitePrefs: InjectionSitePrefsStore(repo: injectionSitePrefsRepo),
            moduleGate: moduleGate,
            // CCH-03 — the Coach nudge dot reads its own thin account-wide read-only service.
            coachNudge: CoachNudgeStore(service: CoachServerService(api: apiClient)),
            // W-COACH-CADENCE (#30) — shares the app-wide reminders store so an
            // accepted (server-minted) reminder lands in the native list without
            // a second source of truth.
            coachCadence: CoachCadenceSuggestionsStore(
                repo: CoachCadenceSuggestionsRepository(api: apiClient),
                remindersStore: measurementRemindersStore,
                // W-FOCUS-FILTER — production reads the live shared Focus-filter
                // config so "pause coach nudges" suppresses the cards while a
                // Focus is on.
                focusFilterConfig: { FocusFilterConfigStore.current() }
            )
        )
    }
}
