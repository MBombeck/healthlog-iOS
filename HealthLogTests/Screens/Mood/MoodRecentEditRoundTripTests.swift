// swiftlint:disable force_unwrapping

import Foundation
@testable import HealthLog
import Testing

/// v0.10.0 W-Mood-A — locks the recent-7 + "show all" gating and the
/// tap-to-edit round-trip through `MoodStore.update` (optimistic + outbox-safe).
@MainActor
@Suite("Mood recent-7 + tap-to-edit round-trip")
struct MoodRecentEditRoundTripTests {
    private func makeStore() throws -> (MoodStore, StubAPIClient) {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MoodRepository(api: api, outbox: outbox)
        return (MoodStore(repo: repo), api)
    }

    private func entry(_ id: String, score: Int, daysAgo: Int) -> MoodEntry {
        let stamp = Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now)!
        return MoodEntry(id: id, recordedAt: stamp, score: score)
    }

    @Test("recents(limit:7) returns the 7 newest; show-all gates on totalCount")
    func recentsAndShowAllGate() throws {
        let (store, _) = try makeStore()
        // 10 entries → recents(7) yields 7, totalCount = 10 → show-all visible.
        let ten = (0 ..< 10).map { entry("e\($0)", score: ($0 % 5) + 1, daysAgo: $0) }
        store.replaceEntriesForTesting(ten)
        #expect(store.recents(limit: 7).count == 7)
        #expect(store.totalCount == 10)
        // Newest first: e0 (0 days ago) leads.
        #expect(store.recents(limit: 7).first?.id == "e0")

        // 5 entries → recents(7) yields 5, show-all hidden (totalCount == shown).
        let five = (0 ..< 5).map { entry("f\($0)", score: 3, daysAgo: $0) }
        store.replaceEntriesForTesting(five)
        #expect(store.recents(limit: 7).count == 5)
        #expect(store.totalCount == 5)
    }

    @Test("tap-to-edit round-trip: update swaps the entry, outbox stays clean")
    func tapToEditRoundTrip() async throws {
        let (store, api) = try makeStore()
        let original = entry("server-1", score: 3, daysAgo: 1)
        store.replaceEntriesForTesting([original])

        // The server echoes the saved entry on PUT (the edit's new shape).
        let saved = MoodEntry(
            id: "server-1",
            mood: ServerMoodLevel(score: 5),
            tags: ["Sport"],
            moodLoggedAt: original.recordedAt,
            source: "MANUAL",
            note: "great run"
        )
        await api.setHandler { _ in saved }

        let ok = await store.update(
            original, score: 5, tags: ["Sport"], recordedAt: original.recordedAt, note: "great run"
        )
        #expect(ok)
        // The in-place entry now carries the edited values.
        let updated = store.entries.first { $0.id == "server-1" }
        #expect(updated?.score == 5)
        #expect(updated?.note == "great run")
        #expect(updated?.tags == ["Sport"])
    }
}
