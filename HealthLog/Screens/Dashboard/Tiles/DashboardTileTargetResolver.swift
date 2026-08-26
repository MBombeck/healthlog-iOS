import Foundation

/// Build 7 / item 7.1 — pure resolver projecting the two secondary stats the
/// **web** dashboard tile (`trend-card.tsx`) ships on every card: the 7-/30-day
/// averages (from the comprehensive digest) and the optional target band
/// ("Zielband", from the personal-targets endpoint).
///
/// Kept as an enum of `nonisolated static` pure functions so the projection
/// contract is unit-testable without a SwiftUI render pass or a live store.
///
/// - **Averages** ride `ComprehensiveDigest.summaries[key].avg7 / avg30` — the
///   exact fields the web tile forwards into `<TrendCard avg7 avg30>`.
/// - **Band** reuses the SAME `InsightsTargetTileGrid.rangeBand(...)` math the
///   Insights target tiles use, so the Dashboard and Insights surfaces can
///   never drift on the in-range percentage or the band labels.
///
/// The `MetricKind → server summary key` mapping is the single
/// `MetricKind.availabilitySummaryKey` table (e.g. `WEIGHT`, `ACTIVITY_STEPS`),
/// so both projections key off the same contract.
enum DashboardTileTargetResolver {
    /// 7-/30-day averages (server-canonical units — the tile converts + formats
    /// them with the same `formatScalar` path as its headline value).
    struct Averages: Equatable {
        let avg7: Double?
        let avg30: Double?
    }

    /// Averages for `kind`, or `nil` when the digest carries no summary for it,
    /// BOTH windows are empty, or the kind is the composite blood-pressure tile.
    ///
    /// **BP omission (honest):** the digest summary for blood pressure is
    /// systolic-only (`BLOOD_PRESSURE_SYS`). A "7d 124" sub-row next to a
    /// "124/81" headline would read as a mismatched half value, so we omit the
    /// averages entirely for the compound tile — mirroring how BP is split into
    /// two distinct tiles on the web dashboard.
    static func averages(for kind: MetricKind, digest: ComprehensiveDigest?) -> Averages? {
        guard kind.descriptor.formatStyle != .bloodPressureCompound else { return nil }
        guard let key = kind.availabilitySummaryKey,
              let summary = digest?.summaries?[key] else { return nil }
        guard summary.avg7 != nil || summary.avg30 != nil else { return nil }
        return Averages(avg7: summary.avg7, avg30: summary.avg30)
    }

    /// Target band ("Zielband") for `kind`, or `nil` when the user has no target
    /// configured, the window is insufficient, or the kind is the composite
    /// blood-pressure tile (its systolic-only band would misrepresent the
    /// paired reading — the Insights BP panel carries the full sys/dia bands).
    static func targetBand(
        for kind: MetricKind,
        targets: InsightsTargetsResponseDTO?
    ) -> RangeBand? {
        guard kind.descriptor.formatStyle != .bloodPressureCompound else { return nil }
        guard let key = kind.availabilitySummaryKey,
              let target = targets?.targets.first(where: { $0.type == key }) else { return nil }
        return InsightsTargetTileGrid.rangeBand(
            range: target.range,
            insufficient: target.insufficientData,
            daysInRange30d: target.daysInRange30d,
            daysLogged30d: target.daysLogged30d,
            unit: target.unit,
            type: target.type
        )
    }
}
