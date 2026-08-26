import Foundation

public extension AppContainer {
    /// **v0.5.5.2 W-IMPL-GRAVATAR-V2.** Cold-launch pre-warm of the
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
    /// ## Email resolution
    ///
    /// Triggers `settingsStore.load()` (idempotent — SWR-cached after the
    /// first successful round-trip), then reads back `profile?.email` to
    /// hand to `AvatarCache.preWarm`. On second-and-later cold launches
    /// the SWR cache emits the profile synchronously; on a fresh install
    /// the load awaits the server fetch.
    ///
    /// The pre-warm itself issues no network request post-W-SEC-A — it
    /// only sweeps any legacy on-disk PNG bytes from a pre-v0.6.2 install.
    /// (The Gravatar fetch + freshness window this comment once described
    /// were removed; the `email` it resolves is no longer consulted —
    /// follow-up cleanup tracked under simplifier A2.)
    ///
    /// Returns immediately for `.unauthenticated` + `.standalone` phases:
    /// standalone has no email to hash, and `.unauthenticated` means the
    /// user is still in onboarding (the avatar surfaces aren't reachable).
    func preWarmAvatarOnLaunch() {
        guard case .authenticated = authStore.phase else { return }
        let settings = settingsStore
        Task.detached(priority: .utility) {
            // Surface the profile (SWR cache → server round-trip). `load()`
            // returns once both observe streams emit a terminal state, so
            // we know `profile` reflects the freshest value the server +
            // cache can produce on this launch.
            await settings.load()
            let email = await MainActor.run { settings.profile?.email }
            await AvatarCache.shared.preWarm(email: email)
        }
    }
}
