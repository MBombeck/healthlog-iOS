import SwiftUI

/// The published measures of the tab header.
public enum HLTabHeaderMetrics {
    /// Least height of the title line. It is the height of an icon button, so
    /// the title's top edge is the same with and without actions.
    public static let titleLineHeight: CGFloat = HLLayout.iconButton
    /// How far a word of the title may shrink. Below four fifths a title
    /// stands visibly smaller than the titles of the tabs beside it, so from
    /// there on the actions move under the title or the word breaks once.
    public static let minimumTitleScale: CGFloat = 0.8
    /// Gap between two actions that stand on their own. Inside the header's
    /// glass group the symbols touch, the group is one surface.
    public static let actionGap: CGFloat = HLSpace.sm
    /// The most symbols the group shows; past that the inner ones fold into
    /// "More".
    public static let maxVisibleActions = 3
    /// Gap between the title and the actions beside it.
    public static let titleActionGap: CGFloat = HLSpace.md
    /// Gap between the title and the actions under it.
    public static let stackedGap: CGFloat = HLSpace.sm
    /// Gap between the title line and the line under it.
    public static let subtitleGap: CGFloat = HLSpace.xxs

    /// Whether the actions keep the title's line: only while the longest
    /// word, shrunk as far as it may, still fits beside them.
    public nonisolated static func actionsBesideTitle(
        width: CGFloat,
        actionsWidth: CGFloat,
        longestWordWidth: CGFloat
    ) -> Bool {
        guard actionsWidth > 0 else { return true }
        return longestWordWidth * minimumTitleScale <= width - actionsWidth - titleActionGap
    }

    /// Whether a word, shrunk as far as it may, fits a line of this width.
    /// A word that does not may break once, so it is never cut off.
    public nonisolated static func wordFitsLine(_ wordWidth: CGFloat, width: CGFloat) -> Bool {
        wordWidth * minimumTitleScale <= width
    }

    /// The width a word of the title takes at full size, at a text size.
    @MainActor
    public static func naturalWidth(of word: String, typeSize: DynamicTypeSize) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(typeSize))
        let size = UIFont.preferredFont(forTextStyle: .largeTitle, compatibleWith: traits).pointSize
        let font = UIFont.systemFont(ofSize: size, weight: .bold)
        return ceil((word as NSString).size(withAttributes: [.font: font]).width)
    }
}

/// How the title of a tab header becomes the words it is set in.
public enum HLTabHeaderTitle {
    /// The title in the language of the surrounding view.
    public static func resolved(_ title: LocalizedStringResource, locale: Locale) -> String {
        var resource = title
        resource.locale = locale
        return String(localized: resource)
    }

    /// The pieces a title may be broken into.
    public static func words(of title: String) -> [String] {
        title.split(whereSeparator: \.isWhitespace).map(String.init)
    }
}

/// The head of a tab or of a page built like one: large title, an optional
/// line under it, actions at the trailing edge.
///
/// It is the first element of an ``HLPage`` and brings no margin of its own,
/// so the title has the same top edge and the same indent on every tab. In a
/// `List` it stands as the first row with ``SwiftUI/View/hlTabHeaderListRow()``.
/// The header carries title and subtitle. In a compact width its actions
/// stand in **one** glass group beside the title (placement `.inline`), so
/// the title keeps the top line of the page and the bar stays empty. In a
/// regular width they stand in the system bar, on a tab root as on a pushed
/// page (placement `.bar`, ``HLTabHeaderActionPlacement``). Built from
/// ``HLTabHeaderActions`` they take the fixed order (info, page setting,
/// coach, add); beside the title the symbols stand without circles of their
/// own and fold into "More" past three. Whatever else stands at the top of a tab (a greeting,
/// a chip bar) is content under the header.
///
/// The title breaks between words and never inside one; a word that is still
/// too wide shrinks. When the longest word, shrunk as far as it may, does not
/// fit beside the actions, the actions move under the title, as they always
/// do in accessibility sizes: right under the title's last line, at the
/// trailing edge, on every page in the same place, with a line under the
/// title following below them. A word too wide even for the whole line
/// breaks once rather than being cut off.
///
/// A title made at run time (a marker's name) is passed as
/// `LocalizedStringResource(String.LocalizationValue(name))`; without an
/// entry in the catalogue it is shown as it is. The title is one static text
/// for VoiceOver and UI tests, `titleIdentifier` names it.
public struct HLTabHeader<Actions: View>: View {
    private let title: LocalizedStringResource
    private let subtitle: LocalizedStringKey?
    private let titleIdentifier: String?
    private let subtitleAccessibilityLabel: Text?
    private let actions: Actions
    /// Whether the header has actions at all.
    private let showsActions: Bool
    /// Typed actions go to the bar the way a pushed page puts them there.
    private let typedActions: HLTabHeaderActions?

