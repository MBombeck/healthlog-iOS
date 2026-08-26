import AppIntents
import SwiftUI
#if canImport(LocalAuthentication)
    import LocalAuthentication
#endif

struct RootView: View {
    // `authStore` + `disclaimerAck` are package-internal (not `private`) so the
    // `RootView+DisclaimerGate.swift` extension can read the phase + ack state.
    @Environment(AuthStore.self) var authStore
    @Environment(SettingsStore.self) private var settings
    @Environment(AppRouter.self) private var router
    @Environment(HKReadinessStore.self) private var hkReadiness
    @Environment(FeatureFlagsStore.self) private var featureFlags
    /// R1 — trägt die Frage vor allen anderen: kennt diese Installation
    /// überhaupt eine Serveradresse? Siehe ``needsServerAddressGate``.
    @Environment(BackendAvailability.self) private var backendAvailability
    @Environment(DisclaimerAckStore.self) var disclaimerAck
    /// Parity item 2.3 — package-internal so `RootView+MfaEnrollmentGate.swift`
    /// can read the resolved forced-enrolment state.
    @Environment(MfaEnrollmentGateStore.self) var mfaEnrollmentGate
    @Environment(CelebrationCoordinator.self) private var celebration
    // Non-private so the `RootView+MfaEnrollmentGate.swift` extension can read
    // the environment (it needs `environment.baseURL` to build the enrolment
    // destination), matching the `authStore` / `disclaimerAck` precedent above.
    @Environment(\.appContainer) var container
    @Environment(\.scenePhase) private var scenePhase
    @State private var locked: Bool = false
    @State private var lastBackgroundedAt: Date?
    @State private var hasPerformedInitialAuth: Bool = false
    @State private var unlockInFlight: Bool = false
    @State private var didActivateHKBackground: Bool = false
    /// 08-09 — the locked session's own sign-out, behind the same destructive
    /// confirmation as Settings and the MFA gate. The lock screen is the one
    /// place a tap is most likely to be accidental (the phone is in a pocket,
    /// the user is aiming at Unlock), and it was the one place that signed out
    /// on contact.
    @State private var lockLogoutConfirmation = LogoutConfirmationState()

    /// Entsperr-Cooldown: Background-Pause unter dieser Schwelle bleibt unlocked.
    private let unlockGracePeriod: TimeInterval = 30

    var body: some View {
        #if DEBUG
            // CYC-1 verify seam: render the real CycleScreen container chrome on
            // the Metal path (the `drawingGroup` clip only shows on Metal, not in
            // ImageRenderer/SwiftUI previews) so the hero-ring un-clip can be
            // screenshot-verified in situ. Launch with `-cycle-ring-verify`. The
            // `@ViewBuilder` keeps the release root un-erased (no `AnyView`).
            if ProcessInfo.processInfo.arguments.contains("-cycle-ring-verify") {
                CycleScreenRingHostPreview(colorScheme: .dark)
            } else {
                rootBody
            }
        #else
            rootBody
        #endif
    }

