import SwiftUI

/// What a list that shows its detail beside it needs to decide, from the
/// width it measured and the text size. Pure, so the rule is tested at every
/// width without a view.
public enum HLListDetailLayout {
    /// How the list and its detail stand.
    public struct Resolution: Equatable, Sendable {
        /// The detail stands beside the list instead of being pushed.
        public let isSideBySide: Bool
        /// The width the list gets, the whole width when it stands alone.
        public let listWidth: CGFloat
    }

    /// Share of the width the list takes beside its detail.
    public static let listShare: CGFloat = 0.55
    /// The list never gets less than this beside its detail: three columns
    /// of a table still fit.
    public static let listMinimum: CGFloat = 400
    /// The list never gets more than this: a wider table is no easier to read.
    public static let listMaximum: CGFloat = 600

    /// Where the detail moves beside the list: from
    /// ``HLLayout/sideBySideMinimum`` on, while there is a detail to show, and
    /// not at the largest text sizes (accessibility 3 and up take one column).
    public static func resolve(width: CGFloat?, typeSize: DynamicTypeSize, detailAvailable: Bool = true) -> Resolution {
        guard let width, width.isFinite, width > 0 else {
            return Resolution(isSideBySide: false, listWidth: 0)
        }
        guard detailAvailable, width >= HLLayout.sideBySideMinimum, typeSize < .accessibility3 else {
            return Resolution(isSideBySide: false, listWidth: width)
        }
        return Resolution(isSideBySide: true, listWidth: listWidth(in: width))
    }

    /// The list's width in a window of `width` that has room for two.
    public static func listWidth(in width: CGFloat) -> CGFloat {
        min(listMaximum, max(listMinimum, (width * listShare).rounded()))
    }
}

/// The selection of a list that shows its detail beside it.
///
/// It belongs to the screen, not to a second navigation stack: it survives a
/// change of width, because it does not look at the width at all, and it
/// resolves to nothing the moment the selected item is gone.
public struct HLPaneSelection<ID: Hashable & Sendable>: Equatable, Sendable {
    public private(set) var selected: ID?

    public init(selected: ID? = nil) {
        self.selected = selected
    }

    public mutating func select(_ id: ID?) {
        selected = id
    }

    /// The selection as far as it still exists in `available`; `nil` when the
    /// item was deleted or filtered away.
    public func resolved(in available: [ID]) -> ID? {
        guard let selected, available.contains(selected) else { return nil }
        return selected
    }

    /// The row to mark: the selection while the detail stands beside the list,
    /// none where a tap pushes the page instead.
    public func highlighted(isSideBySide: Bool, in available: [ID]) -> ID? {
        isSideBySide ? resolved(in: available) : nil
    }

    /// The selection, or the first of `available` while there is none (a
    /// list whose detail is cheap to show starts on its first item).
    public func resolvedOrFirst(in available: [ID]) -> ID? {
        resolved(in: available) ?? available.first
    }
}

/// A list with its detail beside it from ``HLLayout/sideBySideMinimum`` on.
///
/// The container measures its own width. Below the minimum, and at the
/// largest text sizes, only the list shows and the caller pushes the detail
/// as before; beside it the detail is part of the screen, never a second
/// navigation stack. The list keeps its place in the tree in both forms, so
/// its scroll position and state survive a change of width.
public struct HLListDetail<Primary: View, Detail: View>: View {
    private let detailAvailable: Bool
    private let primary: (HLListDetailLayout.Resolution) -> Primary
    private let detail: () -> Detail

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var width: CGFloat?

    /// How many ranks the detail column's section headers step down.
    static var detailRankOffset: Int {
        1
    }

    /// `detailAvailable` is `false` while there is nothing to show beside the
    /// list (loading, empty, failed): the list then keeps the whole width.
    public init(
        detailAvailable: Bool = true,
        @ViewBuilder primary: @escaping (HLListDetailLayout.Resolution) -> Primary,
        @ViewBuilder detail: @escaping () -> Detail
    ) {
        self.detailAvailable = detailAvailable
        self.primary = primary
        self.detail = detail
    }

    /// With a width already measured, so a test can lay the container out at
    /// a known width in a single pass.
    init(
        measuredWidth: CGFloat,
        @ViewBuilder primary: @escaping (HLListDetailLayout.Resolution) -> Primary,
        @ViewBuilder detail: @escaping () -> Detail
    ) {
        self.init(primary: primary, detail: detail)
        _width = State(initialValue: measuredWidth)
    }

    public var body: some View {
        let resolution = HLListDetailLayout.resolve(
            width: width,
            typeSize: dynamicTypeSize,
            detailAvailable: detailAvailable
        )
        HStack(spacing: 0) {
            // One flexible frame in both forms (the list keeps its identity);
            // beside the detail minimum and maximum are the width the rule
            // gives, so the stack cannot hand it half the room instead.
            primary(resolution)
                .frame(
                    minWidth: resolution.isSideBySide ? resolution.listWidth : 0,
                    maxWidth: resolution.isSideBySide ? resolution.listWidth : .infinity
                )
            if resolution.isSideBySide {
                // No rule between the two: list and detail are one page on
                // one surface, each column with its page margin.
                // The detail is a part of this page: its own name is a column
                // header, its section headers step one rank down.
                detail()
                    .environment(\.hlIsDetailColumn, true)
                    .environment(\.hlSectionRankOffset, Self.detailRankOffset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

public extension View {
    /// Holds a lockup (an empty or failed state) at the reading width and
    /// centres it, so on an iPad it stands in the middle of the page and not
    /// at the edge of the window.
    func hlCenteredOnReadableWidth() -> some View {
        frame(maxWidth: HLLayout.readableWidth)
            .frame(maxWidth: .infinity)
    }
}

private struct HLIsDetailColumnKey: EnvironmentKey {
    static let defaultValue = false
}

public extension EnvironmentValues {
    /// `true` in the detail column of an ``HLListDetail``: the page there
    /// heads itself with ``HLColumnHeader`` instead of ``HLTabHeader``.
    var hlIsDetailColumn: Bool {
        get { self[HLIsDetailColumnKey.self] }
        set { self[HLIsDetailColumnKey.self] = newValue }
    }
}

/// The head of a detail column beside a list: the name of the selection in
/// the column header role, an optional line under it, no actions.
///
/// Its top edge is the top edge of the list column's first element, because
/// both columns start at ``HLLayout/pageTop``. The actions of the selection
/// stand in the page's bar (`hlPageActions`). Pushed on its own, the same
/// page heads itself with ``HLTabHeader`` and its sections keep their rank.
public struct HLColumnHeader: View {
    private let title: Text
    private let subtitle: Text?
    private let titleIdentifier: String?

    public init(_ title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil, titleIdentifier: String? = nil) {
        self.title = Text(title)
        self.subtitle = subtitle.map { Text($0) }
        self.titleIdentifier = titleIdentifier
    }

    /// For a name made at run time (a marker, a document).
    public init(verbatim title: String, subtitle: String? = nil, titleIdentifier: String? = nil) {
        self.title = Text(verbatim: title)
        self.subtitle = subtitle.map { Text(verbatim: $0) }
        self.titleIdentifier = titleIdentifier
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: HLTextRole.columnHeader.spec.after) {
            title
                .hlText(.columnHeader)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .modifier(HLOptionalIdentifier(identifier: titleIdentifier))
            if let subtitle {
                subtitle
                    .hlText(.pageSubtitle)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