    @Environment(\.hlTabHeaderActionPlacement) private var requestedPlacement
    @Environment(\.horizontalSizeClass) private var sizeClass

    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .largeTitle) private var wordGap: CGFloat = HLSpace.sm
    @State private var lineWidth: CGFloat?

    public init(
        _ title: LocalizedStringResource,
        subtitle: LocalizedStringKey? = nil,
        titleIdentifier: String? = nil,
        subtitleAccessibilityLabel: Text? = nil,
        @ViewBuilder actions: () -> Actions = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.titleIdentifier = titleIdentifier
        self.subtitleAccessibilityLabel = subtitleAccessibilityLabel
        self.actions = actions()
        showsActions = Actions.self != EmptyView.self
        typedActions = nil
    }

    /// A header whose actions are typed: they stand in the fixed order and
    /// fold into "More" past three (``HLTabHeaderActions``). `.none` is the
    /// header of a pushed page, whose actions belong in the system bar.
    init(
        _ title: LocalizedStringResource,
        subtitle: LocalizedStringKey? = nil,
        titleIdentifier: String? = nil,
        subtitleAccessibilityLabel: Text? = nil,
        actions: HLTabHeaderActions
    ) where Actions == HLTabHeaderActionGroup {
        self.title = title
        self.subtitle = subtitle
        self.titleIdentifier = titleIdentifier
        self.subtitleAccessibilityLabel = subtitleAccessibilityLabel
        self.actions = HLTabHeaderActionGroup(actions: actions)
        showsActions = !actions.items.isEmpty
        typedActions = actions
    }

    private var actionPlacement: HLTabHeaderActionPlacement {
        requestedPlacement.resolved(sizeClass: sizeClass)
    }

    /// Whether the actions stand beside the title instead of in the bar.
    private var actionsInline: Bool {
        showsActions && actionPlacement == .inline
    }

    public var body: some View {
        let text = HLTabHeaderTitle.resolved(title, locale: locale)
        let words = HLTabHeaderTitle.words(of: text)
        let longestWord = words.map { HLTabHeaderMetrics.naturalWidth(of: $0, typeSize: dynamicTypeSize) }.max() ?? 0
        HLTabHeaderLayout(
            alwaysStacked: dynamicTypeSize.isAccessibilitySize,
            longestWordWidth: longestWord,
            hasActions: actionsInline
        ) {
            // The layout keeps the least height of the title line, so a line
            // under a one-line title starts right under the title's words.
            titleLine(text: text, words: words)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            // An empty row would still take its gap in the stacked form.
            if actionsInline {
                HLTabHeaderGlassGroup {
                    actions
                }
            }
            if let subtitle {
                Text(subtitle)
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .modifier(HLOptionalAccessibilityLabel(label: subtitleAccessibilityLabel))
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { lineWidth = $0 }
        .modifier(HLTabHeaderBarActions(
            isActive: showsActions && actionPlacement == .bar,
            typed: typedActions,
            actions: actions
        ))
    }

    private func titleLine(text: String, words: [String]) -> some View {
        HLFlowLayout(spacing: wordGap, lineSpacing: 0) {
            ForEach(Array(words.enumerated()), id: \.offset) { _, word in
                Text(verbatim: word)
                    .font(.hlLargeTitle)
                    .foregroundStyle(HLText.primary)
                    .lineLimit(breaks(word) ? 2 : 1)
                    .minimumScaleFactor(HLTabHeaderMetrics.minimumTitleScale)
            }
        }
        // The words merge into one static text, spoken as the whole title.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: text))
        .accessibilityAddTraits(.isHeader)
        .modifier(HLOptionalIdentifier(identifier: titleIdentifier))
    }

    /// Only a word too wide for the whole line, shrunk as far as it may.
    private func breaks(_ word: String) -> Bool {
        guard let lineWidth, lineWidth > 0 else { return false }
        return !HLTabHeaderMetrics.wordFitsLine(
            HLTabHeaderMetrics.naturalWidth(of: word, typeSize: dynamicTypeSize),
            width: lineWidth
        )
    }
}

/// The one glass surface of a tab header's actions: a capsule as high as an
/// icon button, the symbols side by side in it. The buttons read
/// ``SwiftUI/EnvironmentValues/hlInHeaderActionGroup`` and leave out their own
/// circle, so there is never glass on glass.
struct HLTabHeaderGlassGroup<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        HLGlassEffectContainer(spacing: HLTabHeaderMetrics.actionGap) {
            HStack(spacing: 0) {
                content()
            }
            .environment(\.hlInHeaderActionGroup, true)
            .hlGlassEffect(in: Capsule(), interactive: true, fallback: HLColor.backgroundEleva)
        }
    }
}

private struct HLInHeaderActionGroupKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// `true` inside the glass group of a tab header: an icon button there
    /// draws its symbol only, the group draws the glass.
    var hlInHeaderActionGroup: Bool {
        get { self[HLInHeaderActionGroupKey.self] }
        set { self[HLInHeaderActionGroupKey.self] = newValue }
    }
}

/// Title and actions side by side while the title's longest word fits beside
/// the actions, else the actions under the title, at the trailing edge. A
/// line under the title stays in the title's column beside the actions and
/// follows the actions when they stand under the title, so the actions are
/// always the same distance from the title.
///
/// Subviews in order: the title, the actions when `hasActions`, the line
/// under the title when there is one.
struct HLTabHeaderLayout: Layout {
    let alwaysStacked: Bool
    let longestWordWidth: CGFloat
    var hasActions = true

    /// Where each part stands, for a width.
    struct Frames: Equatable {
        var title: CGRect
        var actions: CGRect?
        var subtitle: CGRect?

        var size: CGSize {
            let parts = [title, actions, subtitle].compactMap(\.self)
            return CGSize(
                width: parts.map(\.maxX).max() ?? 0,
                height: max(parts.map(\.maxY).max() ?? 0, HLTabHeaderMetrics.titleLineHeight)
            )
        }
    }

