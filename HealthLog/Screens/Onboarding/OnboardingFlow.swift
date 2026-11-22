import SwiftUI

/// Onboarding driver: Welcome, ServerURL, Auth, HealthKit, Notifications,
/// AI source, Anamnesis, Baseline profile, Done. There is no separate
/// `.backfill` step; the HealthKit backfill window is chosen inline on the
/// HealthKit step.
///
/// Auth happens BEFORE HealthKit so the Bearer token is in Keychain when
/// `HealthKitService.activateBackground` schedules the first upload-on-wakeup.
struct OnboardingFlow: View {
    @Environment(AuthStore.self) private var authStore
    /// Beantwortet die Frage vor allen anderen: kennt diese Installation
    /// überhaupt eine Serveradresse? Ohne sie darf kein Anmeldeschritt kommen.
    @Environment(BackendAvailability.self) private var backend
    @Environment(AppRouter.self) private var router
    @Environment(\.appContainer) private var container
    /// Device logic only: the iPad walks no HealthKit step.
    @Environment(\.deviceProfile) private var deviceProfile
    /// A11Y — gates the imperative step-transition animations
    /// below so they cross-dissolve instead of sliding when Reduce Motion is on.
    /// The container `.hlAnimation(value: step)` already honours it; the explicit
    /// `withAnimation(...) { step = … }` callsites did not until now.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The flow's state (step, scope, probe answers,
    /// invite token, completion lookup) lives in the container's in-memory
    /// `OnboardingDraftStore`, not in `@State`: the privacy shield rebuilds the
    /// window whenever the scene goes inactive, and the user must come back to
    /// the step and the answers they left. Accessors: `OnboardingFlow+Draft`.
    @State private var fallbackDraft = OnboardingDraftStore() // only without a container
    var draft: OnboardingDraftStore {
        container?.onboardingDraft ?? fallbackDraft
    }

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
                    // The steps are one view, not a navigation stack, so there
                    // is no system back to lean on; this is its stand-in.
                    HLIconButton(systemImage: "chevron.left", label: "onboarding.back") { goBack() }
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
                case .serverURL:
                    ServerURLStep(onContinue: handleServerURLContinue)
                case .auth:
                    ServerAuthStep(
                        registrationEnabled: registrationEnabled,
                        oidcStatus: oidcStatus,
                        webLoginAvailability: webLoginAvailability,
                        prefilledInviteToken: inviteToken,
                        // Der immer verfügbare Ausgang zur Adressfrage.
                        onChangeServer: { goToServerURL() }
                    )
                    // The auth step asks for the answer it needs
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
                    // The app cannot tell whether setup is finished, so it
                    // says that and offers the one honest action.
                    HLEmptyState(
                        icon: "arrow.clockwise.circle",
                        title: "onboarding.route.unavailable.title",
                        message: "onboarding.route.unavailable.body"
                    ) {
                        HLButton(HLControlWord.retry.key, variant: .secondary) {
                            resolvePostAuthenticationRoute()
                        }
                        .accessibilityIdentifier("onboarding.route.retry")
                    }
                    .padding(.horizontal, HLSpace.xl)
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
        // Once, a deletion receipt.
        .safeAreaInset(edge: .bottom) {
            AccountDeletionReceiptNote()
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
        // Pick up an invite token that was parked
        // before the flow appeared (cold launch via the web invite link). Runs
        // once on appear AND when the parked token changes (warm launch / link
        // tapped while the welcome step is on screen).
        //
        // And, before that, the session question. An invite is an
        // offer to sign in; a session that has already been accepted has moved
        // past it, so the resume is asked first.
        .onAppear {
            draft.prepareForAppearance(phase: authStore.phase)
            resumePostAuthenticationRouteIfNeeded()
            consumeInviteTokenIfPresent()
        }
        .onChange(of: router.pendingInviteToken) { _, _ in
            consumeInviteTokenIfPresent()
        }
    }

    // MARK: - Invite deep link

