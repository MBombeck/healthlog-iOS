import Foundation
@testable import HealthLog
import Testing

/// **The on-device FORECAST engine is pinned to the server's forecast engine.**
///
/// The project's standing rule is that the server computes the canonical value
/// and the client consumes the resolved DTO. The cycle surface keeps a second
/// engine on the device so an offline / degraded start still has numbers to
/// paint. That is a deliberate exception, and it only holds while two things are
/// true: the device-computed number is **labelled** as such in the UI
/// (``CyclePredictionProvenance``), and it **cannot silently drift** from the
/// server's answer.
///
/// **Z1 (#72) — what this suite still guards, and what it no longer does.** The
/// on-device engine now covers only the FORECAST half: `nextPeriodStart`, the
/// band, the estimated length and SD, the confidence. The JUDGEMENT half —
/// `state`, `phase`, `overdueDays` — moved to the server's `resolveCycleVerdict`
/// (v1.35.2) and is never computed here, because the server resolves "today"
/// from the profile timezone and an offline device may be a day out. So this
/// pin still guards exactly the surface the on-device engine still owns; it did
/// not become decorative when the verdict arrived. It also no longer covers
/// everything that reaches the ring, and it does not pretend to.
///
/// The fixture below is not hand-written: it is the verbatim JSON output of the
/// SERVER's own TypeScript engine (`predictCycle`,
/// `HealthLog/src/lib/cycle/prediction.ts`, healthlog 1.34.3), bundled with the
/// repo's own `esbuild` and executed on Node, on the exact inputs re-created
/// below. If the Swift engine ever computes a different next period, a different
/// band, a different confidence or a different cycle-length estimate on the same
/// input, THIS TEST BREAKS — instead of a user being shown a different body than
/// the record holds.
///
/// **The fixture ages silently, and that is a real weakness.** A recorded
/// snapshot cannot notice that the thing it was recorded from has moved: change
/// the server engine and this suite stays green while being wrong, which is the
/// exact failure a parity test exists to prevent. Versioned test vectors were
/// requested on #72 and do not exist yet. Until they do, the mitigation is
/// manual and cheap, and it was carried out for this unit:
/// `git diff v1.34.3 origin/main -- src/lib/cycle/prediction.ts` in the server
/// repo is **empty** as of server v1.35.4 — the forecast engine has not moved
/// since the recording, so the fixture is current. Re-run that diff whenever the
/// server version this app targets changes; if it is non-empty, re-record before
/// trusting a green run.
///
/// **Re-recording the fixture.** Run `predictCycle` from the server repo on the
/// inputs in ``Case/startDates`` and paste the result. The inputs are chosen to
/// exercise the three shapes that matter: a regular history, the same history
/// seen from a day well past the predicted start, and an irregular history that
/// widens the band.
@Suite("On-device forecast engine pinned to the server engine")
struct CyclePredictionPinTests {
    // MARK: - The recorded server output

    /// One recorded case: the inputs, and the server's verbatim answer.
    private struct Case {
        let name: String
        let startDates: [String]
        let today: String
        let expected: Expected
    }

    /// The server's `CyclePredictionResult` — all 15 fields, mirrored 1:1 by
    /// ``CyclePredictionEngine/Prediction``.
    private struct Expected {
        let method: String
        let nextPeriodStart: String
        let nextPeriodStartLow: String
        let nextPeriodStartHigh: String
        let predictedPeriodLength: Int
        let fertileWindowStart: String?
        let fertileWindowEnd: String?
        let predictedOvulation: String?
        let ovulationConfirmed: Bool
        let confidence: Double
        let confidenceLabel: String
        let cyclesObserved: Int
        let stillLearning: Bool
        let estimatedCycleLength: Int
        let estimatedCycleSd: Double
    }

