import SwiftUI
#if canImport(UIKit)
    import UIKit
#endif

/// v0.11 W28c — the Insights **Workouts** special page (web `/insights/workouts`).
///
/// A deduped recent-workout list (the server runs the Apple Watch + Withings
/// cross-source merge before it lands here). Each row is the same `WorkoutRow`
/// the More → Workouts surface ships; a tap pushes `WorkoutDetailView` on the
/// container's shared NavigationStack. The page reads `WorkoutsStore` directly.
///
/// **Lives inside the Insights pager.** Owns no `NavigationStack` (the container
/// does). Its inner `ScrollView` reports its offset to `InsightsStripVisibility`
/// for hide-on-scroll; the page wrapper pins it `.containerRelativeFrame(.horizontal)`
/// ONLY (the W44 contract).
///
/// **Self-suppress:** rendered only when the operator has ≥1 workout (gated by
/// `availableSpecials`); the defensive empty branch is a calm
/// `ContentUnavailableView`, never a dead box.
struct InsightsWorkoutsPage: View {
    @Environment(WorkoutsStore.self) private var store
    @Environment(InsightsStripVisibility.self) private var stripVisibility
    @Environment(HKReadinessStore.self) private var hkReadiness

    /// W-B182 — true while the manual "sync from Apple Health" pull is in flight.
    @State private var isSyncing = false

    var body: some View {
        Group {
            if store.workouts.isEmpty {
                emptyState
            } else {
                content
            }
        }
        .background(HLSurface.primary.ignoresSafeArea())
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HLSpace.lg) {
                // v0.13.1 UX-D8/D2 — canonical per-page header (large title +
                // sub-line + equal-circle trailing slot), IDENTICAL anatomy to
                // the metric pages so the header doesn't jump across the pager.
                // Workouts has no per-page gear/coach target, so the trailing
                // slot is empty (no dead affordance) — only the shape unifies.
                InsightsPageHeader(
                    "Workouts",
                    subtitle: LocalizedStringKey(subtitle),
                    accessibilityIdentifierSuffix: "workouts"
                )

                if let meta = store.meta, meta.droppedDuplicates > 0 {
                    Text("Duplicate workouts (Watch + scale) were merged.")
                        .font(.hlCaption)
                        .foregroundStyle(HLText.tertiary)
                        .padding(.horizontal, HLSpace.xs)
                }

                HLCard {
                    VStack(spacing: 0) {
                        ForEach(Array(store.workouts.enumerated()), id: \.element.id) { index, workout in
                            NavigationLink {
                                WorkoutDetailView(workout: workout)
                            } label: {
                                WorkoutRow(workout: workout)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("insights.workouts.row.\(workout.id)")
                            if index < store.workouts.count - 1 {
                                Divider().overlay(HLColor.separator)
                            }
                        }
                    }
                }

                // v0.14.8 W2-SYNCUX — canonical sync-status footer (same
                // primitive as Dashboard/Insights, self-suppressing).
                HLSyncStatusFooter(screenLoading: store.isLoading)
            }
            .padding(.horizontal, HLSpace.lg)
            .padding(.top, HLSpace.lg)
            .padding(.bottom, HLSpace.xxxl)
        }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y
        } action: { _, newOffset in
            stripVisibility.report(offset: newOffset)
        }
        .hlScrollEdgeSoft()
        // W-B184 — WHOOP-style pull-to-refresh (custom glyph + checkmark + one
        // success haptic; the handshake driving the checkmark runs in the modifier).
        .hlPullToRefresh { await store.refresh() }
    }

    /// Localized, plural-aware count line ("3 workouts" / "1 Workout"). Resolved
    /// to a `String` here (then handed to the header as a verbatim key) so the
    /// plural catalog entry `insights.workoutsCount` does the inflection.
    private var subtitle: String {
        String(localized: "insights.workoutsCount \(store.workouts.count)")
    }

    /// W-B182 — calm empty-state with an explicit "sync from Apple Health"
    /// recovery path. Because Apple never reports a workout-READ grant, a denial
    /// is invisible; the importer cannot tell "no workouts" from "read denied".
    /// This affordance re-requests authorization + force-pulls, and (if the list
    /// stays empty) hands the operator a deep-link into the Health app so they
    /// can flip the per-type toggle themselves — the only path Apple leaves once
    /// a read type is determined.
    private var emptyState: some View {
        ScrollView {
            VStack(spacing: HLSpace.lg) {
                HLEmptyState(
                    icon: "figure.run",
                    title: "No workouts yet",
                    message: "Workouts appear here as soon as Apple Watch or another source reports one."
                )

                VStack(spacing: HLSpace.sm) {
                    HLButton(
                        String(localized: "Sync from Apple Health"),
                        icon: "heart.text.square",
                        variant: .primary,
                        size: .large,
                        isLoading: isSyncing
                    ) {
                        Task { await syncFromAppleHealth() }
                    }
                    .disabled(isSyncing)
                    .accessibilityIdentifier("insights.workouts.empty.sync")

                    HLButton(
                        String(localized: "Open Apple Health"),
                        variant: .secondary,
                        size: .large
                    ) {
                        openAppleHealth()
                    }
                    .accessibilityIdentifier("insights.workouts.empty.openHealth")
                }
                .padding(.horizontal, HLSpace.xl)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, HLSpace.xxxl)
            .padding(.bottom, HLSpace.xxxl)
        }
        .refreshable { await store.refresh() }
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

    /// Öffnet die Health-App, damit der Nutzer den Workout-Lesezugriff dort
    /// selbst umstellen kann. **Nicht** die Quellen-Detailseite — Apple bietet
    /// Drittanbietern keinen Deep-Link dorthin (Begründung samt Beleg an
    /// ``HKReadinessStore/healthAppDeepLink``). No-op auf Nicht-UIKit-Builds.
    private func openAppleHealth() {
        #if canImport(UIKit)
            guard let url = HKReadinessStore.healthAppDeepLink else { return }
            UIApplication.shared.open(url)
        #endif
    }
}
