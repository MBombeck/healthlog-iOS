import SwiftUI

/// What the container around an element already puts above and below it.
///
/// A section header wants 24 pt above and 8 pt below itself. Inside a page
/// the stack's own gap is already there, so the header adds or takes back
/// only the difference. The page says what its gap is; a header that hears
/// nothing assumes nothing and brings its full room as real spacing.
public struct HLContainerGap: Equatable, Sendable {
    public var before: CGFloat
    public var after: CGFloat

    public init(before: CGFloat, after: CGFloat) {
        self.before = before
        self.after = after
    }

    /// A container that says nothing: a foreign stack, a plain list.
    public static let none = HLContainerGap(before: 0, after: 0)
}

public extension EnvironmentValues {
    /// The gap the surrounding container puts around each of its elements.
    @Entry var hlContainerGap: HLContainerGap = .none
}

public extension View {
    /// States the gap a hand-built stack puts between its elements, so a
    /// section header inside it keeps its 24 and 8 pt:
    /// `VStack(spacing: 12) { … }.hlContainerGap(12)`.
    func hlContainerGap(_ spacing: CGFloat) -> some View {
        environment(\.hlContainerGap, HLContainerGap(before: spacing, after: spacing))
    }
}

/// How a page lays out its blocks.
public enum HLPageColumns: Equatable, Sendable {
    /// One column, as on the phone.
    case single
    /// `primary` and `secondary` side by side once the page's measured width
    /// reaches ``HLLayout/sideBySideMinimum``, one under the other below it.
    case sideBySide

    /// How the two blocks stand at a measured content width.
    public enum Arrangement: Equatable, Sendable {
        case stacked
        case sideBySide
    }

    /// The arrangement at `width`, the width the page's content gets. A
    /// single-column page always stacks.
    public func arrangement(width: CGFloat) -> Arrangement {
        guard self == .sideBySide, width >= HLLayout.sideBySideMinimum else { return .stacked }
        return .sideBySide
    }

    /// The accessibility sort priority of a column: side by side the leading
    /// column goes first; a single column keeps 0, the order on screen.
    public func readingPriority(leading: Bool) -> Double {
        self == .sideBySide && leading ? 1 : 0
    }

    /// Width of each of the two columns side by side: half of `width` less
    /// half the card gap between them.
    public static func columnWidth(width: CGFloat) -> CGFloat {
        max(0, (width - HLLayout.cardGap) / 2)
    }
}

/// The side margin of a page or a list at a measured width: the page margin,
/// or more where the window is wider than the readable width, so the content
/// stands centred at ``HLLayout/readableWidth``.
public enum HLPageMargins {
    /// The margin on each side at `width`, the full width of the scrolling
    /// view. `nil` (not measured yet) gives the page margin.
    public static func side(width: CGFloat?) -> CGFloat {
        guard let width else { return HLLayout.pageMargin }
        return max(HLLayout.pageMargin, (width - HLLayout.readableWidth) / 2)
    }

    /// The width the content gets between the margins.
    public static func contentWidth(width: CGFloat) -> CGFloat {
        max(0, width - 2 * side(width: width))
    }

    /// The horizontal content margins of a list. `width` is the width the
    /// list is laid out at; `scrollWidth` the width of the scroll view behind
    /// it. Beside a floating sidebar the scroll view reaches under the
    /// sidebar, counts its margins from that hidden edge and keeps its rows at
    /// least clear of the sidebar, so a leading margin smaller than the
    /// sidebar vanished and the rows stood against it. The stretch under the
    /// sidebar is therefore added to the margin on the sidebar's side: the
    /// leading one beside an iPad sidebar, the trailing one beside the
    /// upright tab bar on the outer screen of the Duo. Without a bar both
    /// widths are equal and the margins are ``side(width:)``.
    public static func listInsets(
        width: CGFloat?,
        scrollWidth: CGFloat?,
        hiddenEdge: HorizontalEdge = .leading
    ) -> (leading: CGFloat, trailing: CGFloat) {
        let side = side(width: width)
        guard let width, let scrollWidth else { return (side, side) }
        let hidden = max(0, scrollWidth - width)
        switch hiddenEdge {
        case .leading: return (hidden + side, side)
        case .trailing: return (side, hidden + side)
        }
    }

    /// The edge the scroll view reaches under a bar on, from where the list
    /// stands in its window: a list that starts clear of the window's left
    /// edge has the bar on the left. In a right-to-left layout the left edge
    /// is the trailing one.
    public static func hiddenEdge(listMinX: CGFloat, layoutDirection: LayoutDirection) -> HorizontalEdge {
        let barOnLeft = listMinX > 0.5
        return barOnLeft == (layoutDirection == .leftToRight) ? .leading : .trailing
    }