    private var rootBody: some View {
        Group {
            switch RootPrivacyShieldPolicy.resolve(
                sceneIsActive: scenePhase == .active,
                biometricLocked: locked
            ) {
            case let .protected(reason):
                RootPrivacyShield(
                    reason: reason,
                    onUnlock: { Task { await tryUnlock() } },
                    onSignOut: { lockLogoutConfirmation.request() }
                )
                .hlLogoutConfirmation($lockLogoutConfirmation) { await authStore.logout() }
            case .unprotected:
                ZStack {
                    unprotectedRootBody
                    // RECONCILE-CELEBRATE — health feedback remains inside the
                    // unprotected root branch. When either privacy boundary wins,
                    // this entire subtree (including an already-open celebration)
                    // is unmounted before the protected frame is composed.
                    if let record = celebration.current {
                        CelebrationOverlay(record: record) {
                            celebration.dismiss()
                        }
                        .transition(.opacity)
                    }
                }
            }
        }
        // The former `if scenePhase != .active { PrivacyCoverView() }` overlay
        // is intentionally replaced by the structural branch above. Keeping the
        // historical shape named here documents why the existing security
        // contract now resolves to an even stronger terminal-root composition.
        .animation(.easeInOut(duration: 0.3), value: phaseKey)
        .animation(.easeInOut(duration: 0.2), value: scenePhase == .active)
        .animation(.easeInOut(duration: 0.3), value: needsServerAddressGate)
        .animation(.easeInOut(duration: 0.3), value: needsDisclaimerGate)
        .animation(.easeInOut(duration: 0.3), value: needsMfaEnrollmentGate)
        .animation(.easeInOut(duration: 0.2), value: locked)
        .animation(.easeInOut(duration: 0.2), value: celebration.current?.id)
        .onChange(of: scenePhase) { _, newPhase in
            handle(scenePhase: newPhase)
        }
        .task(id: phaseKey) {
            // 09-06 — an authentication change retires the foreground
            // generation. A pass that started under the previous account is
            // cancelled and drained here, and anything of it that is merely
            // *late* is refused publication by the session it captured. This is
            // the only statement every authenticated-phase transition reaches.
            ForegroundCoordinator.shared.retire()
            await performInitialAuthIfNeeded()
            await loadProfileOnAuthenticationIfNeeded()
            await activateHealthKitBackgroundIfReady()
            await refreshPushRegistrationIfReady()
            await refreshFeatureFlagsIfReady()
            await refreshDisclaimerAckIfReady()
            await refreshMfaEnrollmentIfReady()
            await refreshOnboardingTourIfReady()
            consumePendingDeepLinkIfAuthenticated()
            consumePendingCaptureRequestIfAuthenticated()
            await activateMoodHealthSyncIfReady()
            await activateWorkoutHealthSyncIfReady()
            await activateEcgHealthSyncIfReady()
        }
    }

    private var unprotectedRootBody: some View {
        ZStack {
            HLColor.background.ignoresSafeArea()
            switch authStore.phase {
            case .unknown:
                LoadingScreen()
            case .unauthenticated, .authenticating:
                // `.authenticating` keeps `OnboardingFlow` mounted across the
                // server-branch login boundary so the HealthKit + Notifications
                // permission steps actually render. The promotion to
                // `.authenticated(user)` is driven from
                // `OnboardingFlow.advanceFromNotifications` once those steps
                // complete. Closes iOS issue #10 (B).
                OnboardingFlow()
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            case .authenticated, .standalone:
                // v1.18.6 (DISC-02) + G7 (AUDIT-ONBOARDING) — the one-time
                // medical-disclaimer ack is a GATE in FRONT of the product, not a
                // sheet over an already-mounted shell. Matching web ("acknowledge
                // on Get-started, BEFORE the wizard proceeds"), an authenticated
                // user whose server `disclaimerAcknowledged` is false sees the
                // blocking, non-dismissible disclaimer BEFORE the dashboard/shell.
                // `AuthenticatedShell` is not constructed behind the gate, so the
                // product is genuinely unreachable until ack. After ack
                // (server-persisted), the gate flips and the shell mounts.
                //
                // Fail-soft: the gate only shows once the ack read RESOLVED
                // (`hasLoaded`) AND the resolved value is a definitive
                // not-acknowledged — a transient `/me` error leaves `hasLoaded`
                // unchanged, so a network blip can NEVER lock the user out.
                if needsServerAddressGate {
                    // **R1 — die Adressfrage steht vor dem Produkt.**
                    //
                    // Eine angemeldete Installation ohne hinterlegte Adresse ist
                    // nicht „frisch", sondern übernommen: bis b248 brachte die
                    // App eine eingebaute Adresse mit, seit b249 kommt sie
                    // ausschließlich aus dem Schlüsselbund. Wer vorher den
                    // eingebauten Standard benutzt hat, hat dort nie etwas
                    // hinterlegt. Dieselbe Lage entsteht bei einer
                    // Wiederherstellung ohne Schlüsselbund-Übernahme (der
                    // Eintrag ist `…ThisDeviceOnly`) oder wenn der Eintrag
                    // gelöscht wurde. Statt eine Hülle zu zeigen, in der jede
                    // Fläche mit `serverNotConfigured` scheitert, fragen wir
                    // nach der Adresse — und sagen dazu, warum.
                    //
                    // Die Anmeldung bleibt dabei bestehen: es fehlt die Adresse,
                    // nicht die Sitzung.
                    ServerURLStep(
                        onContinue: {},
                        notice: "onboarding.serverurl.recovery.notice"
                    )
                    .transition(.opacity)
                } else if needsDisclaimerGate {
                    MedicalDisclaimerAckSheet(
                        onAcknowledge: { await acknowledgeDisclaimer() },
                        isSubmitting: disclaimerAck.isAcknowledging,
                        errorMessage: disclaimerAck.error?.userFacingDescription
                    )
                    .transition(.opacity)
                } else if needsMfaEnrollmentGate, let destination = mfaEnrollmentDestination {
                    // Parity item 2.3 — operator-enforced MFA. Same "gate in
                    // front of the product" shape as the disclaimer above: the
                    // shell is not constructed behind it. Web's equivalent is
                    // the `/enroll-mfa` interstitial the proxy redirects to.
                    // Sign-out is the one escape, exactly as on web, so the user
                    // is gated but never trapped.
                    MfaEnrollmentGateSheet(
                        destination: destination,
                        onSignOut: { await authStore.logout() }
                    )
                    .transition(.opacity)
                } else {
                    // Standalone shares the same shell — feature gating happens
                    // inside individual screens via SyncModeStore.isStandalone.
                    AuthenticatedShell()
                        .transition(.opacity)
                }
            }
        }
    }

