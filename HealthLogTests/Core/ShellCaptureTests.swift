@testable import HealthLog
import SwiftUI
import Testing

/// Log in a regular window is the "+" of the tab roots, not a tab: the
/// router opens the picker through a counter there, and the popover hangs on
/// the "+" of the selected root while it is on screen. Compact keeps the Log
/// tab and its snap-back.
@MainActor
@Suite("Shell capture entry")
struct ShellCaptureTests {
    private static let allOpen = Set(SidebarDestination.allCases)

    @Test("Log is a tab when compact and before a size class is known, not when regular")
    func logIsATabOnlyWhenNotRegular() {
        #expect(AppRouter.capturesThroughTab(sizeClass: .compact))
        #expect(AppRouter.capturesThroughTab(sizeClass: nil))
        #expect(!AppRouter.capturesThroughTab(sizeClass: .regular))
    }

    @Test("A capture request in a regular window bumps the counter and keeps the tab")
    func regularRequestUsesTheCounter() {
        let router = AppRouter()
        router.applyShellLayout(ShellLayout(sizeClass: .regular, enabledSections: Self.allOpen))
        router.selectedTab = .insights
        router.requestCapture()
        router.requestCapture()
        #expect(router.captureRequestCount == 2)
        #expect(router.selectedTab == .insights)
    }

    @Test("A capture request in a compact window selects the Log tab")
    func compactRequestSelectsTheTab() {
        let router = AppRouter()
        router.applyShellLayout(ShellLayout(sizeClass: .compact, enabledSections: Self.allOpen))
        router.requestCapture()
        #expect(router.selectedTab == .measure)
        #expect(router.captureRequestCount == 0)
    }

    @Test("The compact bar keeps Log, the regular contract has none")
    func contractHasLogOnlyWhenCompact() {
        let compact = AuthenticatedShell.tabContract(for: ShellLayout(sizeClass: .compact, enabledSections: Self.allOpen))
        let regular = AuthenticatedShell.tabContract(for: ShellLayout(sizeClass: .regular, enabledSections: Self.allOpen))
        #expect(compact.contains { $0.hasPrefix("tab measure") })
        #expect(!regular.contains { $0.hasPrefix("tab measure") })
    }

    @Test("The popover hangs on the selected root's + while it is on screen")
    func popoverAnchor() {
        #expect(ShellCaptureAnchor.presentingTab(form: .regular, visibleTab: .meds, selectedTab: .meds) == .meds)
        #expect(ShellCaptureAnchor.presentingTab(form: .regular, visibleTab: .home, selectedTab: .home) == .home)
        #expect(ShellCaptureAnchor.presentingTab(form: .regular, visibleTab: .insights, selectedTab: .insights) == .insights)
        // Another tab selected, no + on screen, a sheet, or not a root: the top of the window.
        #expect(ShellCaptureAnchor.presentingTab(form: .regular, visibleTab: .home, selectedTab: .more) == nil)
        #expect(ShellCaptureAnchor.presentingTab(form: .regular, visibleTab: nil, selectedTab: .home) == nil)
        #expect(ShellCaptureAnchor.presentingTab(form: .compact, visibleTab: .home, selectedTab: .home) == nil)
        #expect(ShellCaptureAnchor.presentingTab(form: .regular, visibleTab: .more, selectedTab: .more) == nil)
    }
}
