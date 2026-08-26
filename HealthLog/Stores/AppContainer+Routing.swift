import Foundation

// MARK: - v0.7.3 routing bundle (cluster C10)

extension AppContainer {
    /// Constructs the routing pair — `AppRouter` (tab + per-tab
    /// `NavigationPath` state) plus the `DeepLinkRouter` that drives it from
    /// `.onOpenURL`, notification taps, and future universal links.
    ///
    /// The `isAuthenticated` gate reads `authStore.phase` at call time (not at
    /// construction) so a cold-start-from-tap parks the route in
    /// `AppRouter.pendingRoute` until the auth bootstrap promotes the phase to
    /// `.authenticated`. The store is captured weakly — a torn-down container
    /// reports "not authenticated" and the deep link is dropped/parked rather
    /// than crashing.
    ///
    /// Factored out of `AppContainer.init` (v0.7.3) to keep the init body
    /// inside its lint budget. The `appRouter` / `deepLinks` handles stay on
    /// `AppContainer` so the env-injection + external call-sites are unchanged.
    /// Construction is VERBATIM from the prior inline block — same router
    /// instance is handed to the `DeepLinkRouter`, same gate semantics.
    static func makeRouting(authStore: AuthStore) -> (router: AppRouter, deepLinks: DeepLinkRouter) {
        let router = AppRouter()
        let deepLinkRouter = DeepLinkRouter(
            router: router,
            isAuthenticated: { [weak authStore] in
                guard case .authenticated = authStore?.phase else { return false }
                return true
            }
        )
        return (router, deepLinkRouter)
    }
}
