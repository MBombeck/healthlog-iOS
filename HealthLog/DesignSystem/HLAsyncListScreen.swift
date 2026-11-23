import SwiftUI

/// Stable-scroll-root container for push-reached `List` screens with a `.large`
/// title that hydrate asynchronously.
///
/// **Why this exists (RCA `.planning/v0151-audit/RCA-nav-scroll-2.md`).** A pushed
/// screen whose `body` swapped its ROOT from a non-scrolling `ProgressView` to a
/// `List`/`ScrollView` *after* an async `.task` load — while declaring
/// `.navigationBarTitleDisplayMode(.large)` — made the large-title bar bind its
/// collapse + content-insets to the FIRST scroll view in the tree. On frame 1 that
/// was the `ProgressView` (not a scroll view); when the data resolved and the root
/// became a `List`, UIKit re-bound the bar to a brand-new scroll view and
/// re-resolved insets + (on a returned-to screen) the restored offset → the content
/// origin shifted DOWN after load ("the page rucks downward after it loaded").
///
/// **The invariant.** The scrollable container must be present and stable from the
/// FIRST frame, including the loading state. `HLAsyncListScreen` always renders a
/// `List` as its root; the loading state is a skeleton rendered *inside* that same
/// `List`, and the empty state is a row *inside* the same `List` — never a sibling
/// container that replaces the root. Only the *rows* swap across
/// loading → empty → populated; the root container identity is invariant, so the
/// large-title bar binds once and never re-resolves.
///
/// This is the proven shape the healthy screens (`AchievementsScreen`,
/// `PersonalRecordsScreen`) already use (skeleton-from-frame-1); promoted here so
/// new async list screens get it for free.
///
/// The decidable invariant is encoded in
/// `ScrollSpineStability.rootContainerIsScrollableFromFirstFrame` and unit-tested.
///
/// **Phases.** The caller maps its store state into ``HLAsyncListPhase`` and
/// supplies a row-builder per phase. `refresh` is wired to `.refreshable` on the
/// root `List` so pull-to-refresh works in every phase (loading included — the
/// gesture stays available from frame 1).
struct HLAsyncListScreen<Loading: View, Empty: View, Content: View>: View {
    let phase: HLAsyncListPhase
    let listStyle: HLAsyncListStyle
    let refresh: (() async -> Void)?
    @ViewBuilder let loading: () -> Loading
    @ViewBuilder let empty: () -> Empty
    @ViewBuilder let content: () -> Content

    init(
        phase: HLAsyncListPhase,
        listStyle: HLAsyncListStyle = .insetGrouped,
        refresh: (() async -> Void)? = nil,
        @ViewBuilder loading: @escaping () -> Loading,
        @ViewBuilder empty: @escaping () -> Empty,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.phase = phase
        self.listStyle = listStyle
        self.refresh = refresh
        self.loading = loading
        self.empty = empty
        self.content = content
    }

    var body: some View {
        styledList
            // The app canvas under every list built on this primitive.
            // Only Labs painted it; Illness, Documents, Nutrition, Environment,
            // the coach's memory, Allergies and Family history stood on the
            // system's pure black (light grey in light mode) instead.
            .scrollContentBackground(.hidden)
            .background(HLSurface.primary)
            .modifier(HLAsyncListRefresh(refresh: refresh))
    }

    /// The root-container kind this primitive renders for a given phase. ALWAYS
    /// `.scrollable` — the whole point of the primitive is that the `List` root is
    /// present in every phase (loading included), never a `ProgressView` swap. Used
    /// by `ScrollSpineStabilityTests` to assert the RCA-2 invariant on the screens
    /// that adopt this container. See `.planning/v0151-audit/RCA-nav-scroll-2.md`.
    nonisolated static func rootContainerKind(
        for _: HLAsyncListPhase
    ) -> ScrollSpineStability.RootContainerKind {
        .scrollable
    }

    @ViewBuilder
    private var styledList: some View {
        switch listStyle {
        case .insetGrouped:
            rootList.listStyle(.insetGrouped)
        case .plain:
            rootList.listStyle(.plain)
        }
    }

    /// The single, stable `List` root. Present from frame 1 in every phase; only
    /// its rows change. This is what keeps the large-title bar bound to one scroll
    /// view across the async load.
    private var rootList: some View {
        List {
            // An honest error row with a retry stands *inside* the stable
            // `List` root, distinct from a genuine empty state: without it a
            // failed load looked identical to "Add your first…".
            HLStateContainer(phase, placement: .rows, skeleton: loading, empty: empty, content: content)
        }
    }
}

/// The error-phase row for ``HLAsyncListScreen`` — an honest "couldn't load"
/// message + a Retry CTA, rendered INSIDE the stable `List` root so the error
/// state never swaps the scroll container (the RCA-2 invariant). Used by Labs,
/// the Illness journal, and Coach memory so a failed fetch is no longer
/// indistinguishable from a genuinely empty list.
struct HLAsyncListErrorRow: View {
    let retry: (() async -> Void)?

    var body: some View {
        Section {
            HLErrorState(optionalRetry: retry)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
    }
}

/// The phases of a stable-root list. The same four states apply outside of
/// lists, so the type lives on as ``HLLoadPhase``; new code uses that name.
typealias HLAsyncListPhase = HLLoadPhase

/// The list styles `HLAsyncListScreen` supports. `switch`-applied at compile time
/// because `.listStyle(_:)` takes distinct concrete types.
enum HLAsyncListStyle {
    case insetGrouped
    case plain
}

/// Applies `.refreshable` only when a refresh closure is supplied, so a read-only
/// surface does not show a pull-to-refresh affordance.
private struct HLAsyncListRefresh: ViewModifier {
    let refresh: (() async -> Void)?

    func body(content: Content) -> some View {
        if let refresh {
            content
                .refreshable { await refresh() }
                .hlRefreshCommand { await refresh() }
        } else {
            content
        }
    }
}

/// Generic skeleton rows for the loading phase — a stack of placeholder list rows
/// matching a title + caption silhouette. Rendered *inside* the stable `List` root
/// so the loading state never swaps the container. Mirrors the
/// `AchievementsScreen` skeleton intent for list-shaped surfaces.
struct HLAsyncListSkeletonRows: View {
    var rowCount: Int = 6

    var body: some View {
        Section {
            ForEach(0 ..< rowCount, id: \.self) { _ in
                HStack(spacing: HLSpace.md) {
                    VStack(alignment: .leading, spacing: HLSpace.xs) {
                        HLSkeleton(.capsule, width: 160, height: 16)
                        HLSkeleton(.capsule, width: 100, height: 12)
                    }
                    Spacer(minLength: HLSpace.sm)
                    HLSkeleton(.capsule, width: 56, height: 16)
                }
                .padding(.vertical, HLSpace.xxs)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Loading"))
    }
}
