import SwiftUI

/// v0.4.1 redesigned onboarding driver. Branches based on the user's
/// `ModeSelectionStep` choice — server-paired or local-only standalone.
/// Per `M2-A11 §1` the linear v0.4.0 flow had three
/// structural gaps: no mode choice, dead server-URL control, and a
/// pre-login Passkey-enrolment step that always 401'd. All three are
/// addressed here.
///
/// Flow shapes (Task #53 — the AI-source step is the final gate on EVERY
/// branch; there is no separate `.backfill` step — the HealthKit backfill
/// window is chosen inline on the HealthKit step):
/// - Server: Welcome → Mode → ServerURL → Auth → HealthKit → Notif → aiSource → Done
/// - Standalone: Welcome → Mode → HealthKit → Notif → aiSource → Done
///
/// Auth happens BEFORE HealthKit in the server branch so the Bearer token
/// is in Keychain when `HealthKitService.activateBackground` schedules
/// the first upload-on-wakeup. Standalone skips auth + notifications-on-server
/// but keeps APNs local-only path (local notifications via
/// `UserNotifications` still work in standalone mode).
struct OnboardingFlow: View {
    @Environment(AuthStore.self) private var authStore
    @Environment(SyncModeStore.self) private var syncModeStore
    /// R1 — beantwortet die Frage vor allen anderen: kennt diese Installation
    /// überhaupt eine Serveradresse? Ohne sie darf kein Anmeldeschritt kommen.
    @Environment(BackendAvailability.self) private var backend
    @Environment(AppRouter.self) private var router
    @Environment(\.appContainer) private var container
    /// A11Y (audit-v0162 §5) — gates the imperative step-transition animations
    /// below so they cross-dissolve instead of sliding when Reduce Motion is on.
    /// The container `.hlAnimation(value: step)` already honours it; the explicit
    /// `withAnimation(...) { step = … }` callsites did not until now.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var step: Step = OnboardingFlow.initialStep
    /// Set when the user picks a mode in `ModeSelectionStep`. `nil` before
    /// the choice. Drives the rest of the flow.
    @State private var chosenMode: OnboardingMode?
    /// Cached value from the post-ServerURL probe — gates whether the
    /// auth step shows the "Neues Konto" CTA.
    @State private var registrationEnabled: Bool = true
    /// parity 2.9 — cached `GET /api/auth/oidc/status`, probed on the same
    /// beats as `registrationEnabled`. Gates the SSO button (no IdP → hide it)
    /// and, in `OIDC_ONLY` mode, the password / passkey / register CTAs the
    /// server would refuse. `.unknown` until probed → all doors visible.
    @State private var oidcStatus: OidcStatus = .unknown
    /// #65 / 13-02 — cached web-handoff availability, probed on the same beats
    /// as `registrationEnabled` / `oidcStatus`. Gates the self-hosted
    /// web-handoff CTA. Fail-closed: anything but `.available` keeps the native
    /// form. `.probing` until the answer lands — the auth step's FIRST render
    /// sees this value, and it must not be mistaken for "no web login here".
    @State private var webLoginAvailability: WebLoginAvailability = .probing
    /// b182 W-B182-INVITE (GH #16) — the server invite token consumed (one-shot)
    /// from `AppRouter.pendingInviteToken` when the user arrives via the web
    /// invite QR / universal link. Non-nil drives the flow straight into the
    /// server-branch auth step and auto-opens the prefilled `RegistrationSheet`.
    /// Sensitive secret — held only in transient `@State`, never logged.
    @State private var inviteToken: String?
    /// **Phase 08 Wave 1** — the in-flight post-authentication completion
    /// lookup. Held so a repeated `.authenticating` notification cannot start a
    /// second one, and so a sign-out or an account change can cancel the one
    /// that is running instead of letting its answer land on the next session.
    @State private var routeResolution: Task<Void, Never>?
    /// **Phase 16 Plan 01 (K10)** — how much of setup this run owes. `.full`
    /// until a post-authentication decision narrows it; the pre-authentication
    /// walk is always full by construction (nothing has been asked yet).
    @State private var setupScope: PostAuthenticationSetupScope = .full