    /// The covered edge of a list in a sheet: the side with the larger safe
    /// area (the upright system column on the Duo's outer screen). A sheet
    /// stands inset in its window, so its position says nothing; with equal
    /// insets nothing is covered and the position rule decides.
    public static func hiddenEdge(
        leadingSafeArea: CGFloat,
        trailingSafeArea: CGFloat,
        listMinX: CGFloat,
        layoutDirection: LayoutDirection
    ) -> HorizontalEdge {
        if abs(leadingSafeArea - trailingSafeArea) < 0.5 {
            return hiddenEdge(listMinX: listMinX, layoutDirection: layoutDirection)
        }
        return trailingSafeArea > leadingSafeArea ? .trailing : .leading
    }
}

/// The frame of every scrolling page: one margin, one gap between cards, the
/// app background.
///
/// By default the content grows to the readable width and stands centred
/// beyond it, so a page on an iPad or an open Duo keeps the measure of the
/// phone. A page of tiles turns that off (`readable: false`) and can place
/// two blocks side by side (`columns: .sideBySide`).
///
/// The stack is eager on purpose. With a lazy stack the app froze when the
/// share page was left, the main thread stuck in `LazyStack.place`.
public struct HLPage<Content: View>: View {
    /// Insets between the page's edge and its content.
    public static var insets: EdgeInsets {
        HLLayout.pageInsets
    }

    /// Vertical gap between two elements of the page.
    public static var spacing: CGFloat {
        HLLayout.cardGap
    }

    /// The widest the content grows, `nil` for no limit.
    public static func maximumContentWidth(readable: Bool) -> CGFloat? {
        readable ? HLLayout.readableWidth : nil
    }

    private let readable: Bool
    private let content: Content

    public init(readable: Bool = true, @ViewBuilder content: () -> Content) {
        self.readable = readable
        self.content = content()
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Self.spacing) {
                content
            }
            .hlContainerGap(Self.spacing)
            // Grows up to the readable width and stays centred beyond it. Up
            // to that width the frame proposes what the stack got before.
            .frame(maxWidth: Self.maximumContentWidth(readable: readable) ?? .infinity)
            .frame(maxWidth: .infinity)
            .padding(Self.insets)
        }
        .hlScrollEdgeSoft()
        .scrollContentBackground(.hidden)
        .background(HLSurface.primary)
    }
}

public extension HLPage {
    /// A page of two blocks. With `columns: .sideBySide` they stand next to
    /// each other from ``HLLayout/sideBySideMinimum`` on, `primary` leading;
    /// below that, and with `.single`, `primary` stands above `secondary`.
    /// The second column is part of this page, never a second navigation
    /// stack.
    init<Primary: View, Secondary: View>(
        readable: Bool = true,
        columns: HLPageColumns,
        @ViewBuilder primary: () -> Primary,
        @ViewBuilder secondary: () -> Secondary
    ) where Content == HLPageColumnsContent<Primary, Secondary> {
        self.init(readable: readable) {
            HLPageColumnsContent(columns: columns, primary: primary(), secondary: secondary())
        }
    }
}

/// The two blocks of a two-column ``HLPage``.
public struct HLPageColumnsContent<Primary: View, Secondary: View>: View {
    let columns: HLPageColumns
    let primary: Primary
    let secondary: Secondary

    public var body: some View {
        HLPageColumnsLayout(columns: columns) {
            column(leading: true) { primary }
            column(leading: false) { secondary }
        }
        // One container around the pair, so the order below acts between the
        // two columns only and the page's head stays first.
        .accessibilityElement(children: .contain)
    }

    /// One column, one accessibility container. Side by side, VoiceOver and
    /// Full Keyboard Access go through the leading column to its end before
    /// the trailing one; stacked the order is the order on screen, as on the
    /// phone. (`focusSection()` does not exist on iOS.)
    private func column(leading: Bool, @ViewBuilder _ blocks: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: HLLayout.cardGap) {
            blocks()
        }
        .hlContainerGap(HLLayout.cardGap)
        .accessibilityElement(children: .contain)
        .accessibilitySortPriority(columns.readingPriority(leading: leading))
    }
}

