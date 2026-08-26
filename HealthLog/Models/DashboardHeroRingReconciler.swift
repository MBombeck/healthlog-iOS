import Foundation

/// **v0141 — reconciles the dashboard hero score rings onto the Insights source.**
///
/// **Root cause of the data mismatch.** The dashboard hero rings ride the
/// `GET /api/dashboard/snapshot` payload (``DashboardSnapshotBriefing/scoreRings``),
/// which the server serves through a stale-while-revalidate cache
/// (`caches.analytics`, keyed `${userId}|dashboard-snapshot`). The Insights
/// wellness rings come from `GET /api/insights/derived`
/// (``DerivedInsightsStore``), computed LIVE per request. Both call the IDENTICAL
/// server engine (`computeDerivedMetric`) with the same rounding
/// (`clamp100`/`Math.round`), so the two numbers only ever diverge by the
/// cache-freshness skew between the two reads — the operator saw the hero and the
/// Insights overview show the same score a point or two apart while today's data
/// kept landing.
///
/// This reconciler keeps the snapshot rings as the authority for WHICH rings show,
/// their ORDER, and the `MED_COMPLIANCE` dose tally (a snapshot-only value the
/// Insights overview never renders), but OVERRIDES each derived ring's displayed
/// score + band with the live ``DerivedInsightsStore`` value when it is present —
/// so the hero and Insights read ONE source and always agree. When the live store
/// has not loaded a metric yet, it falls back to the snapshot's own value, so the
/// hero never regresses to blank.
///
/// Pure + off-main-actor testable: no SwiftUI, no store — feed it the two decoded
/// arrays and it returns the ordered, reconciled rows.
public enum DashboardHeroRingReconciler {
    /// Which server read backed the displayed value — surfaced for tests + honesty.
    public enum Source: Equatable, Sendable {
        /// The live `/api/insights/derived` value (the shared Insights source).
        case live
        /// The snapshot's own value (live source not loaded, or `MED_COMPLIANCE`).
        case snapshot
    }

    /// One reconciled hero ring row, view-ready.
    public struct Row: Equatable, Sendable, Identifiable {
        /// The snapshot ring — authority for id / order / doses / fallback value.
        public let ring: DashboardScoreRing
        /// The live derived score, when ``DerivedInsightsStore`` carries this metric.
        public let liveScore: Int?
        /// The live derived band, when present.
        public let liveBand: String?

        public var id: ScoreRingID {
            ring.id
        }

        /// `.live` when the shared Insights source backed the value, else `.snapshot`.
        public var source: Source {
            liveScore == nil ? .snapshot : .live
        }

        /// The score to paint — the live value wins, the snapshot value falls back.
        public var displayScore: Int {
            liveScore ?? ring.score
        }

        /// The band to paint — the live value wins, the snapshot value falls back.
        public var displayBand: String {
            liveBand ?? ring.band
        }

        /// 0…1 ring fill for the display score, clamped. Never extrapolated.
        public var fraction: Double {
            max(0, min(1, Double(displayScore) / 100))
        }

        public init(ring: DashboardScoreRing, liveScore: Int? = nil, liveBand: String? = nil) {
            self.ring = ring
            self.liveScore = liveScore
            self.liveBand = liveBand
        }
    }

    /// The derived score-ring ids that have a `/api/insights/derived` counterpart.
    /// `MED_COMPLIANCE` is intentionally absent — its dose tally is a snapshot-only
    /// value the Insights overview never computes, so it always keeps its snapshot
    /// value.
    private static let derivedRingIDs: Set<ScoreRingID> = [.readiness, .recovery, .sleepScore]

    /// Reconcile the server-resolved snapshot rings against the live derived
    /// metrics. Order + membership follow `snapshotRings` (the server's own
    /// selection resolution); a derived ring whose id matches an `ok`,
    /// value-bearing ``DerivedMetricDTO`` adopts that live score + band.
    public static func reconcile(
        snapshotRings: [DashboardScoreRing],
        derived: [DerivedMetricDTO]
    ) -> [Row] {
        // Index the live, value-bearing derived metrics by their server id. The
        // batch route returns each id at most once; first-wins is defensive.
        let liveByMetric: [String: DerivedMetricDTO] = derived.reduce(into: [:]) { acc, dto in
            guard dto.isOK, dto.value?.score != nil, acc[dto.metric] == nil else { return }
            acc[dto.metric] = dto
        }
        return snapshotRings.map { ring in
            guard Self.derivedRingIDs.contains(ring.id),
                  let dto = liveByMetric[ring.id.rawValue],
                  let score = dto.value?.score else
            {
                return Row(ring: ring)
            }
            return Row(ring: ring, liveScore: Int(score.rounded()), liveBand: dto.value?.band)
        }
    }
}