    var body: some View {
        VStack(spacing: 0) {
            // audit 02 · C-2 — back navigation across onboarding steps. A leading
            // back affordance lets the user return (crucially serverURL ↔ auth)
            // so a wrong server URL or a stuck auth step is no longer a
            // force-quit trap. The bar reserves its height even when back is
            // unavailable (welcome / the post-auth boundary), so stepping never
            // jolts the progress bar's vertical position.
            HStack {
                if canGoBack {
                    Button { goBack() } label: {
                        Image(systemName: "chevron.left")
                            .font(.hlTitle3)
                            .foregroundStyle(HLText.primary)
                            // 08-10 — the region, not the glyph. The literal is
                            // `HLHitTarget.minimum` spelled out because this is
                            // a call site that states its own frame, and the
                            // policy that measures it reads the number.
                            .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(Text("onboarding.back"))
                    .accessibilityIdentifier("onboarding.backButton")
                }
                Spacer(minLength: 0)
            }
            .frame(height: 44)
            .padding(.horizontal, HLSpace.lg)
            // Extra top headroom so the bar clears the Dynamic Island on Pro
            // devices (the flow already respects the top safe area; this is
            // defensive breathing room — moved up here from the progress bar).
            .padding(.top, HLSpace.lg)

            ProgressIndicator(
                fraction: routeProgress.fraction,
                accessibilityLabel: routeProgress.label,
                accessibilityValue: routeProgress.value
            )
            .padding(.top, HLSpace.sm)

            Group {
                switch resolvedStep {
                case .welcome:
                    WelcomeStep(onNext: { advanceFromWelcome() })
                case .mode:
                    ModeSelectionStep(onChoose: handleModeChoice(_:))
                case .serverURL:
                    ServerURLStep(onContinue: handleServerURLContinue)
                case .auth:
                    ServerAuthStep(
                        registrationEnabled: registrationEnabled,
                        oidcStatus: oidcStatus,
                        webLoginAvailability: webLoginAvailability,
                        prefilledInviteToken: inviteToken,
                        // R1 — der immer verfügbare Ausgang zur Adressfrage.
                        onChangeServer: { goToServerURL() }
                    )
                    // 13-04 — the auth step asks for the answer it needs
                    // instead of depending on whoever routed here having asked
                    // for it. In production `handleServerURLContinue` has
                    // already run and `AuthService` caches per host, so this
                    // resolves without a second round trip; on any path that
                    // reaches `.auth` without passing through the ServerURL
                    // step — a DEBUG auth-journey boot, and any future route —
                    // it is the difference between a probe and no probe.
                    .task(id: step) {
                        guard step == .auth, webLoginAvailability == .probing else { return }
                        webLoginAvailability = await authStore.webLoginAvailability()
                    }
                case .checkingCompletion:
                    CompletionLookupStep()
                case .completionUnavailable:
                    CompletionUnavailableStep(onRetry: { resolvePostAuthenticationRoute() })
                case .healthKit:
                    HealthKitPermissionStep(
                        onNext: { advanceFromHealthKit() },
                        onSkip: { advanceFromHealthKit() }
                    )
                case .notifications:
                    NotificationsPermissionStep(
                        onNext: { advanceFromNotifications() },
                        onSkip: { advanceFromNotifications() }
                    )
                case .aiSource:
                    AISourceStep(
                        onNext: { advanceFromAISource() },
                        onSkip: { advanceFromAISource() }
                    )
                case .anamnesis:
                    AnamnesisStep(
                        onNext: { advanceFromAnamnesis() },
                        onSkip: { advanceFromAnamnesis() }
                    )
                case .baselineProfile:
                    BaselineProfileStep(
                        onNext: { finishOnboarding() },
                        onSkip: { finishOnboarding() }
                    )
                case .done:
                    // `done` is a transient state — `advanceFromNotifications`
                    // immediately triggers the phase transition. This case
                    // shows a brief loader during the handoff.
                    LoadingHandoffView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.asymmetric(
                insertion: .move(edge: .trailing),
                removal: .move(edge: .leading)
            ))
        }
        // v0.11 W5 — quiet adopt-on-pair indicator. When a previously-standalone
        // user pairs (Settings → `beginServerPairing()` → re-onboard → login),
        // the local mirror is uploaded once; `AuthStore.adoptUploadState` drives
        // a calm inline "moving your data over…" banner pinned above the bottom
        // safe area. Stays absent for every paired-from-start login (the state
        // is `.idle` unless a genuine standalone→paired transition fired).
        .safeAreaInset(edge: .bottom) {
            AdoptUploadIndicator(
                state: authStore.adoptUploadState,
                onRetry: { authStore.retryAdoptUpload() }
            )
        }
        .background(HLColor.background.ignoresSafeArea())
        // v0.5.5.1 perceptual budget (PROJECT_GUIDE.md Marathon discipline →
        // animation 200-300 ms): response tuned from 0.4 → 0.3 to land
        // inside the budget. `hlAnimation` suppresses the spring entirely
        // when Reduce-Motion is on so onboarding step-transitions cross
        // -dissolve rather than slide.
        .hlAnimation(.spring(response: 0.3, dampingFraction: 0.85), value: resolvedStep)
        // Server-branch auto-advance: when the user successfully logs in mid-
        // flow (auth step), bounce them to HealthKit. Registration hits the
        // same `.authenticated` phase.
        .onChange(of: authStore.phase) { _, newPhase in
            handlePhase(newPhase)
        }
        // b182 W-B182-INVITE (GH #16) — pick up an invite token that was parked
        // before the flow appeared (cold launch via the web invite link). Runs
        // once on appear AND when the parked token changes (warm launch / link
        // tapped while the welcome step is on screen).
        //
        // D-24-01-A — and, before that, the session question. An invite is an
        // offer to sign in; a session that has already been accepted has moved
        // past it, so the resume is asked first.
        .onAppear {
            resumePostAuthenticationRouteIfNeeded()
            consumeInviteTokenIfPresent()
        }
        .onChange(of: router.pendingInviteToken) { _, _ in
            consumeInviteTokenIfPresent()
        }
    }

    // MARK: - Invite deep link (b182 W-B182-INVITE)

    /// One-shot consume of `AppRouter.pendingInviteToken` → drive the flow into
    /// the server-branch auth step with the token prefilled. An invite always
    /// implies server mode against the managed host (the bundled default base
    /// URL already resolves there, so no URL override is needed). Only fires
    /// when the user hasn't already committed to a different mode mid-flow.
    private func consumeInviteTokenIfPresent() {
        guard inviteToken == nil, chosenMode == nil,
              let token = router.consumePendingInviteToken() else { return }
        inviteToken = token
        chosenMode = .server
        authStore.markOnboardingMode(.server)
        // Probe registration-status so the auth step renders correctly; the
        // invite still works on a closed instance (the token is the door key).
        Task { registrationEnabled = await authStore.isRegistrationEnabled() }
        // parity 2.9 — and the OIDC status, so an `OIDC_ONLY` instance does not
        // offer the invited user a password form the server will refuse.
        Task { oidcStatus = await authStore.fetchOidcStatus() }
        // #65 — and the web-handoff availability, so a self-hosted instance on
        // the frozen contract offers the web-login CTA (fail-closed otherwise).
        Task { webLoginAvailability = await authStore.webLoginAvailability() }
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) { step = .auth }
    }

    // MARK: - Branching

    private func advanceFromWelcome() {
        // v0.11 W5 — the Release standalone door. The mode-selection step
        // offers "Connect a server" OR "Use without an account" (local-only
        // standalone).
        //
        // v0.15 — server-connect is now MANDATORY: when
        // `FeatureFlags.standaloneModeAvailable == false` we skip the
        // mode-selection fork entirely and go straight to the server-connect
        // path (Welcome → ServerURL → Auth), so no standalone affordance is
        // ever visible. The standalone runtime stays in place; only this
        // entry point is gated. Flip the flag to restore the W5 fork.
        let next = Self.stepAfterWelcome(standaloneModeAvailable: FeatureFlags.standaloneModeAvailable)
        if next == .serverURL {
            // Mirror the side effect that `handleModeChoice(.server)` does so
            // the server branch is fully committed without the fork screen.
            chosenMode = .server
            authStore.markOnboardingMode(.server)
        }
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) { step = next }
    }