    /// One-shot consume of `AppRouter.pendingInviteToken` → drive the flow into
    /// the server-branch auth step with the token prefilled. An invite always
    /// implies server mode against the managed host (the bundled default base
    /// URL already resolves there, so no URL override is needed). Only fires
    /// while the user has not started the server setup themselves.
    private func consumeInviteTokenIfPresent() {
        guard inviteToken == nil, !hasStartedServerSetup,
              let token = router.consumePendingInviteToken() else { return }
        inviteToken = token
        hasStartedServerSetup = true
        // Probe registration-status so the auth step renders correctly; the
        // invite still works on a closed instance (the token is the door key).
        Task { registrationEnabled = await authStore.isRegistrationEnabled() }
        // And the OIDC status, so an `OIDC_ONLY` instance does not
        // offer the invited user a password form the server will refuse.
        Task { oidcStatus = await authStore.fetchOidcStatus() }
        // And the web-handoff availability, so a self-hosted instance on
        // the frozen contract offers the web-login CTA (fail-closed otherwise).
        Task { webLoginAvailability = await authStore.webLoginAvailability() }
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) { step = .auth }
    }

    // MARK: - Branching

    private func advanceFromWelcome() {
        hasStartedServerSetup = true
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) { step = .serverURL }
    }

    // MARK: - Adressfrage vor Anmeldefrage

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
            hasServerAddress: backend.hasServerAddress,
            // And the session question, which outranks both. See
            // ``OnboardingFlow/resolveStep(_:hasServerAddress:phase:)``.
            phase: authStore.phase
        )
    }

    /// Der Ausgang von der Anmeldefläche zurück zur Adressfrage. Eigener
    /// Weg statt `goBack()`, weil er auch dann führen muss, wenn `previousStep`
    /// den Schritt gar nicht als Vorgänger kennt (zum Beispiel Einladungslink).
    private func goToServerURL() {
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) {
            step = .serverURL
        }
    }

    private var canGoBack: Bool {
        Self.previousStep(from: resolvedStep, setupScope: setupScope, includesHealthKit: includesHealthKit) != nil
    }

    /// Whether this device walks the HealthKit step at all.
    private var includesHealthKit: Bool {
        HealthKitAvailabilityPolicy(idiom: deviceProfile.idiom).onboardingIncludesHealthKitStep
    }

    private func goBack() {
        guard let prev = Self.previousStep(
            from: resolvedStep, setupScope: setupScope, includesHealthKit: includesHealthKit
        ) else { return }
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) {
            step = prev
        }
    }

    private func handleServerURLContinue() {
        // Probe registration-status against the now-active baseURL so the
        // auth step can hide / show the "Neues Konto" CTA. Fire-and-forget
        // — failures default to `true` (assume enabled).
        Task {
            registrationEnabled = await authStore.isRegistrationEnabled()
        }
        // Probe the freshly-configured server's OIDC status on the
        // same beat, so the auth step shows only the doors it actually opens.
        Task {
            oidcStatus = await authStore.fetchOidcStatus()
        }
        // Probe web-handoff availability against the now-active base URL,
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
    /// **An assignment, not a transition.** This was
    /// `handlePhaseChange` and it ran only from `.onChange(of: authStore.phase)`.
    /// Two things followed from that, and together they locked the operator out
    /// of his own account: a flow unmounted by the privacy shield across the
    /// moment the session was accepted never heard the notification at all, and
    /// a second sign-in with the same account assigns an **equal** `Phase`,
    /// which publishes no change and so cannot substitute for it. It is now
    /// asked with whatever phase is current — from the change, and from every
    /// appearance (``resumePostAuthenticationRouteIfNeeded()``).
    ///
    /// It used to bounce straight to `.healthKit`, which
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
        // The admissible steps moved into a pure decision, and grew
        // by the ones a REMOUNTED flow is re-created on. The guarantee the old
        // `step == .auth || .completionUnavailable` inline guard carried is
        // unchanged and is now stated where it can be tested: a lookup already
        // in flight (`.checkingCompletion`) is never restarted.
        guard Self.shouldResolvePostAuthenticationRoute(step: step, phase: newPhase) else { return }
        resolvePostAuthenticationRoute()
    }

    /// **The level trigger, and the whole of the fix's
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
            await apply(PostAuthenticationRouteResolver.resolve(
                server: store.resolution ?? .unavailable,
                cache: store.evidence
            ))
        }
    }

    /// The three routes, and nothing else. `setup` is the only one that shows
    /// the optional tail, and ambiguity gets its own surface rather than being
    /// rounded to whichever neighbour is cheaper to render.
    ///
    /// `authenticatedShell` is no longer the same thing as
    /// "nothing left to do". It is the answer to an ACCOUNT question, and the
    /// device still gets asked its own: a handset that has never shown the
    /// HealthKit sheet walks the device-local head before the shell, and only
    /// that. The account-level tail stays skipped for exactly the users 08-08
    /// skipped it for.
    private func apply(_ route: PostAuthenticationRoute) async {
        switch route {
        case .authenticatedShell:
            await enter(PostAuthenticationRouteResolver.setupScope(
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
            advance(to: Self.firstPostAuthenticationStep(includesHealthKit: includesHealthKit))
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
    private func deviceLocalSetupState() async -> DeviceLocalSetupState {
        // A device without HealthKit (the iPad) owes only the notification
        // ask, and the system knows whether it was answered.
        let notificationsOpen = includesHealthKit ? nil : await Self.notificationPermissionIsOpen()
        return Self.deviceLocalSetupState(
            includesHealthKit: includesHealthKit,
            healthKitRequested: container?.hkReadinessStore.hasEverRequestedAuthorization,
            notificationPermissionOpen: notificationsOpen
        )
    }

    private func advance(to next: Step) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) { step = next }
    }

    private func advanceFromHealthKit() {
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) { step = .notifications }
    }

    private func advanceFromNotifications() {
        // The end of a device-local-only run. The account-level
        // tail was answered on whatever device (or web session) finished it,
        // and replaying it here is precisely what 08-08 stopped doing. The
        // handoff mirrors the `.authenticatedShell` arm exactly: no stamp, the
        // account is already complete server-side.
        if setupScope == .deviceLocalOnly {
            advance(to: .done)
            authStore.completeOnboarding()
            return
        }
        // The AI-source choice is now the final onboarding step for
        // every branch. The terminal phase-flip moved to `advanceFromAISource`.
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) { step = .aiSource }
    }

    private func advanceFromAISource() {
        // G2/G3 — the optional anamnesis step comes before the terminal
        // handoff. The phase-flip lives in `finishOnboarding`.
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) { step = .anamnesis }
    }

    /// Routes from the optional anamnesis step into the optional baseline-profile
    /// step. Both are server-only and skippable; the phase-flip stays at
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

    /// Record the onboarding setup wizard as finished server-side so the
    /// completion state survives reinstall, syncs across devices, and is shared
    /// with the web onboarding tour. Optimistic + fire-and-forget: the store
    /// flips its local cache immediately (so routing is correct offline) and
    /// best-effort posts `completed:true` to `POST /api/onboarding/tour`. A
    /// failed/absent endpoint leaves the local cache set; a later `refresh()`
    /// reconciles. No-op when already completed (re-mount-safe).
    private func stampOnboardingComplete() {
        guard let store = container?.onboardingTourStore else { return }
        // Nothing to stamp for a user the server already calls complete.
        // `markCompleted` is a no-op in that case anyway; saying so here is what
        // keeps the write bound to the event that justifies it (this user walked
        // this wizard) rather than to arriving at the end of the flow.
        guard !store.isCompleted else { return }
        Task { await store.markCompleted(owner: authStore.authenticatedRouteOwner) }
    }

    private var routeProgress: RouteProgress {
        Self.progress(for: resolvedStep, setupScope: setupScope, includesHealthKit: includesHealthKit)
    }
}

/// Continuous progress bar replacing the v0.4.0 `ProgressDots`. Discrete
/// dots no longer fit because the route length depends on the setup scope;
/// a continuous indicator avoids jumpy redraws.
/// Every one of the three values is now supplied by
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