    private func frames(width proposedWidth: CGFloat?, subviews: Subviews) -> Frames {
        guard let titleView = subviews.first else { return Frames(title: .zero) }
        let actionsView = hasActions && subviews.count > 1 ? subviews[1] : nil
        let subtitleIndex = actionsView == nil ? 1 : 2
        let subtitleView = subviews.count > subtitleIndex ? subviews[subtitleIndex] : nil
        let actionsSize = actionsView?.sizeThatFits(.unspecified) ?? .zero

        let beside: Bool = {
            guard actionsView != nil, !alwaysStacked else { return actionsView == nil }
            guard let proposedWidth else { return true }
            return HLTabHeaderMetrics.actionsBesideTitle(
                width: proposedWidth,
                actionsWidth: actionsSize.width,
                longestWordWidth: longestWordWidth
            )
        }()

        if beside {
            let besideActions = actionsView == nil ? 0 : actionsSize.width + HLTabHeaderMetrics.titleActionGap
            let columnWidth = proposedWidth.map { max(0, $0 - besideActions) }
            let title = titleView.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil))
            let column = columnWidth ?? title.width
            var result = Frames(title: CGRect(origin: .zero, size: CGSize(width: column, height: title.height)))
            if actionsView != nil {
                result.actions = CGRect(origin: CGPoint(x: column + HLTabHeaderMetrics.titleActionGap, y: 0), size: actionsSize)
            }
            if let subtitleView {
                let line = subtitleView.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil))
                result.subtitle = CGRect(
                    origin: CGPoint(x: 0, y: title.height + HLTabHeaderMetrics.subtitleGap),
                    size: CGSize(width: column, height: line.height)
                )
            }
            return result
        }

        let title = titleView.sizeThatFits(ProposedViewSize(width: proposedWidth, height: nil))
        let width = proposedWidth ?? max(title.width, actionsSize.width)
        var result = Frames(title: CGRect(origin: .zero, size: CGSize(width: width, height: title.height)))
        let titleLine = max(title.height, HLTabHeaderMetrics.titleLineHeight)
        let actionsFrame = CGRect(
            origin: CGPoint(x: width - actionsSize.width, y: titleLine + HLTabHeaderMetrics.stackedGap),
            size: actionsSize
        )
        result.actions = actionsFrame
        if let subtitleView {
            let line = subtitleView.sizeThatFits(ProposedViewSize(width: proposedWidth, height: nil))
            result.subtitle = CGRect(
                origin: CGPoint(x: 0, y: actionsFrame.maxY + HLTabHeaderMetrics.subtitleGap),
                size: CGSize(width: width, height: line.height)
            )
        }
        return result
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let layout = frames(width: proposal.width, subviews: subviews)
        return CGSize(width: proposal.width ?? layout.size.width, height: layout.size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let layout = frames(width: bounds.width, subviews: subviews)
        var index = 0
        func place(_ frame: CGRect) {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
            index += 1
        }
        guard !subviews.isEmpty else { return }
        place(layout.title)
        if hasActions, subviews.count > 1, let actions = layout.actions { place(actions) }
        if index < subviews.count, let subtitle = layout.subtitle { place(subtitle) }
    }
}

/// Where a tab header puts its actions.
public enum HLTabHeaderActionPlacement: Sendable {
    /// In one glass group beside the title, in the content.
    case inline
    /// In the system bar, like every other page: one place for actions on
    /// every page, and no glass in the content layer.
    case bar
    /// Nowhere: a page of a pager that is not the one on screen, so only the
    /// active page writes its actions into the shared bar.
    case hidden
}

public extension HLTabHeaderActionPlacement {
    /// The placement a header uses in a width. In a compact width the actions
    /// always stand beside the title: a symbol in the bar would open an empty
    /// line above the large title and push it down by a bar's height. In the
    /// content they also stay with every pager page and every list row, where
    /// the bar would lose them. A regular width keeps the requested placement.
    nonisolated func resolved(sizeClass: UserInterfaceSizeClass?) -> HLTabHeaderActionPlacement {
        sizeClass == .compact ? .inline : self
    }
}

public extension EnvironmentValues {
    /// Where the tab headers under this view put their actions in a regular
    /// width (a compact width always puts them beside the title, see
    /// ``HLTabHeaderActionPlacement/resolved(sizeClass:)``). In the bar on
    /// every page; a page that hides its bar sets `.inline`, the inactive
    /// pages of a pager and list rows `.hidden`.
    @Entry var hlTabHeaderActionPlacement: HLTabHeaderActionPlacement = .bar
}

/// Hands a tab header's actions to the system bar: typed actions through
/// ``SwiftUI/View/hlPageActions(_:)``, free ones as one trailing group whose
/// buttons draw their symbol only, because the bar draws the glass.
private struct HLTabHeaderBarActions<Actions: View>: ViewModifier {
    let isActive: Bool
    let typed: HLTabHeaderActions?
    let actions: Actions

    func body(content: Content) -> some View {
        if !isActive {
            content
        } else if let typed {
            content.hlPageActions(typed)
        } else {
            content.toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    actions.environment(\.hlInHeaderActionGroup, true)
                }
            }
        }
    }
}

extension View {
    /// A tab root's typed actions in the system bar, in a regular width only;
    /// a compact width shows them beside the title of the header. For a
    /// header that is a list row, where the row cannot hold the bar.
    func hlTabRootBarActions(_ actions: HLTabHeaderActions) -> some View {
        modifier(HLTabRootBarActions(actions: actions))
    }
}

