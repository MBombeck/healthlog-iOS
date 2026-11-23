import SwiftUI

// MARK: - Regular: the sidebar and its detail

/// A regular window (iPad, the open Duo, a wide Stage Manager window) is a
/// sidebar beside its detail, the way Mail, Notes and Files are: every
/// destination in one list, no bar at the top. Across, the sidebar stands
/// beside the detail; upright it folds away behind the system's sidebar
/// button and slides over the detail when opened. Compact keeps the tab bar.
///
/// Why not the adaptable `TabView`: on iPadOS 27 it shows a floating bar at
/// the top whenever its sidebar is folded, keeps the element last chosen in
/// the sidebar there and pages the bar when it runs out of room (F10c, F13).
/// No placement, visibility or customization keeps the bar away without
/// also taking the sidebar button with it.
extension AuthenticatedShell {
    /// One row of the regular sidebar.
    struct SidebarRow: Hashable {
        let id: TabIdentifier
        let titleKey: String
        let systemImage: String

        init(id: TabIdentifier, titleKey: String, systemImage: String) {
            self.id = id
            self.titleKey = titleKey
            self.systemImage = systemImage
        }

        init(destination item: SidebarItem) {
            self.init(id: .section(item.destination), titleKey: item.titleKey, systemImage: item.systemImage)
        }

        init(descriptor: TabDescriptor) {
            self.init(id: descriptor.id, titleKey: descriptor.titleKey, systemImage: descriptor.systemImage)
        }
    }

    /// The head of the sidebar: the destinations of the bar, without Log
    /// (the "+" of these pages) and More (the foot of the list).
    static var sidebarMainRows: [SidebarRow] {
        tabDescriptors.filter { !$0.isAction && $0.id != .more }.map(SidebarRow.init(descriptor:))
    }

    /// The foot of the sidebar: More, with settings and everything that has
    /// no row of its own.
    static var sidebarFootRow: SidebarRow {
        let more = tabDescriptors.first { $0.id == .more }
        return SidebarRow(id: .more, titleKey: more?.titleKey ?? "More", systemImage: more?.systemImage ?? "ellipsis")
    }

    /// The shell's navigation in the current size class. Switching between
    /// the two keeps every path: the stacks read and write the router.
    @ViewBuilder
    func navigationContainer(router: AppRouter) -> some View {
        let layout = shellLayout
        Group {
            if Self.usesSidebar(sizeClass: layout.sizeClass) {
                ShellSplitView(layout: layout, selection: tabSelectionBinding(router: router, layout: layout))
            } else {
                compactTabView(router: router, layout: layout)
            }
        }
        .hlShellLayoutReports(router: router, layout: layout)
    }

    /// Whether the shell is the sidebar and its detail: a regular window.
    /// Before the first size class is known the shell stays the tab bar.
    nonisolated static func usesSidebar(sizeClass: UserInterfaceSizeClass?) -> Bool {
        sizeClass == .regular
    }

    /// The size class the shell builds for. Regular needs a window that is
    /// wide and not short: an iPhone Plus, Pro Max or Air held across is
    /// regular wide but compact high, and turns across only under the full
    /// screen chart or the timeline's cover. Switching the shell there would
    /// tear down the page that presents the cover. Unknown stays unknown.
    nonisolated static func shellSizeClass(
        horizontal: UserInterfaceSizeClass?,
        vertical: UserInterfaceSizeClass?
    ) -> UserInterfaceSizeClass? {
        guard let horizontal else { return nil }
        return horizontal == .regular && vertical != .compact ? .regular : .compact
    }
}

/// The sidebar beside its detail. The selection is the router's, read and
/// written through `AppRouter.resolve`, so the sidebar never selects a
/// place that is not built.
private struct ShellSplitView: View {
    let layout: ShellLayout
    @Binding var selection: AuthenticatedShell.TabIdentifier
    /// Beside the detail in a wide window, folded away otherwise
    /// (``ShellSplitLayout``); the system button changes it in between.
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ShellSidebarList(layout: layout, selection: $selection)
        } detail: {
            ShellDetailColumn(tab: selection, layout: layout)
        }
        .navigationSplitViewStyle(.automatic)
        // Only a crossing of the line changes the column, so the person's
        // own choice holds until the window really grows or shrinks. The
        // column's visibility never changes the width measured here.
        .onGeometryChange(for: Bool.self) { proxy in
            ShellSplitLayout.isWide(width: proxy.size.width)
        } action: { isWide in
            columnVisibility = ShellSplitLayout.visibility(isWide: isWide)
        }
    }
}

/// When the sidebar stands beside the detail. Left to `.automatic`, a window
/// turned across after starting upright kept the sidebar folded away (the
/// split view remembers its state), so the shell asks for it from the
/// window's own measured width: from 1100 pt every iPad across (mini 1133,
/// 11-inch 1210, 13-inch 1376) and a wide Stage Manager window. The 13-inch
/// upright (1032 pt), the mini upright, the open Duo and narrower windows
/// keep the system's folded sidebar. Hausregel, measured, never the device.
enum ShellSplitLayout {
    static let besideMinimumWidth: CGFloat = 1100

