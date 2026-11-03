import SwiftUI

/// #67 — honest per-section error + retry for the Home metrics area.
///
/// Replaces the indefinite `SkeletonContent()` when the dashboard summary
/// subrequest failed with no cached fallback (see
/// `DashboardMetricsSectionState`). The other Home sections (score rings, hero,
/// compliance ring, Vorsorge / rhythm front doors) load through independent
/// stores and stay put — only this section owns the failure, and it offers a
/// retry instead of leaving the user staring at a skeleton that never resolves.
///
/// Reuses the canonical `HLEmptyState` lockup (monochrome, no status colour) so
/// it reads as an honest state, not an alarm — the top-of-screen error banner
/// already carries the transient alert.
struct DashboardMetricsErrorState: View {
    /// Re-runs the summary load + per-kind tile fan-out (force past the TTL).
    let onRetry: () -> Void

    var body: some View {
        // 1.4 B4 — the one empty-state form: on the page, not in a card. The
        // sentence stays because it says what the title cannot (only the
        // tiles failed); "Try again" is `.secondary` like everywhere else.
        HLEmptyState(
            icon: "exclamationmark.arrow.circlepath",
            title: "Couldn't load your metrics",
            message: "The rest of your dashboard is up to date."
        ) {
            HLButton(
                String(localized: "Try again"),
                icon: "arrow.clockwise",
                variant: .secondary,
                action: onRetry
            )
        }
        .accessibilityIdentifier("dashboard.metricsErrorState")
    }
}

#Preview("Metrics error") {
    DashboardMetricsErrorState(onRetry: {})
        .padding()
        .hlScreenBackground()
}
