import SwiftUI

// MARK: - HLDashboardTile previews

//
// Split out of `HLDashboardTile.swift` (AUD-2 H4) so the context-line memo
// additions kept the tile file under the `file_length` budget. Preview-only —
// no behaviour change.

#Preview("Tile — happy path") {
    let metric = DashboardMetric(
        id: "steps",
        kind: .steps,
        title: "Steps",
        latestValue: 8534,
        secondaryValue: nil,
        unit: "Steps",
        trend: .up,
        sparkline: [5234, 6100, 7400, 7000, 7800, 8000, 8534],
        updatedAt: Date()
    )
    HLDashboardTile(metric: metric)
        .padding()
        .hlScreenBackground()
}

#Preview("Tile — empty state") {
    let metric = DashboardMetric(
        id: "spo2",
        kind: .spo2,
        title: "Oxygen saturation",
        latestValue: nil,
        secondaryValue: nil,
        unit: "%",
        trend: .unknown,
        sparkline: [],
        updatedAt: nil
    )
    HLDashboardTile(metric: metric)
        .padding()
        .hlScreenBackground()
}

#Preview("Tile — BP composite") {
    let metric = DashboardMetric(
        id: "bp",
        kind: .bloodPressure,
        title: "Blood pressure",
        latestValue: 124,
        secondaryValue: 81,
        unit: "mmHg",
        trend: .flat,
        sparkline: [120, 122, 124, 125, 122, 123, 124],
        updatedAt: Date()
    )
    HLDashboardTile(metric: metric)
        .padding()
        .hlScreenBackground()
}

#Preview("Tile — weight (lowerIsBetter, down=green)") {
    let metric = DashboardMetric(
        id: "weight",
        kind: .weight,
        title: "Weight",
        latestValue: 72.4,
        secondaryValue: nil,
        unit: "kg",
        trend: .down,
        sparkline: [73.6, 73.4, 73.0, 72.9, 72.7, 72.5, 72.4],
        updatedAt: Date()
    )
    HLDashboardTile(metric: metric)
        .padding()
        .hlScreenBackground()
}
