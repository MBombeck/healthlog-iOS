import Foundation
@testable import HealthLog
import Testing

/// **Multi-night stage composition — decode + percentage maths (parity Build 4
/// · 4.7, audit `09-…md:121-122`).**
///
/// Covers the two things the view cannot check for itself: that the
/// `sleepStages` block off `GET /api/analytics` decodes the way the server
/// actually serialises it (`W/src/app/api/analytics/route.ts:523-590`), and
/// that the share arithmetic behind the stage percentages is correct —
/// including the `IN_BED` exclusion, which is the one mistake that silently
/// halves every reported percentage.
@Suite("Sleep stage composition")
struct SleepStageCompositionTests {
    // MARK: - Decode

    @Test("The analytics sleepStages block decodes into per-night stage maps")
    func breakdownDecodes() throws {
        let json = """
        {
          "sleepStages": {
            "windowDays": 30,
            "nights": 2,
            "totalMinutes": 900,
            "stages": { "DEEP": 150, "REM": 200, "CORE": 500, "AWAKE": 50 },
            "perNight": [
              { "dayKey": "2026-01-13", "stages": { "DEEP": 70, "REM": 95, "CORE": 240, "AWAKE": 20 } },
              { "dayKey": "2026-01-14", "stages": { "DEEP": 80, "REM": 105, "CORE": 260, "AWAKE": 30 } }
            ]
          }
        }
        """
        let envelope = try JSONDecoder.hlDefault.decode(
            AnalyticsSleepStagesEnvelope.self,
            from: Data(json.utf8)
        )
        let breakdown = try #require(envelope.sleepStages)
        #expect(breakdown.windowDays == 30)
        #expect(breakdown.nights == 2)
        #expect(breakdown.perNight.count == 2)
        #expect(breakdown.perNight.first?.dayKey == "2026-01-13")
        #expect(breakdown.perNight.first?.stages[.core] == 240)
        #expect(breakdown.stages[.deep] == 150)
    }

