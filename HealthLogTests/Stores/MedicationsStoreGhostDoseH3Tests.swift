import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **audit-v0162 H-3 regression coverage (medications variant).**
///
/// A foreground / BGTask revalidation of `.medicationsTodayIntakes` that BEGAN
/// before an in-flight `markIntakeQuick` resolves with the dose still `pending`
/// and, pre-fix, wholesale-reassigned `todayIntakes = value` — REPAINTING the
/// just-marked dose back to pending and climbing the app badge (which is
/// derived from `derivedTodayIntakes`) back up.
///
/// The test performs the REAL optimistic `markIntakeQuick` (which bumps the
/// mutation generation) and then feeds a stale `.fresh` payload through the same
/// generation-guarded apply seam `consumeIntakes` uses, captured under the
/// generation an in-flight load would have held. The guard must drop it.
///
/// ## 22-02 (D-15-03-A) — the clock is injected, not observed
///
/// This suite anchored on a bare `Date()` and scheduled its fixture dose five
/// minutes before it, while `derivedTodayIntakes` computes today's window from
/// its own later `.now`. A run that crossed midnight between the two reads
/// landed the dose on YESTERDAY, the today-window filter dropped it, and the
/// very first expectation ("one pending due dose") failed before anything under
/// test ran. That is what happened on the 2026-08-23 23:53 → 00:05 autonomous
/// run — nightly runs are this operation's NORMAL case, so a suite that can
/// fail by the calendar is a build number waiting to burn.
///
/// 09-15's named pattern applies: the fixture takes an injected reference
/// instant and derives every time from it. The zone is derived too — the store's
/// shipped `profileTimeZoneProvider` seam is pointed at a fixed-offset zone in
/// which the injected instant reads as the wanted local time, so today's window
/// is anchored where the case says rather than where the machine happens to be.
/// The 23:59 anchor below is the exact shape that failed; with injection it is
/// just another fixture, and it no longer depends on WHEN the gate runs.
@Suite("MedicationsStore — H-3 marked-dose repaint / badge guard")
struct MedicationsStoreGhostDoseH3Tests {
    /// The two anchors, as local wall-clock times. Mid-day is the ordinary
    /// case; 23:59 is the one that was impossible to pass whenever the wall
    /// clock disagreed with the fixture.
    enum Anchor: String, Sendable, CaseIterable {
        case midday
        case oneMinuteBeforeMidnight

        var localHour: Int {
            switch self {
            case .midday: 12
            case .oneMinuteBeforeMidnight: 23
            }
        }

        var localMinute: Int {
            switch self {
            case .midday: 0
            case .oneMinuteBeforeMidnight: 59
            }
        }
    }

    /// A fixed-offset zone in which `instant` reads as `anchor`'s local time.
    ///
    /// Fixed-offset on purpose: no DST transition can move the day boundary out
    /// from under the fixture, and `Calendar.startOfDay` is then a pure
    /// function of the offset.
    private static func zone(placing instant: Date, at anchor: Anchor) -> TimeZone {
        let secondsIntoUTCDay = Int(instant.timeIntervalSince1970.rounded(.down)) % 86400
        let wanted = anchor.localHour * 3600 + anchor.localMinute * 60
        var offset = wanted - secondsIntoUTCDay
        // Wrap into (-12 h, +12 h] so the offset is always a real zone.
        if offset > 43200 { offset -= 86400 }
        if offset <= -43200 { offset += 86400 }
        return TimeZone(secondsFromGMT: offset)!
    }

    @Test(
        "A stale .fresh from a pre-mark generation does NOT repaint the dose pending or climb the badge",
        arguments: Anchor.allCases
    )
    @MainActor
    func staleFreshDoesNotRepaintMarkedDoseNorClimbBadge(anchor: Anchor) async throws {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        // No SWR coordinator: `markIntakeQuick`'s writeThrough/invalidate become
        // no-ops, isolating the optimistic-patch + generation-guard behaviour.
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)

        // 22-02 (D-15-03-A) — one reference instant, one zone, everything below
        // derived from them. `now` is still a real instant (the store's window
        // filter reads the wall clock); what the injection fixes is WHERE the
        // day boundary sits relative to it.
        let now = Date()
        let zone = Self.zone(placing: now, at: anchor)
        store.profileTimeZoneProvider = { zone }

