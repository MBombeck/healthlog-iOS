import Foundation

public extension AppContainer {
    /// Cold-launch pre-warm of the
    /// `AvatarCache` so the Dashboard's inline header + Profile-screen
    /// hero can paint the operator's Gravatar on the very first body pass
    /// — without waiting for a per-view `.task(id:)` refresh to complete.
    ///
    /// ## Trigger ordering
    ///
    /// Called from `HealthLogApp.body.task` immediately after
    /// `authStore.bootstrap()` resolves and the phase is `.authenticated`.
    /// Fires `Task.detached(priority: .utility)` so the launch tick is
    /// never blocked on the network round-trip.
    ///
    /// ## No profile load (D5 #2)
    ///
    /// This used to call `settingsStore.load()` to resolve an email the
    /// pre-warm no longer reads: post-W-SEC-A it issues no network request and
    /// only sweeps legacy on-disk PNG bytes from a pre-v0.6.2 install. With two
    /// callers per launch (the app's `.task` and `RootView`) that was two extra
    /// profile loads, each with two `/api/auth/me` hydrations. The profile is
    /// loaded once, by `RootView.loadProfileOnAuthenticationIfNeeded()`.
    ///
    /// Returns immediately outside `.authenticated`: `.unauthenticated` means
    /// the user is still in onboarding (the avatar surfaces aren't reachable).
    func preWarmAvatarOnLaunch() {
        guard case .authenticated = authStore.phase else { return }
        Task.detached(priority: .utility) {
            await AvatarCache.shared.preWarm()
        }
    }
}
