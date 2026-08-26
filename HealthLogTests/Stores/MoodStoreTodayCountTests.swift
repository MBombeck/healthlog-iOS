import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **v0.14.2 FW8 — watch multi-log.** The wrist now logs mood unlimited
/// times/day and surfaces an "N today" subhead. `MoodStore.todayCount` is the
/// authoritative phone-side count the snapshot ships; this verifies it counts
/// only today's entries (caller-locale day) and reflects multiple same-day logs.
@MainActor
@Suite("MoodStore — todayCount (watch multi-log)", .serialized)
struct MoodStoreTodayCountTests {
    private func makeAPI() -> APIClient {
        let keychain = InMemoryKeychain()
        try? keychain.setString("token", forKey: KeychainKey.authToken)
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.5.0",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock())
    }

    private func makeStore() throws -> MoodStore {
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MoodRepository(api: makeAPI(), outbox: outbox)
        return MoodStore(repo: repo, undoCoordinator: UndoCoordinator())
    }

    @Test("Counts multiple same-day entries, ignores other days")
    func countsTodayOnly() throws {
        let cal = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let yesterday = now.addingTimeInterval(-60 * 60 * 24)

        let store = try makeStore()
        store.replaceEntriesForTesting([
            MoodEntry(id: "a", recordedAt: now, score: 4),
            MoodEntry(id: "b", recordedAt: now.addingTimeInterval(-3600), score: 2),
            MoodEntry(id: "c", recordedAt: now.addingTimeInterval(-7200), score: 5),
            MoodEntry(id: "d", recordedAt: yesterday, score: 3)
        ])

        // Three of the four entries fall on `now`'s day.
        #expect(store.todayCount(now: now, calendar: cal) == 3)
    }

    @Test("Zero when nothing logged today")
    func zeroWhenNoneToday() throws {
        let cal = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = try makeStore()
        store.replaceEntriesForTesting([
            MoodEntry(id: "old", recordedAt: now.addingTimeInterval(-60 * 60 * 48), score: 3)
        ])
        #expect(store.todayCount(now: now, calendar: cal) == 0)
    }
}
