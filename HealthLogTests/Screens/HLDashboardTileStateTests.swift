import Foundation
@testable import HealthLog
import SnapshotTesting
import Testing

/// State-dump matrix for `HLDashboardTile` — locks the descriptor-driven
/// presentation contract for every `MetricKind` plus the empty-state
/// branch. State-dumps (vs image snapshots) per Echo's rationale: image
/// snapshots of `HLCard` are pixel-fragile across SDKs; the structural
/// state is what actually changes when someone refactors the tile.
@MainActor
@Suite("HLDashboardTile state matrix")
struct HLDashboardTileStateTests {
    /// Helper builds the descriptor a tile would resolve at render time.
    private func descriptor(
        for metric: DashboardMetric,
        provenance: MeasurementSource?
    ) -> [String: String] {
        let kindDescriptor = metric.kind.descriptor
        return [
            "kind": metric.kind.rawValue,
            "sfSymbol": kindDescriptor.sfSymbol,
            "title": String(localized: kindDescriptor.title),
            "unitLabel": String(localized: kindDescriptor.unitLabel),
            "trendPolarity": String(describing: kindDescriptor.trendPolarity),
            "renderHint": String(describing: kindDescriptor.renderHint),
            "formatStyle": String(describing: kindDescriptor.formatStyle),
            "formattedValue": metric.formattedPrimary(),
            "trend": metric.trend.rawValue,
            "supportsDrillDown": "\(kindDescriptor.supportsDrillDown)",
            "provenance": provenance?.rawValue ?? "none",
            "emptyState": metric.latestValue == nil ? "true" : "false",
            "emptyStateCopy": String(localized: kindDescriptor.emptyStateCopy)
        ]
    }

