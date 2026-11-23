@testable import HealthLog
import SwiftUI
import Testing

/// `AppRouter.resolve` decides every tab selection. These tests walk all 13
/// navigable places (four tabs, nine sidebar destinations) through both size
/// classes with the gate open and closed, and check that the result is always
/// a tab the shell builds in that layout.
@Suite("AppRouter.resolve (sidebar and size class)")
struct AppRouterResolveTests {
    typealias Tab = AuthenticatedShell.TabIdentifier

    /// The four destination tabs plus the nine sidebar destinations.
    static let routes: [Tab] = [.home, .meds, .insights, .more] + SidebarDestination.allCases.map { .section($0) }

    static let sizeClasses: [UserInterfaceSizeClass?] = [.compact, .regular, nil]

    /// The tabs the shell builds in a layout: the bar tabs (Log only where
    /// it is a tab, not in a regular window) plus the sidebar tabs (mirrors
    /// `ShellLayout.visibleSections` and `logTab(sizeClass:)`).
    static func builtTabs(sizeClass: UserInterfaceSizeClass?, enabled: Set<SidebarDestination>) -> Set<Tab> {
        let layout = ShellLayout(sizeClass: sizeClass, enabledSections: enabled)
        let log: [Tab] = AppRouter.capturesThroughTab(sizeClass: sizeClass) ? [.measure] : []
        return Set([.home, .meds, .insights, .more] + log + layout.visibleSections.map { .section($0) })
    }

    @Test("There are 15 navigable places: four tabs and eleven sidebar destinations")
    func thirteenRoutes() {
        #expect(Self.routes.count == 15)
        #expect(Set(Self.routes).count == 15)
    }

