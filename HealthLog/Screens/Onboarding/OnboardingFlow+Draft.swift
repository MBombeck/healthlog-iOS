import Foundation

/// #153 — the flow's state, read from and written to the container's
/// `OnboardingDraftStore`. The accessors keep every call site in
/// `OnboardingFlow` as it was when these were `@State`; the store documents what
/// each one holds and when a run starts over.
extension OnboardingFlow {
    var step: Step {
        get { draft.step }
        nonmutating set { draft.step = newValue }
    }

    /// Set when the user picks a mode in `ModeSelectionStep`. `nil` before
    /// the choice. Drives the rest of the flow.
    var chosenMode: OnboardingMode? {
        get { draft.chosenMode }
        nonmutating set { draft.chosenMode = newValue }
    }

    /// Cached value from the post-ServerURL probe — gates whether the
    /// auth step shows the "Neues Konto" CTA.
    var registrationEnabled: Bool {
        get { draft.registrationEnabled }
        nonmutating set { draft.registrationEnabled = newValue }
    }

    /// parity 2.9 — cached `GET /api/auth/oidc/status`, probed on the same
    /// beats as `registrationEnabled`. Gates the SSO button (no IdP → hide it)
    /// and, in `OIDC_ONLY` mode, the password / passkey / register CTAs the
    /// server would refuse. `.unknown` until probed → all doors visible.
    var oidcStatus: OidcStatus {
        get { draft.oidcStatus }
        nonmutating set { draft.oidcStatus = newValue }
    }

    /// #65 / 13-02 — cached web-handoff availability, probed on the same beats
    /// as `registrationEnabled` / `oidcStatus`. Fail-closed: anything but
    /// `.available` keeps the native form. `.probing` until the answer lands.
    var webLoginAvailability: WebLoginAvailability {
        get { draft.webLoginAvailability }
        nonmutating set { draft.webLoginAvailability = newValue }
    }

    /// b182 W-B182-INVITE (GH #16) — the server invite token consumed (one-shot)
    /// from `AppRouter.pendingInviteToken`. Sensitive secret — memory only,
    /// never logged.
    var inviteToken: String? {
        get { draft.inviteToken }
        nonmutating set { draft.inviteToken = newValue }
    }

    /// **Phase 08 Wave 1** — the in-flight post-authentication completion
    /// lookup. Held so a repeated `.authenticating` notification cannot start a
    /// second one, and so a sign-out or an account change can cancel the one
    /// that is running instead of letting its answer land on the next session.
    var routeResolution: Task<Void, Never>? {
        get { draft.routeResolution }
        nonmutating set { draft.routeResolution = newValue }
    }

    /// **Phase 16 Plan 01 (K10)** — how much of setup this run owes. `.full`
    /// until a post-authentication decision narrows it.
    var setupScope: PostAuthenticationSetupScope {
        get { draft.setupScope }
        nonmutating set { draft.setupScope = newValue }
    }
}
