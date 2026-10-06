import Foundation
@testable import HealthLog
import Testing

/// #115 · 1.1 — the weight tile is coloured by the server's target-aware
/// verdict (`GET /api/dashboard/snapshot` → `tiles.weightTrend`, v1.39), not by
/// a client rule that calls every fall good and every rise bad.
///
/// Fixture shapes follow `docs/api/openapi.yaml` at `v1.39.0`
/// (`tiles.weightTrend { direction, targetPosition }`) and the server's own
/// expectations in `src/lib/dashboard/__tests__/snapshot.test.ts`
/// ("below the target: a gain is progress" → `up-good` / `below`).
@Suite("Weight trend — server verdict (#115 1.1)")
@MainActor
struct WeightTrendServerVerdictTests {
    // MARK: - Contract

    private static func snapshot(tiles: String?) -> String {
        let tilesPart = tiles.map { #", "tiles": \#($0)"# } ?? ""
        return #"""
        {
          "briefing": null,
          "briefingState": "ready",
          "briefingUpdatedAt": null,
          "briefingStale": false,
          "healthScore": { "score": 71, "band": "green", "delta": 2 }\#(tilesPart)
        }
        """#
    }

    private static func decode(_ json: String) throws -> DashboardSnapshotBriefing {
        try JSONDecoder.hlDefault.decode(DashboardSnapshotBriefing.self, from: Data(json.utf8))
    }

    @Test("v1.39 snapshot: below the target a gain is progress")
    func decodesServerVerdict() throws {
        let tiles = #"""
        { "summaries": {}, "lastSeenByType": {}, "mood": { "summary": null, "entries": [] },
          "weightTrend": { "direction": "up-good", "targetPosition": "below" } }
        """#
        let decoded = try Self.decode(Self.snapshot(tiles: tiles))
        #expect(decoded.weightTrend == WeightTrendJudgement(direction: .upGood, targetPosition: .below))
        #expect(decoded.healthScore?.score == 71)
    }

    @Test("inside the band the server says hold")
    func decodesHold() throws {
        let tiles = #"{ "weightTrend": { "direction": "hold", "targetPosition": "inside" } }"#
        let decoded = try Self.decode(Self.snapshot(tiles: tiles))
        #expect(decoded.weightTrend?.direction == .hold)
        #expect(decoded.weightTrend?.targetPosition == .inside)
    }

    @Test("snapshot without the block (older server / cached cell) reads as the documented up-bad")
    func absentBlockIsServerDocumentedUpBad() throws {
        let withoutTiles = try Self.decode(Self.snapshot(tiles: nil))
        #expect(withoutTiles.weightTrend == .legacyReading)
        let withoutBlock = try Self.decode(Self.snapshot(tiles: #"{ "summaries": {} }"#))
        #expect(withoutBlock.weightTrend?.direction == .upBad)
        #expect(withoutBlock.weightTrend?.targetPosition == nil)
    }

    @Test("an unknown direction word colours nothing and keeps the snapshot")
    func unknownDirectionIsTolerated() throws {
        let tiles = #"{ "weightTrend": { "direction": "zz-from-the-future", "targetPosition": "nowhere" } }"#
        let decoded = try Self.decode(Self.snapshot(tiles: tiles))
        #expect(decoded.weightTrend?.direction == .unknown)
        #expect(decoded.weightTrend?.targetPosition == .unknown)
        #expect(decoded.healthScore?.score == 71)
    }

    // MARK: - Rendering

    private static func weightMetric(trend: TrendIndicator, sparkline: [Double] = [80, 81]) -> DashboardMetric {
        DashboardMetric(
            id: "weight",
            kind: .weight,
            title: "Gewicht",
            latestValue: 81,
            secondaryValue: nil,
            unit: "kg",
            trend: trend,
            sparkline: sparkline,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private static func role(
        _ trend: TrendIndicator,
        _ sentiment: TrendDirectionSentiment?
    ) -> TrendChip.ColorRole {
        let metric = weightMetric(trend: trend)
        return TrendChip(
            trend: metric.dashboardTrend,
            polarity: metric.kind.descriptor.trendPolarity,
            mode: metric.dashboardTrendMode(weightSentiment: sentiment)
        ).colorRole
    }

    @Test("a gain below the target is progress, a gain above it is not")
    func gainFollowsTheTarget() {
        #expect(Self.role(.up, .upGood) == .statusOK)
        #expect(Self.role(.up, .upBad) == .statusBad)
        #expect(Self.role(.down, .upGood) == .statusBad)
        #expect(Self.role(.down, .upBad) == .statusOK)
    }

    @Test("hold: level is progress, a move either way is neutral")
    func holdSemantics() {
        #expect(Self.role(.flat, .hold) == .statusOK)
        #expect(Self.role(.up, .hold) == .textSecondary)
        #expect(Self.role(.down, .hold) == .textSecondary)
    }

    @Test("no snapshot (offline, not loaded) or an unknown verdict colours nothing")
    func noVerdictNoColour() {
        #expect(Self.role(.up, nil) == .textSecondary)
        #expect(Self.role(.down, nil) == .textSecondary)
        #expect(Self.role(.up, .unknown) == .textSecondary)
    }

    @Test("weight no longer derives a direction from its sparkline")
    func noSparklineFallbackForWeight() {
        #expect(Self.weightMetric(trend: .unknown, sparkline: [70, 75]).dashboardTrend == .unknown)
        // The server's own arrow still renders.
        #expect(Self.weightMetric(trend: .down, sparkline: [72, 73]).dashboardTrend == .down)
    }

    @Test("Insights no longer hard-codes weight as lower-is-better")
    func catalogCarriesNoWeightJudgement() {
        #expect(MetricKind.weight.descriptor.trendPolarity == .neutral)
    }
}