    // MARK: - Adressfrage vor Anmeldefrage (R1)

    /// Der tatsächlich gezeigte Schritt. Weicht von ``step`` nur in einem Fall
    /// ab: der Flow steht auf `.auth`, es ist aber keine Serveradresse
    /// hinterlegt. Dann ist die Adressfrage die einzige sinnvolle Fläche —
    /// jeder Anmeldeversuch würde vor dem ersten Byte an
    /// ``HLError/serverNotConfigured`` scheitern, und genau das hat den
    /// Betreiber ausgesperrt: ein vollständiges Anmeldeformular mit einer roten
    /// Zeile darunter, aus dem kein Knopf herausführte.
    private var resolvedStep: Step {
        Self.resolveStep(
            step,
            chosenMode: chosenMode,
            hasServerAddress: backend.hasServerAddress,
            // D-24-01-A — and the session question, which outranks both. See
            // ``OnboardingFlow/resolveStep(_:chosenMode:hasServerAddress:phase:)``.
            phase: authStore.phase
        )
    }

    /// Der Ausgang von der Anmeldefläche zurück zur Adressfrage (R1). Eigener
    /// Weg statt `goBack()`, weil er auch dann führen muss, wenn `previousStep`
    /// den Schritt gar nicht als Vorgänger kennt (zum Beispiel Einladungslink).
    private func goToServerURL() {
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) {
            step = .serverURL
        }
    }

    private var canGoBack: Bool {
        Self.previousStep(
            from: resolvedStep,
            chosenMode: chosenMode,
            standaloneModeAvailable: FeatureFlags.standaloneModeAvailable,
            setupScope: setupScope
        ) != nil
    }

    private func goBack() {
        guard let prev = Self.previousStep(
            from: resolvedStep,
            chosenMode: chosenMode,
            standaloneModeAvailable: FeatureFlags.standaloneModeAvailable,
            setupScope: setupScope
        ) else { return }
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) {
            step = prev
        }
    }

    private func handleModeChoice(_ choice: ModeSelectionStep.Choice) {
        switch choice {
        case .server:
            chosenMode = .server
            authStore.markOnboardingMode(.server)
            withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) { step = .serverURL }
        case .standalone:
            chosenMode = .standalone
            // Standalone path: skip ServerURL + Auth, go straight to HK.
            // `enterStandaloneMode` flips both SyncMode + AuthStore.phase
            // AFTER the local steps complete — see `advanceFromNotifications`.
            withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) { step = .healthKit }
        }
    }

    private func handleServerURLContinue() {
        // Probe registration-status against the now-active baseURL so the
        // auth step can hide / show the "Neues Konto" CTA. Fire-and-forget
        // — failures default to `true` (assume enabled).
        Task {
            registrationEnabled = await authStore.isRegistrationEnabled()
        }
        // parity 2.9 — probe the freshly-configured server's OIDC status on the
        // same beat, so the auth step shows only the doors it actually opens.
        Task {
            oidcStatus = await authStore.fetchOidcStatus()
        }
        // #65 — probe web-handoff availability against the now-active base URL,
        // so a self-hosted instance on the frozen contract gets the web-login
        // CTA and a pre-contract / offline server keeps the native form.
        Task {
            webLoginAvailability = await authStore.webLoginAvailability()
        }
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) { step = .auth }
    }

    /// Server branch: when login succeeds, the `AuthStore` lands on
    /// `.authenticating(user)` (v0.6.0.9 — was `.authenticated(user)`), and
    /// every sign-in door — password, passkey, OIDC, web handoff, both MFA legs
    /// — arrives here through that one assignment.
    ///
    /// **D-24-01-A (24-02) — an assignment, not a transition.** This was
    /// `handlePhaseChange` and it ran only from `.onChange(of: authStore.phase)`.
    /// Two things followed from that, and together they locked the operator out
    /// of his own account: a flow unmounted by the privacy shield across the
    /// moment the session was accepted never heard the notification at all, and
    /// a second sign-in with the same account assigns an **equal** `Phase`,
    /// which publishes no change and so cannot substitute for it. It is now
    /// asked with whatever phase is current — from the change, and from every
    /// appearance (``resumePostAuthenticationRouteIfNeeded()``).
    ///
    /// **Phase 08 Wave 1.** It used to bounce straight to `.healthKit`, which
    /// meant the server-owned completion flag this app already fetched was read
    /// by nobody: a user who finished setup on another device, or on this device
    /// before a reinstall, walked the optional permission / AI / anamnesis /
    /// baseline steps again, every single time. The jump is now a lookup and a
    /// decision — see ``resolvePostAuthenticationRoute()``.
    private func handlePhase(_ newPhase: AuthStore.Phase) {
        guard case .authenticating = newPhase else {
            // The owner went away or the session was promoted past this flow.
            // Either way a decision in flight belongs to a world that no longer
            // exists, and it must not be allowed to land.
            routeResolution?.cancel()
            routeResolution = nil
            return
        }
        // D-24-01-A — the admissible steps moved into a pure decision, and grew
        // by the ones a REMOUNTED flow is re-created on. The guarantee the old
        // `step == .auth || .completionUnavailable` inline guard carried is
        // unchanged and is now stated where it can be tested: a lookup already
        // in flight (`.checkingCompletion`) is never restarted.
        guard Self.shouldResolvePostAuthenticationRoute(step: step, phase: newPhase) else { return }
        resolvePostAuthenticationRoute()
    }

    /// **D-24-01-A (24-02) — the level trigger, and the whole of the fix's
    /// effect half.**
    ///
    /// Asked on every appearance, so a flow that was unmounted across the moment
    /// its session was accepted — a passkey sheet, an SSO or web-handoff browser,
    /// iOS's own password prompt, or anything else that resigns the scene and
    /// makes ``RootPrivacyShieldPolicy`` replace the subtree — asks the phase
    /// itself instead of waiting for a notification that has already been
    /// delivered. A repeat sign-in cannot substitute for that notification: the
    /// same account assigns an **equal** `Phase`, and an equal assignment
    /// publishes no change.
    private func resumePostAuthenticationRouteIfNeeded() {
        handlePhase(authStore.phase)
    }

    /// Ask whether this account has already finished setup, then route on the
    /// answer. Also the retry action on ``Step/completionUnavailable``.
    ///
    /// The owner is captured **before** the lookup and re-checked after it: a
    /// completion answered for the account that just signed out may not decide
    /// where the account that just signed in is sent.
    private func resolvePostAuthenticationRoute() {
        guard let owner = authStore.authenticatedRouteOwner,
              let store = container?.onboardingTourStore else
        {
            // No admitted owner, or no composed container: there is nothing to
            // ask and nothing that could answer. This is a composition failure
            // rather than an ambiguous answer, so the pre-Wave-1 behaviour —
            // walk the setup tail — stays as the floor. It never opens a shell.
            enter(.full)
            return
        }
        routeResolution?.cancel()
        advance(to: .checkingCompletion)
        routeResolution = Task {
            await store.refresh(owner: owner)
            guard !Task.isCancelled, authStore.authenticatedRouteOwner == owner else { return }
            // `hasLoaded` is not decoration here: `refresh` deliberately settles
            // nothing when the owner changed underneath it, so an unsettled
            // store at this point means the answer was discarded, not that it
            // said "incomplete".
            guard store.hasLoaded else { return }
            apply(PostAuthenticationRouteResolver.resolve(
                server: store.resolution ?? .unavailable,
                cache: store.evidence
            ))
        }
    }

    /// The three routes, and nothing else. `setup` is the only one that shows
    /// the optional tail, and ambiguity gets its own surface rather than being
    /// rounded to whichever neighbour is cheaper to render.
    ///
    /// **16-01 (K10)** — `authenticatedShell` is no longer the same thing as
    /// "nothing left to do". It is the answer to an ACCOUNT question, and the
    /// device still gets asked its own: a handset that has never shown the
    /// HealthKit sheet walks the device-local head before the shell, and only
    /// that. The account-level tail stays skipped for exactly the users 08-08
    /// skipped it for.
    private func apply(_ route: PostAuthenticationRoute) {
        switch route {
        case .authenticatedShell:
            enter(PostAuthenticationRouteResolver.setupScope(
                accountSetupComplete: true,
                deviceLocalSetup: deviceLocalSetupState()
            ))
        case .setup:
            enter(.full)
        case .retryCompletionLookup:
            advance(to: .completionUnavailable)
        }
    }

    /// Commit to a scope and open the surface it starts on. Kept as one place
    /// so the scope the route bar measures and the step the user sees can never
    /// come from two different decisions.
    private func enter(_ scope: PostAuthenticationSetupScope) {
        setupScope = scope
        switch scope {
        case .none:
            advance(to: .done)
            authStore.completeOnboarding()
        case .deviceLocalOnly, .full:
            advance(to: .healthKit)
        }
    }

    /// What this handset can say about its own setup.
    ///
    /// Derived from the device's actual state rather than from a flag this plan
    /// would otherwise have had to invent: `HKReadinessStore` already persists
    /// a per-user `requestedAt` in `UserDefaults`, set the first time the system
    /// sheet is shown, and 13-01's fresh-install sentinel already wipes that
    /// domain on a reinstall. A second flag would have been a second thing to
    /// keep in step with those two, and the first time it drifted it would have
    /// drifted into exactly K10 again.
    ///
    /// No composed container is `unknown`, never `outstanding`: a run that
    /// cannot ask must not invent setup work for a returning user.
    private func deviceLocalSetupState() -> DeviceLocalSetupState {
        guard let readiness = container?.hkReadinessStore else { return .unknown }
        return readiness.hasEverRequestedAuthorization ? .complete : .outstanding
    }

    private func advance(to next: Step) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) { step = next }
    }

    private func advanceFromHealthKit() {
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) { step = .notifications }
    }

    private func advanceFromNotifications() {
        // 16-01 (K10) — the end of a device-local-only run. The account-level
        // tail was answered on whatever device (or web session) finished it,
        // and replaying it here is precisely what 08-08 stopped doing. The
        // handoff mirrors the `.authenticatedShell` arm exactly: no stamp, the
        // account is already complete server-side.
        if setupScope == .deviceLocalOnly {
            advance(to: .done)
            authStore.completeOnboarding()
            return
        }
        // Task #53 — the AI-source choice is now the final onboarding step for
        // every branch. The terminal phase-flip moved to `advanceFromAISource`.
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) { step = .aiSource }
    }

    private func advanceFromAISource() {
        if Self.stepAfterAISource(isStandalone: chosenMode == .standalone) == .done {
            // Standalone has no server, so the about-me anamnesis step is not
            // reachable — finish immediately. This is the moment we flip
            // AuthStore.phase → `.standalone`, which makes `RootView` swap to
            // AuthenticatedShell. Doing it AFTER HK + Notif keeps the
            // onboarding bar visible through the local-permission prompts.
            withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) { step = .done }
            authStore.enterStandaloneMode()
            stampOnboardingComplete()
            return
        }
        // G2/G3 — the server branch now routes into the optional anamnesis
        // step before the terminal handoff. The phase-flip moved to
        // `finishOnboarding`.
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) { step = .anamnesis }
    }

    /// Routes from the optional anamnesis step into the optional baseline-profile
    /// step (G4). Both are server-only and skippable; the phase-flip stays at
    /// `finishOnboarding`, reached from the baseline-profile step's Continue/Later.
    private func advanceFromAnamnesis() {
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) { step = .baselineProfile }
    }

    /// Terminal step for the server branch. Promotes
    /// `AuthStore.phase` from `.authenticating(user)` (where it has sat since
    /// server-login succeeded) to `.authenticated(user)` — the single trigger
    /// for `RootView` to swap `OnboardingFlow` for `AuthenticatedShell`.
    /// Reached from the anamnesis step (Continue or Later).
    private func finishOnboarding() {
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) { step = .done }
        authStore.completeOnboarding()
        stampOnboardingComplete()
    }

    /// #32 — record the onboarding setup wizard as finished server-side so the
    /// completion state survives reinstall, syncs across devices, and is shared
    /// with the web onboarding tour. Optimistic + fire-and-forget: the store
    /// flips its local cache immediately (so routing is correct offline) and
    /// best-effort posts `completed:true` to `POST /api/onboarding/tour`. A
    /// failed/absent endpoint leaves the local cache set; a later `refresh()`
    /// reconciles. No-op when already completed (re-mount-safe). Standalone has
    /// no server, so the POST simply no-ops there — the local cache still routes.
    private func stampOnboardingComplete() {
        guard let store = container?.onboardingTourStore else { return }
        // 08-08 — nothing to stamp for a user the server already calls complete.
        // `markCompleted` is a no-op in that case anyway; saying so here is what
        // keeps the write bound to the event that justifies it (this user walked
        // this wizard) rather than to arriving at the end of the flow.
        guard !store.isCompleted else { return }
        Task { await store.markCompleted(owner: authStore.authenticatedRouteOwner) }
    }

    private var routeProgress: RouteProgress {
        Self.progress(
            for: resolvedStep,
            chosenMode: chosenMode,
            standaloneModeAvailable: FeatureFlags.standaloneModeAvailable,
            setupScope: setupScope
        )
    }
}

