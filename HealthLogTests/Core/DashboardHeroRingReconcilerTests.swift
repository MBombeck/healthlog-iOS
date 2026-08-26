import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// **v0141 — locks the hero-ring ↔ Insights single-source reconciliation.**
///
/// The dashboard hero rings ship on the (cached) dashboard snapshot; the Insights
/// wellness rings come from the (live) `/api/insights/derived` batch. Both call
/// the identical server engine, so they must agree — this suite pins that a
/// derived hero ring adopts the LIVE Insights value (killing the cache-freshness
/// skew the operator saw) while keeping the snapshot as authority for order,
/// membership, and the snapshot-only MED_COMPLIANCE dose tally.
@Suite("DashboardHeroRingReconciler — single source")
struct DashboardHeroRingReconcilerTests {
    // MARK: - Builders

    private func snapshotRing(
        _ id: ScoreRingID,
        score: Int,
        band: String,
        doses: DashboardScoreRing.Doses? = nil
    ) -> DashboardScoreRing {
        DashboardScoreRing(id: id, score: score, band: band, doses: doses)
    }

    private func derived(
        _ metric: String,
        status: String = "ok",
        score: Double?,
        band: String? = nil
    ) -> DerivedMetricDTO {
        DerivedMetricDTO(
            metric: metric,
            status: status,
            value: score.map { DerivedMetricDTO.Value(score: $0, band: band) },
            coverage: .init(requiredInputs: 3, presentInputs: 3, historyDays: 30, missing: []),
            confidence: .init(score: 90, band: "high"),
            provenance: .init(inputs: ["hrv"], source: "DAY", windowDays: 30, computedAt: Date()),
            reason: nil
        )
    }

    // MARK: - Tests

    @Test("a derived ring adopts the LIVE Insights score + band, overriding the stale snapshot")
    func derivedRingPrefersLive() {
        // Snapshot (cached) says 54/yellow; live Insights says 58/yellow.
        let rows = DashboardHeroRingReconciler.reconcile(
            snapshotRings: [snapshotRing(.readiness, score: 54, band: "yellow")],
            derived: [derived("READINESS", score: 58.0, band: "yellow")]
        )
        #expect(rows.count == 1)
        #expect(rows[0].source == .live)
        #expect(rows[0].displayScore == 58)
        #expect(rows[0].displayBand == "yellow")
    }

    @Test("the live score rounds the same way the server rounds the snapshot")
    func liveScoreRounds() {
        let rows = DashboardHeroRingReconciler.reconcile(
            snapshotRings: [snapshotRing(.sleepScore, score: 80, band: "green")],
            derived: [derived("SLEEP_SCORE", score: 82.5, band: "green")]
        )
        #expect(rows[0].displayScore == 83)
    }

    @Test("with no live metric loaded the snapshot value stands (never blank)")
    func fallsBackToSnapshot() {
        let rows = DashboardHeroRingReconciler.reconcile(
            snapshotRings: [snapshotRing(.recovery, score: 71, band: "green")],
            derived: []
        )
        #expect(rows[0].source == .snapshot)
        #expect(rows[0].displayScore == 71)
        #expect(rows[0].displayBand == "green")
    }

    @Test("an insufficient/value-less live envelope does NOT override the snapshot")
    func ignoresInsufficientLive() {
        let rows = DashboardHeroRingReconciler.reconcile(
            snapshotRings: [snapshotRing(.readiness, score: 54, band: "yellow")],
            derived: [derived("READINESS", status: "insufficient", score: nil)]
        )
        #expect(rows[0].source == .snapshot)
        #expect(rows[0].displayScore == 54)
    }

    @Test("MED_COMPLIANCE keeps its snapshot dose tally — never reconciled to a derived value")
    func medComplianceStaysSnapshot() {
        let rows = DashboardHeroRingReconciler.reconcile(
            snapshotRings: [snapshotRing(.medCompliance, score: 33, band: "yellow", doses: .init(taken: 1, scheduled: 3))],
            // A stray same-id derived envelope must be ignored for the dose ring.
            derived: [derived("MED_COMPLIANCE", score: 100.0, band: "green")]
        )
        #expect(rows[0].source == .snapshot)
        #expect(rows[0].displayScore == 33)
        #expect(rows[0].ring.dosesCaption == "1/3")
    }

    @Test("order + membership follow the server-resolved snapshot, live values reconciled in place")
    func preservesOrderAndMembership() {
        let rows = DashboardHeroRingReconciler.reconcile(
            snapshotRings: [
                snapshotRing(.sleepScore, score: 82, band: "green"),
                snapshotRing(.readiness, score: 54, band: "yellow"),
                snapshotRing(.medCompliance, score: 33, band: "yellow", doses: .init(taken: 1, scheduled: 3))
            ],
            derived: [
                derived("READINESS", score: 60.0, band: "yellow"),
                derived("SLEEP_SCORE", score: 84.0, band: "green")
            ]
        )
        #expect(rows.map(\.id) == [.sleepScore, .readiness, .medCompliance])
        #expect(rows.map(\.displayScore) == [84, 60, 33])
        #expect(rows.map(\.source) == [.live, .live, .snapshot])
    }
}
