import Foundation

// **Phase 16 Plan 01 — the onboarding route as a value, out of the view that
// walks it.**
//
// Everything here is `nonisolated static` and pure: the step vocabulary, which
// resource each step configures, the ordered route a branch actually walks, the
// back destination and the progress derived from it. None of it reads `@State`,
// none of it touches a store, and none of it needs a view host to be exercised.
//
// It lives beside `OnboardingFlow` for the reason `OnboardingRouteProgress.swift`
// and `PostAuthenticationRouteSteps.swift` already do: that file carries the
// flow's own state and effects and was over the 600-line budget before this
// plan added a scope to it. 16-01 moved VALUES rather than views — the three
// private chrome views stay where they are on purpose, because
// `AdoptUploadIndicator` is a counted member of the frozen Phase-06
// presentation inventory and walking it into another file would move a census
// row without changing a single behaviour.

extension OnboardingFlow {
    enum Step: Equatable, Hashable {
        case welcome
        case mode
        case serverURL
        case auth
        /// Phase 08 Wave 1 — authentication succeeded and the app is asking the
        /// server whether this account already finished setup. A visible state
        /// rather than a hidden `await`: the alternative is a frozen auth form.
        case checkingCompletion
        /// The completion lookup did not resolve. Not an answer, so not a route:
        /// the user is asked again rather than being replayed through a wizard
        /// they may have finished months ago, or dropped into a shell that may
        /// not be theirs to see.
        case completionUnavailable
        case healthKit
        case notifications
        /// Task #53 — the AI-source choice step (None / On-device / External AI /
        /// Own key, mode- + capability-gated).
        /// Placed last before `done` so the user has seen the app's purpose
        /// (permissions) before deciding how the assistant should work. Skippable
        /// → privacy-first `.none` default.
        case aiSource
        /// G2/G3 (AUDIT-onboarding) — optional anamnesis (chronic conditions +
        /// allergies) + goals capture, mirroring web onboarding step 3. Server-
        /// only (writes through `CoachAboutMeStore` → `PUT /api/coach/about-me`),
        /// so it's reached on the server branch only and is fully
        /// skippable.
        case anamnesis
        // G4 (AUDIT-onboarding) — optional baseline profile (name / height /
        // DOB / gender), mirroring web onboarding step 3. Writes through the
        // EXISTING `SettingsStore.updateProfile` → `PATCH /api/user/profile`
        // (no parallel write path). Server-only, fully skippable, placed after
        // anamnesis and before the terminal handoff.
        case baselineProfile
        case done

        /// **Phase 16 Plan 01 (K10) — which resource a step configures.**
        ///
        /// Written down once, as a property of the step, because the alternative
        /// is the thing that produced K10: the distinction existed only in
        /// people's heads while the code carried a single account-wide flag over
        /// both kinds. A reader who adds a step now has to answer the question
        /// the compiler asks, rather than inherit whichever behaviour the
        /// neighbouring `case` happened to have.
        enum Scope: String, Equatable, Hashable, CaseIterable {
            /// Configures THIS handset. Cannot be finished on another device and
            /// does not survive a reinstall: HealthKit authorization,
            /// notification permission.
            case deviceLocal
            /// Configures the account, wherever it is signed in — including the
            /// web onboarding. Correctly skipped for a completed account.
            case accountLevel
            /// Not a place in the route: the two post-authentication lookup
            /// surfaces and the terminal handoff.
            case transient
        }

        var scope: Scope {
            switch self {
            case .healthKit, .notifications:
                .deviceLocal
            case .welcome, .mode, .serverURL, .auth, .aiSource, .anamnesis, .baselineProfile:
                .accountLevel
            case .checkingCompletion, .completionUnavailable, .done:
                .transient
            }
        }

        /// **D-24-01-A (24-02) — which side of the login this step stands on.**
        ///
        /// These four are the steps a flow can be *re-created* on:
        /// ``OnboardingFlow/initialStep`` is one of them, and a remount after a
        /// scene deactivation lands there whatever the session says. Naming the
        /// set is what lets the routing ask "is this step in front of a login
        /// that has already happened?" — a question the flow could not ask while
        /// its only forward path was a notification.
        ///
        /// It is deliberately not derived from ``activeRoute(chosenMode:standaloneModeAvailable:setupScope:)``:
        /// the boundary is a fact about authentication, not a position in an
        /// array, exactly as ``previousStep(from:chosenMode:standaloneModeAvailable:setupScope:)``
        /// already argues for the one-way door it guards.
        var isPreAuthentication: Bool {
            switch self {
            case .welcome, .mode, .serverURL, .auth:
                true
            case .checkingCompletion, .completionUnavailable, .healthKit, .notifications,
                 .aiSource, .anamnesis, .baselineProfile, .done:
                false
            }
        }
    }