    /// v1.15 W-WORKOUT — start collecting `HKWorkout` and uploading it to the
    /// server so the existing Workouts UI populates. Always-on (workouts are a
    /// core surface, not toggle-gated) — kicked once the user is authenticated
    /// and a container exists; the observer doesn't survive process death, so we
    /// restart it on every launch. Idempotent (the importer no-ops a second
    /// start) and HK-permission-safe (the anchored query just returns nothing
    /// when HK is unauthorised). Skips Standalone — there is no server to
    /// upload to. The post-ingest hook revalidates the Workouts list so freshly
    /// imported workouts surface without a manual pull-to-refresh.
    /// Background/cold-launch ownership is wired independently in
    /// `AppContainer.wireWorkoutBackgroundSync`; this remains the foreground
    /// observer activation and re-auth migration route.
    private func activateWorkoutHealthSyncIfReady() async {
        guard case .authenticated = authStore.phase,
              let container,
              let healthKit = container.healthKit else { return }
        // W-B182 (AUDIT-WORKOUTS-RCA fix #2) — one-shot workout-read re-auth for
        // returning users onboarded before workout read joined `defaultReadTypes`
        // (b171). Runs at most once per user; no-op for users who never connected
        // HK or who already determined workout read. Must precede the importer
        // start so the first sweep can actually see history once granted.
        //
        // W-B184 — when the migration actually ran for a returning user, force a
        // full workout re-sweep: a pre-b182 build may have advanced the workout
        // anchor over an empty (read-unauthorized) sweep, masking all history
        // permanently. Re-auth alone wouldn't recover it (an incremental sweep
        // from the masked anchor sees nothing); resetting the anchor backfills.
        let didReAuthWorkoutRead = await hkReadiness
            .requestWorkoutReadAuthorizationMigrationIfNeeded()
        let userID = container.keychain.getString(forKey: KeychainKey.userID)
        let workoutsStore = container.serverStatsStores.workouts
        await healthKit.startWorkoutImportIfNeeded(
            repo: container.serverStatsRepos.workouts,
            userID: userID,
            forceFullSweep: didReAuthWorkoutRead,
            onIngest: { @Sendable in
                await workoutsStore.revalidateIfStale()
            }
        )
        // W-HKREAD — start the always-on categorical-EVENT importer (heart-
        // rhythm + mobility + audio-exposure events). The uploader is attached
        // during AppContainer composition, well before this auth-gated path, so
        // the importer always has a live upload sink here.
        await healthKit.startEventImportIfNeeded(userID: userID)
    }