    @Test("Every route, size class and gate state resolves to a tab that is built", arguments: routes)
    func neverAMissingTab(route: Tab) {
        let all = Set(SidebarDestination.allCases)
        for sizeClass in Self.sizeClasses {
            for enabled in [all, Set<SidebarDestination>()] {
                let tab = AppRouter.resolve(route, sizeClass: sizeClass, enabledSections: enabled).tab
                #expect(
                    Self.builtTabs(sizeClass: sizeClass, enabled: enabled).contains(tab),
                    "\(route.rawValue) at \(String(describing: sizeClass)) resolved to missing tab \(tab.rawValue)"
                )
            }
        }
    }

    @Test("The four bar tabs always select themselves", arguments: [Tab.home, .meds, .insights, .more])
    func barTabsSelectThemselves(tab: Tab) {
        for sizeClass in Self.sizeClasses {
            for enabled in [Set(SidebarDestination.allCases), []] {
                #expect(AppRouter.resolve(tab, sizeClass: sizeClass, enabledSections: enabled) == .select(tab))
            }
        }
    }

    @Test("Log selects itself where it is a tab and never a missing tab in a regular window")
    func logResolvesToABuiltTab() {
        for sizeClass in Self.sizeClasses {
            for enabled in [Set(SidebarDestination.allCases), []] {
                let resolution = AppRouter.resolve(.measure, sizeClass: sizeClass, enabledSections: enabled)
                #expect(Self.builtTabs(sizeClass: sizeClass, enabled: enabled).contains(resolution.tab))
                #expect(resolution == .select(sizeClass == .regular ? .home : .measure))
            }
        }
    }

    @Test("Regular width with the gate open selects the sidebar tab", arguments: SidebarDestination.allCases)
    func regularOpenSelectsSection(destination: SidebarDestination) {
        let resolution = AppRouter.resolve(.section(destination), sizeClass: .regular, enabledSections: [destination])
        #expect(resolution == .select(.section(destination)))
    }

    @Test("Compact width with the gate open opens the destination on More", arguments: SidebarDestination.allCases)
    func compactOpenPushesOnMore(destination: SidebarDestination) {
        for sizeClass in [UserInterfaceSizeClass.compact, nil] {
            let resolution = AppRouter.resolve(.section(destination), sizeClass: sizeClass, enabledSections: [destination])
            #expect(resolution == .more(pushing: destination))
            #expect(resolution.tab == .more)
        }
    }

    @Test("A closed or unresolved gate opens the destination on More in every size class", arguments: SidebarDestination.allCases)
    func closedGateOpensOnMore(destination: SidebarDestination) {
        let others = Set(SidebarDestination.allCases).subtracting([destination])
        for sizeClass in Self.sizeClasses {
            let resolution = AppRouter.resolve(.section(destination), sizeClass: sizeClass, enabledSections: others)
            #expect(resolution == .more(pushing: destination))
        }
    }

    @Test("The sidebar holds eleven destinations in two sections in table order, the timeline first")
    func sectionTable() {
        #expect(SidebarSection.diary.destinations == [
            .timeline, .measurements, .illness, .seizures, .cycle, .mentalWellbeing, .workouts
        ])
        #expect(SidebarSection.findings.destinations == [.labs, .documents, .checkups, .medicalSources])
    }

    @Test("Gates follow the More rows: modules, the cycle gate, three ungated rows")
    func gates() {
        let allOn = SidebarDestination.enabled(
            isModuleEnabled: { _ in true }, isCycleTrackingAvailable: true, isTimelineAvailable: true,
            isSeizuresAvailable: true
        )
        #expect(allOn == Set(SidebarDestination.allCases))

        let allOff = SidebarDestination.enabled(isModuleEnabled: { _ in false }, isCycleTrackingAvailable: false)
        #expect(allOff == [.measurements, .checkups, .medicalSources])

        let labsOff = SidebarDestination.enabled(
            isModuleEnabled: { $0 != .labs }, isCycleTrackingAvailable: true, isTimelineAvailable: true
        )
        #expect(!labsOff.contains(.labs))
        #expect(labsOff.count == 9, "the seizure diary stays closed without the server's word")

        let pairs: [(ModuleKey, SidebarDestination)] = [
            (.illness, .illness), (.mentalHealth, .mentalWellbeing), (.workouts, .workouts),
            (.labs, .labs), (.inboundDocuments, .documents)
        ]
        for (key, destination) in pairs {
            let set = SidebarDestination.enabled(isModuleEnabled: { $0 != key }, isCycleTrackingAvailable: true)
            #expect(!set.contains(destination), "\(key) must close \(destination)")
        }
        let noCycle = SidebarDestination.enabled(
            isModuleEnabled: { _ in true }, isCycleTrackingAvailable: false, isTimelineAvailable: true,
            isSeizuresAvailable: true
        )
        #expect(noCycle == Set(SidebarDestination.allCases).subtracting([.cycle]))
        // The timeline follows the server version, not a module: the page
        // itself offers to switch its opt-in module on.
        let oldServer = SidebarDestination.enabled(isModuleEnabled: { _ in true }, isCycleTrackingAvailable: true)
        #expect(oldServer == Set(SidebarDestination.allCases).subtracting([.timeline, .seizures]))
    }

    @Test("A compact layout has no sidebar tabs, a regular one only the open ones")
    func visibleSections() {
        let all = Set(SidebarDestination.allCases)
        #expect(ShellLayout(sizeClass: .compact, enabledSections: all).visibleSections.isEmpty)
        #expect(ShellLayout(sizeClass: nil, enabledSections: all).visibleSections.isEmpty)
        #expect(ShellLayout.initial.visibleSections.isEmpty)
        #expect(ShellLayout(sizeClass: .regular, enabledSections: all).visibleSections == SidebarDestination.allCases)
        #expect(
            ShellLayout(sizeClass: .regular, enabledSections: [.labs, .illness]).visibleSections == [.illness, .labs]
        )
    }
}

/// The router side of `resolve`: what happens to selection and paths when the
/// layout changes or a request opens a sidebar destination.
@MainActor
@Suite("AppRouter sidebar layout changes")
struct AppRouterSidebarLayoutTests {
    static let regular = ShellLayout(sizeClass: .regular, enabledSections: Set(SidebarDestination.allCases))
    static let compact = ShellLayout(sizeClass: .compact, enabledSections: Set(SidebarDestination.allCases))

