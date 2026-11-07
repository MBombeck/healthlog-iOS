// App-target symbols (`TodayHeroActionRoute`, `AppRouter`) are not in the
// SPM library; the SPM test build skips the file.
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    /// **1.5 VISIT** — the appointment push `/checkups?visit=<id>` and the
    /// hero's `visit.view` open Vorsorge with that visit under "Nächster
    /// Termin"; anything without a valid id opens Vorsorge as before.
    @MainActor
    @Suite("Next visit: push and hero routing (VISIT)")
    struct NextVisitRoutingTests {
        @Test("the push path names the visit; a tampered or missing id opens plain Vorsorge")
        func pushPath() {
            #expect(DeepLinkRoute.fromPushPath("/checkups?visit=enc_7f3a") == .checkupsVisit(id: "enc_7f3a"))
            #expect(DeepLinkRoute.fromPushPath("/checkups?visit=") == .checkups)
            #expect(DeepLinkRoute.fromPushPath("/checkups?visit=..%2Fx") == .checkups)
            #expect(DeepLinkRoute.fromPushPath("/checkups?visit=a%20b") == .checkups)
            #expect(DeepLinkRoute.fromPushPath("/checkups?view=visits") == .checkups)
            #expect(DeepLinkRoute.fromPushPath("/checkups/enc_7f3a") == .dashboard)
        }

        @Test("the push lands on Vorsorge in More with the visit focused; a plain push clears it")
        func routerFocus() {
            let router = AppRouter()
            router.apply(.checkupsVisit(id: "enc_7f3a"), isAuthenticated: true)
            #expect(router.selectedTab == .more)
            #expect(router.morePath.count == 1)
            #expect(router.focusedVisitId == "enc_7f3a")
            router.apply(.checkups, isAuthenticated: true)
            #expect(router.focusedVisitId == nil)
            #expect(router.morePath.count == 1)
        }

        @Test("a cold-start push waits for sign-in and keeps the visit")
        func coldStart() {
            let router = AppRouter()
            router.apply(.checkupsVisit(id: "enc_7f3a"), isAuthenticated: false)
            #expect(router.focusedVisitId == nil)
            router.consumePendingRoute()
            #expect(router.focusedVisitId == "enc_7f3a")
            #expect(router.selectedTab == .more)
        }

        @Test("sign-out forgets the visit")
        func signOut() {
            let router = AppRouter()
            router.focusVisit("enc_7f3a")
            router.resetNavigationForSignOut()
            #expect(router.focusedVisitId == nil)
        }

        @Test("visit.view: one visit by id, several or a bad id as the list")
        func heroRoute() {
            typealias Route = TodayHeroActionRoute
            #expect(Route.resolve(intent: "visit.view", href: "/checkups?visit=enc_7f3a") == .visit(id: "enc_7f3a"))
            #expect(Route.resolve(intent: "visit.view", href: "/checkups?view=visits") == .checkupsList)
            #expect(Route.resolve(intent: "visit.view", href: nil) == .checkupsList)
            #expect(Route.resolve(intent: "visit.view", href: "/checkups?visit=..%2F") == .checkupsList)
            // The 1.43.11 shape keeps its front door.
            #expect(Route.resolve(intent: "checkup.view", href: "/checkups?visit=enc_7f3a") == .checkupFrontDoor)
        }
    }

#endif
