import Foundation
@testable import HealthLog
import SwiftUI
import Testing

/// SET-ROUTE (#153 follow-up) — the Settings pages are values on the More
/// stack now, held by the container's router so they survive the privacy
/// shield. A sign-out must not carry them into the next session.
@MainActor
@Suite("AppRouter sign-out reset (SET-ROUTE)")
struct AppRouterSignOutResetTests {
    @Test("Settings › Server › Access headers is a value path the router keeps")
    func settingsPagesAreValues() {
        let router = AppRouter()
        router.selectedTab = .more
        router.morePath.append(SettingsRoute.root)
        router.morePath.append(HubRow.serverSync)
        router.morePath.append(SettingsRoute.serverAccessHeaders)
        #expect(router.morePath.count == 3)
        #expect(router.selectedTab == .more)
    }

    @Test("Sign-out returns every stack to its root and the shell to Home")
    func signOutResetsStacks() {
        let router = AppRouter()
        router.selectedTab = .more
        router.morePath.append(SettingsRoute.root)
        router.morePath.append(HubRow.account)
        router.morePath.append(MoreRoute.labs)
        router.homePath.append(MoreRoute.workouts)
        router.medsPath.append(MoreRoute.documents)
        router.insightsPath.append(MoreRoute.environment)

        router.resetNavigationForSignOut()

        #expect(router.selectedTab == .home)
        #expect(router.morePath.isEmpty)
        #expect(router.homePath.isEmpty)
        #expect(router.medsPath.isEmpty)
        #expect(router.insightsPath.isEmpty)
    }

    @Test("The root resets the router when the session ends")
    func rootWiresTheReset() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("HealthLog/App/RootView.swift"), encoding: .utf8)
        #expect(source.contains("if case .unauthenticated = authStore.phase { router.resetNavigationForSignOut() }"))
    }
}
