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
/// - **Band** reuses the SAME `InsightsTargetRangeBand.rangeBand(...)` math the
///   Insights target panel uses, so the Dashboard and Insights surfaces can
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
    ///
    /// **#20** — the target row is picked by ``MetricChartMath/bandTargetType(for:)``,
    /// not by the summary key: the server's `PULSE` row is the resting-pulse band,
    /// so it lands on `.restingHeartRate` and never on raw `.pulse`.
    ///
    /// **#115 P2** — `units` are the account's display units; the band's
    /// canonical bounds convert into them, the same way the headline and the
    /// 7-/30-day averages above it do.
    static func targetBand(
        for kind: MetricKind,
        targets: InsightsTargetsResponseDTO?,
        units: UnitPreferences
    ) -> RangeBand? {
        guard kind.descriptor.formatStyle != .bloodPressureCompound else { return nil }
        // #20 — the band row follows the tile's SERIES: the resting-pulse band
        // (server type `PULSE`) belongs to the resting tile, raw pulse gets none.
        guard let type = MetricChartMath.bandTargetType(for: kind),
              let target = targets?.targets.first(where: { $0.type == type }) else { return nil }
        return InsightsTargetRangeBand.rangeBand(
            range: target.range,
            insufficient: target.insufficientData,
            daysInRange30d: target.daysInRange30d,
            daysLogged30d: target.daysLogged30d,
            unit: target.unit,
            type: target.type,
            units: units
        )
    }
}
