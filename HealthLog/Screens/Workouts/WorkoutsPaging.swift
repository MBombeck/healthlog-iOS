import SwiftUI

/// #19 — the count line both workout lists show above their rows. Reads the
/// server's `meta.total` (canonical rows for the active filter), never the
/// size of the loaded page: "50 of 730 workouts" while pages are still
/// outstanding, "730 workouts" once everything is there.
enum WorkoutsListSummary {
    static func headerText(loaded: Int, total: Int?) -> String {
        guard let total, loaded < total else {
            return String(localized: "insights.workoutsCount \(total ?? loaded)")
        }
        return String(localized: "workouts.count.partial \(loaded) \(total)")
    }

    /// VoiceOver reads the partial state as "… loaded" so the count is not
    /// mistaken for the total; a complete list reads the plain total.
    static func headerAccessibilityLabel(loaded: Int, total: Int?) -> String {
        guard let total, loaded < total else {
            return headerText(loaded: loaded, total: total)
        }
        return String(localized: "workouts.count.partial.a11y \(loaded) \(total)")
    }

    @MainActor
    static func headerText(for store: WorkoutsStore) -> String {
        headerText(loaded: store.workouts.count, total: store.meta?.total)
    }

    @MainActor
    static func headerAccessibilityLabel(for store: WorkoutsStore) -> String {
        headerAccessibilityLabel(loaded: store.workouts.count, total: store.meta?.total)
    }
}

/// #19 — what the end of a workout list shows.
enum WorkoutsPagingFooterState: Equatable {
    /// Nothing loaded yet (the empty state or the first-page load owns the screen).
    case hidden
    /// More pages are due; the footer is the trigger and shows progress.
    case loading
    /// The last page request failed; the footer offers "Try again".
    case failed
    /// Every row up to `meta.total` is listed.
    case end

    static func resolve(
        hasLoadedPage: Bool,
        hasMorePages: Bool,
        hasPageError: Bool
    ) -> WorkoutsPagingFooterState {
        guard hasLoadedPage else { return .hidden }
        if hasPageError { return .failed }
        return hasMorePages ? .loading : .end
    }

    @MainActor
    static func resolve(_ store: WorkoutsStore) -> WorkoutsPagingFooterState {
        resolve(
            hasLoadedPage: store.meta != nil && !store.workouts.isEmpty,
            hasMorePages: store.hasMorePages,
            hasPageError: store.loadMoreError != nil
        )
    }
}

/// #19 — the end-of-list row shared by More → Workouts and the Insights
/// Workouts page. Purely presentational: the screens decide when the next
/// page is requested (a lazy `List` row appearing, or the scroll position
/// nearing the end of the Insights page).
struct WorkoutsPagingFooter: View {
    @Environment(WorkoutsStore.self) private var store

    var body: some View {
        switch WorkoutsPagingFooterState.resolve(store) {
        case .hidden:
            EmptyView()
        case .loading:
            HStack(spacing: HLSpace.sm) {
                ProgressView()
                Text("workouts.paging.loading")
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, HLSpace.md)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("workouts.paging.loading")
        case .failed:
            VStack(spacing: HLSpace.sm) {
                Text("workouts.paging.failed")
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                    .multilineTextAlignment(.center)
                HLButton("Try again", icon: "arrow.clockwise", variant: .secondary, size: .compact) {
                    Task { await store.retryNextPage() }
                }
                .accessibilityIdentifier("workouts.paging.retry")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, HLSpace.md)
        case .end:
            Text("workouts.paging.end")
                .font(.hlCaption)
                .foregroundStyle(HLText.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, HLSpace.md)
                .accessibilityIdentifier("workouts.paging.end")
        }
    }
}
