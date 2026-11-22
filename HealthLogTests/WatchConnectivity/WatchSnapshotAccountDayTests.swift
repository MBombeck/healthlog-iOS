import Foundation
@testable import HealthLog
import Testing

/// "Mood today" on the watch follows the account zone, not the device zone.
/// The fixture puts the device in UTC and the account in Berlin, 30 minutes
/// after Berlin midnight: a mood logged 40 minutes earlier belongs to the
/// device's today but to the account's yesterday.
@MainActor
@Suite("WatchSnapshot account day")
struct WatchSnapshotAccountDayTests {
    private let berlin = TimeZone(identifier: "Europe/Berlin") ?? .gmt
    /// 2026-11-16 23:30 UTC, which is 2026-11-17 00:30 in Berlin.
    private let now = Date(timeIntervalSince1970: 1_794_871_800)
    /// 2026-11-16 22:50 UTC, which is 2026-11-16 23:50 in Berlin.
    private var lateMood: MoodEntry {
        MoodEntry(id: "late", recordedAt: now.addingTimeInterval(-40 * 60), score: 4)
    }

    private var deviceCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    @Test("The day calendar carries the account zone")
    func dayCalendarUsesAccountZone() {
        let calendar = WatchSnapshot.dayCalendar(accountTimeZone: berlin)
        #expect(calendar.timeZone == berlin)
        #expect(calendar.component(.day, from: now) == 17)
    }

    @Test("A mood before account midnight is not today's mood")
    func moodBeforeAccountMidnightIsYesterday() throws {
        let calendar = WatchSnapshot.dayCalendar(accountTimeZone: berlin)
        let store = try makeStore(entries: [lateMood])
        let moodCount = store.todayCount(now: now, calendar: calendar)

        let snap = WatchSnapshot.make(
            medications: [],
            derivedIntakes: [],
            recentMoods: store.entries,
            moodCountToday: moodCount,
            signedIn: true,
            now: now,
            calendar: calendar
        )

        #expect(snap.recentMoodScore == nil)
        #expect(snap.moodCountToday == 0)
    }

    @Test("The device zone alone would have counted it")
    func deviceZoneCountsTheSameMoodAsToday() throws {
        let store = try makeStore(entries: [lateMood])

        let snap = WatchSnapshot.make(
            medications: [],
            derivedIntakes: [],
            recentMoods: store.entries,
            moodCountToday: store.todayCount(now: now, calendar: deviceCalendar),
            signedIn: true,
            now: now,
            calendar: deviceCalendar
        )

        #expect(snap.recentMoodScore == 4)
        #expect(snap.moodCountToday == 1)
    }

    private func makeStore(entries: [MoodEntry]) throws -> MoodStore {
        let repo = try MoodRepository(api: StubAPIClient(), outbox: OutboxQueue(inMemory: true))
        let store = MoodStore(repo: repo)
        store.replaceEntriesForTesting(entries)
        return store
    }
}
