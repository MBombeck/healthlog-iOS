import SwiftUI

/// One action in a tab header or in the bar of a pushed page. Its role fixes
/// its place: from the title outwards info, page setting, filter, select,
/// share, coach, more, add, so every page puts the same symbol in the same
/// spot.
struct HLTabHeaderAction: Identifiable {
    /// The place in the group, inner to outer.
    enum Role: Int, CaseIterable, Comparable, Sendable {
        /// The (i): what the page shows and where its numbers come from.
        case info
        /// The page's own setting (`slider.horizontal.3`): a target range,
        /// the cards shown. Never "Edit".
        case settings
        /// What the list shows (`line.3.horizontal.decrease`), always in the
        /// bar, never in the content.
        case filter
        /// Choosing several entries (`checklist`).
        case select
        /// Sharing the page's object (`square.and.arrow.up`).
        case share
        /// The coach (`sparkles`).
        case coach
        /// Everything else (`ellipsis`): edit, export, delete. Edit is an
        /// entry here unless the page has no other action.
        case more
        /// A new entry (`plus`), always at the trailing edge.
        case add

        static func < (lhs: Role, rhs: Role) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// What a tap does.
    enum Kind {
        case button(() -> Void)
        case menu(AnyView)
        case info(HLInfoContent)
        /// A control that brings its own button (a share link); it is shown
        /// as it is, in the bar and in "More".
        case control(AnyView)
    }

    let role: Role
    let systemImage: String
    let label: LocalizedStringKey
    let identifier: String?
    let isSelected: Bool
    let kind: Kind

    var id: Role {
        role
    }

    /// The (i) of the page. Renders nothing when the content has nothing to say.
    static func info(_ content: HLInfoContent, identifier: String) -> HLTabHeaderAction {
        HLTabHeaderAction(
            role: .info,
            systemImage: "info.circle",
            label: "info.button.a11y \(content.title)",
            identifier: identifier,
            isSelected: false,
            kind: .info(content)
        )
    }

    /// The page's setting. `isSelected` when it is set away from the default
    /// (a filter in force).
    static func settings(
        label: LocalizedStringKey,
        identifier: String? = nil,
        isSelected: Bool = false,
        action: @escaping () -> Void
    ) -> HLTabHeaderAction {
        HLTabHeaderAction(
            role: .settings,
            systemImage: "slider.horizontal.3",
            label: label,
            identifier: identifier,
            isSelected: isSelected,
            kind: .button(action)
        )
    }

    /// The page's setting as a menu of choices.
    static func settingsMenu(
        label: LocalizedStringKey,
        identifier: String? = nil,
        isSelected: Bool = false,
        @ViewBuilder menu: () -> some View
    ) -> HLTabHeaderAction {
        HLTabHeaderAction(
            role: .settings,
            systemImage: "slider.horizontal.3",
            label: label,
            identifier: identifier,
            isSelected: isSelected,
            kind: .menu(AnyView(menu()))
        )
    }

    /// The coach of the page.
    static func coach(identifier: String? = nil, action: @escaping () -> Void) -> HLTabHeaderAction {
        HLTabHeaderAction(
            role: .coach,
            systemImage: "sparkles",
            label: "Ask the coach",
            identifier: identifier,
            isSelected: false,
            kind: .button(action)
        )
    }

    /// A new entry, at the trailing edge.
    static func add(
        label: LocalizedStringKey,
        identifier: String? = nil,
        action: @escaping () -> Void
    ) -> HLTabHeaderAction {
        HLTabHeaderAction(
            role: .add,
            systemImage: "plus",
            label: label,
            identifier: identifier,
            isSelected: false,
            kind: .button(action)
        )
    }

    /// The filter of a list, as a menu of choices. `isSelected` while a
    /// filter is set, so the symbol shows it filled.
    static func filter(
        label: LocalizedStringKey = "Filters",
        identifier: String? = nil,
        isSelected: Bool = false,
        @ViewBuilder menu: () -> some View
    ) -> HLTabHeaderAction {
        HLTabHeaderAction(
            role: .filter,
            systemImage: "line.3.horizontal.decrease",
            label: label,
            identifier: identifier,
            isSelected: isSelected,
            kind: .menu(AnyView(menu()))
        )
    }

    /// Choosing several entries; the symbol is filled while choosing.
    @MainActor
    static func select(isOn: Binding<Bool>, identifier: String? = nil) -> HLTabHeaderAction {
        HLTabHeaderAction(
            role: .select,
            systemImage: "checklist",
            label: "Select",
            identifier: identifier,
            isSelected: isOn.wrappedValue,
            kind: .button { isOn.wrappedValue.toggle() }
        )
    }

