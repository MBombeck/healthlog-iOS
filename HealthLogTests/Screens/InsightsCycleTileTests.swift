import Foundation
@testable import HealthLog
import Testing

/// **W-B184 CYC-4 — Insights overview cycle tile.**
///
/// The cycle summary tile on the Insights overview surfaces the current phase +
/// a next-period line, tappable through to the full ``CycleScreen``. Two
/// contract-bearing behaviours are pinned here:
///
/// 1. **Availability gate.** The tile self-suppresses unless cycle tracking is
///    available (women-only resolution / opt-in) AND a current phase resolves —
///    that path is owned by ``CycleScreenModel/phase(_:)``, which reads the
///    server verdict rather than deriving one (Z1 / #72), and is covered in
///    `CycleScreenModelTests`. Here we assert the maturity branch.
/// 2. **C1 still-learning gate (b183 `38560c9f`).** Below
///    ``CycleMaturity/minCyclesForFertility`` confirmed cycles (or while the
///    prediction is flagged `stillLearning`) the tile must NOT paint a confident
///    "Period in ~N days" countdown — the overview is a glance surface with no
///    room for the still-learning caption + disclaimer the full screen carries.
@Suite("Insights cycle tile (CYC-4)")
struct InsightsCycleTileTests {
    // MARK: - C1 still-learning gate (drives the subtitle copy choice)

    @Test(
        "isStillLearning: < 3 confirmed cycles ⇒ learning (no confident countdown)",
        arguments: [0, 1, 2]
    )
    func learningBelowThreshold(observed: Int) {
        #expect(
            InsightsCycleTile.isStillLearning(
                calendarCyclesObserved: observed,
                predictionCyclesObserved: nil,
                confirmedCycleCount: observed,
                stillLearning: false
            )
        )
    }

    @Test(
        "isStillLearning: ≥ 3 confirmed cycles + not flagged ⇒ confident",
        arguments: [3, 4, 12]
    )
    func confidentAtThreshold(observed: Int) {
        #expect(
            !InsightsCycleTile.isStillLearning(
                calendarCyclesObserved: observed,
                predictionCyclesObserved: nil,
                confirmedCycleCount: observed,
                stillLearning: false
            )
        )
    }

    @Test("stillLearning flag wins even at ≥ 3 cycles (older-server parity)")
    func flagOverridesCount() {
        #expect(
            InsightsCycleTile.isStillLearning(
                calendarCyclesObserved: 5,
                predictionCyclesObserved: nil,
                confirmedCycleCount: 5,
                stillLearning: true
            )
        )
    }

    @Test("calendar profile count is preferred over prediction + confirmed count")
    func calendarProfileWins() {
        // calendar says 4 (confident) even though prediction/confirmed say 1.
        #expect(
            !InsightsCycleTile.isStillLearning(
                calendarCyclesObserved: 4,
                predictionCyclesObserved: 1,
                confirmedCycleCount: 1,
                stillLearning: false
            )
        )
    }

    @Test("falls back to prediction count, then confirmed count, when calendar absent")
    func fallbackChain() {
        // No calendar profile → prediction count (2) drives → still learning.
        #expect(
            InsightsCycleTile.isStillLearning(
                calendarCyclesObserved: nil,
                predictionCyclesObserved: 2,
                confirmedCycleCount: 9,
                stillLearning: false
            )
        )
        // No calendar + no prediction → confirmed count (3) drives → confident.
        #expect(
            !InsightsCycleTile.isStillLearning(
                calendarCyclesObserved: nil,
                predictionCyclesObserved: nil,
                confirmedCycleCount: 3,
                stillLearning: false
            )
        )
    }

    // MARK: - Localization contract (the copy the gate selects between)

    @Test("learning + confident subtitle keys resolve in the catalogue")
    func subtitleKeysResolve() {
        #expect(!String(localized: "cycle.insights.tile.learning").isEmpty)
        #expect(!String(localized: "cycle.insights.tile.inDays").isEmpty)
        #expect(!String(localized: "cycle.insights.tile.dueToday").isEmpty)
        #expect(!String(localized: "cycle.insights.tile.heading").isEmpty)
    }
}