    @Test("An account with no stage-bearing rows decodes to an absent block")
    func nullBlockDecodes() throws {
        let envelope = try JSONDecoder.hlDefault.decode(
            AnalyticsSleepStagesEnvelope.self,
            from: Data(#"{ "sleepStages": null }"#.utf8)
        )
        #expect(envelope.sleepStages == nil)
    }

    @Test("An unknown future stage key is dropped, the night survives")
    func unknownStageKeyIsDropped() throws {
        let night = try JSONDecoder.hlDefault.decode(
            SleepStageNight.self,
            from: Data(#"{ "dayKey": "2026-01-14", "stages": { "DEEP": 80, "LUCID": 15 } }"#.utf8)
        )
        #expect(night.stages[.deep] == 80)
        #expect(night.stages.count == 1)
    }

    @Test("Fractional stage minutes round instead of throwing")
    func fractionalStageMinutesRound() throws {
        let night = try JSONDecoder.hlDefault.decode(
            SleepStageNight.self,
            from: Data(#"{ "dayKey": "2026-01-14", "stages": { "CORE": 266.4999 } }"#.utf8)
        )
        #expect(night.stages[.core] == 266)
    }

    // MARK: - Share maths

    @Test("Shares are the per-stage percentage of the stacked total")
    func sharesArePercentagesOfTheStack() {
        // 100 + 100 + 200 = 400 → 25 % / 25 % / 50 %.
        let shares = SleepStageComposition.shares(of: [.deep: 100, .rem: 100, .core: 200])
        #expect(shares.map(\.percent) == [25, 25, 50])
        #expect(shares.map(\.minutes) == [100, 100, 200])
        #expect(shares.map(\.stage) == [.deep, .rem, .core])
    }

    @Test("IN_BED is excluded — it is the container, not a phase")
    func inBedIsExcludedFromShares() {
        // A source that also reports IN_BED (≈ the sum of the phases) must not
        // land in the stack: including it halves every reported percentage and
        // doubles the column height.
        let shares = SleepStageComposition.shares(
            of: [.deep: 100, .rem: 100, .core: 200, .inBed: 400]
        )
        #expect(shares.contains { $0.stage == .inBed } == false)
        #expect(shares.map(\.percent) == [25, 25, 50])
    }

    @Test("Stages the source never reported are omitted, not shown as zero")
    func absentStagesAreOmitted() {
        // A "REM 0 %" row would read as a measurement — the source simply made
        // no claim about REM.
        let shares = SleepStageComposition.shares(of: [.deep: 60, .core: 340, .rem: 0])
        #expect(shares.map(\.stage) == [.deep, .core])
    }

    @Test("An all-zero window yields no shares rather than a divide by zero")
    func emptyWindowYieldsNoShares() {
        #expect(SleepStageComposition.shares(of: [:]).isEmpty)
        #expect(SleepStageComposition.shares(of: [.deep: 0, .core: 0]).isEmpty)
    }

    @Test("Stack order is deep first, matching the web STAGE_ORDER")
    func stackOrderMatchesWeb() {
        #expect(SleepStageComposition.stackOrder == [.deep, .rem, .core, .asleep, .awake])
    }

    @Test("Per-stage rounding is independent, so shares may not total 100")
    func independentRoundingIsDeliberate() {
        // 1/3 each → 33 + 33 + 33 = 99. The web tooltip rounds each stage on
        // its own too; redistributing here would print a different number on
        // iOS than the web shows for the same night.
        let shares = SleepStageComposition.shares(of: [.deep: 100, .rem: 100, .core: 100])
        #expect(shares.map(\.percent) == [33, 33, 33])
        #expect(shares.reduce(0) { $0 + $1.percent } == 99)
    }

    @Test("Fractions stay exact even where the display percentage rounds")
    func fractionsStayExact() throws {
        let shares = SleepStageComposition.shares(of: [.deep: 100, .rem: 100, .core: 100])
        let first = try #require(shares.first)
        #expect(abs(first.fraction - 1.0 / 3.0) < 0.000_001)
    }

    // MARK: - Window slicing + totals

    @Test("The window toggle takes the TRAILING nights of the series")
    func trailingSliceTakesMostRecentNights() {
        let nights = (1 ... 30).map {
            SleepStageNight(dayKey: String(format: "2026-01-%02d", $0), stages: [.core: 400])
        }
        let week = SleepStageComposition.trailing(nights, days: 7)
        #expect(week.count == 7)
        #expect(week.first?.dayKey == "2026-01-24")
        #expect(week.last?.dayKey == "2026-01-30")
    }

    @Test("A series shorter than the window passes through whole")
    func shortSeriesPassesThrough() {
        let nights = [
            SleepStageNight(dayKey: "2026-01-13", stages: [.core: 400]),
            SleepStageNight(dayKey: "2026-01-14", stages: [.core: 420])
        ]
        #expect(SleepStageComposition.trailing(nights, days: 30).count == 2)
    }

    @Test("Window totals sum the sliced nights element-wise")
    func totalsSumTheSlicedNights() {
        let nights = [
            SleepStageNight(dayKey: "2026-01-13", stages: [.deep: 70, .core: 240]),
            SleepStageNight(dayKey: "2026-01-14", stages: [.deep: 80, .core: 260, .rem: 105])
        ]
        let totals = SleepStageComposition.totals(of: nights)
        #expect(totals[.deep] == 150)
        #expect(totals[.core] == 500)
        #expect(totals[.rem] == 105)
    }

    @Test("The percentages describe the ACTIVE window, not the server's 30 days")
    func percentagesFollowTheActiveWindow() {
        // Night 1 is all CORE; night 2 is half DEEP. A 1-night window must read
        // 50 % deep, a 2-night window 25 % — if the rows read the server's
        // 30-day totals instead they would not move with the toggle at all.
        let nights = [
            SleepStageNight(dayKey: "2026-01-13", stages: [.core: 400]),
            SleepStageNight(dayKey: "2026-01-14", stages: [.core: 200, .deep: 200])
        ]
        let oneNight = SleepStageComposition.shares(
            of: SleepStageComposition.totals(of: SleepStageComposition.trailing(nights, days: 1))
        )
        let twoNights = SleepStageComposition.shares(
            of: SleepStageComposition.totals(of: SleepStageComposition.trailing(nights, days: 2))
        )
        #expect(oneNight.first { $0.stage == .deep }?.percent == 50)
        #expect(twoNights.first { $0.stage == .deep }?.percent == 25)
    }

    @Test("A night's stacked total excludes IN_BED so the column is the real night")
    func stackedMinutesExcludeInBed() {
        let night = SleepStageNight(
            dayKey: "2026-01-14",
            stages: [.deep: 80, .rem: 105, .core: 260, .awake: 25, .inBed: 470]
        )
        #expect(night.stackedMinutes == 470)
    }
}
