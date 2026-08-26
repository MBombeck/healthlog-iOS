import Foundation
@testable import HealthLog
import Testing

/// **Z1 (#72) — the overdue state, and how long a stored verdict may be shown.**
///
/// Supersedes `CycleLateStateTests`. That suite pinned a CLIENT judgement: it
/// asserted that "later than usual" was decided on the device by comparing today
/// against the upper edge of the server's prediction band, and that the ring kept
/// its own day count past that edge. Both halves are gone. Server v1.35.2 sends
/// `state`, and in `OVERDUE` it sends `dayOfCycle: null` on purpose — past the
/// typical length plus its grace the count is no longer an observed fact, and
/// the likeliest reason a cycle runs long is that a new one already started and
/// was never logged. "Day 71" would then be counting something that does not
/// exist. `overdueDays` takes its place, measured against the usual length
/// rather than usual length plus tolerance.
///
/// What this suite pins instead:
/// 1. `OVERDUE` still draws a ring (`spans` + `cycleStartDate` are filled) but
///    claims no position on it, and the centre number is `overdueDays` with copy
///    that says so.
/// 2. A stored verdict is bounded by its OWN horizon, not by a chosen number of
///    days — the offline half of the cut between forecast and judgement.
@Suite("Z1 — overdue rendering + stored-verdict horizon")
struct CycleVerdictTests {
    private let decoder = JSONDecoder.hlDefault

    private func verdict(_ json: String) throws -> CycleVerdictDTO {
        try decoder.decode(CycleVerdictDTO.self, from: Data(json.utf8))
    }

