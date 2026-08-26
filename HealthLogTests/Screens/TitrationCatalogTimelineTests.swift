@testable import HealthLog
import Testing

/// Pure-resolver tests for the catalog titration-ladder "you-are-here"
/// classification (web v1.18.5 parity). Locks the current-step + past/upcoming
/// split from a catalog ladder + the user's current dose.
@Suite("Titration catalog timeline resolver")
struct TitrationCatalogTimelineTests {
    /// Tirzepatide ladder: 2.5 → 5 → 7.5 → 10 → 12.5 → 15 mg.
    private let ladder: [Double] = [2.5, 5, 7.5, 10, 12.5, 15]

    @Test("Current dose on a rung marks that rung current, lower rungs past, higher upcoming")
    func currentDoseOnRung() {
        let steps = TitrationCatalogTimeline.resolve(ladderMg: ladder, currentDoseMg: 7.5)
        #expect(steps.count == 6)
        #expect(steps.map(\.isPast) == [true, true, false, false, false, false])
        #expect(steps.map(\.isCurrent) == [false, false, true, false, false, false])
        #expect(steps.map(\.isUpcoming) == [false, false, false, true, true, true])
        // The single current rung is 7.5.
        #expect(steps.first(where: \.isCurrent)?.doseMg == 7.5)
    }

    @Test("Off-ladder in-between dose marks the highest rung at-or-below as current")
    func offLadderDose() {
        // 6 mg sits between 5 and 7.5 → current rung is 5, 7.5 is upcoming.
        let steps = TitrationCatalogTimeline.resolve(ladderMg: ladder, currentDoseMg: 6)
        #expect(steps.first(where: \.isCurrent)?.doseMg == 5)
        #expect(steps[2].isUpcoming) // 7.5 not yet reached
    }

    @Test("First rung is current at the starting dose")
    func firstRung() {
        let steps = TitrationCatalogTimeline.resolve(ladderMg: ladder, currentDoseMg: 2.5)
        let restUpcoming = steps.dropFirst().allSatisfy(\.isUpcoming)
        #expect(steps.first?.isCurrent == true)
        #expect(restUpcoming)
    }

    @Test("Max dose marks the last rung current, all others past")
    func maxDose() {
        let steps = TitrationCatalogTimeline.resolve(ladderMg: ladder, currentDoseMg: 15)
        let allButLastPast = steps.dropLast().allSatisfy(\.isPast)
        let noneUpcoming = steps.contains(where: \.isUpcoming)
        #expect(steps.last?.isCurrent == true)
        #expect(allButLastPast)
        // No upcoming step remains at the ceiling.
        #expect(noneUpcoming == false)
    }

    @Test("Dose above the ceiling still pins the last rung as current")
    func aboveCeiling() {
        let steps = TitrationCatalogTimeline.resolve(ladderMg: ladder, currentDoseMg: 20)
        #expect(steps.last?.isCurrent == true)
    }

    @Test("Unknown current dose leaves no current rung; marker sits before the first")
    func unknownDose() {
        let steps = TitrationCatalogTimeline.resolve(ladderMg: ladder, currentDoseMg: nil)
        let noneCurrent = steps.allSatisfy { !$0.isCurrent }
        let allUpcoming = steps.allSatisfy(\.isUpcoming)
        #expect(noneCurrent)
        #expect(allUpcoming)
        #expect(TitrationCatalogTimeline.markerAfterIndex(steps) == -1)
    }

    @Test("Dose below the first rung leaves no current rung")
    func belowFirst() {
        let steps = TitrationCatalogTimeline.resolve(ladderMg: ladder, currentDoseMg: 1)
        let noneCurrent = steps.allSatisfy { !$0.isCurrent }
        #expect(noneCurrent)
        #expect(TitrationCatalogTimeline.markerAfterIndex(steps) == -1)
    }

    @Test("markerAfterIndex returns the current rung's index")
    func markerIndex() {
        let steps = TitrationCatalogTimeline.resolve(ladderMg: ladder, currentDoseMg: 10)
        #expect(TitrationCatalogTimeline.markerAfterIndex(steps) == 3)
    }

    @Test("A single-rung ladder yields no plan (self-suppress)")
    func singleRungSuppresses() {
        #expect(TitrationCatalogTimeline.resolve(ladderMg: [5], currentDoseMg: 5).isEmpty)
        #expect(TitrationCatalogTimeline.resolve(ladderMg: [], currentDoseMg: nil).isEmpty)
    }

    @Test("Non-finite / non-positive rungs are filtered before classification")
    func sanitisesRungs() {
        let steps = TitrationCatalogTimeline.resolve(
            ladderMg: [2.5, .nan, -1, 5, 0, 7.5],
            currentDoseMg: 5
        )
        #expect(steps.map(\.doseMg) == [2.5, 5, 7.5])
        #expect(steps.first(where: \.isCurrent)?.doseMg == 5)
    }

    @Test("Unsorted ladder input is sorted ascending before classification")
    func sortsLadder() {
        let steps = TitrationCatalogTimeline.resolve(ladderMg: [7.5, 2.5, 5], currentDoseMg: 5)
        #expect(steps.map(\.doseMg) == [2.5, 5, 7.5])
    }

    @Test("Float-fuzzy current dose still matches the exact rung")
    func epsilonMatch() {
        let steps = TitrationCatalogTimeline.resolve(
            ladderMg: ladder,
            currentDoseMg: 5.0000000001
        )
        #expect(steps.first(where: \.isCurrent)?.doseMg == 5)
    }
}
