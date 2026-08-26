import Foundation

extension AuthStore {
    convenience init(
        auth: AuthService,
        keychain: KeychainStoring,
        syncMode: SyncModeStore? = nil,
        defaults: UserDefaults = .standard,
        sessionRegistry: AuthenticatedSessionLeaseRegistry
    ) {
        self.init(auth: auth, keychain: keychain, syncMode: syncMode, defaults: defaults)
        authenticatedSessionRegistry = sessionRegistry
    }

    /// Admits `ownerID` to the shared authenticated-session registry.
    ///
    /// **Called from `AuthStore.phase`'s `didSet` since plan 07-09, and from
    /// nowhere else in production.** Phase 06 built one awaited teardown
    /// orchestrator for the four terminal paths — user logout, terminal 401,
    /// deletion, switch-server — and admission had no mirror image: this method
    /// and `AppContainer.authenticatedSessionBoundaryHooks.activate` were called
    /// only from tests. So `AuthenticatedSessionLeaseRegistry.capture` returned
    /// `nil` on every real device, `HealthSyncAuthenticatedLease.admit` threw
    /// `unavailableAuthentication`, and every Phase-07 admission-gated sweep —
    /// the app-owned sample collection, the daily statistics, the State-of-Mind
    /// import, the Apple-medication import, the cycle import, the heart-event
    /// import — refused, while every toggle still read "on".
    ///
    /// The epoch that `didSet` already maintained is exactly the fact the
    /// registry needs: an owner appeared, or an owner went away. Deriving
    /// admission from it rather than from a list of call sites means
    /// `bootstrap()`, every `login*`/`register`/MFA/SSO/web-login path,
    /// `completeOnboarding()` and a sharing-recovery actor change all admit
    /// through one statement, and no future login path can forget to.
    ///
    /// **The Phase-06 invariants are preserved rather than re-litigated.** Every
    /// admitting transition happens while its caller holds the account boundary
    /// (`beginAuthenticationTransition`), so no activation can precede a
    /// predecessor's teardown; every owner-losing transition invalidates,
    /// including `enterStandaloneMode()` and `beginServerPairing()`, which used
    /// to leave a live registry behind an unauthenticated shell. The four
    /// terminal paths still invalidate at their own commitment point *before*
    /// any wipe — what `didSet` adds afterwards is an idempotent re-assertion,
    /// never a replacement.
    @discardableResult
    func activateAuthenticatedSession(ownerID: String) -> AuthenticatedSessionLease? {
        authenticatedSessionRegistry.activate(ownerID: ownerID)
    }

    func captureAuthenticatedSession(ownerID: String) -> AuthenticatedSessionLease? {
        authenticatedSessionRegistry.capture(ownerID: ownerID)
    }

    func invalidateAuthenticatedSession() {
        authenticatedSessionRegistry.invalidate()
    }

    /// No authenticated task producers are owned by this plan yet. The awaited
    /// seam exists now so Plan 06-05 can drain the producers introduced by the
    /// downstream store plans without changing the terminal hook contract.
    func awaitAuthenticatedSessionQuiescence() async {}
}