    @Test("weight tile — happy-path, manual provenance")
    func weightTile() {
        let metric = DashboardMetric(
            id: "weight",
            kind: .weight,
            title: "Gewicht",
            latestValue: 72.4,
            secondaryValue: nil,
            unit: "kg",
            trend: .down,
            sparkline: [73, 72.8, 72.4],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        assertSnapshot(of: descriptor(for: metric, provenance: .manual), as: .dump)
    }

    @Test("blood pressure tile — composite display, HealthKit provenance")
    func bpTile() {
        let metric = DashboardMetric(
            id: "bp",
            kind: .bloodPressure,
            title: "Blutdruck",
            latestValue: 124,
            secondaryValue: 81,
            unit: "mmHg",
            trend: .flat,
            sparkline: [122, 124, 124],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        assertSnapshot(of: descriptor(for: metric, provenance: .appleHealth), as: .dump)
    }

    @Test("steps tile — grouped integer, higherIsBetter, HealthKit")
    func stepsTile() {
        let metric = DashboardMetric(
            id: "steps",
            kind: .steps,
            title: "Schritte",
            latestValue: 8534,
            secondaryValue: nil,
            unit: "Schritte",
            trend: .up,
            sparkline: [6000, 7000, 8534],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        assertSnapshot(of: descriptor(for: metric, provenance: .appleHealth), as: .dump)
    }

    @Test("sleep tile — duration format, neutral polarity")
    func sleepTile() {
        let metric = DashboardMetric(
            id: "sleep",
            kind: .sleep,
            title: "Schlaf",
            latestValue: 7.5,
            secondaryValue: nil,
            unit: "h",
            trend: .flat,
            sparkline: [7.0, 7.25, 7.5],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        assertSnapshot(of: descriptor(for: metric, provenance: .appleHealth), as: .dump)
    }

    @Test("SpO2 tile — rawValue is server-aligned 'oxygenSaturation'")
    func spo2Tile() {
        let metric = DashboardMetric(
            id: "oxygenSaturation",
            kind: .spo2,
            title: "Sauerstoffsättigung",
            latestValue: 97,
            secondaryValue: nil,
            unit: "%",
            trend: .flat,
            sparkline: [98, 97, 97],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        assertSnapshot(of: descriptor(for: metric, provenance: .appleHealth), as: .dump)
    }

    @Test("glucose tile — neutral polarity, integer format")
    func glucoseTile() {
        let metric = DashboardMetric(
            id: "glucose",
            kind: .glucose,
            title: "Blutzucker",
            latestValue: 98,
            secondaryValue: nil,
            unit: "mg/dL",
            trend: .up,
            sparkline: [88, 95, 98],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        assertSnapshot(of: descriptor(for: metric, provenance: .manual), as: .dump)
    }

    @Test("totalBodyWater tile — server-aligned rawValue")
    func bodyWaterTile() {
        let metric = DashboardMetric(
            id: "totalBodyWater",
            kind: .bodyWater,
            title: "Gesamtkörperwasser",
            latestValue: 38.2,
            secondaryValue: nil,
            unit: "kg",
            trend: .flat,
            sparkline: [38.0, 38.2, 38.2],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        assertSnapshot(of: descriptor(for: metric, provenance: .withings), as: .dump)
    }

    @Test("empty tile — no data, descriptor surfaces CTA copy")
    func emptyTile() {
        let metric = DashboardMetric(
            id: "boneMass",
            kind: .boneMass,
            title: "Knochenmasse",
            latestValue: nil,
            secondaryValue: nil,
            unit: "kg",
            trend: .unknown,
            sparkline: [],
            updatedAt: nil
        )
        assertSnapshot(of: descriptor(for: metric, provenance: nil), as: .dump)
    }

    @Test("trend chip colours only from a server verdict (1.5 VERDICTS)")
    func trendChipVerdictMatrix() {
        // Without a verdict every direction is monochrome; with one the
        // server's table decides; an unknown trend draws nothing.
        for trend in [TrendIndicator.up, .down, .flat] {
            #expect(TrendChip(trend: trend, mode: .neutral).colorRole == .textSecondary)
        }
        #expect(TrendChip(trend: .unknown, mode: .neutral).colorRole == .none)
        #expect(TrendChip(trend: .up, mode: .serverSentiment(.upGood)).colorRole == .statusOK)
        #expect(TrendChip(trend: .up, mode: .serverSentiment(.upBad)).colorRole == .statusBad)
        #expect(TrendChip(trend: .down, mode: .serverSentiment(.upBad)).colorRole == .statusOK)
        #expect(TrendChip(trend: .up, mode: .serverSentiment(.hold)).colorRole == .textSecondary)
        #expect(TrendChip(trend: .flat, mode: .serverSentiment(.hold)).colorRole == .statusOK)
        #expect(TrendChip(trend: .up, mode: .serverSentiment(.unknown)).colorRole == .textSecondary)
        #expect(TrendChip(trend: .unknown, mode: .serverVerdict(.positive)).colorRole == .none)
    }

    @Test("dashboard metric shows the server's trend only — no sparkline-derived arrow (#115 B7)")
    func dashboardMetricEffectiveTrend() {
        let supported = DashboardMetric(
            id: "sleep",
            kind: .sleep,
            title: "Schlaf",
            latestValue: 7.5,
            secondaryValue: nil,
            unit: "h",
            trend: .unknown,
            sparkline: [6.8, 7.5],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let clinical = DashboardMetric(
            id: "pulse",
            kind: .pulse,
            title: "Puls",
            latestValue: 70,
            secondaryValue: nil,
            unit: "bpm",
            trend: .up,
            sparkline: [65, 70],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        #expect(supported.dashboardTrend == .unknown)
        #expect(clinical.dashboardTrend == .up)
        // 1.5 VERDICTS — no verdict anywhere: neutral, also for a rising pulse
        // the old polarity table painted red.
        #expect(TileTrendVerdicts.none.mode(for: supported) == .neutral)
        #expect(TileTrendVerdicts.none.mode(for: clinical) == .neutral)
        #expect(TrendChip(
            trend: clinical.dashboardTrend,
            mode: TileTrendVerdicts.none.mode(for: clinical)
        ).colorRole == .textSecondary)
    }
}