    // **H3 auth-journey (audit-v0162).** The step the flow opens on. In DEBUG,
    // the `-uitest-auth-journey` boot opens straight on `.auth` so a hermetic
    // UITest can drive the real login form + `MfaChallengeSheet` without first
    // walking Welcome → ServerURL (the ServerURL probe hits a live host that the
    // fixture protocol can't stub). Mirrors the existing `-uitest-hermetic`
    // seam; compiled out of Release, where it is always `.welcome`.
    #if DEBUG
        static var initialStep: Step {
            ProcessInfo.processInfo.arguments.contains("-uitest-auth-journey") ? .auth : .welcome
        }
    #else
        static var initialStep: Step {
            .welcome
        }
    #endif

    /// Pure routing decision for the step that follows Welcome — gated by the
    /// standalone availability flag. Server-mandatory builds bypass the
    /// `ModeSelectionStep` fork (no standalone option is ever offered);
    /// standalone-enabled builds show the fork.
    ///
    /// Extracted as a `static` pure function so the gate can be unit-tested
    /// without standing up the whole view tree.
    nonisolated static func stepAfterWelcome(standaloneModeAvailable: Bool) -> Step {
        standaloneModeAvailable ? .mode : .serverURL
    }

    /// Reine Form von ``resolvedStep`` — ohne View-Baum testbar.
    ///
    /// **D-24-01-A (24-02) — a second question of exactly the same kind.**
    ///
    /// R1 already established the shape: a step the flow *thinks* it is on can
    /// be wrong for the world it is in, and the resolved step is where that is
    /// corrected. R1's world-fact was "this install knows no server address".
    /// This plan's is "this session has already been accepted": a scene
    /// deactivation unmounts the flow, `@State step` is re-created at
    /// ``initialStep``, and the flow reopens a pre-authentication surface over a
    /// live session it can no longer be told about — the notification that would
    /// have moved it was delivered while it was unmounted, and a repeat login
    /// assigns an **equal** `Phase`, which publishes nothing.
    ///
    /// Answering from the phase rather than from a change in it is what makes
    /// the first render after a remount already correct, whatever the remount
    /// was caused by. The `phase` parameter is defaulted so every existing call
    /// site keeps its meaning: a caller that names no phase is asking the R1
    /// question and gets the R1 answer.
    nonisolated static func resolveStep(
        _ step: Step,
        chosenMode: OnboardingMode?,
        hasServerAddress: Bool,
        phase: AuthStore.Phase = .unknown
    ) -> Step {
        // An accepted session outranks the address question too: past the login
        // the address is settled by the session that used it.
        if case .authenticating = phase, step.isPreAuthentication { return .checkingCompletion }
        guard step == .auth, !hasServerAddress else { return step }
        return .serverURL
    }

    /// **D-24-01-A (24-02) — the forward route is a question about the phase the
    /// flow is looking at, never about a change in it.**
    ///
    /// `true` when this flow owes the post-authentication decision: the session
    /// has been accepted and the flow is standing either in front of the login
    /// boundary (including a step it was re-created on) or on the retry surface
    /// the lookup's own failure produces.
    ///
    /// `.checkingCompletion` is refused, which preserves the guarantee the
    /// `onChange` guard carried before this plan: a lookup already in flight is
    /// not restarted by a repeated notification. Everything past the boundary is
    /// refused because the decision has been made and acted on.
    nonisolated static func shouldResolvePostAuthenticationRoute(
        step: Step,
        phase: AuthStore.Phase
    ) -> Bool {
        guard case .authenticating = phase else { return false }
        return step.isPreAuthentication || step == .completionUnavailable
    }

    // MARK: - Back navigation (audit 02 · C-2)

