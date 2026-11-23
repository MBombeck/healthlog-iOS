@testable import HealthLog
import SwiftUI
import Testing

/// A regular window is the sidebar beside its detail, without a bar at the
/// top: Dashboard, Medications and Insights, the sections, More at the foot.
/// Every row selects a place the window builds, and the timeline has its
/// row even before the server version is known (build 312 on the iPad).
@MainActor
@Suite("Shell sidebar")
struct ShellSidebarTests {
    private static let allOpen = Set(SidebarDestination.allCases)

    @Test("Only a regular window is the sidebar; compact and an unknown size class keep the tab bar")
    func sidebarOnlyWhenRegular() {
        #expect(AuthenticatedShell.usesSidebar(sizeClass: .regular))
        #expect(!AuthenticatedShell.usesSidebar(sizeClass: .compact))
        #expect(!AuthenticatedShell.usesSidebar(sizeClass: nil))
    }

    @Test("The sidebar opens with Dashboard, Medications and Insights and ends with More; Log is the +")
    func headAndFoot() {
        #expect(AuthenticatedShell.sidebarMainRows.map(\.id) == [.home, .meds, .insights])
        #expect(AuthenticatedShell.sidebarFootRow.id == .more)
        #expect(AuthenticatedShell.sidebarFootRow.systemImage == "ellipsis")
        #expect(!AuthenticatedShell.sidebarMainRows.contains { $0.id == .measure })
    }

    @Test("Every sidebar row selects itself: the window builds each place it lists")
    func everyRowResolvesToItself() {
        let layout = ShellLayout(sizeClass: .regular, enabledSections: Self.allOpen)
        let rows = AuthenticatedShell.sidebarMainRows
            + AuthenticatedShell.sidebarGroups(for: layout).flatMap(\.items).map(AuthenticatedShell.SidebarRow.init(destination:))
            + [AuthenticatedShell.sidebarFootRow]
        for row in rows {
            let resolution = AppRouter.resolve(row.id, sizeClass: .regular, enabledSections: layout.enabledSections)
            #expect(resolution == .select(row.id), "\(row.id.rawValue) does not select itself")
        }
    }

    @Test("A request for More still selects More in a regular window")
    func moreResolvesWhenRegular() {
        let resolution = AppRouter.resolve(.more, sizeClass: .regular, enabledSections: Self.allOpen)
        #expect(resolution == .select(.more))
    }

    /// Build 312 on the iPad: right after a sign-in the remembered server
    /// version is gone and the next probe comes with the next foreground.
    /// The sidebar then had no timeline, and nothing ever read
    /// `/api/timeline`. Unknown now offers it, at the head of "Tagebuch".
    @Test("The timeline heads the sidebar's diary before the server version is known")
    func timelineWithoutAKnownVersion() throws {
        let enabled = SidebarDestination.enabled(
            isModuleEnabled: { _ in true },
            isCycleTrackingAvailable: false,
            isTimelineAvailable: TimelineRepository.isTimelineAvailable(serverVersion: nil)
        )
        let layout = ShellLayout(sizeClass: .regular, enabledSections: enabled)
        let diary = try #require(AuthenticatedShell.sidebarGroups(for: layout).first)
        #expect(diary.section == .diary)
        #expect(diary.items.first?.destination == .timeline)
        #expect(AppRouter.resolve(.section(.timeline), sizeClass: .regular, enabledSections: enabled) == .select(.section(.timeline)))
        // A server known to be older than the route keeps the row away.
        let old = SidebarDestination.enabled(
            isModuleEnabled: { _ in true },
            isCycleTrackingAvailable: false,
            isTimelineAvailable: TimelineRepository.isTimelineAvailable(serverVersion: "1.41.0")
        )
        #expect(!old.contains(.timeline))
    }