    /// Sharing a file or a link through the system's share sheet.
    @MainActor
    static func share(item: URL, label: LocalizedStringKey = "Share", identifier: String? = nil) -> HLTabHeaderAction {
        shareAction(AnyView(ShareLink(item: item) { Label(label, systemImage: shareSymbol) }), label: label, identifier: identifier)
    }

    /// Sharing a text through the system's share sheet.
    @MainActor
    static func share(text: String, label: LocalizedStringKey = "Share", identifier: String? = nil) -> HLTabHeaderAction {
        shareAction(AnyView(ShareLink(item: text) { Label(label, systemImage: shareSymbol) }), label: label, identifier: identifier)
    }

    static let shareSymbol = "square.and.arrow.up"

    private static func shareAction(_ link: AnyView, label: LocalizedStringKey, identifier: String?) -> HLTabHeaderAction {
        HLTabHeaderAction(
            role: .share,
            systemImage: shareSymbol,
            label: label,
            identifier: identifier,
            isSelected: false,
            kind: .control(link)
        )
    }

    /// "More": edit, export, delete and the rest, in one menu.
    static func more(
        label: LocalizedStringKey = "More",
        identifier: String? = nil,
        @ViewBuilder menu: () -> some View
    ) -> HLTabHeaderAction {
        HLTabHeaderAction(
            role: .more,
            systemImage: "ellipsis",
            label: label,
            identifier: identifier,
            isSelected: false,
            kind: .menu(AnyView(menu()))
        )
    }

    /// Edit as the page's only action: the pencil directly. A page with
    /// other actions puts Edit into ``more(label:identifier:menu:)``.
    static func edit(identifier: String? = nil, action: @escaping () -> Void) -> HLTabHeaderAction {
        HLTabHeaderAction(
            role: .more,
            systemImage: "pencil",
            label: HLControlWord.edit.key,
            identifier: identifier,
            isSelected: false,
            kind: .button(action)
        )
    }

    /// A new entry of one of several kinds.
    static func addMenu(
        label: LocalizedStringKey,
        identifier: String? = nil,
        @ViewBuilder menu: () -> some View
    ) -> HLTabHeaderAction {
        HLTabHeaderAction(
            role: .add,
            systemImage: "plus",
            label: label,
            identifier: identifier,
            isSelected: false,
            kind: .menu(AnyView(menu()))
        )
    }
}

/// The actions of a tab header, in the order the roles fix.
struct HLTabHeaderActions: ExpressibleByArrayLiteral {
    let items: [HLTabHeaderAction]

    /// No actions: the header of a page pushed onto a stack, whose actions
    /// stand in the system bar.
    static var none: HLTabHeaderActions {
        HLTabHeaderActions([])
    }

    init(_ items: [HLTabHeaderAction]) {
        // One per role, the first one given wins; then the fixed order.
        var seen: Set<HLTabHeaderAction.Role> = []
        self.items = items.filter { seen.insert($0.role).inserted }.sorted { $0.role < $1.role }
    }

    init(arrayLiteral elements: HLTabHeaderAction...) {
        self.init(elements)
    }

    /// Which roles show as symbols and which fold into "More". Up to
    /// ``HLTabHeaderMetrics/maxVisibleActions`` all show; past that the
    /// outer ones (coach, add) keep their symbols and the inner ones go into
    /// the menu, which takes the innermost place.
    static func arrangement(
        of roles: [HLTabHeaderAction.Role],
        limit: Int = HLTabHeaderMetrics.maxVisibleActions
    ) -> (visible: [HLTabHeaderAction.Role], folded: [HLTabHeaderAction.Role]) {
        let ordered = roles.sorted()
        guard ordered.count > limit else { return (ordered, []) }
        let kept = max(limit - 1, 0)
        return (Array(ordered.suffix(kept)), Array(ordered.prefix(ordered.count - kept)))
    }
}

/// The symbols of a typed tab header. The header puts them into its glass
/// group; this view only orders them and builds "More".
struct HLTabHeaderActionGroup: View {
    let actions: HLTabHeaderActions
    @State private var shownInfo: HLInfoContent?

    /// The symbol of the folded actions: the bare ellipsis, as in the system bar.
    static let moreSymbol = "ellipsis"

    var body: some View {
        let arrangement = HLTabHeaderActions.arrangement(of: actions.items.map(\.role))
        let folded = actions.items.filter { arrangement.folded.contains($0.role) }
        if !folded.isEmpty {
            HLIconButton(systemImage: Self.moreSymbol, label: "More", style: .bar, menu: {
                ForEach(folded) { item in
                    menuEntry(item)
                }
            })
            .accessibilityIdentifier("hl.tabHeader.more")
            .sheet(item: $shownInfo) { content in
                HLInfoSheet(content: content)
            }
        }
        ForEach(actions.items.filter { arrangement.visible.contains($0.role) }) { item in
            symbol(item)
        }
    }

