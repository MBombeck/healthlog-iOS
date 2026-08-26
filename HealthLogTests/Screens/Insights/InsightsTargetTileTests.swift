import Foundation
@testable import HealthLog
import SwiftUI
import Testing

/// v0.6.1.1 (handbook drift D-013 close) — regression locks for the new
/// `InsightsTargetTile` primitive + the `InsightsTargetTileGrid` mapping
/// from the API target type strings to the Gewicht / Ruhepuls / Mood /
/// Steps / Compliance row composition.
@Suite("InsightsTargetTile + InsightsTargetTileGrid")
@MainActor
struct InsightsTargetTileTests {
    // MARK: - Trend resolver

    @Test("Trend.resolve maps API down + lowerIsBetter to favorable")
    func trendDownLowerIsBetterIsFavorable() {
        let trend = InsightsTargetTile.Trend.resolve(apiTrend: .down, lowerIsBetter: true)
        #expect(trend.symbolName == "arrow.up")
        // favourable still inherits HLText.secondary (mono), not statusBad
    }

    @Test("Trend.resolve maps API up + lowerIsBetter to adverse")
    func trendUpLowerIsBetterIsAdverse() {
        let trend = InsightsTargetTile.Trend.resolve(apiTrend: .up, lowerIsBetter: true)
        #expect(trend.symbolName == "arrow.down")
    }

    @Test("Trend.resolve handles nil API trend gracefully")
    func trendNilIsNone() {
        let trend = InsightsTargetTile.Trend.resolve(apiTrend: nil, lowerIsBetter: false)
        #expect(trend.symbolName == nil)
    }

    // MARK: - InTargetState resolver

    @Test("InTargetState picks the most recent non-nil bucket as the badge")
    func inTargetStateLatestBucketWins() {
        let buckets: [InsightsTargetsResponseDTO.TargetItem.ConsistencyBucket?] = [
            .outBand, .outBand, nil, .nearBand, .inBand, nil, nil
        ]
        let state = InsightsTargetTile.InTargetState.resolve(
            consistency7d: buckets,
            insufficient: false,
            hasRange: true
        )
        #expect(state == .inBand)
    }

    @Test("InTargetState returns unknown when no range configured")
    func inTargetStateNoRangeUnknown() {
        let buckets: [InsightsTargetsResponseDTO.TargetItem.ConsistencyBucket?] = [.inBand]
        let state = InsightsTargetTile.InTargetState.resolve(
            consistency7d: buckets,
            insufficient: false,
            hasRange: false
        )
        #expect(state == .unknown)
    }

    @Test("InTargetState returns unknown when insufficientData flag set")
    func inTargetStateInsufficientUnknown() {
        let buckets: [InsightsTargetsResponseDTO.TargetItem.ConsistencyBucket?] = [.inBand]
        let state = InsightsTargetTile.InTargetState.resolve(
            consistency7d: buckets,
            insufficient: true,
            hasRange: true
        )
        #expect(state == .unknown)
    }

    @Test("inBand state surfaces the 'Im Zielbereich' badge label")
    func inBandBadgeLabel() {
        #expect(InsightsTargetTile.InTargetState.inBand.badge?.label == "Im Zielbereich")
    }

    @Test("unknown state surfaces no badge")
    func unknownBadgeNil() {
        #expect(InsightsTargetTile.InTargetState.unknown.badge == nil)
    }

    // MARK: - Render smoke

    @Test("InsightsTargetTile renders to a non-zero image")
    func tileRenders() {
        let view = InsightsTargetTile(
            iconSystemName: "scalemass",
            title: "Gewicht",
            valueText: "72,4",
            unitText: "kg",
            sparkline: [73.0, 72.8, 72.6, 72.5, 72.4],
            trend: .favorable,
            inTargetState: .inBand,
            supportLine: "Ø 30 T 72,8 kg"
        )
        let renderer = ImageRenderer(content: view.frame(width: 360, height: 180))
        renderer.scale = 1
        let image = renderer.uiImage
        #expect(image != nil)
        #expect((image?.size.width ?? 0) > 0)
    }

    @Test("InsightsTargetTile half-width compact pair renders side by side")
    func halfWidthPairRenders() {
        let pair = HStack(spacing: HLSpace.md) {
            InsightsTargetTile(
                iconSystemName: "face.smiling",
                title: "Stimmung",
                valueText: "3,8",
                sparkline: [3.4, 3.6, 3.8],
                compact: true
            )
            InsightsTargetTile(
                iconSystemName: "waveform.path.ecg",
                title: "Stabilität",
                valueText: "82",
                unitText: "%",
                sparkline: [78, 80, 82],
                compact: true
            )
        }
        let renderer = ImageRenderer(content: pair.frame(width: 393, height: 180))
        renderer.scale = 1
        let image = renderer.uiImage
        #expect(image != nil)
    }