    /// v0.10.0 W-Mood-B — restore the Apple-Health State-of-Mind import
    /// observer when the user has the sync toggle on (the observer doesn't
    /// survive process death). No-op when the toggle is off.
    private func activateMoodHealthSyncIfReady() async {
        guard case .authenticated = authStore.phase,
              let container else { return }
        await container.moodHealthSyncStore.activateIfEnabled()
    }

    /// GH #74 — run one ECG sweep on the transition into `.authenticated`, when
    /// the device-local upload switch is on. There is no observer to restore:
    /// the ECG path deliberately holds no background subscription (see
    /// ``AppContainer/refreshHealthKitDailyStatsForToday(force:)``), so this
    /// launch pass plus the foreground tick are the whole schedule. No-op when
    /// the switch is off.
    private func activateEcgHealthSyncIfReady() async {
        guard case .authenticated = authStore.phase,
              let container else { return }
        await container.ecgHealthSyncStore.activateIfEnabled()
    }

    /// #142 — load the profile on the phase transition into `.authenticated` so
    /// `profile.avatarUrl` (the `DashboardHeader` avatar dependency) resolves
    /// right after an in-session re-login. Cold launch loads it via
    /// `preWarmAvatarOnLaunch()`; a re-login flips the phase without re-running it
    /// and `clearOnLogout()` wiped `profile`, blanking the avatar for minutes.
    /// Idempotent: `profile == nil` skips cold launch (preWarm already loaded it).
    private func loadProfileOnAuthenticationIfNeeded() async {
        guard case .authenticated = authStore.phase,
              let container,
              settings.profile == nil else { return }
        await settings.load()
        // #30 — load the server module map alongside the profile so module-gated
        // surfaces resolve on the same authentication tick. Fail-open inside the
        // gate (all modules on) so a network blip never hides a valid surface.
        await container.moduleGate.load()
        container.cycleGate.refresh() // server `cycle` flag may now win
        container.preWarmAvatarOnLaunch()
    }

    /// F-1 server-coord — pull `/api/feature-flags` once per session
    /// + on every app-foreground transition. The store memoises
    /// in-memory, so render-path reads stay synchronous and never
    /// hit the network. Fail-open: on network error the last-known
    /// snapshot stays in place (R5 operator-control philosophy).
    /// Standalone-mode skips entirely — there is no server to ask.
    private func refreshFeatureFlagsIfReady() async {
        guard case .authenticated = authStore.phase else { return }
        await featureFlags.refresh()
    }

    /// #32 — reconcile the server-owned onboarding-tour / setup-completion flag
    /// (`onboardingTourCompleted` off `/api/auth/me`) on the authentication tick.
    /// Server-authoritative: a `true` from another device wins over a stale local
    /// cache, so a reinstalled / second-device user is not re-dropped into setup.
    /// 08-08 — owner-bound: this account's answer, cached under this account.
    private func refreshOnboardingTourIfReady() async {
        guard case .authenticated = authStore.phase,
              let container else { return }
        await container.onboardingTourStore.refresh(owner: authStore.authenticatedRouteOwner)
    }

    /// APNs-Token rotiert bei iCloud-Restore + selten beim System-Update. Beim
    /// Cold-Start + jedem Foreground-Wechsel rufen wir
    /// \`registerForRemoteNotificationsIfAuthorized()\`; ein unveränderter Token
    /// wird via \`NotificationService.didRegister\` deduped (kein POST), nur eine
    /// echte Änderung landet als neuer \`POST /api/devices\`.
    private func refreshPushRegistrationIfReady() async {
        guard case .authenticated = authStore.phase,
              let container else { return }
        #if canImport(UserNotifications) && canImport(UIKit)
            await container.notifications.registerForRemoteNotificationsIfAuthorized()
        #endif
    }

