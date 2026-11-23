import AppIntents
#if canImport(CoreSpotlight)
    import CoreSpotlight
#endif
import SwiftUI
#if canImport(UIKit)
    import UIKit
#endif
#if canImport(Spezi) && canImport(SpeziHealthKit)
    import Spezi
    import SpeziHealthKit
#endif

@main
struct HealthLogApp: App {
    // `@UIApplicationDelegateAdaptor` ist die offizielle Brücke zwischen SwiftUI-
    // Lifecycle und UIKit-`UIApplicationDelegate`-Callbacks. Apple liefert APNs-
    // Tokens ausschließlich über `application:didRegisterForRemoteNotifications…:`
    // — ohne diesen Adapter feuert der Callback niemals (auch nicht über
    // `.onChange(of: scenePhase)`).
    //
    // HealthLogSpeziDelegate subclasses SpeziAppDelegate and composes
    // the legacy AppDelegate-based APNs forwarder. This boots Spezi + the
    // HealthKitConstraint-bearing HealthLogStandard while preserving HP5
    // MOOD_REMINDER + silent-sync push delivery (see file-doc on the
    // delegate for the lifecycle ordering rationale).
    #if canImport(UIKit) && canImport(Spezi) && canImport(SpeziHealthKit) && canImport(SpeziLocalStorage)
        @UIApplicationDelegateAdaptor(HealthLogSpeziDelegate.self) private var appDelegate
    #elseif canImport(UIKit)
        @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif
    @State private var container: AppContainer

    init() {
        // Keychain first — `AppEnvironment.resolve` reads the user-chosen
        // custom server URL from `KeychainKey.serverURL`, falling back to the
        // bundle default when absent. v0.4.1 onboarding writes the override
        // BEFORE any authenticated request fires, so on next launch the
        // resolve call picks the right baseURL.
        let keychain = KeychainStore()
        // AUDIT-v0162 H2 — carry any legacy `.standard`-domain "hide medication
        // name" opt-out (written before the flag moved to the shared App-Group
        // suite the Notification Service Extension reads) forward into the
        // shared suite. Idempotent + no-op once the shared suite holds a value.
        LockScreenPrivacy.migrateLegacyValueIfNeeded()
        // Siri names no medication on a locked iPhone (the intents that
        // write run there by design).
        #if canImport(UIKit)
            IntentMedicationNamePrivacy.isDeviceLocked = { !UIApplication.shared.isProtectedDataAvailable }
        #endif
        // The ordered launch prologue. Everything that must happen
        // before the first `AppEnvironment.resolve` of the process lives in
        // `LaunchPrologue.run`, in one place, and returns the order it ran in
        // so a test can assert it instead of a comment claiming it.
        //
        // The prologue is also where the fresh-install rule's second
        // premise is composed. `UserDefaults.standard` carries what older
        // builds wrote; the witness below carries what earlier launches left on
        // disk. Passed explicitly rather than defaulted: this is the one call
        // site whose answer reaches a real user's Keychain, so it names the
        // store it consults instead of inheriting it.
        let prologue = LaunchPrologue.run(
            defaults: UserDefaults.standard,
            keychain: keychain,
            containerWitness: ApplicationSupportPriorLaunchWitness.production(),
            applyUITestOverrides: { keychain in
                #if DEBUG
                    // UI-test seam. The `-uitest-baseURL <url>`
                    // launch argument writes the override into the keychain
                    // BEFORE `AppEnvironment.resolve` runs, so the demo
                    // XCUITest can pin the app to `https://demo.healthlog.dev`
                    // without going through the ServerURL onboarding step
                    // manually. Production builds never see this branch
                    // (guarded by `#if DEBUG`). It runs AFTER the
                    // fresh-install guard, so a seeded base URL survives the
                    // guard's wipe instead of being erased by it.
                    Self.applyUITestEnvironmentOverrides(keychain: keychain)
                #endif
            },
            resolveEnvironment: { AppEnvironment.resolve(keychain: $0) }
        )
        let env = prologue.environment
        // 25-01 (decision E-2026-08-28) — the update-notice arming decision,
        // taken exactly once per install from the prologue's own ledger.
        // `.freshInstall` disarms the card forever (a fresh install runs
        // onboarding and must never see it, even when onboarding is skipped);
        // the two pre-existing outcomes arm it. Recorded here, in the same
        // init that ran the guard, so a fresh install's very first launch
        // writes its disarm before any UI exists.
        HealthKitUpdateNotice.recordLaunch(outcome: prologue.freshInstall)

        #if canImport(AuthenticationServices) && canImport(UIKit)
            let passkey: PasskeyServiceProtocol = PasskeyService()
        #else
            let passkey: PasskeyServiceProtocol = StubPasskeyService()
        #endif

        // The one read of the device class. The iPad has no HealthKit
        // writer at all, so nothing downstream can ask Apple Health for anything.
        let deviceProfile = DeviceProfile.current()
        #if canImport(HealthKit)
            let hk: AnyHealthKitWriter? = HealthKitAvailabilityPolicy(idiom: deviceProfile.idiom).readsHealthKit
                ? HealthKitService(keychain: keychain, bundleID: env.bundleID)
                : nil
        #else
            let hk: AnyHealthKitWriter? = nil
        #endif

        let container = AppContainer(
            environment: env,
            keychain: keychain,
            passkey: passkey,
            healthKit: hk,
            deviceProfile: deviceProfile
        )
        _container = State(initialValue: container)

        // Before any scene: a background launch never reaches the view tasks
        // that used to admit the account and arm its observers.
        Self.activateStoredSession(container: container, readsHealthKit: hk != nil)
    }