    private func routerOnLabsWithDetail() -> AppRouter {
        let router = AppRouter()
        router.applyShellLayout(Self.regular)
        router.openSidebarDestination(.labs)
        var path = NavigationPath()
        path.append(MoreRoute.documents)
        router.setSectionPath(path, for: .labs)
        return router
    }

    @Test("Regular: opening a destination selects its tab and leaves More alone")
    func openOnRegular() {
        let router = AppRouter()
        router.morePath.append(SettingsRoute.root)
        router.applyShellLayout(Self.regular)
        router.openSidebarDestination(.checkups)
        #expect(router.selectedTab == .section(.checkups))
        #expect(router.sectionPath(.checkups).isEmpty)
        #expect(router.morePath.count == 1)
    }

    @Test("Before the shell reports a layout, every destination opens on More as before")
    func initialLayoutKeepsFiveTabBehaviour() {
        for destination in SidebarDestination.allCases {
            let router = AppRouter()
            router.openSidebarDestination(destination)
            #expect(router.selectedTab == .more)
            #expect(router.morePath.count == 1)
            #expect(router.sectionPaths.isEmpty)
        }
    }

    @Test("Turning compact switches to More, drops the section path, opens the same screen")
    func sizeClassLossSwitchesToMore() {
        let router = routerOnLabsWithDetail()
        #expect(router.sectionPath(.labs).count == 1)

        router.applyShellLayout(Self.compact)

        #expect(router.selectedTab == .more)
        #expect(router.sectionPaths[.labs] == nil)
        #expect(router.morePath.count == 1)
    }

    @Test("A closed module switches to More, keeps the More stack and drops the section path")
    func moduleLossKeepsMoreStack() {
        let router = routerOnLabsWithDetail()
        router.morePath.append(SettingsRoute.root)

        router.applyShellLayout(ShellLayout(
            sizeClass: .regular,
            enabledSections: Set(SidebarDestination.allCases).subtracting([.labs])
        ))

        #expect(router.selectedTab == .more)
        #expect(router.sectionPaths[.labs] == nil)
        #expect(router.morePath.count == 1)
    }

    @Test("Turning compact pushes the destination onto the More stack that is there")
    func sizeClassLossPushesOntoMoreStack() {
        let router = routerOnLabsWithDetail()
        router.morePath.append(SettingsRoute.root)

        router.applyShellLayout(Self.compact)

        #expect(router.selectedTab == .more)
        #expect(router.sectionPaths[.labs] == nil)
        #expect(router.morePath.count == 2)
    }

    @Test("A layout reported in the background changes nothing; back in front it applies")
    func backgroundLayoutIsDeferred() {
        let router = routerOnLabsWithDetail()

        router.reportShellLayout(Self.compact, sceneIsActive: false)
        router.reportShellLayout(Self.regular, sceneIsActive: false)
        #expect(router.selectedTab == .section(.labs))
        #expect(router.sectionPath(.labs).count == 1)

        router.reportShellLayout(Self.regular, sceneIsActive: true)
        #expect(router.selectedTab == .section(.labs))
        #expect(router.sectionPath(.labs).count == 1)

        router.reportShellLayout(Self.compact, sceneIsActive: true)
        #expect(router.selectedTab == .more)
        #expect(router.sectionPaths[.labs] == nil)
    }

    @Test("Compact with the gate closed: a cycle link still opens the cycle screen on More")
    func compactClosedGateKeepsPush() {
        let router = AppRouter()
        router.applyShellLayout(ShellLayout(
            sizeClass: .compact,
            enabledSections: Set(SidebarDestination.allCases).subtracting([.cycle, .mentalWellbeing])
        ))
        router.apply(.cycle, isAuthenticated: true)
        #expect(router.selectedTab == .more)
        #expect(router.morePath.count == 1)

        router.apply(.mentalWellbeing, isAuthenticated: true)
        #expect(router.selectedTab == .more)
        #expect(router.morePath.count == 1)
    }