    /// Cold-Start-from-Tap: User hat auf einen Push-Banner getapped, App war
    /// noch nicht authentifiziert → DeepLinkRouter hat die Route in
    /// \`AppRouter.pendingRoute\` geparkt. Sobald wir hier in der \`.authenticated\`-
    /// Phase landen, konsumieren wir die Route. Idempotent.
    private func consumePendingDeepLinkIfAuthenticated() {
        guard case .authenticated = authStore.phase else { return }
        router.consumePendingRoute()
    }

    /// **v0.8.4 WWIDGET-3** — consume a one-shot "Erfassen" control marker.
    /// The `OpenCaptureIntent` (Control Center / Action Button) drops a marker
    /// into the shared App Group; here, on every foreground / launch tick, we
    /// pick it up and ask the router to surface the capture picker. One-shot +
    /// stale-guarded inside ``CaptureRequestStore`` so it fires once per tap
    /// and never on an unrelated later launch. Authenticated-only — capture
    /// is an in-app surface that needs a signed-in shell; an unauth marker is
    /// dropped (the consume still clears the file).
    private func consumePendingCaptureRequestIfAuthenticated() {
        let request = CaptureRequestStore().consume()
        guard let request else { return }
        guard case .authenticated = authStore.phase else { return }
        // v0.10.0 W-Mood-B — the marker now carries the target surface so the
        // shared one-shot hand-off routes a capture tap to the capture picker
        // and a mood-control tap to the mood quick-entry sheet.
        switch request.surface {
        case .capture:
            router.requestCapture()
        case .mood:
            router.requestMoodQuickEntry()
        case .medication:
            // v0.14.x Q — Home-Screen Quick Action "Log an intake" → the
            // medication quick-intake confirm sheet (same surface the central
            // CapturePicker's `.medication` row hands off to).
            router.requestMedicationQuickIntake()
        }
    }

    /// Re-Entry-Pfad: User ist bereits onboarded + HK-berechtigt → BG-Deliveries
    /// reaktivieren, sonst feuern `HKObserverQuery` und `BGProcessingTask` nicht.
    /// Onboarding selbst ruft `activateHealthKitBackground()` direkt nach Consent — diese
    /// Methode hier ist nur für den Cold-Start-Pfad zuständig.
    ///
    /// **v0.4.1 (F7) — Readiness statt body-mass-proxy:** Der pre-v0.4.1-Check
    /// las `authorizationStatus(for: HKQuantityType(.bodyMass)) == .sharingAuthorized`
    /// als Proxy für "User hat den HK-Sheet gesehen". Das war fragile (F1 §R2):
    /// User, die nur Reads gewährt + Body-Mass-Write abgelehnt haben (typisches
    /// Pattern bei Wage-Drittapp-Nutzern), schlüpften durch und bekamen jeden
    /// Cold-Start einen lautlosen Skip der BG-Reaktivierung. Jetzt läuft der
    /// Check über `HKReadinessStore.refresh()` (echter Status-Query) +
    /// `state.isFullyGranted || partiallyGranted` (mindestens irgendwas gewährt
    /// → BG-Deliveries scharfschalten, der Rest wird durch den Connect-Banner
    /// gefixt).
    private func activateHealthKitBackgroundIfReady() async {
        guard !didActivateHKBackground,
              case .authenticated = authStore.phase,
              let container else { return }
        // Real-Status-Check (statt body-mass-proxy). `refresh()` ist idempotent
        // und schreibt nur den `state`-Enum — billig genug für jeden task-id-Hop.
        await hkReadiness.refresh()
        // Aktiviere BG-Deliveries, sobald der Auth-Sheet je lief — auch bei
        // `.denied` (nur WRITE abgelehnt: die READ-Streams fliessen trotzdem und
        // MÜSSEN im Background gepullt werden). Dies ist die EINZIGE Stelle, die
        // BGProcessing- + BGAppRefresh-Task erstmalig einreiht; ein write-
        // abgeleitetes `.denied → skip` liess die betroffene Kohorte komplett
        // ohne eingereihte Tasks zurück — kein Wecker, kein Pull (#66-Restlücke).
        // `.notRequested` (Sheet nie gezeigt) bleibt der einzige Skip.
        let shouldReactivate = hkReadiness.hasEverRequestedAuthorization
        guard shouldReactivate else {
            // connectionLabel is an enum-derived status label — operator-grade.
            // swiftlint:disable:next hllog_public_privacy_interpolation
            HLLog.healthKit.debug("HK-BG-Reaktivierung übersprungen — Status: \(hkReadiness.connectionLabel, privacy: .public).")
            return
        }
        didActivateHKBackground = true
        // Restored Backfill-Window-Cutoff aus UserDefaults applizieren, BEVOR die
        // BG-Deliveries den ersten ObserverQuery ausloesen. Bei einem User, der
        // schon einen Anchor hat, ist das Predicate ohnehin no-op (HK ignoriert
        // es). Bei einem User dessen App geloescht + frisch installiert wurde,
        // erinnert sich UserDefaults nicht — restore liefert nil und wir machen
        // Default-Verhalten.
        await container.restoreHealthKitBackfillWindow()
        // **Phase 07 / plan 07-09** — this is the `coldActivation` trigger and it
        // is now named as one. The trigger is spelled out rather than inferred:
        // the budget the pass runs under (four pages per type, a first history
        // import permitted) and the capability set it plans are both resolved
        // from this value, and a cold launch plans *everything* — which is why
        // `HealthSyncCompositionPlan.installed(for: .coldActivation)` could only
        // move in the commit that changed this line.
        await container.activateHealthKitBackground(for: HealthSyncTrigger.coldActivation)
    }

