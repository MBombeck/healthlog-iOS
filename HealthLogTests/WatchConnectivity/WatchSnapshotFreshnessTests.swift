import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// The watch must never read "all done today" from a snapshot that does not
/// describe today: neither from a store that has not loaded yet (a background
/// launch) nor from a snapshot of an earlier day.
@MainActor
@Suite("Watch snapshot freshness")
struct WatchSnapshotFreshnessTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    private func snapshot(generatedAt: Date) -> WatchSnapshot {
        WatchSnapshot(
            doses: [],
            scheduledCount: 2,
            takenCount: 2,
            recentMoodScore: nil,
            signedIn: true,
            generatedAt: generatedAt
        )
    }

    // MARK: - Push gate

    @Test("signed in: push only once medications and the today list have loaded; signed out → push")
    func pushGate() {
        #expect(!WatchSnapshotPushGate.allowsPush(signedIn: true, hasLoadedMedications: false, hasLoadedTodayList: false))
        #expect(!WatchSnapshotPushGate.allowsPush(signedIn: true, hasLoadedMedications: true, hasLoadedTodayList: false))
        #expect(WatchSnapshotPushGate.allowsPush(signedIn: true, hasLoadedMedications: true, hasLoadedTodayList: true))
        #expect(WatchSnapshotPushGate.allowsPush(signedIn: false, hasLoadedMedications: false, hasLoadedTodayList: false))
    }

    @Test("logout forgets the today list")
    func logoutResetsTodayList() {
        let coordinator = WatchSessionCoordinator()
        coordinator.hasSeenTodayIntakes = true
        coordinator.pushLogoutReset()
        #expect(!coordinator.hasSeenTodayIntakes)
    }

    @Test("a screen left open re-evaluates at midnight and when the snapshot ages out")
    func todayBoundaries() {
        let snap = snapshot(generatedAt: date(11, 7))
        let boundaries = snap.todayBoundaries(after: date(11, 21), calendar: calendar)
        #expect(boundaries == [date(12, 0), date(12, 7)])
        #expect(!snap.isStaleForToday(now: date(11, 23, 59), calendar: calendar))
        #expect(snap.isStaleForToday(now: boundaries[0], calendar: calendar))
    }

    @Test("a provider without a trustworthy snapshot pushes nothing")
    func coordinatorSkipsNilSnapshot() {
        let coordinator = WatchSessionCoordinator()
        coordinator.snapshotProvider = { nil }
        coordinator.pushCurrent()
        #expect(coordinator.lastPushedSnapshot == nil)
    }

    @Test("a provider with a snapshot still pushes it")
    func coordinatorPushesSnapshot() {
        let coordinator = WatchSessionCoordinator()
        let fresh = snapshot(generatedAt: date(11, 8))
        coordinator.snapshotProvider = { fresh }
        coordinator.pushCurrent()
        #expect(coordinator.lastPushedSnapshot == fresh)
    }

    // MARK: - Today on the wrist

    @Test("same day and younger than a day → today")
    func sameDayIsFresh() {
        let snap = snapshot(generatedAt: date(11, 7))
        #expect(!snap.isStaleForToday(now: date(11, 21), calendar: calendar))
    }

    @Test("yesterday evening → not today, even a few hours later")
    func yesterdayIsStale() {
        let snap = snapshot(generatedAt: date(10, 22))
        #expect(snap.isStaleForToday(now: date(11, 7), calendar: calendar))
    }

    @Test("the placeholder never counts as today")
    func placeholderIsStale() {
        #expect(WatchSnapshot.placeholder.isStaleForToday(now: date(11, 8), calendar: calendar))
    }
}
