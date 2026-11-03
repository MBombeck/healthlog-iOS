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
/// This view is the data-empty branch: the way to a first value (the centre
/// "Erfassen" action); the `HealthKitConnectBanner` above carries the connect
/// affordance when HK isn't granted yet. `TileGridEmptyState` stays reserved for the
/// genuinely-hidden-everything case (see
/// `DashboardScreen.hasUserHiddenAllMetricTiles`).
struct DashboardNoDataEmptyState: View {
    /// Opens the capture picker (same path as the centre "Erfassen" slot).
    let onCapture: () -> Void

    var body: some View {
        // 1.4 B2 — title and button only: the Apple Health banner above
        // already asks for the connection, and the button says the rest.
        // 1.4 B4 — the one empty-state form: on the page, not in a card, and
        // the one action `.secondary`.
        HLEmptyState(
            icon: "heart.text.square",
            title: "No data yet"
        ) {
            HLButton(
                String(localized: "Capture first value"),
                icon: "plus",
                variant: .secondary,
                action: onCapture
            )
        }
        .accessibilityIdentifier("dashboard.noDataEmptyState")
    }
}

#Preview("No data yet") {
    DashboardNoDataEmptyState(onCapture: {})
        .padding()
        .hlScreenBackground()
}