    /// **R1 — die Adressfrage steht vor dem Produkt.** `true`, wenn eine
    /// angemeldete Installation keine Serveradresse (mehr) kennt.
    var needsServerAddressGate: Bool {
        Self.needsServerAddressGate(
            phase: authStore.phase,
            hasServerAddress: backendAvailability.hasServerAddress
        )
    }

    /// Reine Form von ``needsServerAddressGate`` — ohne View-Baum testbar.
    ///
    /// Nur `.authenticated` wird abgefangen. `.standalone` ist ausgenommen:
    /// dort ist „keine Adresse" der bestimmungsgemäße Dauerzustand, kein
    /// Befund. `.unauthenticated` / `.authenticating` sind ausgenommen, weil
    /// dort ohnehin `OnboardingFlow` läuft, der die Adressfrage selbst
    /// vorzieht (``OnboardingFlow/resolveStep(_:chosenMode:hasServerAddress:)``)
    /// — zwei Gates auf derselben Frage wären ein Sprung im Bild.
    nonisolated static func needsServerAddressGate(
        phase: AuthStore.Phase,
        hasServerAddress: Bool
    ) -> Bool {
        guard !hasServerAddress else { return false }
        switch phase {
        case .authenticated: return true
        case .unknown, .unauthenticated, .authenticating, .standalone: return false
        }
    }

    private var phaseKey: String {
        switch authStore.phase {
        case .unknown: "unknown"
        case .unauthenticated: "unauth"
        case .authenticating: "authenticating"
        case .authenticated: "auth"
        case .standalone: "standalone"
        }
    }

    private func performInitialAuthIfNeeded() async {
        guard authStore.phase.isUnlockEligible,
              settings.biometricLockEnabled,
              !hasPerformedInitialAuth else { return }
        hasPerformedInitialAuth = true
        locked = true
        await tryUnlock()
    }

    /// **09-06** — hand the foreground to its single owner.
    ///
    /// Synchronous, because this scene-phase handler is: a boundary that had to
    /// be awaited from here would get a fire-and-forget `Task` wrapped around
    /// it, which is precisely the untracked sibling this plan removes. The
    /// coordinator owns the one task, cancels and drains whichever pass preceded
    /// it, and closes `foreground.pass` on every exit.
    ///
    /// The lease is the account this pass belongs to. `nil` for `.standalone`
    /// and `.unknown`, where there is no server session to become stale against;
    /// a `nil` lease leaves the pass fenced by its own generation and by
    /// cancellation, which is the whole of what those phases can be stale on.
    private func startForegroundPass() {
        guard let container else { return }
        var lease: AuthenticatedSessionLease?
        if let owner = AuthStore.sessionOwner(in: authStore.phase) {
            lease = authStore.captureAuthenticatedSession(ownerID: owner)
        }
        ForegroundCoordinator.shared.begin(
            ForegroundPassPlan.make(
                container: container,
                authStore: authStore,
                settings: settings,
                hkReadiness: hkReadiness
            ),
            lease: lease
        )
    }