/// Continuous progress bar replacing the v0.4.0 `ProgressDots`. Discrete
/// dots no longer fit because the branched flow has variable lengths
/// (6 / 5 / 5 steps depending on mode); a continuous indicator avoids
/// jumpy redraws when the user changes mode.
/// 08-10 — every one of the three values is now supplied by
/// ``OnboardingFlow/RouteProgress``, and none is composed here. The spoken value
/// used to be `"\(Int(progress * 100)) percent"`: an English literal that no
/// catalogue entry covered, built from a fraction nobody could name, telling a
/// user who cannot see the bar a number instead of a position.
private struct ProgressIndicator: View {
    let fraction: Double
    let accessibilityLabel: String
    let accessibilityValue: String

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(HLColor.surface)
                Capsule()
                    .fill(HLText.primary)
                    .frame(width: max(0, geo.size.width * fraction))
                    // v0.5.5.1 perceptual budget: 0.4 → 0.3.
                    .hlAnimation(.spring(response: 0.3, dampingFraction: 0.85), value: fraction)
            }
        }
        .frame(height: 4)
        .padding(.horizontal, HLSpace.xl)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("onboarding.progress")
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityValue(Text(accessibilityValue))
    }
}

/// v0.11 W5 — calm inline "moving your data over…" banner for the
/// standalone→paired adopt-on-pair upload. Reads `AuthStore.adoptUploadState`;
/// renders nothing for `.idle` (every paired-from-start login). Monochrome,
/// glass-free, pinned above the bottom safe area. Reduce-motion-gated entrance.
///
/// v0.14.8 W2-SYNCUX — the banner chrome itself was extracted into the shared
/// `HLSyncBanner` (DesignSystem) so the first-login sync indicator in
/// `AuthenticatedShell` speaks the identical visual language. This view keeps
/// only the adopt-state → banner-content mapping.
private struct AdoptUploadIndicator: View {
    let state: AuthStore.AdoptUploadState
    /// v0.13 WR — invoked when the user taps the retry affordance on the
    /// `.failed` banner. Re-runs the (idempotent) adopt-on-pair upload.
    var onRetry: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch state {
            case .idle:
                EmptyView()
            case let .uploading(progress):
                HLSyncBanner(
                    text: progress.total > 0
                        ? String(
                            format: String(localized: "onboarding.adopt.uploading.progress"),
                            progress.completed, progress.total
                        )
                        : String(localized: "onboarding.adopt.uploading"),
                    showsSpinner: true
                )
            case .done:
                HLSyncBanner(
                    text: String(localized: "onboarding.adopt.done"),
                    symbol: "checkmark.circle.fill"
                )
            case .failed:
                // v0.13 WR — the glyph is now a real retry action, not a passive
                // label. The upload is idempotent, so re-running is safe.
                HLSyncBanner(
                    text: String(localized: "onboarding.adopt.failed"),
                    symbol: "arrow.clockwise",
                    actionLabel: String(localized: "onboarding.adopt.retry"),
                    action: onRetry,
                    actionAccessibilityIdentifier: "onboarding.adopt.retry"
                )
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.9), value: state)
    }
}

/// Shown while the onboarding flow is being dismounted in favour of
/// `AuthenticatedShell`. Visible for a single SwiftUI run-loop tick in
/// the common case.
private struct LoadingHandoffView: View {
    var body: some View {
        VStack(spacing: HLSpace.md) {
            ProgressView()
                .controlSize(.large)
            Text("Preparing HealthLog…")
                .font(.hlSubhead)
                .foregroundStyle(HLText.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
