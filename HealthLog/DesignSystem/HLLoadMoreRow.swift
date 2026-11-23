import SwiftUI

/// The end of a list that has more: one form for "load more" everywhere.
///
/// In a `List` the last row loads the next page by itself as it scrolls into
/// view (`.onAppear`) and shows the small spinner meanwhile, as Documents and
/// Workouts do. On an ``HLPage`` the link "Load more" stands centred under
/// the last card; while the page loads, the spinner takes its place at the
/// same height, so nothing below jumps. Without more to load the row is
/// gone.
struct HLLoadMoreRow: View {
    /// How the next page is asked for.
    enum Trigger: Equatable, Sendable {
        /// The row loads when it appears: the last row of a `List`.
        case onAppear
        /// The link "Load more": the end of a page of cards.
        case link
    }

    /// What the row shows.
    enum Shape: Equatable, Sendable {
        case hidden
        case link
        /// The spinner; `loadsOnAppear` when its appearing asks for the page.
        case progress(loadsOnAppear: Bool)
    }

    nonisolated static let identifier = "hl.loadMore"
    /// Link and spinner stand at the same height.
    static let height: CGFloat = HLLinkButton.hitHeight

    nonisolated static func shape(hasMore: Bool, isLoading: Bool, trigger: Trigger) -> Shape {
        guard hasMore else { return .hidden }
        switch trigger {
        case .onAppear: return .progress(loadsOnAppear: !isLoading)
        case .link: return isLoading ? .progress(loadsOnAppear: false) : .link
        }
    }

    private let hasMore: Bool
    private let isLoading: Bool
    private let trigger: Trigger
    private let load: () -> Void

    init(hasMore: Bool, isLoading: Bool, trigger: Trigger = .link, load: @escaping () -> Void) {
        self.hasMore = hasMore
        self.isLoading = isLoading
        self.trigger = trigger
        self.load = load
    }

    var body: some View {
        switch Self.shape(hasMore: hasMore, isLoading: isLoading, trigger: trigger) {
        case .hidden:
            EmptyView()
        case .link:
            HLLinkButton("Load more", action: load)
                .accessibilityIdentifier(Self.identifier)
        case let .progress(loadsOnAppear):
            HLInlineProgress()
                .frame(maxWidth: .infinity, minHeight: Self.height)
                .accessibilityIdentifier(Self.identifier)
                .onAppear { if loadsOnAppear { load() } }
        }
    }
}
