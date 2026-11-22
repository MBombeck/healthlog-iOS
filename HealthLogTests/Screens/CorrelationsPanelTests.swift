import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// Locks the CorrelationsPanel gating contract.
@Suite("CorrelationsPanel gating")
struct CorrelationsPanelTests {
    @Test("hasAnyCard is false on empty digest")
    @MainActor
    func emptyDigest() {
        let digest = ComprehensiveDigest()
        let panel = CorrelationsPanel(digest: digest)
        #expect(panel.hasAnyCard == false)
    }

    @Test("hasAnyCard is false when scatter array is too small (< 5)")
    @MainActor
    func tooFewPoints() {
        let digest = ComprehensiveDigest(
            weightBpCorrelation: CorrelationStat(r: 0.4, strength: .moderat, n: 4),
            scatterData: [
                WeightBPPoint(weight: 78, sysBP: 130),
                WeightBPPoint(weight: 79, sysBP: 132),
                WeightBPPoint(weight: 80, sysBP: 135)
            ]
        )
        let panel = CorrelationsPanel(digest: digest)
        #expect(panel.hasAnyCard == false)
    }

    @Test("hasAnyCard becomes true once any pair has n ≥ 5")
    @MainActor
    func sufficientPoints() {
        let digest = ComprehensiveDigest(
            weightBpCorrelation: CorrelationStat(r: 0.4, strength: .moderat, n: 6),
            scatterData: [
                WeightBPPoint(weight: 78, sysBP: 130),
                WeightBPPoint(weight: 79, sysBP: 132),
                WeightBPPoint(weight: 80, sysBP: 135),
                WeightBPPoint(weight: 81, sysBP: 138),
                WeightBPPoint(weight: 82, sysBP: 140)
            ]
        )
        let panel = CorrelationsPanel(digest: digest)
        #expect(panel.hasAnyCard == true)
    }

    @Test("hasAnyCard requires BOTH correlation stat AND scatter data")
    @MainActor
    func scatterOnlyIsInsufficient() {
        // Correlation is nil but scatter data exists — server can emit either
        // alone in theory; we render only when both are present.
        let digest = ComprehensiveDigest(
            scatterData: [
                WeightBPPoint(weight: 78, sysBP: 130),
                WeightBPPoint(weight: 79, sysBP: 132),
                WeightBPPoint(weight: 80, sysBP: 135),
                WeightBPPoint(weight: 81, sysBP: 138),
                WeightBPPoint(weight: 82, sysBP: 140)
            ]
        )
        let panel = CorrelationsPanel(digest: digest)
        #expect(panel.hasAnyCard == false)
    }

    /// I-1 D — the panel now renders a SUBSET of pairs (the per-metric relocation
    /// contract). `hasAnyCard` must honour the `pairs` filter so a metric page
    /// that doesn't own a present pairing renders nothing.
    @Test("hasAnyCard honours the pair subset — owned pair true, foreign pair false")
    @MainActor
    func pairSubsetGating() {
        let digest = ComprehensiveDigest(
            weightBpCorrelation: CorrelationStat(r: 0.4, strength: .moderat, n: 6),
            scatterData: [
                WeightBPPoint(weight: 78, sysBP: 130),
                WeightBPPoint(weight: 79, sysBP: 132),
                WeightBPPoint(weight: 80, sysBP: 135),
                WeightBPPoint(weight: 81, sysBP: 138),
                WeightBPPoint(weight: 82, sysBP: 140)
            ]
        )
        // Blutdruck owns Weight×BP → renders.
        #expect(CorrelationsPanel(digest: digest, pairs: [.weightBp]).hasAnyCard == true)
        // Puls owns Mood×Puls only → the present Weight×BP pairing is foreign →
        // nothing renders on the Puls page.
        #expect(CorrelationsPanel(digest: digest, pairs: [.moodPulse]).hasAnyCard == false)
        // Medikamente owns BP×Compliance only → foreign → nothing.
        #expect(CorrelationsPanel(digest: digest, pairs: [.bpMedication]).hasAnyCard == false)
    }
}

/// Locks `ComprehensiveDigest.nonEmpty` — used by the `AIInsightResponse`
/// decoder to collapse an all-nil digest to `nil` so UI sites can branch.
@Suite("ComprehensiveDigest.nonEmpty")
struct ComprehensiveDigestNonEmptyTests {
    @Test("All-nil digest collapses to nil")
    func allNil() {
        let digest = ComprehensiveDigest()
        #expect(digest.nonEmpty == nil)
    }

    @Test("Any single signal keeps digest non-nil")
    func singleSignal() {
        #expect(ComprehensiveDigest(bmi: 22).nonEmpty != nil)
        #expect(ComprehensiveDigest(dataSpanDays: 0).nonEmpty != nil)
        #expect(ComprehensiveDigest(hasProvider: false).nonEmpty != nil)
        #expect(ComprehensiveDigest(alerts: [HealthAlert(level: .info, title: "x", message: "y")]).nonEmpty != nil)
        #expect(ComprehensiveDigest(totalMeasurements: 0).nonEmpty != nil)
    }

    @Test("Empty scatter arrays alone don't keep digest alive")
    func emptyArraysCollapse() {
        let digest = ComprehensiveDigest(scatterData: [], moodBpScatterData: [], alerts: [])
        #expect(digest.nonEmpty == nil)
    }
}