    var body: some Scene {
        WindowGroup {
            #if canImport(Spezi) && canImport(SpeziHealthKit) && canImport(SpeziLocalStorage)
                rootView
                    .spezi(appDelegate)
            #else
                rootView
            #endif
        }
        .commands {
            ShellCommands()
            HLPeriodCommands()
        }
    }

    /// Locked from the first composition when a stored session was admitted
    /// at launch and the biometric lock is on.
    private var startsLocked: Bool {
        AppLockClock.startsLocked(
            phase: container.authStore.phase,
            lockEnabled: container.settingsStore.biometricLockEnabled
        )
    }

    /// The unmodified SwiftUI view tree. Factored out so the `body` can
    /// conditionally apply `.spezi(_:)` only when SpeziHealthKit is linked
    /// — non-Spezi build configurations (test stubs, CI smoke targets)
    /// keep working unchanged.
    private var rootView: some View {
        RootView(initiallyLocked: startsLocked)
            // The app drew. Resumed from the same
            // one-shot render callback that owns the first-paint signposts, and
            // attached here, to `RootView()` itself, so it is that view's own
            // appearance rather than a proxy for it. Ordinary foreground
            // bootstrap awaits this before it asks the outbox to open; a
            // background write does not wait for it at all.
            .hlEmitFirstFrame(FirstFrameSignal.shared)
            // Date pickers stack their label at the
            // accessibility sizes, app-wide (sheets inherit it).
            .datePickerStyle(HLAdaptiveDatePickerStyle())
            .environment(container.authStore)
            // Capability surface (auth + reachability).
            .environment(container.backendAvailability)
            .environment(container.dashboardStore)
            .environment(container.dashboardLayoutStore)
            .environment(container.measurementsStore)
            .environment(container.medicationsStore)
            // Unified delivery preferences (Live Activity +
            // AlarmKit critical alarm) with per-channel "Dieses Gerät / Alle
            // Geräte" scope. Read/written by the medication edit sheet's
            // toggles; the per-med Live-Activity opt-in moved here (the
            // standalone LiveActivityPreferences shim was removed in v0.9.0).
            .environment(container.deliveryPreferencesStore)
            .environment(container.moodStore)
            .environment(container.moodTagCatalogStore)
            .environment(container.moodTagManagementStore)
            .environment(container.insightsStore)
            .environment(container.dailyBriefingStore)
            .environment(container.healthScoreStore)
            .environment(container.achievementsStore)
            .environment(container.settingsStore)
            // App-wide Vorsorge reminder store (Home tile + manage screen).
            .environment(container.measurementRemindersStore)
            .environment(container.aiProviderStore)
            .environment(container.chartsStore)
            .environment(container.doctorReportStore)
            .environment(container.localDoctorReportStore)
            .environment(container.disclaimerAckStore)
            .environment(container.diabetesStore)
            .environment(container.injectionSitePrefsStore)
            // Settings-surface stores (passkey /
            // Withings) so those screens go through Store→Repo, not in-View API.
            .environment(container.passkeyManagementStore)
            // Settings → Security (password change).
            .environment(container.accountSecurityStore)
            // Active-session management + the forced
            // second-factor enrolment gate (the latter read by `RootView`).
            .environment(container.sessionsStore)
            .environment(container.mfaEnrollmentGateStore)
            .environment(container.withingsIntegrationStore)
            // WHOOP integration store.
            .environment(container.whoopIntegrationStore)
            // v1.18.7 web-parity (❌-7) — Oura / Polar / Fitbit / Nightscout.
            .environment(container.ouraIntegrationStore)
            .environment(container.polarIntegrationStore)
            .environment(container.fitbitIntegrationStore)
            // v1.28.11 — Strava workout/activity connector.
            .environment(container.stravaIntegrationStore)
            .environment(container.nightscoutIntegrationStore)
            // Self-hosted avatar store (display + upload).
            .environment(container.avatarStore)
            .environment(container.hkReadinessStore)
            // The device class, read once in `init`; screens that need device
            // logic (never layout) read it from here.
            .environment(\.deviceProfile, container.deviceProfile)
            // Local per-card hide state for the Insights wellness score
            // cards (Recovery / Cardio-fitness / … cards that can never fill
            // without an Apple Watch), read by `InsightsScoreCardsBlock` + the
            // Insights customisation screen's "Score cards" toggles.
            .environment(container.wellnessCardVisibilityStore)
            // Web-Parity-Stores. Liefern Workouts, Targets,
            // Personal Records und Source-Priority an die neuen More-Tab
            // Surfaces. Stores stammen aus dem `serverStatsStores` Bundle
            // (V052-A7), die Surfaces wurden in F-3 ergänzt.
            // Server-first Insights tile layout store, consumed
            // by InsightsScreen + the in-grid edit mode.
            .environment(container.insightsLayoutStore)
            // Sync-state handshake store, read by the subtle
            // "Zuletzt synchronisiert" caption at the bottom of the Dashboard +
            // Insights scroll content (the discreet last-synced status line).
            .environment(container.serverStatsStores.syncState)
            .environment(container.serverStatsStores.workouts)
            .environment(container.serverStatsStores.personalRecords)
            .environment(container.serverStatsStores.insightsTargets)
            .environment(container.serverStatsStores.sourcePriority)
            // Editable target-range overrides.
            // Consumed by the inline per-metric band editor
            // (`InsightsTargetBandEditorSheet`) reached from ChartDetailScreen,
            // after the standalone Goals destination was retired.
            .environment(container.serverStatsStores.userThresholds)
            // The Insights overview RhythmEvents card + derived
            // re-frames block (server-derived, paired-only, self-suppressing).
            .environment(container.serverStatsStores.rhythmEvents)
            .environment(container.serverStatsStores.derivedMetrics)
            // The pulse page's intraday day-curve store
            // (server-derived, cloud-gated, self-suppressing on an empty day).
            .environment(container.serverStatsStores.intradayPulse)
            // The Insights ECG surface store. Its
            // `hasRecordings` flag data-gates the ECG pill, so an account with
            // no recordings never sees the surface at all.
            .environment(container.serverStatsStores.ecg)
            // Web-parity `TodayHero` — the daily-digest store backing the
            // dashboard `TodayHeroCard` (server-authoritative, self-hiding).
            .environment(container.serverStatsStores.dailyDigest)
            // The Insights overview discovered-correlations block
            // (server-derived, operator-gated, self-suppressing).
            .environment(container.serverStatsStores.correlationsDiscovery)
            // The Insights overview "Zeitraum im Rückblick" retrospective
            // card (server-derived, display-only, week/month toggle).
            .environment(container.serverStatsStores.narrative)
            // The Insights → Mood page relations cards (tag-influence
            // + "better days" board, server-derived, association-not-cause).
            .environment(container.serverStatsStores.moodRelations)
            // The Insights → Recovery sub-page store (strain /
            // training-load / autonomic-charge + heart-and-energy family,
            // server-computed, data-gated).
            .environment(container.serverStatsStores.recovery)
            // v1.25 — the three read-only "clinical signals"
            // awareness cards' store (Insights health-status + breathing-screening,
            // Labs labs-changes; server-authoritative, render-don't-recompute,
            // each card self-suppresses when its read is absent).
            .environment(container.serverStatsStores.clinicalSignals)
            // Shared celebration slot the
            // RootView overlays atop `AuthenticatedShell` whenever a
            // commit produces a new personal record.
            .environment(container.celebrationCoordinator)
            // The LOINC physician-review registry injection was
            // removed with the feature. No environment value replaces it:
            // there is no local review state left for a view to read.
            // HK-direct today step total
            // store consumed by the dashboard Steps tile + chart-detail
            // today-segment so they paint live numbers instead of the
            // frozen server `stats:` row.
            .environment(container.liveHealthKitTodayStore)
            .environment(container.appRouter)
            .environment(\.appContainer, container)
            // Der medizinische Pauschaltext lebt nur am Ack-Sheet und in
            // Einstellungen → Über diese App; keine Fläche muss ihn situativ
            // unterdrücken, daher keine Environment-Injektion.
            .preferredColorScheme(container.settingsStore.appearance.colorScheme)
            // The app-root tint is anchored to `HLText.primary` (handbook
            // §1.2), so every control that inherits `.tint` (toolbar items,
            // segmented pickers, ProgressView, selected tab) stays monochrome
            // and the persisted `preferredTint` cannot leak through. AskCoach
            // surfaces opt back into the gradient locally (handbook §5.9).
            .tint(HLText.primary)
            // `HLToggleStyle` rendert einen nativen Switch, gepinnt auf
            // `.tint(HLText.secondary)`: ein heller Tint würde im Dark Mode mit
            // dem weißen Thumb zu einer unsichtbaren Pille verschmelzen. So
            // bleibt der ON-Track in Light und Dark sichtbar, mit nativer
            // Drag-, Fokus-, A11y- und Reduce-Motion-Behandlung.
            .toggleStyle(.hl)
            .onOpenURL { url in
                container.deepLinks.handle(url)
            }
            // Universal-link entry point. A user
            // who scans the web invite QR / taps
            // `https://<eigener-server>/auth/register?invite=hlv_…` opens the
            // app here, sofern das Build eine passende `applinks:`-Association
            // mitbringt. Der akzeptierte Host ist der EINGERICHTETE Server —
            // die App kennt keinen eigenen mehr. Ohne eingerichteten Server
            // wird nichts geroutet. Die schmale
            // `DeepLinkRoute.universalLink(_:expectedHost:)`-Factory matcht nur
            // den Invite-Pfad; alles andere bleibt in Safari. Das Token wird
            // auth-agnostisch geparkt → vorbefüllte Registrierung im Onboarding.
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                guard let url = activity.webpageURL,
                      let route = DeepLinkRoute.universalLink(
                          url,
                          expectedHost: AppEnvironment.currentBaseURL(keychain: container.keychain)?.host
                      ) else { return }
                container.deepLinks.handle(route)
            }
            // CoreSpotlight continuation. A tap on a HealthLog
            // Spotlight result resumes here; the indexed `uniqueIdentifier` IS
            // a `healthlog://` deep-link (medication detail / Insights metric),
            // so we feed it straight to the same `DeepLinkRouter` every other
            // entry point uses — no side table, one routing path.
            .onContinueUserActivity(CSSearchableItemActionType) { activity in
                guard let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                      let url = URL(string: identifier) else { return }
                container.deepLinks.handle(url)
            }
            .task {
                // Register the Siri / Spotlight
                // shortcut phrases (Log BG / Log BP / Mark medication
                // taken). The system auto-discovers the provider, but an
                // explicit update keeps the parameter-dependent phrases
                // (medication picker) fresh after a relevant data change.
                HealthLogAppShortcuts.updateAppShortcutParameters()
                // Sweep app-owned Apple-Health import
                // multipart residue on EVERY real launch. `async let` makes
                // this a structured child of the launch task: it runs
                // alongside the auth bootstrap instead of in front of it, and
                // it is awaited below rather than detached, so it cannot
                // outlive the launch it belongs to. It is deliberately not
                // reached through `makeExportStore()` — that factory only
                // exists once the user opens the export/import surface, which
                // is exactly the user whose crashed import left the residue.
                async let sweptImportTemps = AppContainer.sweepAppleHealthImportTemps()
                await container.authStore.bootstrap()
                _ = await sweptImportTemps
                // Once auth state is resolved, warm the SWR
                // cache for the top three chart-detail destinations
                // (weight / BP / pulse). Non-blocking, off the
                // bootstrap critical path. Skip when unauthenticated
                // since `measurementsRepo` would 401.
                if case .authenticated = container.authStore.phase {
                    container.prefetchTopMetricsSeries()
                    // Warm the daily-generated Insights caches
                    // (assessments / comprehensive / briefing / targets) so the
                    // per-metric pages paint cache-first when the user opens
                    // Insights. Fire-and-forget + backend-availability-gated.
                    await container.insightsPrefetch.warm()
                    // Pre-warm the Gravatar
                    // disk cache so the Dashboard's inline header avatar
                    // can paint the cached PNG on the very first body
                    // pass instead of flashing the initials gradient
                    // while the per-view refresh hits the network.
                    container.preWarmAvatarOnLaunch()
                }
            }
    }
}

