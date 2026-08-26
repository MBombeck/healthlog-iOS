import Foundation
@testable import HealthLog
import Testing

/// **FW8-FIX — wrist "N today" optimistic count-combine math.**
///
/// The watch renders "N today" as the phone's authoritative
/// `WatchSnapshot.moodCountToday` PLUS the wrist taps the latest snapshot does
/// not yet reflect (a DELTA, never a `max`). These guard the two High bugs the
/// FW8 review flagged — undercount when the day already had entries, and a
/// stale count after local midnight — plus the failed-ack rollback the prior
/// tests missed entirely.
@Suite("Wrist mood count-combine (FW8-FIX)")
struct WatchMoodCountTests {
    private let base = Date(timeIntervalSince1970: 1_700_000_000) // fixed reference

    // MARK: - Undercount (the High bug)

    @Test("Fresh wrist tap on a day that already has entries adds to the count")
    func deltaOnTopOfExistingEntries() {
        // Phone snapshot generated before the tap, already shows 2 today.
        let snapshotAt = base
        let tapAt = base.addingTimeInterval(60) // tapped AFTER the snapshot

        let count = WatchMoodCount.displayedCount(
            snapshotCount: 2,
            pendingTaps: [tapAt],
            snapshotGeneratedAt: snapshotAt
        )
        // 2 (phone) + 1 (unreflected wrist tap) — NOT max(2, 1) == 2.
        #expect(count == 3)
    }

    @Test("Offline burst adds the full delta on top of the baseline")
    func offlineBurstDelta() {
        let snapshotAt = base
        let taps = [60.0, 90.0, 120.0].map { base.addingTimeInterval($0) }
        let count = WatchMoodCount.displayedCount(
            snapshotCount: 2,
            pendingTaps: taps,
            snapshotGeneratedAt: snapshotAt
        )
        // 2 baseline + 3 offline taps == 5 (the old max(2, 3) == 3 was wrong).
        #expect(count == 5)
    }

    // MARK: - Reconcile (snapshot catches up)

    @Test("A snapshot generated after the taps reflects them — delta drops to 0")
    func snapshotReflectsTaps() {
        let taps = [60.0, 90.0].map { base.addingTimeInterval($0) }
        // Fresh snapshot generated AFTER the taps, count now includes them.
        let snapshotAt = base.addingTimeInterval(120)

        let unreflected = WatchMoodCount.unreflectedTaps(
            pendingTaps: taps,
            snapshotGeneratedAt: snapshotAt
        )
        #expect(unreflected.isEmpty)

        let count = WatchMoodCount.displayedCount(
            snapshotCount: 4,
            pendingTaps: taps,
            snapshotGeneratedAt: snapshotAt
        )
        #expect(count == 4) // no double-count of the processed burst
    }

    // MARK: - Midnight reset (the second High bug)

    @Test("After local midnight the count follows the phone's reset, not a stale tap")
    func midnightReset() {
        // Logged at 23:5x — tap predates the post-midnight snapshot.
        let eveningTap = base
        // Phone pushes a fresh snapshot just after midnight: count back to 0,
        // generatedAt newer than the evening tap.
        let postMidnightSnapshotAt = base.addingTimeInterval(600)

        let count = WatchMoodCount.displayedCount(
            snapshotCount: 0,
            pendingTaps: [eveningTap],
            snapshotGeneratedAt: postMidnightSnapshotAt
        )
        // The stale "1 today" is gone — the new day honestly reads 0.
        #expect(count == 0)
    }

    // MARK: - Failed-ack rollback

    @Test("Dropping a failed tap from the pending set rolls the count back by one")
    func failedAckRollback() {
        let snapshotAt = base
        let okTap = base.addingTimeInterval(60)
        let failedTap = base.addingTimeInterval(90)

        let before = WatchMoodCount.displayedCount(
            snapshotCount: 1,
            pendingTaps: [okTap, failedTap],
            snapshotGeneratedAt: snapshotAt
        )
        #expect(before == 3) // 1 baseline + 2 pending

        // The client removes the failed tap from its keyed map; simulate that.
        let after = WatchMoodCount.displayedCount(
            snapshotCount: 1,
            pendingTaps: [okTap],
            snapshotGeneratedAt: snapshotAt
        )
        #expect(after == 2) // rolled back by exactly one, no negative
    }

    @Test("Negative or zero snapshot counts never underflow the displayed count")
    func nonNegative() {
        let count = WatchMoodCount.displayedCount(
            snapshotCount: -5,
            pendingTaps: [],
            snapshotGeneratedAt: base
        )
        #expect(count == 0)
    }
}