    @Test("Regular cold start before the cycle gate resolves: the link opens on More")
    func regularUnresolvedGateOpensOnMore() {
        let router = AppRouter()
        // The cycle gate reads false until the settings have loaded.
        router.applyShellLayout(ShellLayout(
            sizeClass: .regular,
            enabledSections: Set(SidebarDestination.allCases).subtracting([.cycle])
        ))
        router.apply(.cycle, isAuthenticated: true)
        #expect(router.selectedTab == .more)
        #expect(router.morePath.count == 1)
        #expect(router.sectionPaths.isEmpty)
    }

    @Test("Before the router catches up, the shown selection is already a built tab")
    func displayedTabResolvesBeforeTheSwitch() {
        let router = routerOnLabsWithDetail()
        #expect(router.displayedTab(in: Self.regular) == .section(.labs))
        #expect(router.displayedTab(in: Self.compact) == .more)
        #expect(router.selectedTab == .section(.labs))
    }

    @Test("A layout change that keeps the tab keeps its path; other gone tabs lose theirs")
    func unaffectedTabKeepsPath() {
        let router = routerOnLabsWithDetail()
        var path = NavigationPath()
        path.append(MoreRoute.illness)
        router.setSectionPath(path, for: .illness)

        router.applyShellLayout(ShellLayout(
            sizeClass: .regular,
            enabledSections: Set(SidebarDestination.allCases).subtracting([.illness])
        ))

        #expect(router.selectedTab == .section(.labs))
        #expect(router.sectionPath(.labs).count == 1)
        #expect(router.sectionPaths[.illness] == nil)
    }

    @Test("Compact selection on a bar tab is untouched by a layout change")
    func barTabUntouched() {
        let router = AppRouter()
        router.applyShellLayout(Self.regular)
        router.selectedTab = .meds
        router.medsPath.append(MoreRoute.labs)
        router.applyShellLayout(Self.compact)
        #expect(router.selectedTab == .meds)
        #expect(router.medsPath.count == 1)
    }

    @Test("Deep links to Vorsorge, cycle and the check-in use the sidebar tab on regular width")
    func deepLinksUseSidebarTabs() {
        let router = AppRouter()
        router.applyShellLayout(Self.regular)

        router.apply(.checkups, isAuthenticated: true)
        #expect(router.selectedTab == .section(.checkups))

        router.apply(.cycle, isAuthenticated: true)
        #expect(router.selectedTab == .section(.cycle))

        router.apply(.mentalWellbeing, isAuthenticated: true)
        #expect(router.selectedTab == .section(.mentalWellbeing))
        #expect(router.morePath.isEmpty)
    }

    @Test("Deep links on compact width land on More with one pushed screen, as before")
    func deepLinksOnCompact() {
        let router = AppRouter()
        router.applyShellLayout(Self.compact)
        router.apply(.checkups, isAuthenticated: true)
        #expect(router.selectedTab == .more)
        #expect(router.morePath.count == 1)
    }

    @Test("The values table opens in the Messwerte tab on regular width, on More otherwise")
    func measurementList() {
        let regular = AppRouter()
        regular.applyShellLayout(Self.regular)
        regular.showMeasurementList(.weight)
        #expect(regular.selectedTab == .section(.measurements))
        #expect(regular.sectionPath(.measurements).count == 1)
        #expect(regular.morePath.isEmpty)

        let compact = AppRouter()
        compact.applyShellLayout(Self.compact)
        compact.showMeasurementList(.weight)
        #expect(compact.selectedTab == .more)
        #expect(compact.morePath.count == 1)
    }

    @Test("Sign-out drops every sidebar path")
    func signOutDropsSectionPaths() {
        let router = routerOnLabsWithDetail()
        router.resetNavigationForSignOut()
        #expect(router.sectionPaths.isEmpty)
        #expect(router.selectedTab == .home)
    }
}
