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
            switch phase {
            case .loading:
                loading()
            case .empty:
                empty()
            case let .error(retry):
                // AUD-5 H1 — a server error / cold-offline fetch failure is
                // distinct from a genuine empty state: render an honest error row
                // with a Retry CTA *inside* the stable `List` root (never a sibling
                // container that would re-bind the large-title bar). Without this
                // arm a 500 / offline-with-cold-cache looked identical to "Add your
                // first…" on Labs / Illness / CoachMemory.
                HLAsyncListErrorRow(retry: retry)
            case .loaded:
                content()
            }
        }
    }
}

/// The error-phase row for ``HLAsyncListScreen`` — an honest "couldn't load"
/// message + a Retry CTA, rendered INSIDE the stable `List` root so the error
/// state never swaps the scroll container (the RCA-2 invariant). Used by Labs,
/// the Illness journal, and Coach memory so a failed fetch is no longer
/// indistinguishable from a genuinely empty list (AUD-5 H1).
struct HLAsyncListErrorRow: View {
    let retry: (() async -> Void)?

    var body: some View {
        Section {
            HLEmptyState(
                icon: "exclamationmark.triangle",
                title: "async.list.error.title",
                message: "async.list.error.subtitle"
            ) {
                if let retry {
                    HLButton("async.list.error.retry", icon: "arrow.clockwise", variant: .primary) {
                        Task { await retry() }
                    }
                    .accessibilityIdentifier("async.list.error.retry")
                }
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
    }
}

/// QOL-ERR-1 — the cold-error unavailable state for `ScrollView`- / `Group`-based
/// screens that can't host the `List`-only ``HLAsyncListErrorRow`` (Cycle,
/// Mental-Wellbeing, Mood-History). A cold offline start / server 500 with no
/// cached data used to render indistinguishably from a genuine empty state ("no
/// data yet"); this surfaces an honest "couldn't load" + a Retry CTA instead,
/// reusing the same `async.list.error.*` copy as the list error row so the two
/// error surfaces read identically. Built on the canonical ``HLEmptyState``
/// lockup (audit-01 C1), centered in the host like the system primitive was.
struct HLRetryUnavailableView: View {
    let retry: () async -> Void

    var body: some View {
        HLEmptyState(
            icon: "exclamationmark.triangle",
            title: "async.list.error.title",
            message: "async.list.error.subtitle"
        ) {
            HLButton("async.list.error.retry", icon: "arrow.clockwise", variant: .primary) {
                Task { await retry() }
            }
            .accessibilityIdentifier("async.list.error.retry")
        }
        .containerCentered()
    }
}

/// The async render phases a stable-root list distinguishes. The container
/// renders the SAME `List` root for all of them — only the rows differ.
enum HLAsyncListPhase: Equatable {
    /// First load with nothing to show yet — render skeleton rows.
    case loading
    /// Loaded, but no data — render the empty-state row(s).
    case empty
    /// AUD-5 H1 — the fetch FAILED (server 500 / cold-offline) and there is no
    /// cached data to fall back to. Render an honest error row + a Retry CTA,
    /// distinct from the genuine `.empty` "add your first…" state. The associated
    /// closure re-runs the screen's load; `nil` renders the message without a CTA.
    case error(retry: (() async -> Void)?)
    /// Loaded with data — render the real rows.
    case loaded

    /// `Equatable` by CASE only — the `.error` retry closure is not comparable
    /// and its identity is irrelevant to view diffing (the row is the same
    /// regardless of which load it re-runs). This keeps the phase usable as an
    /// `onChange`/animation value without forcing the closure to be `Equatable`.
    static func == (lhs: HLAsyncListPhase, rhs: HLAsyncListPhase) -> Bool {
        switch (lhs, rhs) {
        case (.loading, .loading), (.empty, .empty), (.error, .error), (.loaded, .loaded):
            true
        default:
            false
        }
    }
}

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
            content.refreshable { await refresh() }
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
