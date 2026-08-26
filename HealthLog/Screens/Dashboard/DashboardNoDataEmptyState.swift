import SwiftUI

/// v0.14.8 AUDIT-HOME H2 — honest first-run / no-data empty state.
///
/// Pre-fix, a fresh account (zero measurements) auto-hid every synth tile via
/// `DashboardEmptyTilePolicy`, leaving `visibleMetrics` empty — and the grid
/// rendered `TileGridEmptyState`: *"You've hidden every tile. Add some
/// back…"*. The user hid nothing, and the CTA landed in a customize screen
/// where every row was already "Pinned" — a confusing dead-end as the very
/// first impression of the app.
///
/// This view is the data-empty branch: calm guidance toward connecting Apple
/// Health (the `HealthKitConnectBanner` above carries the actual connect
/// affordance when HK isn't granted yet) or capturing a first value via the
/// centre "Erfassen" action. `TileGridEmptyState` stays reserved for the
/// genuinely-hidden-everything case (see
/// `DashboardScreen.hasUserHiddenAllMetricTiles`).
struct DashboardNoDataEmptyState: View {
    /// Opens the capture picker (same path as the centre "Erfassen" slot).
    let onCapture: () -> Void

    var body: some View {
        HLCard {
            HLEmptyState(
                icon: "heart.text.square",
                title: "No data yet",
                message: "Connect Apple Health or capture your first value — your metrics will appear here automatically."
            ) {
                HLButton(
                    String(localized: "Capture first value"),
                    icon: "plus",
                    variant: .restrained,
                    action: onCapture
                )
            }
            .accessibilityIdentifier("dashboard.noDataEmptyState")
        }
    }
}

#Preview("No data yet") {
    DashboardNoDataEmptyState(onCapture: {})
        .padding()
        .hlScreenBackground()
}
