import Foundation
@testable import HealthLog
import Testing

/// **View-model + explainer mapping tests.**
///
/// Asserts the load-bearing pure logic: the SERVER verdict → `HLCycleRing.Model`
/// mapping (arcs from `spans`, day marker from `dayOfCycle`, fertile window and
/// ovulation mapped from dates), the centre copy per state, and the phase the
/// explainer keys its copy off.
///
/// **Z1 (#72).** The suite used to assert that the client derived all of this
/// from the per-day calendar labels — the current cycle window, the day count,
/// the segment collapse, a population-default backdrop when the data looked
/// sparse. Those functions are gone: every one of them was a second opinion
/// about a person's body formed on a device that may not know which day it is in
/// that person's profile timezone. What is asserted now is that the app draws
/// what the server said, and nothing more.
@Suite("CycleScreenModel + explainer mapping")
struct CycleScreenModelTests {
    // MARK: - Fixtures

    private let decoder = JSONDecoder.hlDefault

    /// The canonical `IN_CYCLE` verdict: a 28-day observed run starting
    /// 2026-06-01, today is day 9, arcs M 5 / F 8 / O 2 / L 13, fertile window
    /// 2026-06-09…2026-06-15 (days 9…15).
    private func inCycleVerdict(
        dayOfCycle: Int = 9,
        daysUntilNext: Int? = 20
    ) throws -> CycleVerdictDTO {
        let until = daysUntilNext.map(String.init) ?? "null"
        let json = Data(#"""
        {"state":"IN_CYCLE","dayOfCycle":\#(dayOfCycle),"cycleLength":28,"phase":"FOLLICULAR",
         "spans":[{"phase":"MENSTRUAL","fraction":0.17857142857142858},
                  {"phase":"FOLLICULAR","fraction":0.2857142857142857},
                  {"phase":"OVULATORY","fraction":0.07142857142857142},
                  {"phase":"LUTEAL","fraction":0.4642857142857143}],
         "cycleStartDate":"2026-06-01","overdueDays":null,"daysUntilNext":\#(until),
         "fertileWindow":{"start":"2026-06-09","end":"2026-06-15","active":true}}
        """#.utf8)
        return try decoder.decode(CycleVerdictDTO.self, from: json)
    }

    /// The `OVERDUE` verdict as the server sends it: no day, no phase, an
    /// idealized 28-day arc set, `cycleStartDate` still a fact, `overdueDays`
    /// in place of the count.
    private func overdueVerdict(overdueDays: Int? = 12) throws -> CycleVerdictDTO {
        let over = overdueDays.map(String.init) ?? "null"
        let json = Data(#"""
        {"state":"OVERDUE","dayOfCycle":null,"cycleLength":28,"phase":null,
         "spans":[{"phase":"MENSTRUAL","fraction":0.17857142857142858},
                  {"phase":"FOLLICULAR","fraction":0.25},
                  {"phase":"OVULATORY","fraction":0.07142857142857142},
                  {"phase":"LUTEAL","fraction":0.5}],
         "cycleStartDate":"2026-05-01","overdueDays":\#(over),"daysUntilNext":null,
         "fertileWindow":{"start":null,"end":null,"active":false}}
        """#.utf8)
        return try decoder.decode(CycleVerdictDTO.self, from: json)
    }

    private func insufficientVerdict() throws -> CycleVerdictDTO {
        let json = Data(#"""
        {"state":"INSUFFICIENT_DATA","dayOfCycle":null,"cycleLength":null,"phase":null,
         "spans":[],"cycleStartDate":null,"overdueDays":null,"daysUntilNext":null,
         "fertileWindow":{"start":null,"end":null,"active":false}}
        """#.utf8)
        return try decoder.decode(CycleVerdictDTO.self, from: json)
    }

    private func prediction() throws -> CyclePredictionDTO {
        let json = Data(#"""
        {"method":"CALENDAR","nextPeriodStart":"2026-06-29",
         "nextPeriodStartLow":"2026-06-27","nextPeriodStartHigh":"2026-07-01",
         "fertileWindowStart":"2026-06-09","fertileWindowEnd":"2026-06-15",
         "predictedOvulation":"2026-06-14","ovulationConfirmed":false,
         "confidence":0.74,"cyclesObserved":4,"stillLearning":false,"disclaimer":"x"}
        """#.utf8)
        return try decoder.decode(CyclePredictionDTO.self, from: json)
    }

    // MARK: - Ring model

    @Test("ringModel maps the verdict → arcs + day marker + fertile + ovulation")
    func ringModelMapping() throws {
        let model = try #require(CycleScreenModel.ringModel(
            verdict: inCycleVerdict(), prediction: prediction(),
            centerTitle: "T", centerSubtitle: "S"
        ))
        #expect(model.cycleLengthDays == 28)
        #expect(model.dayOfCycle == 9)
        #expect(model.showsDayMarker)
        // Four contiguous phase arcs in order, cut from the server's fractions.
        #expect(model.segments.count == 4)
        #expect(model.segments[0].phase == .menstrual)
        #expect(model.segments[0].dayRange == 1 ... 5)
        #expect(model.segments[1].phase == .follicular)
        #expect(model.segments[1].dayRange == 6 ... 13)
        #expect(model.segments[2].phase == .ovulatory)
        #expect(model.segments[2].dayRange == 14 ... 15)
        #expect(model.segments[3].phase == .luteal)
        #expect(model.segments[3].dayRange == 16 ... 28)
        // Dates mapped against `cycleStartDate` — not re-derived from the grid.
        #expect(model.fertileWindow == 9 ... 15)
        #expect(model.predictedOvulationDay == 14)
    }

    @Test("INSUFFICIENT_DATA has nothing to draw — no ring, no invented backdrop")
    func insufficientDrawsNothing() throws {
        let thin = try insufficientVerdict()
        let forecast = try prediction()
        #expect(CycleScreenModel.ringModel(
            verdict: thin, prediction: forecast,
            centerTitle: "T", centerSubtitle: "S"
        ) == nil)
    }

    /// v1.16.15 — while still learning the hero ring must NOT paint the fertile
    /// band or the ovulation marker, so it agrees with the calendar + summary
    /// cards. The phase shape itself stays (the ring is still informative).
    @Test("suppressFertility strips the fertile band + ovulation from the ring")
    func ringSuppressesFertilityWhileLearning() throws {
        let suppressed = try #require(CycleScreenModel.ringModel(
            verdict: inCycleVerdict(), prediction: prediction(),
            centerTitle: "T", centerSubtitle: "S", suppressFertility: true
        ))
        #expect(suppressed.fertileWindow == nil)
        #expect(suppressed.predictedOvulationDay == nil)
        #expect(suppressed.segments.count == 4)
    }

    /// **Bug-fix pin (phase arc proportions vs server/web).** Each phase arc must
    /// occupy a DAY-PROPORTIONAL fraction of the ring — day `d` owns the slice
    /// `[(d-1)/L, d/L)` — and the segments must tile the full circle 0→1 with no
    /// gap/overlap, day 1 anchored at 12 o'clock (fraction 0). The fractions now
    /// arrive from the server's `spans` (`verdict.ts`: `counts[phase] / total`)
    /// instead of being counted on the device; the geometry contract is the same.
    @Test("phase arc fractions are day-proportional and tile the circle (server parity)")
    func phaseArcProportions() throws {
        let model = try #require(CycleScreenModel.ringModel(
            verdict: inCycleVerdict(), prediction: prediction(),
            centerTitle: "T", centerSubtitle: "S"
        ))
        let length = model.cycleLengthDays
        #expect(length == 28)

        struct ExpectedArc {
            let phase: CyclePhasePalette.Phase
            let start: Double
            let end: Double
        }
        let expected: [ExpectedArc] = [
            .init(phase: .menstrual, start: 0.0, end: 5.0 / 28.0),
            .init(phase: .follicular, start: 5.0 / 28.0, end: 13.0 / 28.0),
            .init(phase: .ovulatory, start: 13.0 / 28.0, end: 15.0 / 28.0),
            .init(phase: .luteal, start: 15.0 / 28.0, end: 1.0)
        ]
        #expect(model.segments.count == expected.count)
        var runningEnd = 0.0
        for (segment, exp) in zip(model.segments, expected) {
            let arc = HLCycleRing.dayRangeToArc(range: segment.dayRange, cycleLength: length)
            #expect(segment.phase == exp.phase)
            #expect(abs(arc.start - exp.start) < 0.0001)
            #expect(abs(arc.end - exp.end) < 0.0001)
            // No seam: each segment starts exactly where the previous ended.
            #expect(abs(arc.start - runningEnd) < 0.0001)
            runningEnd = arc.end
        }
        #expect(abs(runningEnd - 1.0) < 0.0001)
    }

    /// The `spans` → day-range cut must tile `1...cycleLength` exactly for any
    /// length, including ones where the fractions do not land on whole days.
    @Test(
        "spans tile 1…cycleLength with no gap or overlap",
        arguments: [7, 21, 28, 29, 33, 45]
    )
    func spansTileExactly(length: Int) throws {
        let arcs = try CycleScreenModel.segments(inCycleVerdict().spans, cycleLength: length)
        #expect(arcs.first?.dayRange.lowerBound == 1)
        #expect(arcs.last?.dayRange.upperBound == length)
        for (previous, next) in zip(arcs, arcs.dropFirst()) {
            #expect(next.dayRange.lowerBound == previous.dayRange.upperBound + 1)
        }
    }

    // MARK: - Current phase (drives the explainer)

    @Test("phase is read off the verdict, and `nil` is a real answer")
    func phaseFromVerdict() throws {
        let live = try inCycleVerdict()
        let late = try overdueVerdict()
        let thin = try insufficientVerdict()
        #expect(CycleScreenModel.phase(live) == .follicular)
        // OVERDUE / INSUFFICIENT_DATA carry `phase: null` — the server states it
        // does not know, and so does the app. The explainer then does not render.
        #expect(CycleScreenModel.phase(late) == nil)
        #expect(CycleScreenModel.phase(thin) == nil)
        #expect(CycleScreenModel.phase(nil) == nil)
    }

    @Test("explainer copy keys are distinct per phase")
    func explainerCopyDistinct() {
        let phases = CyclePhasePalette.Phase.allCases
        let bodies = phases.map { CyclePhaseExplainer.bodyKey(for: $0) }
        // All four phase bodies must be different keys.
        #expect(Set(bodies.map { "\($0)" }).count == phases.count)
        // Each phase has a matching named graphic slot.
        for phase in phases {
            let slot = CyclePhaseExplainer.highlightAssetName(for: phase)
            #expect(slot.hasPrefix("cycle.phase."))
            #expect(slot.hasSuffix(".highlight"))
        }
    }

    /// v0.14.10 §4 — only the menstrual highlight image bottom-anchors (its art is
    /// black at the top + colour at the bottom); the other three phases stay
    /// centred. Pins the per-phase content alignment so the slot can't silently
    /// re-centre the menstrual image (hiding its colourful bottom).
    @Test("only the menstrual highlight image bottom-anchors; the rest stay centred")
    func menstrualHighlightBottomAnchored() {
        #expect(PhaseHighlightSlot.contentAlignment(for: .menstrual) == .bottom)
        for phase in [CyclePhasePalette.Phase.follicular, .ovulatory, .luteal] {
            #expect(PhaseHighlightSlot.contentAlignment(for: phase) == .center)
        }
    }

    // MARK: - Countdown

    /// The countdown is the verdict's own `daysUntilNext`, resolved server-side
    /// against the PROFILE timezone. Nothing is subtracted on the device — the
    /// signed/clamped date arithmetic that used to sit here (and told the user
    /// the period was "due today" every day for weeks) has no successor.
    @Test("centre title reads daysUntilNext straight off the verdict")
    func countdownFromVerdict() throws {
        let inFive = try inCycleVerdict(daysUntilNext: 5)
        #expect(CycleScreenModel.centerTitle(verdict: inFive, hasPrediction: true).contains("5"))
        let dueToday = try inCycleVerdict(daysUntilNext: 0)
        #expect(
            CycleScreenModel.centerTitle(verdict: dueToday, hasPrediction: true)
                == String(localized: "cycle.home.center.dueToday")
        )
        // Null with a forecast on file = the predicted start has passed.
        let passed = try inCycleVerdict(daysUntilNext: nil)
        #expect(
            CycleScreenModel.centerTitle(verdict: passed, hasPrediction: true)
                == String(localized: "cycle.home.center.dueWindow")
        )
        // Null with no forecast at all = nothing to count down to.
        #expect(
            CycleScreenModel.centerTitle(verdict: passed, hasPrediction: false)
                == String(localized: "cycle.home.center.learning.title")
        )
    }
}