    /// Recorded 2026-07-31 from `predictCycle(cycles, [], profile, today, [])`
    /// with `profile = { goal: "GENERAL_HEALTH", typicalCycleLength: null,
    /// typicalPeriodLength: null, lutealPhaseLength: null, predictionEnabled:
    /// true, rawChartMode: false }` and every cycle carrying only a `startDate`
    /// (the server's `completedLengths` diffs consecutive start dates and never
    /// reads `endDate` — verified: the `endDate`-populated variant is
    /// byte-identical).
    private static let cases: [Case] = [
        Case(
            name: "A_regular — 28-day history",
            startDates: ["2026-01-05", "2026-02-02", "2026-03-02", "2026-03-30"],
            today: "2026-04-10",
            expected: Expected(
                method: "CALENDAR",
                nextPeriodStart: "2026-04-27",
                nextPeriodStartLow: "2026-04-25",
                nextPeriodStartHigh: "2026-04-29",
                predictedPeriodLength: 5,
                fertileWindowStart: "2026-04-08",
                fertileWindowEnd: "2026-04-14",
                predictedOvulation: "2026-04-13",
                ovulationConfirmed: false,
                confidence: 0.3,
                confidenceLabel: "low",
                cyclesObserved: 3,
                stillLearning: false,
                estimatedCycleLength: 28,
                estimatedCycleSd: 1
            )
        ),
        Case(
            // Same history, seen 23 days AFTER the predicted start. The FORECAST
            // does not move by a single field — lateness is not a forecast
            // property, which is precisely why it now travels in `verdict`.
            name: "B_late — same history, today far past the predicted start",
            startDates: ["2026-01-05", "2026-02-02", "2026-03-02", "2026-03-30"],
            today: "2026-05-20",
            expected: Expected(
                method: "CALENDAR",
                nextPeriodStart: "2026-04-27",
                nextPeriodStartLow: "2026-04-25",
                nextPeriodStartHigh: "2026-04-29",
                predictedPeriodLength: 5,
                fertileWindowStart: "2026-04-08",
                fertileWindowEnd: "2026-04-14",
                predictedOvulation: "2026-04-13",
                ovulationConfirmed: false,
                confidence: 0.3,
                confidenceLabel: "low",
                cyclesObserved: 3,
                stillLearning: false,
                estimatedCycleLength: 28,
                estimatedCycleSd: 1
            )
        ),
        Case(
            name: "C_irregular — 32/24/34-day history widens the band",
            startDates: ["2026-01-05", "2026-02-06", "2026-03-02", "2026-04-05"],
            today: "2026-04-20",
            expected: Expected(
                method: "CALENDAR",
                nextPeriodStart: "2026-05-07",
                nextPeriodStartLow: "2026-05-03",
                nextPeriodStartHigh: "2026-05-11",
                predictedPeriodLength: 5,
                fertileWindowStart: "2026-04-18",
                fertileWindowEnd: "2026-04-24",
                predictedOvulation: "2026-04-23",
                ovulationConfirmed: false,
                confidence: 0.2,
                confidenceLabel: "low",
                cyclesObserved: 3,
                stillLearning: false,
                estimatedCycleLength: 32,
                estimatedCycleSd: 2.97
            )
        )
    ]

    private static let profile = CyclePredictionEngine.CycleProfileInput(
        goal: .generalHealth,
        typicalCycleLength: nil,
        typicalPeriodLength: nil,
        lutealPhaseLength: nil,
        predictionEnabled: true,
        rawChartMode: false
    )

    // MARK: - The pin

    @Test("on-device engine reproduces the server engine field-for-field")
    func engineMatchesServerFixture() {
        for testCase in Self.cases {
            let actual = CyclePredictionEngine.predictCycle(
                cycles: testCase.startDates.map { CyclePredictionEngine.CycleInput(startDate: $0) },
                dayLogs: [],
                profile: Self.profile,
                today: testCase.today
            )
            let want = testCase.expected
            #expect(actual.method.rawValue == want.method, "\(testCase.name): method")
            #expect(actual.nextPeriodStart == want.nextPeriodStart, "\(testCase.name): nextPeriodStart")
            #expect(actual.nextPeriodStartLow == want.nextPeriodStartLow, "\(testCase.name): low")
            #expect(actual.nextPeriodStartHigh == want.nextPeriodStartHigh, "\(testCase.name): high")
            #expect(actual.predictedPeriodLength == want.predictedPeriodLength, "\(testCase.name): periodLength")
            #expect(actual.fertileWindowStart == want.fertileWindowStart, "\(testCase.name): fertileStart")
            #expect(actual.fertileWindowEnd == want.fertileWindowEnd, "\(testCase.name): fertileEnd")
            #expect(actual.predictedOvulation == want.predictedOvulation, "\(testCase.name): ovulation")
            #expect(actual.ovulationConfirmed == want.ovulationConfirmed, "\(testCase.name): ovulationConfirmed")
            #expect(abs(actual.confidence - want.confidence) < 0.0001, "\(testCase.name): confidence")
            #expect(actual.confidenceLabel.rawValue == want.confidenceLabel, "\(testCase.name): confidenceLabel")
            #expect(actual.cyclesObserved == want.cyclesObserved, "\(testCase.name): cyclesObserved")
            #expect(actual.stillLearning == want.stillLearning, "\(testCase.name): stillLearning")
            #expect(actual.estimatedCycleLength == want.estimatedCycleLength, "\(testCase.name): estLength")
            #expect(abs(actual.estimatedCycleSd - want.estimatedCycleSd) < 0.0001, "\(testCase.name): estSd")
        }
    }

