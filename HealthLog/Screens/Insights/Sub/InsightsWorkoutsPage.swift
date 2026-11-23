import SwiftUI
#if canImport(UIKit)
    import UIKit
#endif

/// The Insights **Workouts** special page (web `/insights/workouts`).
///
/// A deduped recent-workout list (the server runs the Apple Watch + Withings
/// cross-source merge before it lands here). Each row is the same `WorkoutRow`
/// the More → Workouts surface ships; a tap pushes `WorkoutDetailView` on the
/// container's shared NavigationStack. The page reads `WorkoutsStore` directly.
///
/// **Lives inside the Insights pager.** Owns no `NavigationStack` (the container
/// does). The page wrapper pins it `.containerRelativeFrame(.horizontal)` ONLY
/// (the W44 contract).
///
/// **Paging:** the sub-line shows the server's `meta.total` ("50 of 730
/// workouts" while pages are outstanding), the rows sit in a lazy stack, and
/// the next page is requested when the scroll position comes within one
/// screen of the end, until `meta.total` is reached.
///
/// **Self-suppress:** rendered only when the operator has ≥1 workout (gated by
/// `availableSpecials`); the defensive empty branch is a calm
/// `ContentUnavailableView`, never a dead box.
struct InsightsWorkoutsPage: View {
    @Environment(WorkoutsStore.self) private var store
    @Environment(HKReadinessStore.self) private var hkReadiness
    @Environment(\.deviceProfile) private var deviceProfile

    /// True while the manual "sync from Apple Health" pull is in flight.
    @State private var isSyncing = false

    var body: some View {
        content
    }

    /// The (i) of the page. No coach circle yet: a page may not add a sheet
    /// of its own outside the frozen presentation census.
    private var headerActions: HLTabHeaderActions {
        HLTabHeaderActions([
            .info(InsightsSpecialPageInfo.workouts(), identifier: "insights.workouts.info")
        ])
    }

    /// In the Insights pager the head is pinned above the strip.
    @Environment(\.insightsInPager) private var inPager

    /// The page's head: pinned above the strip in the pager, at the top
    /// of the content elsewhere. In the pager the count line moves into the
    /// content, so every head of the pager is one line high.
    private func pageHeader(withSubtitle: Bool) -> some View {
        HLTabHeader(
            "Workouts",
            subtitle: withSubtitle && !store.workouts.isEmpty ? LocalizedStringKey(subtitle) : nil,
            titleIdentifier: "insights.page.header.title.workouts",
            subtitleAccessibilityLabel: Text(verbatim: WorkoutsListSummary.headerAccessibilityLabel(for: store)),
            actions: headerActions
        )
    }

    /// The page stands in every state, so the title does not jump when the
    /// workouts arrive; without any the empty state sits in the free area.
    private var content: some View {
        HLPage {
            // Canonical per-page header, the same anatomy as the metric pages
            // so the header does not jump across the pager. The sub-line
            // stays: it says how much of the history has loaded.
            if inPager {
                if !store.workouts.isEmpty {
                    Text(subtitle)
                        .hlText(.pageSubtitle)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(Text(verbatim: WorkoutsListSummary.headerAccessibilityLabel(for: store)))
                }
            } else {
                pageHeader(withSubtitle: true)
            }
            HLStateContainer(store.workouts.isEmpty ? .empty : .loaded) {
                EmptyView()
            } empty: {
                emptyState
            } content: {
                HLCard {
                    LazyVStack(spacing: HLSpace.sm) {
                        ForEach(store.workouts, id: \.id) { workout in
                            NavigationLink {
                                WorkoutDetailView(workout: workout)
                            } label: {
                                WorkoutRow(workout: workout)
                                    .contentShape(Rectangle())
                            }
                            // A data row: the whole row presses, no chevron.
                            .buttonStyle(.hlRow)
                            .accessibilityIdentifier("insights.workouts.row.\(workout.id)")
                        }
                    }
                }

                WorkoutsPagingFooter()

                // Canonical sync-status footer (same
                // primitive as Dashboard/Insights, self-suppressing).
                HLSyncStatusFooter(screenLoading: store.isLoading)
            }
        }
        // A ScrollView has no lazy end-of-list row to hang the trigger
        // on, so the scroll geometry is the trigger: coming within one screen
        // of the end asks for the next page. It fires on the false → true edge;
        // the appended rows push the end away again, and the store ignores a
        // request while one is in flight.
        .onScrollGeometryChange(for: Bool.self) { geometry in
            Self.isNearEnd(geometry)
        } action: { _, nearEnd in
            if nearEnd { Task { await store.loadNextPage() } }
        }
        // WHOOP-style pull-to-refresh (custom glyph + checkmark + one
        // success haptic; the handshake driving the checkmark runs in the modifier).
        .hlPullToRefresh { await store.refresh() }
        // In the pager the head stands fixed at the top, over the strip.
        .insightsPageHead(enabled: inPager) { pageHeader(withSubtitle: false) }
    }

