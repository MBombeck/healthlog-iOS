import SwiftUI

/// A More destination that becomes its own sidebar tab on a regular-width
/// window. The cases and their order are the sidebar table of the iPad plan
/// with the timeline at the head of the diary; everything else stays in More.
enum SidebarDestination: String, CaseIterable, Hashable, Sendable {
    /// "Zeitleiste": the whole record on one time axis.
    case timeline
    case measurements
    case illness
    /// "Anfallskalender": only while the server says `seizures` is on.
    case seizures
    case cycle
    case mentalWellbeing
    case workouts
    case labs
    case documents
    case checkups
    case medicalSources

    /// The sidebar section the destination is listed under.
    var section: SidebarSection {
        switch self {
        case .timeline, .measurements, .illness, .seizures, .cycle, .mentalWellbeing, .workouts: .diary
        case .labs, .documents, .checkups, .medicalSources: .findings
        }
    }

    /// The destinations whose gate is open, from the same gates the More rows
    /// read. A destination without a gate is always open.
    static func enabled(
        isModuleEnabled: (ModuleKey) -> Bool,
        isCycleTrackingAvailable: Bool,
        isTimelineAvailable: Bool = false,
        isSeizuresAvailable: Bool = false
    ) -> Set<SidebarDestination> {
        Set(allCases.filter { destination in
            switch destination {
            case .timeline: isTimelineAvailable
            case .measurements, .checkups, .medicalSources: true
            case .illness: isModuleEnabled(.illness)
            case .seizures: isSeizuresAvailable
            case .cycle: isCycleTrackingAvailable
            case .mentalWellbeing: isModuleEnabled(.mentalHealth)
            case .workouts: isModuleEnabled(.workouts)
            case .labs: isModuleEnabled(.labs)
            case .documents: isModuleEnabled(.inboundDocuments)
            }
        })
    }

    /// Pushes the value the More row for this destination pushes, so a
    /// destination without its own tab opens on the More stack exactly as a
    /// tap on its row would.
    func appendMoreRow(to path: inout NavigationPath) {
        switch self {
        case .timeline: path.append(MoreRoute.timeline)
        case .measurements: path.append(MoreRoute.measurements)
        case .illness: path.append(MoreRoute.illness)
        case .seizures: path.append(MoreRoute.seizures)
        case .cycle: path.append(SettingsRoute.cycle)
        case .mentalWellbeing: path.append(MentalWellbeingRoute())
        case .workouts: path.append(MoreRoute.workouts)
        case .labs: path.append(MoreRoute.labs)
        case .documents: path.append(MoreRoute.documents)
        case .checkups: path.append(SettingsRoute.checkups)
        case .medicalSources: path.append(MoreRoute.medicalSources)
        }
    }
}

/// The two sidebar sections, in sidebar order.
enum SidebarSection: String, CaseIterable, Hashable, Sendable {
    /// "Tagebuch": what the user records day by day.
    case diary
    /// "Befunde": what comes back from doctors and labs.
    case findings

    var destinations: [SidebarDestination] {
        SidebarDestination.allCases.filter { $0.section == self }
    }
}

/// What the shell can show right now: the horizontal size class of the window
/// and the sidebar destinations whose gate is open.
struct ShellLayout: Equatable, Sendable {
    var sizeClass: UserInterfaceSizeClass?
    var enabledSections: Set<SidebarDestination>

    /// Before the shell has reported anything: no sidebar, every gate open, so
    /// the router behaves exactly as the five-tab bar always has.
    static let initial = ShellLayout(sizeClass: nil, enabledSections: Set(SidebarDestination.allCases))

    /// The sidebar tabs that exist in this layout, in sidebar order.
    var visibleSections: [SidebarDestination] {
        guard sizeClass == .regular else { return [] }
        return SidebarDestination.allCases.filter(enabledSections.contains)
    }
}

/// Where a navigation request lands in a given layout.
enum ShellResolution: Equatable, Sendable {
    /// The tab exists: select it.
    case select(AuthenticatedShell.TabIdentifier)
    /// The sidebar tab does not exist: select More and push the destination's
    /// More row, so the user lands on the same screen a tap on that row opens.
    case more(pushing: SidebarDestination)

    /// The tab the `TabView` selects.
    var tab: AuthenticatedShell.TabIdentifier {
        switch self {
        case let .select(tab): tab
        case .more: .more
        }
    }
}

