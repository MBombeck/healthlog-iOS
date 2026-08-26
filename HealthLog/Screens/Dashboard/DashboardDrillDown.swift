import SwiftUI

/// Single-presentation token for the chart-detail drill-down. Replaces the
/// pre-v0.4.0 two-`@State` race (`presentedKind` + `detailStore`) that
/// rendered `EmptyView` → black-screen on every other tap (A1-Audit §3.1,
/// user-report #2 "Seite wird schwarz und die App hängt sich auf").
///
/// W-IMPL-MOTION-POLISH (v0.5.5.1) adds the optional `namespace` payload —
/// the matched-geometry namespace owned by the presenting screen
/// (`DashboardScreen` for the dashboard path, `nil` for the Charts list
/// path until that surface adopts the same transition). The push closure
/// forwards it to `ChartDetailScreen`, which applies the destination
/// `matchedGeometryEffect` on its hero number when the namespace is
/// non-nil. The UUID `id` continues to gate per-presentation identity —
/// the namespace is presentation-stable additional context.
struct MetricDrillDown: Identifiable, Hashable {
    let kind: MetricKind
    /// Stable per-presentation id so SwiftUI treats consecutive openings of
    /// the same kind as distinct presentations (avoids reuse oddities).
    let id: UUID
    /// Optional matched-geometry namespace owned by the presenting screen.
    /// Pre-W-IMPL-MOTION-POLISH call sites pass `nil` and the destination
    /// falls through to the default push transition.
    let namespace: Namespace.ID?

    init(kind: MetricKind, namespace: Namespace.ID? = nil) {
        self.kind = kind
        id = UUID()
        self.namespace = namespace
    }

    static func == (lhs: MetricDrillDown, rhs: MetricDrillDown) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// Defensive fallback view used when `navigationDestination(item:)`
/// resolves with neither a prepared `drillDownStore` nor a live
/// `appContainer` — should never fire in production but renders
/// **something visible** instead of silently swallowing the push.
/// See WEIGHT-TILE-TAP-FIX commit for the operator-reported bug this
/// defends against. Shared between `DashboardScreen` + `ChartsScreen`
/// because both surfaces wire identical drill-down semantics into
/// `ChartDetailScreen`.
struct DrillDownErrorState: View {
    let kindRaw: String
    let surface: String

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.md) {
            Text(String(localized: "Detail view could not be loaded"))
                .font(.hlTitle3)
                .foregroundStyle(HLText.primary)
            Text(String(localized: "Please go back and tap again."))
                .font(.hlBody)
                .foregroundStyle(HLText.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(HLSpace.lg)
        .task {
            HLLog.ui.error("\(surface) drill-down fallback rendered — \(kindRaw)")
        }
    }
}
