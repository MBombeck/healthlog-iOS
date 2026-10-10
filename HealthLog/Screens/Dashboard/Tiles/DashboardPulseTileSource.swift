import Foundation

/// #20 — which heart-rate series the Dashboard pulse slot shows.
///
/// Mirrors the web dashboard (`src/app/page-client.tsx`, HealthLog v1.39.x:
/// `hasRestingHr = (summaries.RESTING_HEART_RATE?.count ?? 0) > 0`,
/// `pulseTileSummary = hasRestingHr ? rhr : p`, band only when `hasRestingHr`):
///
/// - **Resting data present** → the pulse slot shows the resting series. On iOS
///   that series already has its own tile (`.restingHeartRate`: title, headline,
///   sparkline, trend, 7d/30d from `RESTING_HEART_RATE`, and the resting band,
///   see ``MetricChartMath/bandTargetType(for:)``), so the slot renders THAT
///   tile, and the standalone resting tile is dropped so the same number does
///   not appear twice.
/// - **No resting data** (or the digest has not landed) → raw `PULSE`, which
///   never carries the resting band (HealthLog#584).
///
/// Pure, so the slot contract is unit-testable without a SwiftUI host.
enum DashboardPulseTileSource {
    /// One rendered tile: `layoutKind` is the layout row that owns the slot
    /// (order, visibility, pin), `metric` is what the tile shows.
    struct Slot: Equatable {
        let layoutKind: MetricKind
        let metric: DashboardMetric
    }

    /// The web's has-resting signal: the digest summaries carry at least one
    /// `RESTING_HEART_RATE` row.
    static func hasRestingData(_ digest: ComprehensiveDigest?) -> Bool {
        (digest?.summaries?["RESTING_HEART_RATE"]?.count ?? 0) > 0
    }

    /// Resolves the slots for `metrics` (summary order, before layout sorting).
    ///
    /// - Parameter pulseTileVisible: the user's layout shows the pulse tile.
    ///   When hidden, nothing is swapped and the resting tile keeps its own slot.
    ///
    /// When the resting tile has not been synthesized yet the pulse slot stays
    /// raw heart rate (without a band) rather than showing an invented value.
    static func slots(
        for metrics: [DashboardMetric],
        digest: ComprehensiveDigest?,
        pulseTileVisible: Bool
    ) -> [Slot] {
        let identity = metrics.map { Slot(layoutKind: $0.kind, metric: $0) }
        guard pulseTileVisible,
              hasRestingData(digest),
              metrics.contains(where: { $0.kind == .pulse }),
              let resting = metrics.first(where: { $0.kind == .restingHeartRate }) else { return identity }
        return metrics.compactMap { metric in
            switch metric.kind {
            case .pulse: Slot(layoutKind: .pulse, metric: resting)
            case .restingHeartRate: nil
            default: Slot(layoutKind: metric.kind, metric: metric)
            }
        }
    }

    /// The layout rows whose tiles need a `DashboardMetric` (placeholder until
    /// the series lands): every tile-visible metric row, plus the resting row
    /// whenever the pulse tile is visible, because the pulse slot shows the
    /// resting series on accounts that have one. A hidden resting row added this
    /// way still never gets its own slot (layout visibility drops it).
    static func tileRows(in layout: DashboardWidgetLayout) -> [(kind: MetricKind, order: Int)] {
        var rows: [(kind: MetricKind, order: Int)] = layout.widgets.compactMap { widget in
            guard widget.effectiveTileVisible, let kind = DashboardWidgetId.metricKind(forId: widget.id) else { return nil }
            return (kind, widget.order)
        }
        if rows.contains(where: { $0.kind == .pulse }), !rows.contains(where: { $0.kind == .restingHeartRate }) {
            let order = layout.widgets.first { DashboardWidgetId.metricKind(forId: $0.id) == .restingHeartRate }?.order
            rows.append((.restingHeartRate, order ?? Int.max))
        }
        return rows
    }
}