    /// Turned across after an upright start, the sidebar stayed folded away
    /// (run 2 of P2): every iPad across stands it beside the page.
    @Test(
        "The sidebar stands beside the page from 1100 pt on, below it the system folds it away",
        arguments: zip(
            [CGFloat(320), 440, 466, 540, 669, 744, 834, 1032, 1133, 1210, 1376],
            [false, false, false, false, false, false, false, false, true, true, true]
        )
    )
    func sidebarBesideTheWideWindow(width: CGFloat, beside: Bool) {
        #expect(ShellSplitLayout.isWide(width: width) == beside)
        #expect(ShellSplitLayout.visibility(isWide: beside) == (beside ? .all : .automatic))
    }

    /// Review P2: an iPhone Pro Max or Air turned across under the full
    /// screen chart or the timeline's cover is regular wide but compact high;
    /// the shell must stay the tab bar there.
    @Test(
        "Only a window wide and not short is the sidebar",
        arguments: [
            (
                UserInterfaceSizeClass?.some(.regular),
                UserInterfaceSizeClass?.some(.regular),
                UserInterfaceSizeClass?.some(.regular)
            ), // iPad, open Duo
            (.regular, .compact, .compact), // iPhone Pro Max or Air across
            (.compact, .compact, .compact), // iPhone across
            (.compact, .regular, .compact), // iPhone upright, folded Duo
            (.regular, nil, .regular),
            (nil, .regular, nil)
        ]
    )
    func shellSizeClass(
        horizontal: UserInterfaceSizeClass?,
        vertical: UserInterfaceSizeClass?,
        expected: UserInterfaceSizeClass?
    ) {
        let shell = AuthenticatedShell.shellSizeClass(horizontal: horizontal, vertical: vertical)
        #expect(shell == expected)
        #expect(AuthenticatedShell.usesSidebar(sizeClass: shell) == (expected == .regular))
    }

    /// Review P2: a change of row destroyed the page left behind. Visited
    /// places stay mounted: Insights on one of its pages, then Dashboard,
    /// then Insights again finds the same Insights.
    @Test("Visited places stay mounted: Insights, Dashboard, Insights again")
    func visitedPlacesStayMounted() {
        let layout = ShellLayout(sizeClass: .regular, enabledSections: Self.allOpen)
        var mounted = ShellDetailMemory.mounted(visited: [], selected: .home, layout: layout)
        #expect(mounted == [.home])
        mounted = ShellDetailMemory.mounted(visited: mounted, selected: .insights, layout: layout)
        #expect(mounted == [.home, .insights])
        mounted = ShellDetailMemory.mounted(visited: mounted, selected: .home, layout: layout)
        #expect(mounted == [.home, .insights])
        mounted = ShellDetailMemory.mounted(visited: mounted, selected: .insights, layout: layout)
        #expect(mounted == [.home, .insights])
        // Log is never a place; it stands for Dashboard.
        #expect(ShellDetailMemory.mounted(visited: [], selected: .measure, layout: layout) == [.home])
    }

    @Test("A place the layout no longer builds is let go")
    func closedPlaceIsDropped() {
        let open = ShellLayout(sizeClass: .regular, enabledSections: Self.allOpen)
        let mounted = ShellDetailMemory.mounted(visited: [.home, .section(.labs)], selected: .meds, layout: open)
        #expect(mounted == [.home, .section(.labs), .meds])
        let closed = ShellLayout(sizeClass: .regular, enabledSections: Self.allOpen.subtracting([.labs]))
        #expect(ShellDetailMemory.mounted(visited: mounted, selected: .meds, layout: closed) == [.home, .meds])
    }

    @Test("A size-class change keeps the paths of the main places")
    func sizeClassChangeKeepsPaths() {
        let router = AppRouter()
        router.applyShellLayout(ShellLayout(sizeClass: .regular, enabledSections: Self.allOpen))
        router.selectedTab = .meds
        router.medsPath.append("detail")
        router.homePath.append("chart")
        router.applyShellLayout(ShellLayout(sizeClass: .compact, enabledSections: Self.allOpen))
        #expect(router.selectedTab == .meds)
        #expect(router.medsPath.count == 1)
        #expect(router.homePath.count == 1)
        router.applyShellLayout(ShellLayout(sizeClass: .regular, enabledSections: Self.allOpen))
        #expect(router.selectedTab == .meds)
        #expect(router.medsPath.count == 1)
    }
}