    private func symbol(_ item: HLTabHeaderAction) -> some View {
        symbolContent(item).modifier(HLActionZoomSource(role: AnyHashable(item.role)))
    }

    @ViewBuilder
    private func symbolContent(_ item: HLTabHeaderAction) -> some View {
        switch item.kind {
        case let .button(action):
            HLIconButton(systemImage: item.systemImage, label: item.label, style: .bar, isSelected: item.isSelected, action: action)
                .modifier(HLOptionalIdentifier(identifier: item.identifier))
        case let .menu(menu):
            HLIconButton(systemImage: item.systemImage, label: item.label, style: .bar, isSelected: item.isSelected, menu: { menu })
                .modifier(HLOptionalIdentifier(identifier: item.identifier))
        case let .info(content):
            HLInfoButton(content: content, style: .circle, accessibilityIdentifier: item.identifier ?? content.identifier)
        case let .control(view):
            view
                .labelStyle(.iconOnly)
                .font(.hlTitle3)
                .foregroundStyle(HLText.secondary)
                .frame(width: HLIconButton.baseSide, height: HLIconButton.baseSide)
                .modifier(HLOptionalIdentifier(identifier: item.identifier))
        }
    }

    @ViewBuilder
    private func menuEntry(_ item: HLTabHeaderAction) -> some View {
        switch item.kind {
        case let .button(action):
            Button(action: action) { Label(item.label, systemImage: item.systemImage) }
        case let .menu(menu):
            Menu { menu } label: { Label(item.label, systemImage: item.systemImage) }
        case let .info(content):
            if !content.isEmpty {
                Button { shownInfo = content } label: { Label(item.label, systemImage: item.systemImage) }
            }
        case let .control(view):
            view
        }
    }
}

// MARK: - Pushed pages

extension View {
    /// The bar actions of a pushed page, in the same order as a tab header:
    /// one group at the trailing edge of the navigation bar, from the title
    /// outwards info, setting, filter, select, share, coach, more, add. The
    /// system draws the glass around the group. No `.tint`, no
    /// `.primaryAction`, no own back button.
    func hlPageActions(_ actions: HLTabHeaderActions) -> some View {
        modifier(HLPageActions(actions: actions))
    }
}

/// See ``SwiftUI/View/hlPageActions(_:)``.
struct HLPageActions: ViewModifier {
    let actions: HLTabHeaderActions

    func body(content: Content) -> some View {
        let split = Self.split(actions)
        content.toolbar {
            if !split.group.isEmpty {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    ForEach(split.group) { item in
                        HLPageActionItem(item: item)
                    }
                }
                .hlVisibilityPriority(.standard)
            }
            // The page's main action is the last to fold away when the
            // window narrows; it stays the outermost symbol.
            if let primary = split.primary {
                ToolbarItem(placement: .topBarTrailing) {
                    HLPageActionItem(item: primary)
                }
                .hlVisibilityPriority(.primary)
            }
        }
    }

    /// The add action on its own, the others as one group in their order.
    static func split(_ actions: HLTabHeaderActions) -> (group: [HLTabHeaderAction], primary: HLTabHeaderAction?) {
        let primary = actions.items.last { $0.role == .add }
        return (actions.items.filter { $0.role != .add }, primary)
    }
}

/// One symbol in the bar of a pushed page.
struct HLPageActionItem: View {
    let item: HLTabHeaderAction

    var body: some View {
        content.modifier(HLActionZoomSource(role: AnyHashable(item.role)))
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case let .button(action):
            Button(action: action) { symbol }
                .accessibilityLabel(Text(item.label))
                .accessibilityAddTraits(item.isSelected ? .isSelected : [])
                .modifier(HLOptionalIdentifier(identifier: item.identifier))
        case let .menu(menu):
            Menu { menu } label: { symbol }
                .accessibilityLabel(Text(item.label))
                .accessibilityAddTraits(item.isSelected ? .isSelected : [])
                .modifier(HLOptionalIdentifier(identifier: item.identifier))
        case let .info(content):
            HLInfoButton(content: content, style: .toolbar, accessibilityIdentifier: item.identifier ?? content.identifier)
        case let .control(view):
            view
                .modifier(HLOptionalIdentifier(identifier: item.identifier))
        }
    }

    private var symbol: some View {
        Label(item.label, systemImage: item.systemImage)
            .symbolVariant(item.isSelected ? .fill : .none)
    }
}

extension HLInfoContent: Identifiable {
    var id: String {
        identifier
    }
}