    /// **The forecast engine carries no notion of lateness — by design, on both
    /// sides.** Identical inputs seen from before and from long after the
    /// predicted start produce identical predictions. This is why the client
    /// must never read lateness out of a prediction (which is what the deleted
    /// `isPeriodLate` band comparison did): the answer is simply not in there.
    /// It lives in `verdict.state`, computed once, server-side, against the
    /// profile's own timezone.
    @Test("the forecast engine has no notion of lateness — A and B are identical")
    func forecastCarriesNoLatenessSignal() {
        let a = Self.cases[0]
        let b = Self.cases[1]
        #expect(a.startDates == b.startDates)
        #expect(a.expected.nextPeriodStart == b.expected.nextPeriodStart)
        #expect(a.expected.nextPeriodStartHigh == b.expected.nextPeriodStartHigh)
        #expect(a.expected.confidence == b.expected.confidence)
    }

    // MARK: - The engine → DTO bridge mirrors the server's suppression

    /// The offline fallback is rendered through the same wire type as the server
    /// path, so it must apply the same structural fertility suppression the
    /// server applies in `toCyclePredictionDTO` — otherwise the offline path
    /// would paint a fertile window the online path refuses to show.
    @Test("engine → DTO bridge suppresses fertility exactly like the server")
    func bridgeMirrorsServerSuppression() {
        let result = CyclePredictionEngine.predictCycle(
            cycles: Self.cases[0].startDates.map { CyclePredictionEngine.CycleInput(startDate: $0) },
            dayLogs: [],
            profile: Self.profile,
            today: Self.cases[0].today
        )
        // GENERAL_HEALTH → no fertile window on the wire (server dto.ts:218-229).
        #expect(CycleGoalPolicy.allowsFertileWindow(.generalHealth) == false)
        let hidden = result.asPredictionDTO(goalAllowsFertile: false)
        #expect(hidden.fertileWindowStart == nil)
        #expect(hidden.fertileWindowEnd == nil)
        #expect(hidden.predictedOvulation == nil)
        #expect(hidden.ovulationConfirmed == false)
        // The non-fertility fields survive verbatim.
        #expect(hidden.nextPeriodStart == "2026-04-27")
        #expect(hidden.nextPeriodStartHigh == "2026-04-29")
        #expect(hidden.cyclesObserved == 3)
        #expect(hidden.stillLearning == false)
        // …and the server resolves the disclaimer, so the bridge never invents
        // one (the card falls back to `cycle.prediction.disclaimer.local`).
        #expect(hidden.disclaimer.isEmpty)

        // A goal that DOES allow the window keeps it (still-learning gate off).
        #expect(CycleGoalPolicy.allowsFertileWindow(.tryingToConceive))
        let shown = result.asPredictionDTO(goalAllowsFertile: true)
        #expect(shown.fertileWindowStart == "2026-04-08")
        #expect(shown.predictedOvulation == "2026-04-13")
    }

    /// Still learning (< 3 observed cycles) suppresses fertility even for a goal
    /// that allows it — the server's `!result.stillLearning` half of the gate.
    @Test("still learning suppresses fertility even for a fertility goal")
    func stillLearningSuppressesFertility() {
        let result = CyclePredictionEngine.predictCycle(
            cycles: [
                CyclePredictionEngine.CycleInput(startDate: "2026-03-02"),
                CyclePredictionEngine.CycleInput(startDate: "2026-03-30")
            ],
            dayLogs: [],
            profile: Self.profile,
            today: "2026-04-10"
        )
        #expect(result.stillLearning)
        let dto = result.asPredictionDTO(goalAllowsFertile: true)
        #expect(dto.fertileWindowStart == nil)
        #expect(dto.predictedOvulation == nil)
    }
}
