import Foundation

/// W52 (v0.11 overview rework) — pure derivation helpers extracted out of
/// `InsightsScreen.swift` so the screen body stays under the length cap after the
/// inline Vitals dashboard block landed. Both are pure reads over server payloads
/// with no view state.
extension InsightsScreen {
    /// Server target-type strings → `MetricKind` mapping used to filter the
    /// long-tail "Weitere Werte" cards so we don't duplicate a tile that already
    /// lives in the `InsightsTargetTileGrid`. Targets the user doesn't have
    /// configured pass through and the long-tail can still surface them via the
    /// standard per-kind block.
    static func tileGridCoveredKinds(
        _ targets: [InsightsTargetsResponseDTO.TargetItem]
    ) -> Set<MetricKind> {
        var excluded: Set<MetricKind> = []
        for target in targets {
            switch target.type {
            case "WEIGHT": excluded.insert(.weight)
            case "PULSE": excluded.insert(.pulse)
            case "RESTING_HR": excluded.insert(.restingHeartRate)
            case "ACTIVITY_STEPS": excluded.insert(.steps)
            case "BODY_FAT": excluded.insert(.bodyFat)
            case "SLEEP_DURATION": excluded.insert(.sleep)
            default: break
            }
        }
        return excluded
    }
}