    // MARK: - InsightsScreen composition contract

    private func loadInsightsScreenSource() throws -> String {
        let testFilePath = URL(fileURLWithPath: #filePath)
        let repoRoot = testFilePath
            .deletingLastPathComponent() // Insights/
            .deletingLastPathComponent() // Screens/
            .deletingLastPathComponent() // HealthLogTests/
            .deletingLastPathComponent() // repo root
        let insightsDir = repoRoot
            .appendingPathComponent("HealthLog")
            .appendingPathComponent("Screens")
            .appendingPathComponent("Insights")
        // W-PERF-INSIGHTS (v0152) — the overview's loaded composition (incl. the
        // Trends row mount) was extracted into store-scoped leaves in
        // `Sub/InsightsOverviewSlots.swift` (pure code movement) to shrink
        // Observation invalidation. Scan both so the go-deeper contract follows.
        let screen = try String(
            contentsOf: insightsDir.appendingPathComponent("InsightsScreen.swift"),
            encoding: .utf8
        )
        let slots = try String(
            contentsOf: insightsDir
                .appendingPathComponent("Sub")
                .appendingPathComponent("InsightsOverviewSlots.swift"),
            encoding: .utf8
        )
        return screen + "\n" + slots
    }

    @Test("InsightsScreen no longer composes the overview \"Deine Ziele\" tile grid (I-3 ITEM 4)")
    func insightsScreenDropsTileGrid() throws {
        // I-3 ITEM 4 — the overview "Deine Ziele" `InsightsTargetTileGrid`
        // (Gewicht/Ruhepuls/Mood+Stabilität/Schritte/Compliance) was removed
        // because every one of those metrics owns a per-metric Insights page
        // reachable via the tab strip — the grid duplicated them. The grid type
        // + tile still exist (covered by the unit tests in this suite) for any
        // future reuse; they are simply no longer mounted on the overview.
        let source = try loadInsightsScreenSource()
        let codeLines = source.components(separatedBy: "\n").filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.hasPrefix("//") && !trimmed.hasPrefix("///")
        }
        let codeBody = codeLines.joined(separator: "\n")
        #expect(!codeBody.contains("InsightsTargetTileGrid("))
        // v0.14.9 §1 — the "Rückblick" retrospective card was removed from the
        // overview (operator: doesn't fit, too much). It must NOT be mounted.
        #expect(!codeBody.contains("InsightsRetrospectiveCard("))
    }

    @Test("InsightsScreen renders the inline Trends row but NOT the relocated correlations row")
    func insightsScreenWiresGoDeeperInlineBlocks() throws {
        let source = try loadInsightsScreenSource()
        let codeLines = source.components(separatedBy: "\n").filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.hasPrefix("//") && !trimmed.hasPrefix("///")
        }
        let codeBody = codeLines.joined(separator: "\n")
        // The on-device briefing-driven mini-chart Trends row stays on the
        // overview.
        #expect(codeBody.contains("InsightsTrendsRow("))
        // I-1 D — the cross-metric correlation cards were RELOCATED off the
        // overview onto the per-metric pages they belong to (Weight×BP →
        // Blutdruck, Mood×Puls → Puls, Mood×Gewicht → Gewicht, Mood×BP →
        // Stimmung, BP×Compliance → Medikamente). The overview must no longer
        // render `InsightsCorrelationsRow` (no duplication).
        #expect(!codeBody.contains("InsightsCorrelationsRow("))
    }

    @Test("InsightsScreen.tileGridCoveredKinds includes weight when target present")
    func tileGridCoverageWeight() {
        let item = InsightsTargetsResponseDTO.TargetItem(
            type: "WEIGHT",
            label: "Gewicht",
            current: 72.4,
            average30: 72.8,
            trend: .down,
            unit: "kg",
            range: .init(min: 68, max: 75),
            classification: nil,
            source: "weight",
            daysInRange7d: 5,
            daysLogged7d: 6,
            daysInRange30d: 22,
            daysLogged30d: 28,
            lastMetGoalAt: nil,
            streakDays: 3,
            insufficientData: false,
            consistency7d: [.inBand, .inBand, .nearBand, .inBand, nil, .inBand, .inBand]
        )
        let excluded = InsightsScreen.tileGridCoveredKinds([item])
        #expect(excluded.contains(.weight))
        #expect(!excluded.contains(.hrv))
    }
}