        // The dose is scheduled five minutes before the anchor — on the 23:59
        // anchor that is 23:54 the same local day, which is precisely the shape
        // the wall-clock version dropped.
        let scheduled = now.addingTimeInterval(-5 * 60)
        let dose = MedicationIntake(
            id: "intake-1",
            medicationId: "med-1",
            scheduledAt: scheduled,
            takenAt: nil,
            status: .pending,
            snoozedUntil: nil
        )
        store._testForceSet(todayIntakes: [dose])
        #expect(store.dueOrMissedCount(at: now) == 1, "one pending due dose before the mark (\(anchor.rawValue))")

        // Capture the generation an in-flight `load()` observe stream would hold.
        let loadGeneration = store.currentMutationGeneration

        // The mark's POST returns the saved TAKEN intake; anything else (the
        // detached compliance refresh) throws and is swallowed.
        await api.setHandler { anyReq in
            if anyReq is APIRequest<MedicationIntakeWireDTO> {
                return MedicationIntakeWireDTO(
                    id: "intake-1",
                    medicationId: "med-1",
                    scheduledFor: scheduled,
                    takenAt: now
                )
            }
            throw HLError.offline
        }

        // REAL optimistic mark → bumps the mutation generation, patches to taken.
        let outcome = await store.markIntakeQuick(intakeId: "intake-1", status: .taken, now: now)
        #expect(outcome == .success)
        #expect(store.todayIntakes.first?.status == .taken)
        #expect(store.dueOrMissedCount(at: now) == 0, "badge ticks down the moment the dose is marked")

        // A revalidation that began BEFORE the mark resolves with the dose still
        // pending. Applied under the stale generation, the H-3 guard drops it.
        let applied = store.applyTodayIntakes([dose], loadGeneration: loadGeneration)
        #expect(applied == false, "H-3: a stale-generation fresh payload is dropped")
        #expect(store.todayIntakes.first?.status == .taken, "dose stays taken — not repainted pending")
        #expect(store.dueOrMissedCount(at: now) == 0, "H-3: the app badge must NOT climb back up")

        // Control: a payload under the CURRENT generation still applies normally
        // (the guard only rejects stale generations, never fresh loads).
        let currentGeneration = store.currentMutationGeneration
        let appliedCurrent = store.applyTodayIntakes([dose], loadGeneration: currentGeneration)
        #expect(appliedCurrent, "a current-generation payload applies as usual")
        #expect(store.todayIntakes.first?.status == .pending, "current-generation payload overwrites")
    }

    /// **The mechanism, reproduced deterministically.**
    ///
    /// Not a re-run and not a hope: this drives the today-window filter the way
    /// the old fixture drove it — a dose anchored on one instant, the window
    /// evaluated on a LATER one — and shows the dose leaving the window the
    /// moment the two straddle midnight. It is the same computation
    /// `derivedTodayIntakes` performs (fixed-offset gregorian calendar,
    /// `startOfDay` … `+1 day`), so the failure the 23:53 → 00:05 run met is
    /// reproduced here rather than described.
    @Test("Warum die Uhr injiziert gehoert: dieselbe Dosis faellt ueber Mitternacht aus dem Fenster")
    func theOldShapeDropsTheDoseAcrossMidnight() throws {
        let zone = try #require(TimeZone(secondsFromGMT: 0))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone

        // 23:54 on day D — the fixture's dose, five minutes before a 23:59 read.
        let fixtureRead = Date(timeIntervalSince1970: 1_756_079_940) // 23:59:00 UTC
        let scheduled = fixtureRead.addingTimeInterval(-5 * 60)

        func isInTodaysWindow(evaluatedAt moment: Date) -> Bool {
            let startOfToday = calendar.startOfDay(for: moment)
            let endOfToday = calendar.date(byAdding: .day, value: 1, to: startOfToday)!
            return scheduled >= startOfToday && scheduled < endOfToday
        }

        #expect(isInTodaysWindow(evaluatedAt: fixtureRead), "same day: the dose is in the window")
        #expect(
            isInTodaysWindow(evaluatedAt: fixtureRead.addingTimeInterval(2 * 60)) == false,
            "two minutes later the window has rolled and the dose is gone — the 23:53 → 00:05 failure"
        )
    }
}