#if DEBUG
    extension HealthLogApp {
        /// **v0.5.4.1 UI-test seam.** Inspects `ProcessInfo.arguments` for
        /// `-uitest-baseURL <url>` and writes the URL to the
        /// `KeychainKey.serverURL` slot so `AppEnvironment.resolve` picks
        /// it up on the very first invocation. Debug-only by construction —
        /// the file is wrapped in `#if DEBUG` so Release builds never link
        /// this method.
        static func applyUITestEnvironmentOverrides(keychain: KeychainStoring) {
            let args = ProcessInfo.processInfo.arguments
            // Boot straight into an authenticated,
            // network-free state backed by bundled fixtures. Runs FIRST so the
            // seeded base URL + token win before `AppEnvironment.resolve`. When
            // active it short-circuits the rest of the overrides (it already
            // wipes residue + disables the biometric lock).
            if HermeticUITestSupport.isActive {
                // Exactly one of these seeds (each guards on its own arg): the
                // authenticated hermetic boot seeds a token + lands on the
                // dashboard; the H3 auth-journey boot seeds only the server URL
                // and lands on the onboarding auth step (login form).
                HermeticUITestSupport.seedAuthenticatedSession(keychain: keychain)
                HermeticUITestSupport.seedAuthJourney(keychain: keychain)
                return
            }
            if args.contains("-uitest-skip-bootstrap") {
                // **Onboarding UI-test seam.** A simulator reused across UI-test
                // runs retains residual auth state — a Bearer token + `userID`
                // in the Keychain. `AuthStore.bootstrap()` would then resolve to
                // `.authenticated` and mount `AuthenticatedShell`
                // instead of `OnboardingFlow`, so the Welcome CTA never appears.
                // This flag purges that residue BEFORE bootstrap runs so the
                // phase deterministically resolves to `.unauthenticated` →
                // `WelcomeStep`. Runs FIRST so a co-passed `-uitest-baseURL`
                // override below survives the wipe. Debug-only (the whole
                // extension is `#if DEBUG`).
                try? keychain.removeAll()
                // Clear the one-shot first-login-banner
                // flag so walkthrough tests exercise a true first login on a
                // reused simulator.
                UserDefaults.standard.removeObject(forKey: FirstLoginSyncBanner.completedDefaultsKey)
                // A reused simulator's container carries an install
                // sentinel from earlier runs, which would arm the update-
                // notice card on this build's first onboarding walkthrough.
                // The walkthroughs exercise a true first launch, and a true
                // first launch never sees the card.
                HealthKitUpdateNotice.disarm()
            }
            if let idx = args.firstIndex(of: "-uitest-baseURL"),
               idx + 1 < args.count
            {
                let urlString = args[idx + 1]
                if let url = URL(string: urlString), url.host?.isEmpty == false {
                    try? keychain.setString(url.absoluteString, forKey: KeychainKey.serverURL)
                }
            }
            if args.contains("-uitest-disable-biometric-lock") {
                // Pre-seed the UserDefaults slot SettingsStore reads on init
                // so the AccessGuard never asks for the device passcode on a
                // simulator that has no biometrics enrolled.
                UserDefaults.standard.set(false, forKey: "hl.settings.biometricLock")
            }
        }
    }
#endif

private struct AppContainerKey: EnvironmentKey {
    static let defaultValue: AppContainer? = nil
}

extension EnvironmentValues {
    var appContainer: AppContainer? {
        get { self[AppContainerKey.self] }
        set { self[AppContainerKey.self] = newValue }
    }
}

// UI-Standard R15 — `MedicalDisclaimerAcknowledgedKey` und sein
// `EnvironmentValues`-Zugang sind ersatzlos entfallen. Der DISC-02-Ansatz von
// v1.18.6 hing sechs Pauschaltexte an einen Unterdrückungs-Schalter; §3 des
// UI-Standards streicht die Texte selbst, womit der Schalter ohne Aufgabe
// dasteht. `DisclaimerAckStore` bleibt — er trägt weiterhin das blockierende
// Gate vor der App (`RootView+DisclaimerGate`).