    /// **The ordered steps this install will actually walk.**
    ///
    /// One array, and everything about position derives from it: the back
    /// destination, the progress numerator and the progress denominator. Before
    /// 08-10 those were three separate hand-maintained tables — a `switch` of
    /// predecessors, a `switch` of fractions and a `switch` of labels that named
    /// counts ("Schritt 4 von 6") no branch ever had — and they disagreed. A
    /// standalone user was charged for the server URL and login steps they never
    /// saw; a server user finished at 0.97 of a route with eight steps in it.
    ///
    /// A step a branch does not show is **absent**, not zero-weighted: that is
    /// what makes a skipped step uncounted rather than invisibly counted.
    ///
    /// The three transient states — the two post-authentication lookup surfaces
    /// and the terminal handoff — are deliberately not members. They are not
    /// places in the route; ``RouteProgress`` anchors them to the ones they
    /// stand on.
    /// 16-01 — `setupScope` narrows the same array rather than introducing a
    /// second one. A device-local-only run walks exactly the steps whose
    /// ``Step/scope`` says they configure this handset, so the back
    /// destination, the numerator and the denominator all follow it for free:
    /// a returning user on a new phone is told "Schritt 1 von 2", not
    /// "Schritt 5 von 7" of a route they are not walking.
    nonisolated static func activeRoute(
        chosenMode: OnboardingMode?,
        standaloneModeAvailable: Bool,
        setupScope: PostAuthenticationSetupScope = .full
    ) -> [Step] {
        var route: [Step] = [.welcome]
        if standaloneModeAvailable { route.append(.mode) }
        if chosenMode == .standalone {
            // No server: no address to give, no account to sign into, and the
            // two server-only intake steps are unreachable.
            route.append(contentsOf: [.healthKit, .notifications, .aiSource])
        } else {
            route.append(contentsOf: [
                .serverURL, .auth, .healthKit, .notifications, .aiSource, .anamnesis, .baselineProfile
            ])
        }
        guard setupScope == .deviceLocalOnly else { return route }
        return route.filter { $0.scope == .deviceLocal }
    }

    /// Pure predecessor decision for the back affordance. `nil` means "no back"
    /// — the first step of the active route, the terminal `done`, and crucially
    /// the **post-auth boundary** (`healthKit` on the server branch):
    /// once the user has authenticated we must NOT let a back tap walk them back
    /// across the login into the auth form. The pre-auth pair (`serverURL ↔
    /// auth`) — the trap the audit called out — is fully reversible.
    ///
    /// 08-10 — the predecessor is now read off ``activeRoute(chosenMode:standaloneModeAvailable:)``
    /// instead of being a second table that had to agree with it. The two
    /// answers that are *not* route positions stay explicit above the lookup,
    /// because a one-way door is not a position: the boundary is a rule about
    /// authentication, and expressing it as "the array has no earlier element"
    /// would make it an accident of ordering.
    nonisolated static func previousStep(
        from step: Step,
        chosenMode: OnboardingMode?,
        standaloneModeAvailable: Bool,
        setupScope: PostAuthenticationSetupScope = .full
    ) -> Step? {
        switch step {
        // `checkingCompletion` and `completionUnavailable` sit on the far side
        // of the login, so they share the post-auth boundary's answer: there is
        // no back across an authentication. `done` is terminal.
        case .done, .checkingCompletion, .completionUnavailable:
            return nil
        // Server (and the legacy `.demo` value): authenticated by the time
        // HealthKit shows. Standalone reached it straight from the fork and
        // keeps its ordinary predecessor.
        case .healthKit where chosenMode != .standalone:
            return nil
        default:
            break
        }
        let route = activeRoute(
            chosenMode: chosenMode,
            standaloneModeAvailable: standaloneModeAvailable,
            setupScope: setupScope
        )
        guard let index = route.firstIndex(of: step), index > 0 else { return nil }
        return route[index - 1]
    }

    /// Pure routing decision for the step after the AI-source choice — gated by
    /// whether this is a standalone install. Standalone has no server, so the
    /// server-only about-me anamnesis step (`PUT /api/coach/about-me`) is not
    /// reachable and the flow finishes directly; server mode routes into the
    /// optional anamnesis step. Extracted `static` so the gate is unit-testable
    /// without the view tree.
    nonisolated static func stepAfterAISource(isStandalone: Bool) -> Step {
        isStandalone ? .done : .anamnesis
    }

    // MARK: - Progress

    /// The one pure seam that maps a resolved route to its position, its
    /// fraction and the two strings assistive technology reads.
    ///
    /// Everything it returns is derived from
    /// ``activeRoute(chosenMode:standaloneModeAvailable:)``, so a branch that
    /// does not walk a step is never charged for it and a route that grows a
    /// step does not need a second table updated to match.
    nonisolated static func progress(
        for step: Step,
        chosenMode: OnboardingMode?,
        standaloneModeAvailable: Bool,
        setupScope: PostAuthenticationSetupScope = .full
    ) -> RouteProgress {
        RouteProgress(
            step: step,
            in: activeRoute(
                chosenMode: chosenMode,
                standaloneModeAvailable: standaloneModeAvailable,
                setupScope: setupScope
            )
        )
    }
}
