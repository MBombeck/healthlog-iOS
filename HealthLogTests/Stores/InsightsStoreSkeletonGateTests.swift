import Foundation
@testable import HealthLog
import Testing

/// v0.7.1 B1.2 (W-INSIGHTS-SKELETON-GATE, A-UIUX-H-1) — pins the fan-out
/// readiness aggregator that decides whether the Insights surface paints its
/// coherent cold-launch silhouette or the live composition.
///
/// The aggregator is pure (`nonisolated static`) so the contract is asserted
/// without standing up the seven sibling stores the live screen reads from.
@Suite("Insights skeleton fan-out gate")
struct InsightsStoreSkeletonGateTests {
    private func gate(
        hasSettledOnce: Bool = false,
        isLoading: Bool = false,
        hasComprehensive: Bool = false,
        hasCards: Bool = false,
        hasMeasurements: Bool = false,
        hasHealthScore: Bool = false,
        hasTargets: Bool = false,
        hasMood: Bool = false
    ) -> Bool {
        InsightsStore.isInitialSkeletonVisible(
            hasSettledOnce: hasSettledOnce,
            isLoading: isLoading,
            hasComprehensive: hasComprehensive,
            hasCards: hasCards,
            hasMeasurements: hasMeasurements,
            hasHealthScore: hasHealthScore,
            hasTargets: hasTargets,
            hasMood: hasMood
        )
    }

    @Test("Cold launch with a fetch in flight shows the silhouette")
    func coldLaunchShowsSkeleton() {
        #expect(gate(isLoading: true) == true)
    }

    @Test("Idle pre-task first frame (nothing loading, nothing settled) paints, not skeleton")
    func idleFirstFrameDoesNotShowSkeleton() {
        #expect(gate(isLoading: false) == false)
    }

    @Test("Once settled, the gate never re-flashes even with a revalidation in flight")
    func settledLatchSuppressesReflash() {
        #expect(gate(hasSettledOnce: true, isLoading: true) == false)
        #expect(gate(hasSettledOnce: true, isLoading: false) == false)
    }

    @Test(
        "Any single resolved source paints the live composition",
        arguments: [
            "comprehensive", "cards", "measurements",
            "healthScore", "targets", "mood",
        ]
    )
    func anyResolvedSourcePaints(source: String) {
        let result = gate(
            isLoading: true,
            hasComprehensive: source == "comprehensive",
            hasCards: source == "cards",
            hasMeasurements: source == "measurements",
            hasHealthScore: source == "healthScore",
            hasTargets: source == "targets",
            hasMood: source == "mood"
        )
        #expect(result == false)
    }

    @Test("A failed fetch that latched the gate paints the error composition, not the silhouette")
    func failedFetchPaintsErrorComposition() {
        // hasSettledOnce flips true on the `.failed` arm even with no payload.
        #expect(gate(hasSettledOnce: true, isLoading: false, hasComprehensive: false) == false)
    }
}