    /// Localized, plural-aware count line ("730 workouts" / "50 of 730
    /// workouts"). Resolved to a `String` here (then handed to the header as a
    /// verbatim key) so the plural catalog entry `insights.workoutsCount` does
    /// the inflection. The number is the server's `meta.total`, not the
    /// size of the loaded page.
    private var subtitle: String {
        WorkoutsListSummary.headerText(for: store)
    }

    /// Within one container height of the end of the content.
    static func isNearEnd(_ geometry: ScrollGeometry) -> Bool {
        isNearEnd(
            offsetY: geometry.contentOffset.y,
            containerHeight: geometry.containerSize.height,
            contentHeight: geometry.contentSize.height
        )
    }

    static func isNearEnd(offsetY: CGFloat, containerHeight: CGFloat, contentHeight: CGFloat) -> Bool {
        guard containerHeight > 0, contentHeight > 0 else { return false }
        return offsetY + containerHeight * 2 >= contentHeight
    }

    /// Calm empty-state with an explicit "sync from Apple Health"
    /// recovery path. Because Apple never reports a workout-READ grant, a denial
    /// is invisible; the importer cannot tell "no workouts" from "read denied".
    /// This affordance re-requests authorization + force-pulls, and (if the list
    /// stays empty) hands the operator a deep-link into the Health app so they
    /// can flip the per-type toggle themselves — the only path Apple leaves once
    /// a read type is determined.
    private var emptyState: some View {
        // One lockup, one action: the sync that pulls the workouts in (it asks
        // for the read permission first). The second "Open Apple Health"
        // button is gone; the permission lives in Settings like every other
        // Health read.
        HLEmptyState(
            icon: "figure.run",
            // The same words as the Workouts list under More.
            title: LocalizedStringKey(WorkoutsScreen.Layout.emptyTitle),
            message: LocalizedStringKey(WorkoutsScreen.Layout.emptySubtitle)
        ) {
            // A device that reads no HealthKit (the iPad) has nothing to sync.
            if HealthKitAvailabilityPolicy(idiom: deviceProfile.idiom).offersAuthorization {
                HLButton(
                    "Sync from Apple Health",
                    systemImage: "heart.text.square",
                    variant: .secondary,
                    isLoading: isSyncing
                ) {
                    Task { await syncFromAppleHealth() }
                }
                .disabled(isSyncing)
                .accessibilityIdentifier("insights.workouts.empty.sync")
            }
        }
        .accessibilityIdentifier("insights.workouts.empty")
    }

    /// Re-request HK auth (which includes `workoutType()`), force-pull all
    /// collected types, then revalidate the list so a freshly-granted history
    /// surfaces without a manual relaunch.
    private func syncFromAppleHealth() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        await hkReadiness.requestAuthorization()
        await hkReadiness.triggerManualSync()
        await store.refresh()
    }
}
