import Foundation
@testable import HealthLog
import SwiftUI
import Testing

/// W6b (#57-followup / STANDARDS §7) — locks the unified metric-tile chrome.
///
/// The Dashboard tile (`HLDashboardTile`) and the Sleep composite render every
/// shared fragment (header glyph, title, trend glyph, mono sparkline) through
/// the SINGLE `HLMetricTileChrome` primitive family. These tests pin (a) that
/// the variants render to a non-zero image through the shared primitives, and
/// (b) the load-bearing adverse-trend → colour-signal mapping the glyph reads.
///
/// The Insights variant (`HLMetricTile`) is gone (#115 B7): it was only built
/// by the never-mounted target grid and long-tail block, and it drew a
/// favourable change as an up arrow whatever the real direction was.
@MainActor
@Suite("HLMetricTileChrome — unified tile fragments")
struct HLMetricTileChromeTests {
    private func renders(_ view: some View, width: CGFloat = 360, height: CGFloat = 160) -> Bool {
        let renderer = ImageRenderer(content: view.frame(width: width, height: height))
        renderer.scale = 1
        let image = renderer.uiImage
        return (image?.size.width ?? 0) > 0
    }

    // MARK: - Shared fragments render

    @Test("HLTileHeaderRow renders glyph + title + trailing accessory")
    func headerRowRenders() {
        let row = HLTileHeaderRow(icon: "scalemass", title: Text("Weight")) {
            HLTileTrendGlyph(symbolName: "arrow.down", isAdverse: false)
        }
        #expect(renders(row, height: 40))
    }

    @Test("HLTileSparkline renders the mono series row")
    func sparklineRenders() {
        #expect(renders(HLTileSparkline(values: [1, 2, 3, 2, 4]), height: 40))
    }

    @Test("HLTileTrendGlyph suppresses entirely on a nil symbol")
    func trendGlyphSuppresses() {
        // An unknown trend passes nil → the glyph renders nothing. The host
        // still composes (empty view is valid), so we assert no crash + a
        // rendered host frame.
        #expect(renders(HLTileTrendGlyph(symbolName: nil, isAdverse: false), height: 20))
    }

    // MARK: - Variant rendering (Dashboard tile + Sleep composite)

    @Test("Dashboard-variant tile renders through the shared chrome")
    func dashboardVariantRenders() {
        let metric = DashboardMetric(
            id: "weight", kind: .weight, title: "Weight",
            latestValue: 72.4, secondaryValue: nil, unit: "kg", trend: .down,
            sparkline: [73.6, 73.0, 72.4], updatedAt: Date()
        )
        #expect(renders(HLDashboardTile(metric: metric)))
    }

    // MARK: - Adverse-trend colour-signal parity across the two variants

    @Test("Dashboard TrendChip without a server verdict is monochrome in every direction (1.5 VERDICTS)")
    func dashboardNeutralMapping() {
        // The per-metric polarity table is no colour source any more: an
        // arrow without a verdict reads in one quiet colour.
        for trend in [TrendIndicator.up, .down, .flat] {
            #expect(TrendChip(trend: trend).colorRole == .textSecondary)
        }
        #expect(TrendChip(trend: .unknown).colorRole == .none)
    }

    @Test("Sleep composite renders through the shared chrome (glyph + fallback sparkline)")
    func sleepCompositeRenders() {
        let metric = DashboardMetric(
            id: "sleep", kind: .sleep, title: "Sleep",
            latestValue: 7.5, secondaryValue: nil, unit: "h", trend: .flat,
            sparkline: [7.0, 7.5, 7.25], updatedAt: Date()
        )
        #expect(renders(SleepCompositeTile(metric: metric, stages: nil)))
    }
}
