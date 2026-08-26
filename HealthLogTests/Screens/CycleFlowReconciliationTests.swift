import Foundation
@testable import HealthLog
import Testing

/// **CU-25 (#72) — flow without an active period asks EXACTLY once.**
///
/// Logging flow and marking a period start are two different acts. A cycle span
/// is created only by `POST /api/cycle/period`; a day log is attached to the
/// latest span starting on or before its date. So bleeding logged with no
/// period start is filed against the PREVIOUS cycle — the record then holds one
/// very long cycle with bleeding inside it, the prediction stays anchored to the
/// old start, and everything downstream reads "later than usual".
///
/// The honest response is to ask the user, once, at the moment it happens. This
/// suite pins "once": the first bleeding day of a run asks, days 2…n never do,
/// and a declined answer is not re-asked.
@Suite("CU-25 — flow-without-period reconciliation prompt")
struct CycleFlowReconciliationTests {
    private let decoder = JSONDecoder.hlDefault

    /// One calendar day to build: an offset from the run start, the server's
    /// phase label (nil = unlabelled), and the logged flow (nil = none).
    private struct DaySpec {
        let offset: Int
        var phase: String?
        var flow: String?
    }

    /// Build calendar days from ``DaySpec`` entries.
    private func days(start: String, entries: [DaySpec]) throws -> [CalendarDayDTO] {
        try entries.map { entry in
            let date = CyclePredictionEngine.addDays(start, entry.offset)
            let phase = entry.phase.map { "\"\($0)\"" } ?? "null"
            let flow = entry.flow.map { "\"\($0)\"" } ?? "null"
            let json = Data(#"""
            {"date":"\#(date)","phase":\#(phase),"isPredictedPeriod":false,
             "isFertileWindow":false,"isPredictedOvulation":false,
             "isPeriodLogged":\#(entry.flow != nil),"flow":\#(flow),
             "hasSymptoms":false,"confidence":0.5,"basalBodyTempC":null,
             "ovulationTest":null,"cervicalMucus":null}
            """#.utf8)
            return try decoder.decode(CalendarDayDTO.self, from: json)
        }
    }

    /// A luteal stretch with no bleeding anywhere — the classic situation: the
    /// previous cycle is still "open" and today's bleeding would be filed into
    /// it instead of starting a new one.
    private func lutealStretch() throws -> [CalendarDayDTO] {
        try days(
            start: "2026-05-01",
            entries: (0 ..< 20).map { DaySpec(offset: $0, phase: "LUTEAL", flow: nil) }
        )
    }

    // MARK: - It asks

    @Test("bleeding on a day no period covers asks the question")
    func asksOnFlowWithoutPeriod() throws {
        let calendar = try lutealStretch()
        #expect(CycleFlowReconciliation.shouldAskPeriodStarted(
            flow: .medium,
            periodAction: nil,
            date: "2026-05-21",
            days: calendar,
            declined: []
        ))
    }

    @Test(
        "every bleeding level asks; NONE never does",
        arguments: [
            (CycleFlowLevel.spotting, true),
            (.light, true),
            (.medium, true),
            (.heavy, true),
            (.none, false)
        ]
    )
    func bleedingLevels(flow: CycleFlowLevel, expected: Bool) throws {
        let calendar = try lutealStretch()
        #expect(CycleFlowReconciliation.shouldAskPeriodStarted(
            flow: flow,
            periodAction: nil,
            date: "2026-05-21",
            days: calendar,
            declined: []
        ) == expected)
    }

    // MARK: - It asks exactly ONCE

    /// The load-bearing acceptance criterion. Day 1 of a bleeding run asks; days
    /// 2…n do not, because the preceding day already carries bleeding. Logging a
    /// whole period therefore produces exactly one prompt, not one per entry.
    @Test("a five-day period produces exactly ONE prompt")
    func exactlyOnePromptPerRun() throws {
        var calendar = try lutealStretch()
        var prompts = 0
        for dayIndex in 0 ..< 5 {
            let date = CyclePredictionEngine.addDays("2026-05-21", dayIndex)
            if CycleFlowReconciliation.shouldAskPeriodStarted(
                flow: .medium,
                periodAction: nil,
                date: date,
                days: calendar,
                declined: []
            ) {
                prompts += 1
            }
            // The day just written is now part of the cached calendar, still
            // unattributed (`phase: null`) because no span was created.
            calendar += try days(start: date, entries: [DaySpec(offset: 0, phase: nil, flow: "MEDIUM")])
        }
        #expect(prompts == 1)
    }

    @Test("a declined day is never asked again")
    func declinedIsNotReasked() throws {
        let calendar = try lutealStretch()
        #expect(CycleFlowReconciliation.shouldAskPeriodStarted(
            flow: .medium,
            periodAction: nil,
            date: "2026-05-21",
            days: calendar,
            declined: ["2026-05-21"]
        ) == false)
    }

    // MARK: - It does not ask when there is nothing to reconcile

    @Test("an explicit period choice in the form answers the question already")
    func explicitPeriodChoiceSkipsPrompt() throws {
        let calendar = try lutealStretch()
        for action in [CyclePeriodAction.start, .end] {
            #expect(CycleFlowReconciliation.shouldAskPeriodStarted(
                flow: .medium,
                periodAction: action,
                date: "2026-05-21",
                days: calendar,
                declined: []
            ) == false)
        }
    }

    @Test("a day the server already labels menstrual is attributed — no prompt")
    func menstrualDayNeedsNoPrompt() throws {
        let calendar = try days(
            start: "2026-05-21",
            entries: [DaySpec(offset: 0, phase: "MENSTRUAL", flow: "MEDIUM")]
        )
        #expect(CycleFlowReconciliation.shouldAskPeriodStarted(
            flow: .medium,
            periodAction: nil,
            date: "2026-05-21",
            days: calendar,
            declined: []
        ) == false)
    }

    @Test("an empty calendar (cold cache) still asks — flow with no known span")
    func emptyCalendarAsks() {
        #expect(CycleFlowReconciliation.shouldAskPeriodStarted(
            flow: .light,
            periodAction: nil,
            date: "2026-05-21",
            days: [],
            declined: []
        ))
    }
}
