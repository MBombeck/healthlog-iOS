import SwiftUI

// MARK: - Sidebar sections (regular width)

/// The two sidebar sections of a regular-width window: "Tagebuch" and
/// "Befunde", each with the More destinations whose gate is open. A compact
/// window builds neither, so the iPhone keeps its five-tab bar.
extension AuthenticatedShell {
    /// One sidebar tab as the shell builds it, and the contract the tests dump.
    struct SidebarItem: Hashable {
        let destination: SidebarDestination
        let titleKey: String
        let systemImage: String
    }

    /// One sidebar section with its tabs.
    struct SidebarGroup: Hashable {
        let section: SidebarSection
        let titleKey: String
        let items: [SidebarItem]
    }

    /// Catalog key of a section heading.
    static func titleKey(for section: SidebarSection) -> String {
        switch section {
        case .diary: "sidebar.section.diary"
        case .findings: "sidebar.section.findings"
        }
    }

    /// A sidebar tab carries the title and symbol of its More row, so the
    /// same place reads the same in both.
    static func sidebarItem(for destination: SidebarDestination) -> SidebarItem {
        let row: MoreScreen.Layout.Row = switch destination {
        case .timeline: MoreScreen.Layout.timelineRow
        case .measurements: MoreScreen.Layout.measurementsRow
        case .illness: MoreScreen.Layout.illnessRow
        case .seizures: MoreScreen.Layout.seizuresRow
        case .cycle: MoreScreen.Layout.cycleRow
        case .mentalWellbeing: MoreScreen.Layout.mentalWellbeingRow
        case .workouts: MoreScreen.Layout.workoutsRow
        case .labs: MoreScreen.Layout.labsRow
        case .documents: MoreScreen.Layout.documentsRow
        case .checkups: MoreScreen.Layout.vorsorgeRow
        case .medicalSources: MoreScreen.Layout.medicalSourcesRow
        }
        return SidebarItem(destination: destination, titleKey: row.title, systemImage: baseSymbol(row.icon))
    }

    /// The base name of an SF Symbol: the system chooses the variant for the
    /// placement, the same way it does for the bar tabs.
    static func baseSymbol(_ name: String) -> String {
        name.hasSuffix(".fill") ? String(name.dropLast(".fill".count)) : name
    }

    /// The sections the shell builds in `layout`: none when compact, otherwise
    /// both, each with the destinations whose gate is open.
    static func sidebarGroups(for layout: ShellLayout) -> [SidebarGroup] {
        let visible = Set(layout.visibleSections)
        return SidebarSection.allCases.compactMap { section in
            let items = section.destinations.filter(visible.contains).map(sidebarItem(for:))
            guard !items.isEmpty else { return nil }
            return SidebarGroup(section: section, titleKey: titleKey(for: section), items: items)
        }
    }

    /// Every navigation place the shell builds in `layout`, in order, one
    /// line each. The structural contract `AuthenticatedShellTabsTests`
    /// dumps: compact, the tabs of the bar; regular, the rows of the sidebar.
    static func tabContract(for layout: ShellLayout) -> [String] {
        guard layout.sizeClass == .regular else {
            return tabDescriptors.filter { !$0.isAction || AppRouter.capturesThroughTab(sizeClass: layout.sizeClass) }.map { tab in
                "tab \(tab.id.rawValue) | \(tab.titleKey) | \(tab.systemImage)\(tab.isAction ? " | action" : "")"
            }
        }
        let row = { (item: SidebarRow) in "row \(item.id.rawValue) | \(item.titleKey) | \(item.systemImage)" }
        let sections = sidebarGroups(for: layout).flatMap { group in
            ["section \(group.section.rawValue) | \(group.titleKey)"] + group.items.map { item in
                "  " + row(SidebarRow(destination: item))
            }
        }
        return sidebarMainRows.map(row) + sections + [row(sidebarFootRow)]
    }

    /// The Log action slot at the centre of the compact bar. It opens the
    /// capture picker on selection rather than navigating; the selection snaps
    /// back to the previous real tab. Its body paints the app background, so
    /// the one pass before the snap-back does not flash. A regular window has
    /// no tab bar: Log is the "+" of the sidebar's main destinations.
    @TabContentBuilder<TabIdentifier>
    func logTab(sizeClass: UserInterfaceSizeClass?) -> some TabContent<TabIdentifier> {
        if AppRouter.capturesThroughTab(sizeClass: sizeClass) {
            Tab("Log", systemImage: "plus.circle", value: TabIdentifier.measure) {
                HLColor.background
                    .ignoresSafeArea()
            }
            .accessibilityLabel(Text("Add measurement"))
        }
    }
}

/// A sidebar tab: its own stack, its own path on the router, and the same
/// destinations as the More stack.
struct SidebarDestinationStack: View {
    let destination: SidebarDestination
    @Environment(AppRouter.self) private var router

    var body: some View {
        NavigationStack(path: Binding(
            get: { router.sectionPath(destination) },
            set: { router.setSectionPath($0, for: destination) }
        )) {
            SidebarDestinationScreen(destination: destination)
                // Only the root screen is a tab root; pages pushed onto this
                // stack keep the inline title of a subpage.
                .environment(\.hlIsTabRoot, true)
                .hlMoreDestinations()
        }
    }
}

// MARK: - Tab root title

extension EnvironmentValues {
    /// Whether the page is the root of a tab. Set by a sidebar tab for its
    /// root screen; a page pushed onto More leaves it `false`.
    @Entry var hlIsTabRoot = false
}

extension View {
    /// Title display of a screen that is a sidebar tab on a regular-width
    /// window and a subpage of More otherwise. The system title is inline in
    /// both: the large title of a page is its ``HLTabHeader``, warm and on
    /// the page's margin, so a section root and a tab root share one title
    /// system. Kept as a name until the section roots drop the call.
    func hlTabRootTitleDisplayMode() -> some View {
        navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Layout reports

extension View {
    /// The shell's reports to the router, the same for the tab bar and the
    /// sidebar: the layout (size class and open gates) and the selection
    /// haptic.
    func hlShellLayoutReports(router: AppRouter, layout: ShellLayout) -> some View {
        modifier(ShellLayoutReportsModifier(router: router, layout: layout))
    }
}

private struct ShellLayoutReportsModifier: ViewModifier {
    let router: AppRouter
    let layout: ShellLayout
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            // A vanishing sidebar row hands over to More only while the scene
            // is active; in between `displayedTab(in:)` keeps the selection on
            // a built place. Back in front, the current layout is reported again.
            .onChange(of: layout, initial: true) { _, newLayout in
                router.reportShellLayout(newLayout, sceneIsActive: scenePhase == .active)
            }
            .onChange(of: scenePhase) { _, phase in
                router.reportShellLayout(layout, sceneIsActive: phase == .active)
            }
            .sensoryFeedback(.selection, trigger: router.selectedTab)
    }
}