    /// The `OVERDUE` shape from `verdict.ts`: idealized 28-day arcs, no day, no
    /// phase, the cycle start still on file, `overdueDays` carrying the count.
    private func overdue(days: Int = 12, start: String = "2026-05-01") throws -> CycleVerdictDTO {
        try verdict(#"""
        {"state":"OVERDUE","dayOfCycle":null,"cycleLength":28,"phase":null,
         "spans":[{"phase":"MENSTRUAL","fraction":0.17857142857142858},
                  {"phase":"FOLLICULAR","fraction":0.25},
                  {"phase":"OVULATORY","fraction":0.07142857142857142},
                  {"phase":"LUTEAL","fraction":0.5}],
         "cycleStartDate":"\#(start)","overdueDays":\#(days),"daysUntilNext":null,
         "fertileWindow":{"start":null,"end":null,"active":false}}
        """#)
    }

    private func inCycle(day: Int = 9, length: Int = 28, until: Int?) throws -> CycleVerdictDTO {
        try verdict(#"""
        {"state":"IN_CYCLE","dayOfCycle":\#(day),"cycleLength":\#(length),"phase":"FOLLICULAR",
         "spans":[{"phase":"MENSTRUAL","fraction":0.18},{"phase":"FOLLICULAR","fraction":0.29},
                  {"phase":"OVULATORY","fraction":0.07},{"phase":"LUTEAL","fraction":0.46}],
         "cycleStartDate":"2026-06-01","overdueDays":null,
         "daysUntilNext":\#(until.map(String.init) ?? "null"),
         "fertileWindow":{"start":"2026-06-09","end":"2026-06-15","active":true}}
        """#)
    }

    // MARK: - The overdue state on the ring

    /// The regression this ticket started from was a ring that went blank. It
    /// still does not: `spans` and `cycleStartDate` are filled in `OVERDUE`, so
    /// the arcs draw. What changes is that nothing points at a day.
    @Test("OVERDUE keeps the ring and drops the day marker")
    func overdueDrawsRingWithoutMarker() throws {
        let model = try #require(CycleScreenModel.ringModel(
            verdict: overdue(), prediction: nil, centerTitle: "T", centerSubtitle: "S"
        ))
        #expect(model.cycleLengthDays == 28)
        #expect(model.segments.count == 4)
        // No position is claimed: the server sent `dayOfCycle: null`.
        #expect(model.showsDayMarker == false)
        // And no fertility claim is pinned onto an idealized arc set either.
        #expect(model.fertileWindow == nil)
        #expect(model.predictedOvulationDay == nil)
    }

    /// The number in the middle is `overdueDays`, and the label says what it
    /// counts. "12 Tage überfällig" is a different statement from "Tag 12", and
    /// the copy must not let the two be confused.
    @Test("the centre number is overdueDays, and the copy names what it counts")
    func overdueCentreNamesItsNumber() throws {
        let title = try CycleScreenModel.centerTitle(verdict: overdue(days: 12), hasPrediction: true)
        #expect(title == String(format: String(localized: "cycle.home.center.overdue.title"), 12))
        #expect(title.contains("12"))
        // It is NOT the cycle-day phrasing.
        #expect(title != String(format: String(localized: "cycle.home.center.cycleDay"), 12))

        // The subtitle anchors the count in the fact that survives OVERDUE: the
        // last logged period start.
        let subtitle = try CycleScreenModel.centerSubtitle(verdict: overdue(days: 12, start: "2026-05-01"))
        #expect(subtitle != String(format: String(localized: "cycle.home.center.cycleDay"), 12))
        #expect(!subtitle.isEmpty)
    }

    @Test("an OVERDUE verdict without overdueDays says 'later than usual', never a day count")
    func overdueWithoutCountDegradesHonestly() throws {
        let missing = try verdict(#"""
        {"state":"OVERDUE","dayOfCycle":null,"cycleLength":28,"phase":null,
         "spans":[{"phase":"MENSTRUAL","fraction":1.0}],
         "cycleStartDate":null,"overdueDays":null,"daysUntilNext":null,
         "fertileWindow":{"start":null,"end":null,"active":false}}
        """#)
        #expect(
            CycleScreenModel.centerTitle(verdict: missing, hasPrediction: true)
                == String(localized: "cycle.home.center.late.title")
        )
        #expect(
            CycleScreenModel.centerSubtitle(verdict: missing)
                == String(localized: "cycle.home.center.overdue.subtitle.noStart")
        )
    }

    // MARK: - The stored verdict's horizon

    /// The horizon is not a chosen number of days. An `IN_CYCLE` verdict
    /// describes a cycle that, by its own forecast, ends in `daysUntilNext`
    /// days; once that many days have passed it can no longer answer the one
    /// question a reader would take from it ("did the period arrive on time?").
    @Test("IN_CYCLE is bounded by its own daysUntilNext")
    func inCycleHorizonIsItsOwnForecast() throws {
        let snapshot = try CycleVerdictSnapshot(verdict: inCycle(until: 3), asOf: Date(timeIntervalSince1970: 0))
        #expect(snapshot.horizon == .days(3))
        #expect(snapshot.isShowable(now: Date(timeIntervalSince1970: 0)))
        #expect(snapshot.isShowable(now: Date(timeIntervalSince1970: 3 * 86400)))
        // Day four: the cycle it describes was forecast to be over. A dated
        // "everything is within range" from here on says nothing true about now.
        #expect(snapshot.isShowable(now: Date(timeIntervalSince1970: 4 * 86400)) == false)
    }

    /// With no forecast on file the remaining days of the DRAWN cycle carry the
    /// same meaning — still the verdict's own number, not one we picked.
    @Test("IN_CYCLE without a forecast falls back to the drawn cycle's remainder")
    func inCycleHorizonFallsBackToCycleRemainder() throws {
        let snapshot = try CycleVerdictSnapshot(
            verdict: inCycle(day: 20, length: 28, until: nil),
            asOf: Date(timeIntervalSince1970: 0)
        )
        #expect(snapshot.horizon == .days(8))
    }

    /// Nothing left to bound it with → valid for the day it was made and no
    /// longer. Saying nothing beats a dated statement that cannot be checked.
    @Test("IN_CYCLE with nothing to bound it expires the same day")
    func inCycleWithoutAnyBoundExpiresImmediately() throws {
        let bare = try verdict(#"""
        {"state":"IN_CYCLE","dayOfCycle":null,"cycleLength":null,"phase":"LUTEAL",
         "spans":[{"phase":"LUTEAL","fraction":1.0}],"cycleStartDate":"2026-06-01",
         "overdueDays":null,"daysUntilNext":null,
         "fertileWindow":{"start":null,"end":null,"active":false}}
        """#)
        let snapshot = CycleVerdictSnapshot(verdict: bare, asOf: Date(timeIntervalSince1970: 0))
        #expect(snapshot.horizon == .days(0))
        #expect(snapshot.isShowable(now: Date(timeIntervalSince1970: 0)))
        #expect(snapshot.isShowable(now: Date(timeIntervalSince1970: 86400)) == false)
    }

    /// "The record holds an open cycle that has run past your usual length" does
    /// not become false by waiting — it only becomes more so. Hiding a
    /// late-period statement because it aged would fail in the one direction
    /// that matters. The number is dated on screen rather than aged forward.
    @Test("OVERDUE and INSUFFICIENT_DATA do not expire from age")
    func openEndedStates() throws {
        let late = try CycleVerdictSnapshot(verdict: overdue(), asOf: Date(timeIntervalSince1970: 0))
        #expect(late.horizon == .openEnded)
        #expect(late.isShowable(now: Date(timeIntervalSince1970: 400 * 86400)))

        let thin = try verdict(#"""
        {"state":"INSUFFICIENT_DATA","dayOfCycle":null,"cycleLength":null,"phase":null,
         "spans":[],"cycleStartDate":null,"overdueDays":null,"daysUntilNext":null,
         "fertileWindow":{"start":null,"end":null,"active":false}}
        """#)
        let learning = CycleVerdictSnapshot(verdict: thin, asOf: Date(timeIntervalSince1970: 0))
        #expect(learning.horizon == .openEnded)
        #expect(learning.isShowable(now: Date(timeIntervalSince1970: 400 * 86400)))
    }

    /// Age is a plain duration, deliberately not a calendar-day difference: a
    /// day boundary needs a timezone, and the zone this verdict was resolved in
    /// is the profile's — the very thing an offline device may not hold.
    @Test("elapsed days are measured as a duration, with no timezone in the way")
    func elapsedIsDurationBased() throws {
        let snapshot = try CycleVerdictSnapshot(verdict: inCycle(until: 10), asOf: Date(timeIntervalSince1970: 0))
        #expect(snapshot.elapsedDays(now: Date(timeIntervalSince1970: 0)) == 0)
        #expect(snapshot.elapsedDays(now: Date(timeIntervalSince1970: 86399)) == 0)
        #expect(snapshot.elapsedDays(now: Date(timeIntervalSince1970: 86400)) == 1)
        // A clock that went backwards never yields a negative age.
        #expect(snapshot.elapsedDays(now: Date(timeIntervalSince1970: -86400)) == 0)
    }

    // MARK: - Wire shape

    @Test("the verdict survives a persistence round-trip")
    func snapshotRoundTrips() throws {
        let snapshot = try CycleVerdictSnapshot(verdict: overdue(days: 7), asOf: Date(timeIntervalSince1970: 1_800_000))
        let data = try JSONEncoder.hlDefault.encode(snapshot)
        let back = try JSONDecoder.hlDefault.decode(CycleVerdictSnapshot.self, from: data)
        #expect(back == snapshot)
        #expect(back.verdict.overdueDays == 7)
        #expect(back.verdict.stateValue == .overdue)
    }

    /// Tolerant decode: an unknown future state must not hard-fail the envelope,
    /// and it must not silently read as a known one either.
    @Test("an unknown state decodes without claiming to be a known one")
    func unknownStateIsNotGuessed() throws {
        let future = try verdict(#"""
        {"state":"PREGNANT","dayOfCycle":null,"cycleLength":null,"phase":null,
         "spans":[],"cycleStartDate":null,"overdueDays":null,"daysUntilNext":null,
         "fertileWindow":{"start":null,"end":null,"active":false}}
        """#)
        #expect(future.state == "PREGNANT")
        #expect(future.stateValue == nil)
        #expect(CycleScreenModel.phase(future) == nil)
    }
}
