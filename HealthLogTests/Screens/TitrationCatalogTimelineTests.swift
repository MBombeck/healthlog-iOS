@testable import HealthLog
import Testing

/// Pure-resolver tests for the catalog titration schedule.
///
/// 1.0.3 (App Review 1.4.2, ruling R10): the resolver used to classify the
/// whole ladder into past / current / **upcoming** rungs so the view could
/// draw the escalation ahead of the user. That forward projection is gone, and
/// the assertions below are the regression anchor: nothing above the current
/// dose may ever come back out of `resolve`.
@Suite("Titration catalog schedule resolver")
struct TitrationCatalogTimelineTests {
    /// Tirzepatide ladder: 2.5 → 5 → 7.5 → 10 → 12.5 → 15 mg.
    private let ladder: [Double] = [2.5, 5, 7.5, 10, 12.5, 15]

    @Test("Schedule stops at the current rung — no rung above the current dose")
    func truncatesAtCurrentDose() {
        let steps = TitrationCatalogTimeline.resolve(ladderMg: ladder, currentDoseMg: 7.5)
        #expect(steps.map(\.doseMg) == [2.5, 5, 7.5])
        #expect(steps.map(\.isCurrent) == [false, false, true])
        #expect(steps.allSatisfy { $0.doseMg <= 7.5 })
    }

    @Test("Off-ladder in-between dose ends the schedule at the highest rung at-or-below")
    func offLadderDose() {
        // 6 mg sits between 5 and 7.5 → the schedule ends at 5; 7.5 is never shown.
        let steps = TitrationCatalogTimeline.resolve(ladderMg: ladder, currentDoseMg: 6)
        #expect(steps.map(\.doseMg) == [2.5, 5])
        #expect(steps.last?.isCurrent == true)
    }

    @Test("At the starting dose the schedule is the starting rung alone")
    func firstRung() {
        let steps = TitrationCatalogTimeline.resolve(ladderMg: ladder, currentDoseMg: 2.5)
        #expect(steps.map(\.doseMg) == [2.5])
        #expect(steps.first?.isCurrent == true)
    }

    @Test("Max dose yields the whole ladder with the last rung current")
    func maxDose() {
        let steps = TitrationCatalogTimeline.resolve(ladderMg: ladder, currentDoseMg: 15)
        #expect(steps.map(\.doseMg) == ladder)
        #expect(steps.last?.isCurrent == true)
        #expect(steps.dropLast().allSatisfy { !$0.isCurrent })
    }

    @Test("Dose above the ceiling still ends at the last rung")
    func aboveCeiling() {
        let steps = TitrationCatalogTimeline.resolve(ladderMg: ladder, currentDoseMg: 20)
        #expect(steps.map(\.doseMg) == ladder)
        #expect(steps.last?.isCurrent == true)
    }

    @Test("Unknown current dose yields no schedule at all (self-suppress)")
    func unknownDose() {
        #expect(TitrationCatalogTimeline.resolve(ladderMg: ladder, currentDoseMg: nil).isEmpty)
    }

    @Test("Dose below the first rung yields no schedule (no forward ladder)")
    func belowFirst() {
        #expect(TitrationCatalogTimeline.resolve(ladderMg: ladder, currentDoseMg: 1).isEmpty)
    }

    @Test("Exactly one rung is marked current, and it is the last")
    func singleCurrentRung() {
        let steps = TitrationCatalogTimeline.resolve(ladderMg: ladder, currentDoseMg: 10)
        #expect(steps.filter(\.isCurrent).count == 1)
        #expect(steps.last?.isCurrent == true)
    }

    @Test("A single-rung ladder yields no schedule (self-suppress)")
    func singleRungSuppresses() {
        #expect(TitrationCatalogTimeline.resolve(ladderMg: [5], currentDoseMg: 5).isEmpty)
        #expect(TitrationCatalogTimeline.resolve(ladderMg: [], currentDoseMg: nil).isEmpty)
    }

    @Test("Non-finite / non-positive rungs are filtered before truncation")
    func sanitisesRungs() {
        let steps = TitrationCatalogTimeline.resolve(
            ladderMg: [2.5, .nan, -1, 5, 0, 7.5],
            currentDoseMg: 5
        )
        #expect(steps.map(\.doseMg) == [2.5, 5])
        #expect(steps.last?.isCurrent == true)
    }

    @Test("Unsorted ladder input is sorted ascending before truncation")
    func sortsLadder() {
        let steps = TitrationCatalogTimeline.resolve(ladderMg: [7.5, 2.5, 5], currentDoseMg: 5)
        #expect(steps.map(\.doseMg) == [2.5, 5])
    }

    @Test("Float-fuzzy current dose still matches the exact rung")
    func epsilonMatch() {
        let steps = TitrationCatalogTimeline.resolve(
            ladderMg: ladder,
            currentDoseMg: 5.0000000001
        )
        #expect(steps.map(\.doseMg) == [2.5, 5])
        #expect(steps.last?.isCurrent == true)
    }
}
