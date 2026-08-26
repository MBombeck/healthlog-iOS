import Foundation
@testable import HealthLog
import Testing

/// **C1 — fertility-prediction maturity gate.**
///
/// Pins the trust + App Store §1.4.1 / EU-MDR contract: a still-learning user
/// (`< CycleMaturity.minCyclesForFertility` confirmed cycles, OR a prediction
/// flagged `stillLearning`) must NOT see concrete fertile-window / ovulation
/// markers painted as fact — on the calendar, in its a11y labels, in the legend,
/// or in the prediction summary. At `>= 3` cycles everything renders as before.
@Suite("Cycle maturity gate (C1)")
@MainActor
struct CycleMaturityGateTests {
    // MARK: - Fixtures

    /// A fertile + predicted-ovulation calendar day (the markers under test).
    private func fertileOvulationDay() throws -> CalendarDayDTO {
        let json = Data(#"""
        {"date":"2026-06-14","phase":"OVULATORY","isPredictedPeriod":false,
         "isFertileWindow":true,"isPredictedOvulation":true,"isPeriodLogged":false,
         "flow":null,"hasSymptoms":true,"confidence":0.2,"basalBodyTempC":null,
         "ovulationTest":null,"cervicalMucus":null}
        """#.utf8)
        return try JSONDecoder.hlDefault.decode(CalendarDayDTO.self, from: json)
    }

    /// A prediction carrying a fertile window + ovulation date.
    private func prediction(cyclesObserved: Int, stillLearning: Bool) throws -> CyclePredictionDTO {
        let json = Data(#"""
        {"method":"CALENDAR","nextPeriodStart":"2026-06-29",
         "nextPeriodStartLow":"2026-06-27","nextPeriodStartHigh":"2026-07-01",
         "fertileWindowStart":"2026-06-09","fertileWindowEnd":"2026-06-15",
         "predictedOvulation":"2026-06-14","ovulationConfirmed":false,
         "confidence":0.2,"cyclesObserved":\#(cyclesObserved),
         "stillLearning":\#(stillLearning),"disclaimer":""}
        """#.utf8)
        return try JSONDecoder.hlDefault.decode(CyclePredictionDTO.self, from: json)
    }

    // MARK: - CycleMaturity predicate

    @Test("minCyclesForFertility threshold is 3 (server / ACOG parity)")
    func threshold() {
        #expect(CycleMaturity.minCyclesForFertility == 3)
    }

    @Test(
        "showsFertility gates on cycle count when stillLearning is unknown",
        arguments: [(0, false), (1, false), (2, false), (3, true), (4, true)]
    )
    func showsFertilityByCount(cyclesObserved: Int, expected: Bool) {
        #expect(CycleMaturity.showsFertility(cyclesObserved: cyclesObserved) == expected)
    }

    @Test("explicit stillLearning=true suppresses even at a high count")
    func stillLearningWins() {
        #expect(CycleMaturity.showsFertility(cyclesObserved: 9, stillLearning: true) == false)
        // stillLearning=false defers to the count.
        #expect(CycleMaturity.showsFertility(cyclesObserved: 9, stillLearning: false) == true)
        #expect(CycleMaturity.showsFertility(cyclesObserved: 1, stillLearning: false) == false)
    }

    @Test("suppressFertility is the inverse of showsFertility")
    func inverse() {
        #expect(CycleMaturity.suppressFertility(cyclesObserved: 1) == true)
        #expect(CycleMaturity.suppressFertility(cyclesObserved: 3) == false)
    }

    // MARK: - Prediction summary suppression

    @Test("prediction summary suppresses fertile/ovulation rows at < 3 cycles")
    func summarySuppressedWhenLearning() throws {
        let pred = try prediction(cyclesObserved: 1, stillLearning: true)
        #expect(CyclePredictionSummary.showsFertility(pred, cyclesObserved: 1) == false)
        // The next-period range is still produced (it always shows).
        #expect(CyclePredictionSummary.range(pred) != "—")
        // The fertile/ovulation values themselves still FORMAT (the gate is the
        // render decision, not the data) — proving the rows are suppressed by the
        // predicate, not by missing data.
        #expect(CyclePredictionSummary.fertile(pred) != nil)
        #expect(CyclePredictionSummary.formatted(pred.predictedOvulation) != nil)
    }

    @Test("prediction summary shows fertile/ovulation rows at >= 3 cycles")
    func summaryShownWhenMature() throws {
        let pred = try prediction(cyclesObserved: 4, stillLearning: false)
        #expect(CyclePredictionSummary.showsFertility(pred, cyclesObserved: 4) == true)
        #expect(CyclePredictionSummary.fertile(pred) != nil)
        #expect(CyclePredictionSummary.formatted(pred.predictedOvulation) != nil)
    }

    // MARK: - Calendar a11y suppression

    @Test("calendar a11y drops fertile/ovulation labels while suppressed; symptom stays")
    func a11ySuppressed() throws {
        let dto = try fertileOvulationDay()
        let suppressed = CycleCalendarGrid.accessibilityLabel(
            dayNumber: 14, dto: dto, suppressFertility: true
        )
        let ovulationLabel = String(localized: "cycle.calendar.a11y.ovulation")
        let fertileLabel = String(localized: "cycle.calendar.a11y.fertile")
        let symptomsLabel = String(localized: "cycle.calendar.a11y.symptoms")
        #expect(!suppressed.contains(ovulationLabel))
        #expect(!suppressed.contains(fertileLabel))
        // Symptoms are a fact, not a prediction — they stay.
        #expect(suppressed.contains(symptomsLabel))
    }

    @Test("calendar a11y keeps fertile/ovulation labels when mature")
    func a11yShown() throws {
        let dto = try fertileOvulationDay()
        let shown = CycleCalendarGrid.accessibilityLabel(
            dayNumber: 14, dto: dto, suppressFertility: false
        )
        let ovulationLabel = String(localized: "cycle.calendar.a11y.ovulation")
        #expect(shown.contains(ovulationLabel))
    }
}