    nonisolated static func isWide(width: CGFloat) -> Bool {
        width >= besideMinimumWidth
    }

    nonisolated static func visibility(isWide: Bool) -> NavigationSplitViewVisibility {
        isWide ? .all : .automatic
    }
}

/// The sidebar: Dashboard, Medications and Insights, the sections
/// "Tagebuch" and "Befunde" with the destinations whose gate is open, and
/// More at the foot.
private struct ShellSidebarList: View {
    let layout: ShellLayout
    @Binding var selection: AuthenticatedShell.TabIdentifier

    var body: some View {
        List(selection: listSelection) {
            Section {
                ForEach(AuthenticatedShell.sidebarMainRows, id: \.id) { row($0) }
            }
            ForEach(AuthenticatedShell.sidebarGroups(for: layout), id: \.section) { group in
                Section(LocalizedStringKey(group.titleKey)) {
                    ForEach(group.items, id: \.destination) { item in
                        row(AuthenticatedShell.SidebarRow(destination: item))
                    }
                }
            }
            Section {
                row(AuthenticatedShell.sidebarFootRow)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle(Text(verbatim: "HealthLog"))
    }

    private func row(_ row: AuthenticatedShell.SidebarRow) -> some View {
        // No identifier of its own: the row's cell carries the title as its
        // label, as every sidebar row of the system does.
        Label(LocalizedStringKey(row.titleKey), systemImage: row.systemImage)
            .tag(row.id)
    }

    /// The list deselects nothing on its own; a `nil` from it keeps the place.
    private var listSelection: Binding<AuthenticatedShell.TabIdentifier?> {
        Binding(
            get: { selection },
            set: { newValue in
                if let newValue { selection = newValue }
            }
        )
    }
}

/// The detail: the page of the chosen place with its own stack, exactly the
/// screen the tab of the compact bar shows. Like the tabs of a `TabView`,
/// every place visited stays mounted and only the chosen one is shown, so
/// coming back finds it as it was left: the Insights page, a pushed
/// medication history, the scroll position, a filter. A place the layout no
/// longer builds (a module switched off) is let go.
private struct ShellDetailColumn: View {
    let tab: AuthenticatedShell.TabIdentifier
    let layout: ShellLayout
    @State private var visited: [AuthenticatedShell.TabIdentifier] = []

    var body: some View {
        let mounted = ShellDetailMemory.mounted(visited: visited, selected: tab, layout: layout)
        ZStack {
            ForEach(mounted, id: \.self) { place in
                let isFront = place == tab
                ShellDetailPage(tab: place)
                    .environment(\.hlShellPlaceIsFront, isFront)
                    .opacity(isFront ? 1 : 0)
                    .allowsHitTesting(isFront)
                    .accessibilityHidden(!isFront)
                    .zIndex(isFront ? 1 : 0)
            }
        }
        .onChange(of: mounted, initial: true) { _, now in
            visited = now
        }
    }
}

/// Which places the detail keeps mounted. A pure function, so the rule is
/// testable without rendering.
enum ShellDetailMemory {
    /// The places visited so far, in the order of the first visit, with
    /// `selected` added; places the layout no longer builds are dropped.
    /// Log is never a place of its own (a regular window has no Log tab).
    nonisolated static func mounted(
        visited: [AuthenticatedShell.TabIdentifier],
        selected: AuthenticatedShell.TabIdentifier,
        layout: ShellLayout
    ) -> [AuthenticatedShell.TabIdentifier] {
        let target = selected == .measure ? .home : selected
        var places = visited.filter { isBuilt($0, in: layout) }
        if !places.contains(target) { places.append(target) }
        return places
    }

    /// Whether the regular layout builds `place`.
    nonisolated static func isBuilt(_ place: AuthenticatedShell.TabIdentifier, in layout: ShellLayout) -> Bool {
        switch place {
        case .measure: false
        case .home, .meds, .insights, .more: true
        case let .section(destination): layout.visibleSections.contains(destination)
        }
    }
}

/// One place of the detail.
private struct ShellDetailPage: View {
    let tab: AuthenticatedShell.TabIdentifier

    var body: some View {
        switch tab {
        // A regular window has no Log place; the router never selects it.
        case .home, .measure:
            DashboardScreen()
        case .meds:
            MedicationsScreen()
        case .insights:
            InsightsContainerScreen()
        case .more:
            MoreScreen()
        case let .section(destination):
            SidebarDestinationStack(destination: destination)
        }
    }
}

extension EnvironmentValues {
    /// Whether the page is the one the detail shows. Pages kept mounted
    /// behind it read `false`; everywhere else it is `true`.
    @Entry var hlShellPlaceIsFront = true
}