/// Places the two columns from the width it is offered, in the same pass,
/// so nothing is stored and nothing jumps after a first frame.
struct HLPageColumnsLayout: Layout {
    let columns: HLPageColumns

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout Void) -> CGSize {
        let width = proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        switch columns.arrangement(width: width) {
        case .sideBySide:
            let column = ProposedViewSize(width: HLPageColumns.columnWidth(width: width), height: nil)
            let height = subviews.map { $0.sizeThatFits(column).height }.max() ?? 0
            return CGSize(width: width, height: height)
        case .stacked:
            let row = ProposedViewSize(width: width, height: nil)
            let heights = subviews.map { $0.sizeThatFits(row).height }
            let gaps = HLLayout.cardGap * CGFloat(max(0, visibleCount(heights) - 1))
            return CGSize(width: width, height: heights.reduce(0, +) + gaps)
        }
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout Void) {
        switch columns.arrangement(width: bounds.width) {
        case .sideBySide:
            let width = HLPageColumns.columnWidth(width: bounds.width)
            let column = ProposedViewSize(width: width, height: nil)
            for (index, subview) in subviews.enumerated() {
                let x = bounds.minX + CGFloat(index) * (width + HLLayout.cardGap)
                subview.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading, proposal: column)
            }
        case .stacked:
            let row = ProposedViewSize(width: bounds.width, height: nil)
            var y = bounds.minY
            for subview in subviews {
                let height = subview.sizeThatFits(row).height
                subview.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading, proposal: row)
                if height > 0 { y += height + HLLayout.cardGap }
            }
        }
    }

    /// An empty column takes no gap.
    private func visibleCount(_ heights: [CGFloat]) -> Int {
        heights.filter { $0 > 0 }.count
    }
}

public extension View {
    /// Gives a `List` or `Form` the margins, the row grid, the gap between
    /// sections and the background of ``HLPage``, so a system list lines up
    /// with the cards of a scrolling page. The rows take their surface and
    /// insets from `hlFormRowSurface()`.
    ///
    /// The side margins come from the list's own measured width: the page
    /// margin, and beyond the readable width as much as centres the rows at
    /// ``HLLayout/readableWidth``. The list stays full width, so it scrolls
    /// from edge to edge (``HLPageMargins/listInsets(width:scrollWidth:)``).
    func hlPageMargins() -> some View {
        modifier(HLPageMarginsModifier())
    }
}

private struct HLPageMarginsModifier: ViewModifier {
    /// The list's laid-out width and its scroll view's width. The margins it
    /// sets change neither, so the measure cannot feed back into itself.
    @State private var width: CGFloat?
    @State private var scrollWidth: CGFloat?
    /// Where the list starts in its window; tells on which side a bar hides.
    @State private var minX: CGFloat = 0
    /// The list's leading and trailing safe area; read only in a sheet.
    @State private var safeArea = EdgeInsets()
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.hlPresentedInSheet) private var inSheet

    private var hiddenEdge: HorizontalEdge {
        guard inSheet else { return HLPageMargins.hiddenEdge(listMinX: minX, layoutDirection: layoutDirection) }
        return HLPageMargins.hiddenEdge(
            leadingSafeArea: safeArea.leading, trailingSafeArea: safeArea.trailing,
            listMinX: minX, layoutDirection: layoutDirection
        )
    }

    func body(content: Content) -> some View {
        let insets = HLPageMargins.listInsets(width: width, scrollWidth: scrollWidth, hiddenEdge: hiddenEdge)
        content
            .contentMargins(.leading, insets.leading, for: .scrollContent)
            .contentMargins(.trailing, insets.trailing, for: .scrollContent)
            // The page's room above the first element, in place of the
            // list's own, so a tab header in the first row stands where it
            // stands on a page.
            .contentMargins(.top, HLLayout.pageTop, for: .scrollContent)
            .environment(\.defaultMinListRowHeight, HLLayout.rowPitch)
            // Sections stand a card gap apart, and a section header knows
            // that this gap is above it and none is below it.
            .listSectionSpacing(HLLayout.cardGap)
            .environment(\.hlContainerGap, HLContainerGap(before: HLLayout.cardGap, after: 0))
            .scrollContentBackground(.hidden)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minX } action: { minX = $0 }
            .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { safeArea = $0 }
            .onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.width } action: { _, newWidth in
                scrollWidth = newWidth
            }
            .background(HLSurface.primary)
    }
}

#Preview("HLPage, light") {
    HLPagePreview()
        .preferredColorScheme(.light)
}

#Preview("HLPage, dark") {
    HLPagePreview()
        .preferredColorScheme(.dark)
}

#Preview("HLPage, largest type") {
    HLPagePreview()
        .dynamicTypeSize(.accessibility5)
}

private struct HLPagePreview: View {
    var body: some View {
        HLPage {
            HLCard("Overview") {
                Text(verbatim: "128/82 mmHg")
                    .font(.hlBody)
            }
            HLCard("Notes") {
                Text(verbatim: "72,4 kg")
                    .font(.hlBody)
            }
        }
    }
}