public extension View {
    /// Free tab header actions (icon buttons) in the system bar, hung on the
    /// screen's container rather than on the header: one trailing group whose
    /// buttons draw their symbol only, because the bar draws the glass. For a
    /// header that is a list row, where the row cannot hold the bar.
    func hlHeaderBarActions(@ViewBuilder _ actions: () -> some View) -> some View {
        let actions = actions()
        return toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                actions.environment(\.hlInHeaderActionGroup, true)
            }
        }
    }
}

/// See ``SwiftUI/View/hlTabRootBarActions(_:)``.
private struct HLTabRootBarActions: ViewModifier {
    let actions: HLTabHeaderActions
    @Environment(\.horizontalSizeClass) private var sizeClass

    func body(content: Content) -> some View {
        if HLTabHeaderActionPlacement.bar.resolved(sizeClass: sizeClass) == .bar {
            content.hlPageActions(actions)
        } else {
            content
        }
    }
}

/// Sets an accessibility identifier only when there is one.
struct HLOptionalIdentifier: ViewModifier {
    let identifier: String?

    func body(content: Content) -> some View {
        if let identifier {
            content.accessibilityIdentifier(identifier)
        } else {
            content
        }
    }
}

/// Sets a spoken label only when there is one.
struct HLOptionalAccessibilityLabel: ViewModifier {
    let label: Text?

    func body(content: Content) -> some View {
        if let label {
            content.accessibilityLabel(label)
        } else {
            content
        }
    }
}

public extension View {
    /// A tab header as the first row of a `List`: no row surface, no line,
    /// no insets of its own, its top edge at the top of the row. With
    /// `hlPageMargins()` on the list the title stands where it stands on an
    /// ``HLPage``: 16 pt in, 12 pt under the top of the content.
    func hlTabHeaderListRow() -> some View {
        // Its own section with no spacing after it: the head's own card gap
        // is the only room between the head and the list's first element.
        // The head is the section's header, not a row: an inset-grouped list
        // clips each row to the section's rounded corners, which cut the
        // first letter of a large title standing on the row's edge.
        Section {
            EmptyView()
        } header: {
            tabHeaderListRowContent()
                .textCase(nil)
        }
        .listSectionSpacing(0)
    }

    private func tabHeaderListRowContent() -> some View {
        // A list row is torn down when it scrolls away, and with it what it
        // gave the bar. Its actions therefore never go from the row into the
        // bar; in a regular width the screen hangs them on the list
        // (`hlTabRootBarActions`). In a compact width they stand in the row.
        environment(\.hlTabHeaderActionPlacement, .hidden)
            .tabHeaderListRowLayout()
    }
}

private extension View {
    func tabHeaderListRowLayout() -> some View {
        // The list centres a row in its least height; the head keeps its top
        // edge instead. The room above comes from `hlPageMargins()`. Below
        // the head the row keeps a card gap of its own and the list adds
        // none, so the first card stands 16 pt and the first section header
        // 24 pt under the title, as on a page, at every title height.
        padding(.bottom, HLLayout.cardGap)
            .frame(minHeight: HLLayout.rowPitch, alignment: .top)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}

#Preview("HLTabHeader, light") {
    HLTabHeaderPreview()
        .preferredColorScheme(.light)
}

#Preview("HLTabHeader, dark") {
    HLTabHeaderPreview()
        .preferredColorScheme(.dark)
}

#Preview("HLTabHeader, largest type") {
    HLTabHeaderPreview()
        .dynamicTypeSize(.accessibility5)
}

private struct HLTabHeaderPreview: View {
    var body: some View {
        HLPage {
            HLTabHeader("Medications", subtitle: "Daily") {
                HLIconButton(systemImage: "plus", label: HLControlWord.add.key, style: .bar) {}
                HLIconButton(systemImage: "gearshape", label: "Settings", style: .bar) {}
            }
            HLCard("Overview", layout: .rows) {
                HLRowLayout(title: "Blood pressure", indicator: .disclosure)
            }
            HLTabHeader("More")
            HLCard("Notes", layout: .rows) {
                HLRowLayout(title: "Weight", indicator: .disclosure)
            }
        }
    }
}
