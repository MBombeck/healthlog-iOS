import Foundation
import Testing
#if canImport(UserNotifications) && canImport(UIKit)
    @testable import HealthLog
    import UserNotifications

    // swiftlint:disable force_unwrapping

    /// The push `url` (server `tap-target.ts`, v1.43) opens
    /// the native screen; a path without one opens home.
    @Suite("Push url opens the native screen (#141)", .serialized, .mockURLSession)
    @MainActor
    struct PushURLRoutingTests {
        private static let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "1.3.0",
            buildNumber: "1"
        )

        private func makeService(appRouter: AppRouter, authenticated: Bool = true) -> NotificationService {
            NotificationService(
                api: APIClient(environment: Self.env, keychain: InMemoryKeychain(), sessionConfiguration: .mock()),
                environment: Self.env,
                keychain: InMemoryKeychain(),
                deepLinks: DeepLinkRouter(router: appRouter, isAuthenticated: { authenticated })
            )
        }

        private func payload(event: String, url: String?, deepLink: URL? = nil, medicationId: String? = nil) -> APNsPayload {
            APNsPayload(
                title: "t", body: "b", eventType: event, metricType: nil, deepLink: deepLink,
                medicationId: medicationId, url: url
            )
        }

        @Test("The top-level url key is read off the APNs userInfo, an empty one is absent")
        func parsesURL() throws {
            let parsed = try #require(APNsPayload.parse(userInfo: ["eventType": "SECURITY_ALERT", "url": "/settings/security"]))
            #expect(parsed.url == "/settings/security")
            let empty = try #require(APNsPayload.parse(userInfo: ["eventType": "SYSTEM_ALERT", "url": ""]))
            #expect(empty.url == nil)
            let none = try #require(APNsPayload.parse(userInfo: ["eventType": "MEDICATION_INTAKE_SYNC"]))
            #expect(none.url == nil)
        }

        @Test("Every path tap-target.ts emits maps to its screen, the rest opens home", arguments: [
            ("/", DeepLinkRoute.dashboard),
            ("/mood?add=1", .mood),
            ("/mood", .dashboard),
            ("/medications", .medications),
            ("/medications?highlight=med_1", .medicationDue(id: "med_1", slot: nil)),
            ("/medications?highlight=..%2Fx", .medications),
            ("/medications/med_1", .medication(id: "med_1")),
            ("/medications/med_1/stock", .medication(id: "med_1")),
            ("/medications/..%2Fx", .medications),
            ("/checkups", .checkups),
            ("/cycle", .cycle),
            ("/coach", .coach),
            ("/settings/security", .settingsSecurity),
            ("/settings/integrations", .settingsIntegrations),
            ("/settings/unknown", .dashboard),
            ("/achievements", .dashboard),
            ("/measurements", .dashboard),
            ("/insights", .insights(metric: nil)),
            // Server 1.49.0: `/insights/<slug>` opens that Insights page.
            ("/insights/medications", .insights(metric: "medications")),
            ("https://evil.example/settings/security", .dashboard),
            ("//evil.example/cycle", .dashboard),
            ("/cycle\\x", .dashboard),
            ("/cycle x", .dashboard)
        ])
        func mapsPath(path: String, expected: DeepLinkRoute) {
            #expect(DeepLinkRoute.fromPushPath(path) == expected)
        }

        @Test("A Guardian's push (no medication id, url /) opens home")
        func guardianOpensHome() async {
            let router = AppRouter()
            router.selectedTab = .more
            let svc = makeService(appRouter: router)
            await svc.dispatchAction(
                actionID: UNNotificationDefaultActionIdentifier,
                payload: payload(event: "MEDICATION_REMINDER", url: "/")
            )
            #expect(router.selectedTab == .home)
        }

        @Test("A security alert opens Settings, Security with the real back stack")
        func securityAlertOpensSecurity() async {
            let router = AppRouter()
            let svc = makeService(appRouter: router)
            await svc.dispatchAction(
                actionID: UNNotificationDefaultActionIdentifier,
                payload: payload(event: "SECURITY_ALERT", url: "/settings/security")
            )
            #expect(router.selectedTab == .more)
            #expect(router.morePath.count == 2)
        }

        @Test("Checkups and cycle land on the More stack, integrations behind Settings")
        func moreStackDestinations() {
            let router = AppRouter()
            router.apply(.checkups, isAuthenticated: true)
            #expect(router.selectedTab == .more)
            #expect(router.morePath.count == 1)
            router.apply(.cycle, isAuthenticated: true)
            #expect(router.morePath.count == 1)
            router.apply(.settingsIntegrations, isAuthenticated: true)
            #expect(router.morePath.count == 2)
            router.apply(.settingsNotifications, isAuthenticated: true)
            #expect(router.morePath.count == 2)
        }

        @Test("url wins over the older deepLink; deepLink stays the fallback")
        func urlWinsOverDeepLink() throws {
            let link = try #require(URL(string: "healthlog://dashboard"))
            let both = payload(event: "SYSTEM_ALERT", url: "/cycle", deepLink: link)
            #expect(NotificationService.bodyTapTarget(for: both) == .route(.cycle))
            let legacy = payload(event: "SYSTEM_ALERT", url: nil, deepLink: link)
            #expect(NotificationService.bodyTapTarget(for: legacy) == .link(link))
            #expect(NotificationService.bodyTapTarget(for: payload(event: "X", url: nil)) == nil)
        }

        @Test("A tap before sign-in parks the route and replays it after")
        func coldStartParksRoute() async {
            let router = AppRouter()
            let svc = makeService(appRouter: router, authenticated: false)
            await svc.dispatchAction(
                actionID: UNNotificationDefaultActionIdentifier,
                payload: payload(event: "SECURITY_ALERT", url: "/settings/security")
            )
            #expect(router.pendingRoute == .settingsSecurity)
            router.consumePendingRoute()
            #expect(router.selectedTab == .more)
            #expect(router.morePath.count == 2)
        }

        @Test("A medication reminder with its id lands on its due dose on the list (#186)")
        func medicationIdStillWins() async {
            let router = AppRouter()
            let svc = makeService(appRouter: router)
            await svc.dispatchAction(
                actionID: UNNotificationDefaultActionIdentifier,
                payload: payload(event: "MEDICATION_REMINDER", url: "/medications", medicationId: "med_9")
            )
            #expect(router.selectedTab == .meds)
            #expect(router.medsPath.isEmpty)
            #expect(router.pendingMedicationLanding?.medicationId == "med_9")
        }
    }
#endif
