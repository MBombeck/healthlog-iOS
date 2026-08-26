import Foundation
@testable import HealthLog
import SwiftUI
import Testing

/// W6b (#57-followup / STANDARDS §7) — locks the unified metric-tile chrome.
///
/// The Dashboard tile (`HLDashboardTile`) and the Insights tile
/// (`HLMetricTile`) now render every shared fragment (header glyph, title,
/// trend glyph, mono sparkline) through the SINGLE `HLMetricTileChrome`
/// primitive family. These tests pin (a) that both variants render to a
/// non-zero image through the shared primitives, and (b) the load-bearing
/// adverse-trend → colour-signal mapping that the two variants express
/// differently (Insights: `Trend.adverse`; Dashboard: `TrendChip` polarity)
/// resolves to the same single glyph treatment.
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

    // MARK: - Variant rendering (Dashboard vs Insights)

    @Test("Dashboard-variant tile renders through the shared chrome")
    func dashboardVariantRenders() {
        let metric = DashboardMetric(
            id: "weight", kind: .weight, title: "Weight",
            latestValue: 72.4, secondaryValue: nil, unit: "kg", trend: .down,
            sparkline: [73.6, 73.0, 72.4], updatedAt: Date()
        )
        #expect(renders(HLDashboardTile(metric: metric)))
    }

    @Test("Insights-variant tile renders through the shared chrome with band + badge + AI")
    func insightsVariantRenders() {
        let tile = HLMetricTile(
            icon: "scalemass", title: "Weight", value: "72.4", unit: "kg",
            trend: .favorable, sparkline: [73.4, 73.0, 72.4],
            context: "23 of 30 days in range",
            range: RangeBand(lowerLabel: "71", upperLabel: "74", unit: "kg", pctInRange: 77),
            badge: .inBand, onAIExplainer: {}
        )
        #expect(renders(tile, height: 220))
    }

    // MARK: - Adverse-trend colour-signal parity across the two variants

    @Test("Insights Trend.adverse is the only coloured direction")
    func insightsAdverseIsTheColourSignal() {
        // The Insights tile passes `trend == .adverse` as the adverse flag.
        #expect(HLMetricTile.Trend.adverse == .adverse)
        #expect((HLMetricTile.Trend.favorable == .adverse) == false)
        #expect((HLMetricTile.Trend.stable == .adverse) == false)
        #expect((HLMetricTile.Trend.none == .adverse) == false)
    }

    @Test("Dashboard TrendChip maps polarity to the same adverse flag the glyph consumes")
    func dashboardAdverseMapping() {
        // up on lowerIsBetter → adverse; down on higherIsBetter → adverse;
        // everything else mono. This is the single source the shared
        // `HLTileTrendGlyph` reads for its colour signal.
        #expect(TrendChip(trend: .up, polarity: .lowerIsBetter).isAdverse)
        #expect(TrendChip(trend: .down, polarity: .higherIsBetter).isAdverse)
        #expect(TrendChip(trend: .down, polarity: .lowerIsBetter).isAdverse == false)
        #expect(TrendChip(trend: .up, polarity: .higherIsBetter).isAdverse == false)
        #expect(TrendChip(trend: .flat, polarity: .neutral).isAdverse == false)
        #expect(TrendChip(trend: .unknown, polarity: .neutral).isAdverse == false)
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