extension AppRouter {
    /// The one place that decides which tab a request selects. The `TabView`
    /// never gets a selection that this function did not produce, so it never
    /// selects a tab that is not built (an iOS 27 `TabView` may crash on that).
    nonisolated static func resolve(
        _ route: AuthenticatedShell.TabIdentifier,
        sizeClass: UserInterfaceSizeClass?,
        enabledSections: Set<SidebarDestination>
    ) -> ShellResolution {
        // A regular window has no Log tab; the action stays where it was.
        if route == .measure, !capturesThroughTab(sizeClass: sizeClass) { return .select(.home) }
        guard case let .section(destination) = route else { return .select(route) }
        // The gate decides only whether the sidebar tab exists. Compact, or
        // with the gate closed or not yet resolved (a cold start reads the
        // cycle gate before the settings load), the request opens on More as
        // it always has.
        guard sizeClass == .regular, enabledSections.contains(destination) else {
            return .more(pushing: destination)
        }
        return .select(route)
    }

    /// The selection the `TabView` shows in `layout`. Differs from
    /// `selectedTab` only for the one pass between a layout change and
    /// ``applyShellLayout(_:)``.
    func displayedTab(in layout: ShellLayout) -> AuthenticatedShell.TabIdentifier {
        Self.resolve(selectedTab, sizeClass: layout.sizeClass, enabledSections: layout.enabledSections).tab
    }

    /// The shell reports its layout, but only an active scene changes the
    /// router: a size-class flip for the app-switcher snapshot or a Stage
    /// Manager resize in the background must not drop a sidebar path. The
    /// shell reports again when the scene becomes active; until then
    /// ``displayedTab(in:)`` keeps the `TabView` on a built tab.
    func reportShellLayout(_ layout: ShellLayout, sceneIsActive: Bool) {
        guard sceneIsActive else { return }
        applyShellLayout(layout)
    }

    /// A new size class or a changed gate. A sidebar tab that is gone hands
    /// over to More before it disappears: only its own path is dropped (a
    /// `NavigationPath` cannot be read back, so nothing migrates). When its
    /// destination is still open, its More row goes on top of the More stack;
    /// a closed module leaves the More stack as it is.
    func applyShellLayout(_ layout: ShellLayout) {
        guard layout != shellLayout else { return }
        shellLayout = layout
        let visible = Set(layout.visibleSections)
        for destination in sectionPaths.keys where !visible.contains(destination) {
            sectionPaths[destination] = nil
        }
        guard case .section = selectedTab else { return }
        let resolution = Self.resolve(selectedTab, sizeClass: layout.sizeClass, enabledSections: layout.enabledSections)
        guard case let .more(destination) = resolution else { return }
        selectedTab = .more
        if layout.enabledSections.contains(destination) {
            isMovingPagesForLayout = true
            defer { isMovingPagesForLayout = false }
            destination.appendMoreRow(to: &morePath)
        }
    }

    /// Opens `destination` at its root: as its own sidebar tab when the
    /// layout has one, otherwise on the More stack.
    func openSidebarDestination(_ destination: SidebarDestination) {
        let resolution = Self.resolve(
            .section(destination),
            sizeClass: shellLayout.sizeClass,
            enabledSections: shellLayout.enabledSections
        )
        switch resolution {
        case let .select(tab):
            sectionPaths[destination] = .init()
            selectedTab = tab
        case let .more(destination):
            selectedTab = .more
            morePath = .init()
            destination.appendMoreRow(to: &morePath)
        }
    }

    /// Selects `tab`, or More when that tab is not built in the current layout.
    func selectResolved(_ tab: AuthenticatedShell.TabIdentifier) {
        selectedTab = Self.resolve(
            tab,
            sizeClass: shellLayout.sizeClass,
            enabledSections: shellLayout.enabledSections
        ).tab
    }

    /// The navigation path of a sidebar tab.
    func sectionPath(_ destination: SidebarDestination) -> NavigationPath {
        sectionPaths[destination] ?? .init()
    }

    /// Writes a sidebar tab's path. A stack that is torn down after its tab
    /// left the layout writes once more on the way out; that write is dropped
    /// so the discarded path does not come back.
    func setSectionPath(_ path: NavigationPath, for destination: SidebarDestination) {
        guard shellLayout.visibleSections.contains(destination) else {
            sectionPaths[destination] = nil
            return
        }
        sectionPaths[destination] = path
    }
}
