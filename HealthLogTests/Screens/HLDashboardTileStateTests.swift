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

    @Test("trend chip dashboard-direction mode is literal across polarity")
    func trendChipDashboardDirectionMatrix() {
        // This is the requested literal dashboard indicator mode, independent
        // of clinical polarity: up = green, down = red, flat = secondary,
        // unknown = absent. Polarity-aware semantics elsewhere stay unchanged.
        let polarities: [MetricKindDescriptor.TrendPolarity] = [.higherIsBetter, .lowerIsBetter, .neutral]
        let trends: [TrendIndicator] = [.up, .down, .flat, .unknown]
        var matrix: [String: String] = [:]
        for polarity in polarities {
            for trend in trends {
                let color = TrendChip(
                    trend: trend,
                    polarity: polarity,
                    mode: .dashboardDirection
                ).colorRole.rawValue
                matrix["\(polarity).\(trend.rawValue)"] = color
            }
        }
        assertSnapshot(of: matrix, as: .dump)
    }

    @Test("trend chip default mode preserves polarity-aware clinical semantics")
    func trendChipDefaultPolarityMatrix() {
        #expect(TrendChip(trend: .up, polarity: .lowerIsBetter).colorRole == .statusBad)
        #expect(TrendChip(trend: .down, polarity: .higherIsBetter).colorRole == .statusBad)
        #expect(TrendChip(trend: .up, polarity: .higherIsBetter).colorRole == .textSecondary)
        #expect(TrendChip(trend: .down, polarity: .lowerIsBetter).colorRole == .textSecondary)
        #expect(TrendChip(trend: .flat, polarity: .neutral).colorRole == .textSecondary)
        #expect(TrendChip(trend: .unknown, polarity: .neutral).colorRole == .none)
    }

    @Test("dashboard metric derives only supported unknown trends from its visible sparkline")
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

        #expect(supported.dashboardTrend == .up)
        #expect(clinical.dashboardTrend == .up)
        #expect(supported.dashboardTrendMode == .dashboardDirection)
        #expect(clinical.dashboardTrendMode == .polarityAware)
        #expect(TrendChip(
            trend: clinical.dashboardTrend,
            polarity: clinical.kind.descriptor.trendPolarity,
            mode: clinical.dashboardTrendMode
        ).colorRole == .statusBad)
    }
}
