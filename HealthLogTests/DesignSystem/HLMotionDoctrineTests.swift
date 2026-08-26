import Foundation
@testable import HealthLog
import Testing

/// Locks the **200–300 ms perceptual-motion doctrine** for the design-system
/// motion tokens (PROJECT_GUIDE.md → "Animation Duration Target: 200-300 ms").
///
/// v0.12 W3-6 anchor: `HLMotion.progress` shipped at 0.6s — 2× the doctrine
/// ceiling and 2× the `HLRing` sweep tempo (0.28s) it lived beside. SwiftUI's
/// `Animation` value is opaque (no introspectable duration), so the token is
/// built from the plain `HLMotion.progressDuration` constant and this suite
/// asserts the raw seconds. If a future edit drifts the progress tween back
/// over the budget, this test breaks before the sluggish feel ships.
@Suite("HLMotion doctrine — 200–300 ms budget")
struct HLMotionDoctrineTests {
    @Test("progress fill is ≤ 0.3s (doctrine ceiling)")
    func progressWithinBudget() {
        #expect(HLMotion.progressDuration <= 0.3)
    }

    @Test("progress fill is not instant / not negative (still a real tween)")
    func progressIsRealTween() {
        #expect(HLMotion.progressDuration > 0)
    }

    @Test("progress fill matches the HLRing sweep tempo (0.28s)")
    func progressMatchesRingSweep() {
        // The progress fill sits beside the ring sweep on the same surfaces
        // (Health Score, compliance, achievements). Keeping them equal stops
        // a fill from lagging the ring it animates with.
        #expect(HLMotion.progressDuration == 0.28)
    }
}
