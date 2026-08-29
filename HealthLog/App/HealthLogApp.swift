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
    // v0.5.5: HealthLogSpeziDelegate subclasses SpeziAppDelegate and composes
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
        // 13-01 — the ordered launch prologue. Everything that must happen
        // before the first `AppEnvironment.resolve` of the process lives in
        // `LaunchPrologue.run`, in one place, and returns the order it ran in
        // so a test can assert it instead of a comment claiming it.
        //
        // 13-05 — the prologue is also where the fresh-install rule's second
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
                    // v0.5.4.1 — UI-test seam. The `-uitest-baseURL <url>`
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

        #if canImport(HealthKit)
            let hk: AnyHealthKitWriter? = HealthKitService(keychain: keychain, bundleID: env.bundleID)
        #else
            let hk: AnyHealthKitWriter? = nil
        #endif

        let container = AppContainer(
            environment: env,
            keychain: keychain,
            passkey: passkey,
            healthKit: hk
        )
        _container = State(initialValue: container)
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
    }

    /// The unmodified SwiftUI view tree. Factored out so the `body` can
    /// conditionally apply `.spezi(_:)` only when SpeziHealthKit is linked
    /// — non-Spezi build configurations (test stubs, CI smoke targets)
    /// keep working unchanged.
    private var rootView: some View {
        RootView()
            // Phase 09 / plan 09-05 — the app drew. Resumed from the same
            // one-shot render callback that owns the first-paint signposts, and
            // attached here, to `RootView()` itself, so it is that view's own
            // appearance rather than a proxy for it. Ordinary foreground
            // bootstrap awaits this before it asks the outbox to open; a
            // background write does not wait for it at all.
            .hlEmitFirstFrame(FirstFrameSignal.shared)
            .environment(container.authStore)
            .environment(container.syncModeStore)
            // R4 §3.1 — capability surface (sync-mode + auth + reachability).
            // Server-derived surfaces consult this to decide between live
            // content and `HLCloudDerivedPlaceholder`. Always-true flags in
            // paired mode → no behaviour change for paired users.
            .environment(container.backendAvailability)
            .environment(container.dashboardStore)
            .environment(container.dashboardLayoutStore)
            .environment(container.measurementsStore)
            .environment(container.medicationsStore)
            // v0.9.0 RA3 — unified delivery preferences (Live Activity +
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
            // v0.15 W-FRONTDOORS — app-wide Vorsorge reminder store (Home tile + manage screen).
            .environment(container.measurementRemindersStore)
            .environment(container.aiProviderStore)
            .environment(container.chartsStore)
            // v0.6.2.3 F2-CHARTLAG — hoisted from `ChartsScreen` so the
            // overlay survives navigation pop + tab-switch re-mount.
            .environment(container.trendsOverlayStore)
            .environment(container.doctorReportStore)
            .environment(container.localDoctorReportStore)
            .environment(container.disclaimerAckStore)
            .environment(container.diabetesStore)
            .environment(container.injectionSitePrefsStore)
            // v0.8.0 W6 — Settings-surface stores (passkey /
            // Withings) so those screens go through Store→Repo, not in-View API.
            .environment(container.passkeyManagementStore)
            // Settings → Security (password change).
            .environment(container.accountSecurityStore)
            // Parity 2.2 / 2.3 — active-session management + the forced
            // second-factor enrolment gate (the latter read by `RootView`).
            .environment(container.sessionsStore)
            .environment(container.mfaEnrollmentGateStore)
            .environment(container.withingsIntegrationStore)
            // v0.14.1 — WHOOP integration store.
            .environment(container.whoopIntegrationStore)
            // v1.18.7 web-parity (❌-7) — Oura / Polar / Fitbit / Nightscout.
            .environment(container.ouraIntegrationStore)
            .environment(container.polarIntegrationStore)
            .environment(container.fitbitIntegrationStore)
            // v1.28.11 (#46) — Strava workout/activity connector.
            .environment(container.stravaIntegrationStore)
            .environment(container.nightscoutIntegrationStore)
            // v0.8.0 W11 — self-hosted avatar store (display + upload).
            .environment(container.avatarStore)
            .environment(container.hkReadinessStore)
            // v0141 — local per-card hide state for the Insights wellness score
            // cards (Recovery / Cardio-fitness / … cards that can never fill
            // without an Apple Watch), read by `InsightsScoreCardsBlock` + the
            // Insights customisation screen's "Score cards" toggles.
            .environment(container.wellnessCardVisibilityStore)
            .environment(container.featureFlagsStore)
            // v0.5.3-F3 — Web-Parity-Stores. Liefern Workouts, Targets,
            // Personal Records und Source-Priority an die neuen More-Tab
            // Surfaces. Stores stammen aus dem `serverStatsStores` Bundle
            // (V052-A7), die Surfaces wurden in F-3 ergänzt.
            // v0.8.0 W10 — server-first Insights tile layout store, consumed
            // by InsightsScreen + the in-grid edit mode.
            .environment(container.insightsLayoutStore)
            // v0.14.1 — sync-state handshake store, read by the subtle
            // "Zuletzt synchronisiert" caption at the bottom of the Dashboard +
            // Insights scroll content (the discreet last-synced status line).
            .environment(container.serverStatsStores.syncState)
            .environment(container.serverStatsStores.workouts)
            .environment(container.serverStatsStores.personalRecords)
            .environment(container.serverStatsStores.insightsTargets)
            .environment(container.serverStatsStores.sourcePriority)
            // v0.7.1 W-TARGETS-EDITOR — editable target-range overrides.
            // v0.11 W-B — consumed by the inline per-metric band editor
            // (`InsightsTargetBandEditorSheet`) reached from ChartDetailScreen,
            // after the standalone Goals destination was retired (W-A).
            .environment(container.serverStatsStores.userThresholds)
            // v0.12 W5b — the Insights overview RhythmEvents card + derived
            // re-frames block (server-derived, paired-only, self-suppressing).
            .environment(container.serverStatsStores.rhythmEvents)
            .environment(container.serverStatsStores.derivedMetrics)
            // v0141 W-PARITY (P7) — the pulse page's intraday day-curve store
            // (server-derived, cloud-gated, self-suppressing on an empty day).
            .environment(container.serverStatsStores.intradayPulse)
            // v0141 W-PARITY (P8) — the Insights ECG surface store. Its
            // `hasRecordings` flag data-gates the ECG pill, so an account with
            // no recordings never sees the surface at all.
            .environment(container.serverStatsStores.ecg)
            // Web-parity `TodayHero` — the daily-digest store backing the
            // dashboard `TodayHeroCard` (server-authoritative, self-hiding).
            .environment(container.serverStatsStores.dailyDigest)
            // v0.12 — the Insights overview discovered-correlations block
            // (server-derived, operator-gated, self-suppressing).
            .environment(container.serverStatsStores.correlationsDiscovery)
            // I-3 — the Insights overview "Zeitraum im Rückblick" retrospective
            // card (server-derived, display-only, week/month toggle).
            .environment(container.serverStatsStores.narrative)
            // v0.14.1 — the Insights → Mood page relations cards (tag-influence
            // + "better days" board, server-derived, association-not-cause).
            .environment(container.serverStatsStores.moodRelations)
            // W-B189 (#23) — the Insights → Recovery sub-page store (strain /
            // training-load / autonomic-charge + heart-and-energy family,
            // server-computed, data-gated).
            .environment(container.serverStatsStores.recovery)
            // v1.25 (GH iOS #38) — the three read-only "clinical signals"
            // awareness cards' store (Insights health-status + breathing-screening,
            // Labs labs-changes; server-authoritative, render-don't-recompute,
            // each card self-suppresses when its read is absent).
            .environment(container.serverStatsStores.clinicalSignals)
            // v0.5.5.6 RECONCILE-CELEBRATE — shared celebration slot the
            // RootView overlays atop `AuthenticatedShell` whenever a
            // commit produces a new personal record.
            .environment(container.celebrationCoordinator)
            // 08-06 — the LOINC physician-review registry injection was
            // removed with the feature. No environment value replaces it:
            // there is no local review state left for a view to read.
            // v0.6.2.x bug-c10-ios-direct — HK-direct today step total
            // store consumed by the dashboard Steps tile + chart-detail
            // today-segment so they paint live numbers instead of the
            // frozen server `stats:` row.
            .environment(container.liveHealthKitTodayStore)
            .environment(container.appRouter)
            .environment(\.appContainer, container)
            // UI-Standard R15 (U1) — die `\.medicalDisclaimerAcknowledged`-
            // Injektion ist entfallen. Der Pauschaltext lebt nur noch am
            // Ack-Sheet und in Einstellungen → Über diese App; damit gibt es
            // keine Fläche mehr, die ihn situativ unterdrücken müsste.
            .preferredColorScheme(container.settingsStore.appearance.colorScheme)
            // Accent-Picker-Expansion (2026-05-16) — re-elevates the
            // user-pickable `preferredTint` to drive the global `.tint(...)`
            // of the entire shell, reversing the C-7 single-accent freeze.
            // Operator-feedback on `walking-checkpoint-1`: *"das mit dieser
            // Akzentfarbe muss man auswählen können"*. Every passive control
            // that inherits `.tint` (Toggle, Picker, ProgressView, selected
            // TabView item, NavigationLink chevron, segmented controls etc.)
            // v0.6.1 monochrome direction: the app-root tint is anchored
            // to `HLText.primary` (handbook §1.2). The accent-picker UI was
            // retired in v0.6.1.0, but the underlying `preferredTint`
            // preference still seeped through to every SwiftUI control via
            // this root binding — producing the operator-reported "lila ist
            // wieder da" regression on v0.6.1.x. Pinning to `HLText.primary`
            // here keeps toolbar items, segmented pickers and the like
            // monochrome by default. AskCoach surfaces opt back into the
            // gradient locally per handbook §5.9, and chart/ring sites that
            // used to read `preferredTint` are pinned to `HLText.primary`
            // alongside this commit.
            .tint(HLText.primary)
            // REG-13 (2026-05-21, TestFlight Build 23) — Operator-Feedback:
            // "guck mal bei den Schaltern, wenn ich weiß und dunkel mache,
            // dann kann ich den Schalter nicht mehr sehen". Bestimmte
            // `HLTint`-Picks (`schwarz`, `weiss`, `cyan`) resolven in Dark
            // Mode zu sehr hellen Werten, sodass der weiße Thumb mit dem
            // ON-Track-Fill zu einem einzigen unsichtbaren Pill verschmilzt.
            // QoL-A2: `HLToggleStyle` rendert jetzt einen NATIVEN Switch
            // (`.toggleStyle(.switch)`), gepinnt auf `.tint(HLText.secondary)`
            // — mono ON-Track, garantiert sichtbar gegen den weißen Thumb in
            // Light + Dark (REG-13), mit voller nativer Drag/Focus/A11y +
            // system-eigenem Reduce-Motion-Handling.
            .toggleStyle(.hl)
            .onOpenURL { url in
                container.deepLinks.handle(url)
            }
            // b182 W-B182-INVITE (GH #16) — universal-link entry point. A user
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
            // W-B187 QOL-2 — CoreSpotlight continuation. A tap on a HealthLog
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
                // v0.7.1 W-APPINTENTS — register the Siri / Spotlight
                // shortcut phrases (Log BG / Log BP / Mark medication
                // taken). The system auto-discovers the provider, but an
                // explicit update keeps the parameter-dependent phrases
                // (medication picker) fresh after a relevant data change.
                HealthLogAppShortcuts.updateAppShortcutParameters()
                // Phase 09 / plan 09-02 — sweep app-owned Apple-Health import
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
                // W1-3 — once auth state is resolved, warm the SWR
                // cache for the top three chart-detail destinations
                // (weight / BP / pulse). Non-blocking, off the
                // bootstrap critical path. Skip when unauthenticated
                // since `measurementsRepo` would 401.
                if case .authenticated = container.authStore.phase {
                    container.prefetchTopMetricsSeries()
                    // W3 (v0.11 #22) — warm the daily-generated Insights caches
                    // (assessments / comprehensive / briefing / targets) so the
                    // per-metric pages paint cache-first when the user opens
                    // Insights. Fire-and-forget + backend-availability-gated.
                    await container.insightsPrefetch.warm()
                    // v0.5.5.2 W-IMPL-GRAVATAR-V2 — pre-warm the Gravatar
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
            // W-HERMETIC-E2E (v0152) — boot straight into an authenticated,
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
                // in the Keychain, or a `standalone` OnboardingMode in
                // UserDefaults. `AuthStore.bootstrap()` would then resolve to
                // `.authenticated` / `.standalone` and mount `AuthenticatedShell`
                // instead of `OnboardingFlow`, so the Welcome CTA never appears.
                // This flag purges that residue BEFORE bootstrap runs so the
                // phase deterministically resolves to `.unauthenticated` →
                // `WelcomeStep`. Runs FIRST so a co-passed `-uitest-baseURL`
                // override below survives the wipe. Debug-only (the whole
                // extension is `#if DEBUG`).
                try? keychain.removeAll()
                UserDefaults.standard.removeObject(forKey: SyncModeStore.storageKey)
                UserDefaults.standard.removeObject(forKey: SyncModeStore.onboardingModeKey)
                // v0.14.8 W2-SYNCUX — clear the one-shot first-login-banner
                // flag so walkthrough tests exercise a true first login on a
                // reused simulator.
                UserDefaults.standard.removeObject(forKey: FirstLoginSyncBanner.completedDefaultsKey)
                // 25-01 — a reused simulator's container carries an install
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

// UI-Standard R15 (U1) — `MedicalDisclaimerAcknowledgedKey` und sein
// `EnvironmentValues`-Zugang sind ersatzlos entfallen. Der DISC-02-Ansatz von
// v1.18.6 hing sechs Pauschaltexte an einen Unterdrückungs-Schalter; §3 des
// UI-Standards streicht die Texte selbst, womit der Schalter ohne Aufgabe
// dasteht. `DisclaimerAckStore` bleibt — er trägt weiterhin das blockierende
// Gate vor der App (`RootView+DisclaimerGate`).
