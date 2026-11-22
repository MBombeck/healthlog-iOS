import SwiftUI

/// The four states of content that is loaded.
public enum HLLoadPhase: Equatable {
    /// First load with nothing to show yet.
    case loading
    /// Loaded, and there is nothing.
    case empty
    /// The load failed and there is nothing stored to fall back on. `retry`
    /// runs the load again.
    case error(retry: () async -> Void)
    /// Loaded with content.
    case loaded

    /// Equal by case alone: the retry closure cannot be compared, and which
    /// load it repeats changes nothing about what is shown.
    public static func == (lhs: HLLoadPhase, rhs: HLLoadPhase) -> Bool {
        switch (lhs, rhs) {
        case (.loading, .loading), (.empty, .empty), (.error, .error), (.loaded, .loaded):
            true
        default:
            false
        }
    }
}

/// The published measures of the empty and the failed state.
public enum HLStateLayout {
    /// Share of the visible height the lockup is centred in. Three quarters
    /// puts it at the optical centre and leaves room for a header above it
    /// without making the page scroll.
    public static let freeAreaShare: CGFloat = 0.75
}

/// Where a state container stands.
enum HLStatePlacement {
    /// On a page or in any other scrolling content: empty and failed states
    /// are centred in the free area.
    case page
    /// As rows of a `List`: the caller's rows pass through unchanged.
    case rows
}

/// Shows the loading, empty, failed or loaded form of some content.
///
/// It goes inside the scrolling root of a screen, never around it: the root
/// stays the same in all four states, so a large title binds to it once and
/// the page does not jump when the load ends.
public struct HLStateContainer<Content: View, Empty: View, Skeleton: View>: View {
    private let phase: HLLoadPhase
    private let placement: HLStatePlacement
    private let skeleton: () -> Skeleton
    private let empty: () -> Empty
    private let content: () -> Content

    public init(
        _ phase: HLLoadPhase,
        @ViewBuilder skeleton: @escaping () -> Skeleton,
        @ViewBuilder empty: @escaping () -> Empty,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(phase, placement: .page, skeleton: skeleton, empty: empty, content: content)
    }

    init(
        _ phase: HLLoadPhase,
        placement: HLStatePlacement,
        @ViewBuilder skeleton: @escaping () -> Skeleton,
        @ViewBuilder empty: @escaping () -> Empty,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.phase = phase
        self.placement = placement
        self.skeleton = skeleton
        self.empty = empty
        self.content = content
    }

    public var body: some View {
        // Only the builder of the current state runs, so loaded content is
        // never built over data that is not there yet.
        switch phase {
        case .loading:
            skeleton()
        case .empty:
            switch placement {
            case .page: HLStateFreeArea { empty() }
            case .rows: empty()
            }
        case let .error(retry):
            switch placement {
            case .page: HLStateFreeArea { HLErrorState(retry: retry) }
            case .rows: HLAsyncListErrorRow(retry: retry)
            }
        case .loaded:
            content()
        }
    }
}

/// Holds a state lockup in the middle of the free area of its scrolling
/// container, so an empty page does not leave two thirds of it blank. The
/// area is a floor, not a fixed height: a lockup in very large type grows
/// past it instead of being cut off.
private struct HLStateFreeArea<Lockup: View>: View {
    @ViewBuilder let lockup: () -> Lockup

    var body: some View {
        ZStack {
            Color.clear
                .containerRelativeFrame(.vertical) { length, _ in
                    length * HLStateLayout.freeAreaShare
                }
            lockup()
        }
        .frame(maxWidth: .infinity)
    }
}

extension View {
    /// Centres a state lockup in the free area of a scrolling page, the way
    /// ``HLStateContainer`` places its empty and failed states.
    func hlStateFreeArea() -> some View {
        HLStateFreeArea { self }
    }
}

/// The one form of "this could not be loaded": symbol, title, one sentence
/// and the button that tries again.
public struct HLErrorState: View {
    private let message: LocalizedStringKey?
    private let retry: (() async -> Void)?

    public init(_ message: LocalizedStringKey? = nil, retry: @escaping () async -> Void) {
        self.message = message
        self.retry = retry
    }

    /// A failed state that cannot be repeated from where it stands.
    init(_ message: LocalizedStringKey? = nil, optionalRetry retry: (() async -> Void)?) {
        self.message = message
        self.retry = retry
    }

    public var body: some View {
        HLEmptyState(
            icon: "exclamationmark.triangle",
            title: "async.list.error.title",
            message: message ?? "async.list.error.subtitle"
        ) {
            if let retry {
                HLButton(HLControlWord.retry.key, systemImage: "arrow.clockwise", variant: .secondary) {
                    Task { await retry() }
                }
                .accessibilityIdentifier("async.list.error.retry")
            }
        }
    }
}

#Preview("HLStateContainer, light") {
    HLStateContainerPreview()
        .preferredColorScheme(.light)
}

#Preview("HLStateContainer, dark") {
    HLStateContainerPreview()
        .preferredColorScheme(.dark)
}

#Preview("HLStateContainer, largest type") {
    HLStateContainerPreview()
        .dynamicTypeSize(.accessibility5)
}

private struct HLStateContainerPreview: View {
    @State private var step = 0

    private var phase: HLLoadPhase {
        switch step % 4 {
        case 0: .empty
        case 1: .error(retry: {})
        case 2: .loading
        default: .loaded
        }
    }

    var body: some View {
        HLPage {
            HLStateContainer(phase) {
                HLSkeleton(.capsule, width: 160, height: 16)
            } empty: {
                HLEmptyState(icon: "tray", title: "No measurements yet") {
                    HLButton("Log a measurement", systemImage: "plus", variant: .secondary) {}
                }
            } content: {
                HLCard("Overview", layout: .rows) {
                    HLRowLayout(title: "Weight", indicator: .disclosure)
                }
            }
            HLLinkButton("More") { step += 1 }
        }
    }
}