    private func handle(scenePhase newPhase: ScenePhase) {
        switch newPhase {
        case .background, .inactive:
            // Wenn das Lock-Overlay aktiv ist (oder Face-ID gerade läuft), wird
            // `.inactive` durch das System-Sheet selbst getriggert. In dem Fall
            // dürfen wir `lastBackgroundedAt` NICHT überschreiben — sonst
            // entsteht ein Loop nach Sheet-Dismiss.
            guard !locked, !unlockInFlight else { break }
            lastBackgroundedAt = .now
        case .active:
            // v0.8.4 WWIDGET-3 — a tap on the "Erfassen" control foregrounds
            // the app (scenePhase → .active) rather than changing phaseKey, so
            // the capture-marker consume must run here too, not only in the
            // phaseKey task. One-shot + stale-guarded, so a no-op when no
            // marker is pending. Synchronous and router-bound, so it stays the
            // scene handler's own statement rather than a pass member.
            consumePendingCaptureRequestIfAuthenticated()
            // 09-06 — everything else this tick used to fan out into a dozen
            // free-standing `Task { … }` siblings now runs as one bounded,
            // ordered, fenced pass. The coordinator opens and closes
            // `foreground.pass`, cancels and drains the previous pass, and
            // refuses a publication from a session that has been superseded.
            startForegroundPass()

            guard authStore.phase.isUnlockEligible, settings.biometricLockEnabled else {
                locked = false
                return
            }
            // Re-Auth nur, wenn die App tatsächlich pausiert war UND die
            // Grace-Period überschritten ist. `lastBackgroundedAt == nil`
            // bedeutet hier "kein Pending Re-Lock" (Cold-Start ist separat).
            guard let lastBg = lastBackgroundedAt,
                  Date.now.timeIntervalSince(lastBg) > unlockGracePeriod else { return }
            // Trigger sofort konsumieren — verhindert doppelten Task bei
            // schnellen ScenePhase-Cycles.
            lastBackgroundedAt = nil
            locked = true
            Task { await tryUnlock() }
        @unknown default:
            break
        }
    }

    private func tryUnlock() async {
        guard !unlockInFlight else { return }
        unlockInFlight = true
        defer { unlockInFlight = false }

        let result = await BiometricGate.evaluate()
        switch result {
        case .success:
            locked = false
            lastBackgroundedAt = nil
        case .unavailable:
            // Gerät hat kein Biometric / kein Passcode → Schutz nicht durchsetzbar.
            // Bewusst NICHT auto-unlocken: User muss explizit weiter.
            locked = true
        case .userCanceled, .failed:
            // Lock bleibt aktiv. User kann manuell erneut probieren.
            locked = true
        }
    }
}

private struct LoadingScreen: View {
    var body: some View {
        VStack(spacing: HLSpace.md) {
            Image(systemName: "heart.text.square.fill")
                // Cover-scale brand glyph (audit-01 H2 — was an off-scale,
                // unannotated 48pt; now the canonical `HLIconSize.cover`,
                // matching `PrivacyCoverView`).
                .font(.hlIcon(HLIconSize.cover, weight: .bold))
                .foregroundStyle(HLText.primary)
            ProgressView()
        }
    }
}

/// Compatibility surface for focused lock tests and previews. Production root
/// composition mounts `RootPrivacyShield` directly and never overlays this view
/// above an authenticated subtree.
struct LockOverlay: View {
    let onUnlock: () -> Void
    let onSignOut: () -> Void

    static let unlockButtonIdentifier = "lockOverlay.unlockButton"
    static let signOutButtonIdentifier = "lockOverlay.signOutButton"

    var body: some View {
        RootPrivacyShield(
            reason: .biometricLocked,
            onUnlock: onUnlock,
            onSignOut: onSignOut
        )
    }
}
