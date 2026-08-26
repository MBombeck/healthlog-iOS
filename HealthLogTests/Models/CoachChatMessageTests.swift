import Foundation
@testable import HealthLog
import SwiftData
import Testing

/// v0.5.7 G.5 — SwiftData round-trip coverage for `CoachChatMessage`.
///
/// Locks the three contracts the `CoachConversationStore` persistence
/// path relies on:
///
/// 1. **Round-trip preserves every stored field.** Insert a row,
///    fetch by id, assert the fixture equals the rehydrated value
///    on `id` / `userID` / `role` / `text` / `createdAt`.
/// 2. **User-partition filter works.** Two rows under different
///    `userID` partitions; a fetch scoped to one partition must NOT
///    surface the other partition's row.
/// 3. **Sort by `createdAt` ascending matches insert order.** The
///    hydrate path in `CoachConversationStore.hydrate` relies on this
///    so the SpeziChat transcript renders user → assistant → user →
///    assistant in chronological order, not reverse-time order.
///
/// Tests run against `CoachChatStore.makeInMemory()` so no disk I/O
/// fires during the suite — same posture the `OutboxStore`
/// test suites use.
@MainActor
@Suite("CoachChatMessage — SwiftData round-trip")
struct CoachChatMessageTests {
    private func makeStore() throws -> CoachChatStore {
        let container = try CoachChatStore.makeInMemory()
        return CoachChatStore(container: container)
    }

    @Test("insert + fetch round-trip preserves every stored field")
    func roundTripPreservesAllFields() throws {
        let store = try makeStore()
        let id = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let row = CoachChatMessage(
            id: id,
            userID: "user-A",
            role: .user,
            text: "Was bedeutet mein Blutdruck?",
            createdAt: createdAt
        )
        store.insert(row)

        let fetched = store.fetch(userID: "user-A")
        #expect(fetched.count == 1)
        let first = try #require(fetched.first)
        #expect(first.id == id)
        #expect(first.userID == "user-A")
        #expect(first.role == .user)
        #expect(first.text == "Was bedeutet mein Blutdruck?")
        #expect(first.createdAt == createdAt)
        #expect(first.roleRaw == "user")
    }

    @Test("user-partition filter scopes reads to the requested userID")
    func partitionFilterDoesNotLeakAcrossUsers() throws {
        let store = try makeStore()
        store.insert(CoachChatMessage(userID: "user-A", role: .user, text: "Frage A"))
        store.insert(CoachChatMessage(userID: "user-B", role: .user, text: "Frage B"))

        let aRows = store.fetch(userID: "user-A")
        let bRows = store.fetch(userID: "user-B")

        #expect(aRows.count == 1)
        #expect(aRows.first?.text == "Frage A")
        #expect(bRows.count == 1)
        #expect(bRows.first?.text == "Frage B")
        // Negative — neither side surfaces the other partition's row.
        #expect(aRows.allSatisfy { $0.userID == "user-A" })
        #expect(bRows.allSatisfy { $0.userID == "user-B" })
    }

    @Test("fetch orders rows by createdAt ascending — matches insert order")
    func fetchOrdersAscendingByCreatedAt() throws {
        let store = try makeStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        // Insert in REVERSE chronological order so the test fails if
        // the descriptor accidentally orders by insertion order /
        // descending / unsorted.
        store.insert(CoachChatMessage(userID: "u", role: .user, text: "third", createdAt: base.addingTimeInterval(20)))
        store.insert(CoachChatMessage(userID: "u", role: .user, text: "first", createdAt: base))
        store.insert(CoachChatMessage(userID: "u", role: .user, text: "second", createdAt: base.addingTimeInterval(10)))

        let rows = store.fetch(userID: "u")
        #expect(rows.map(\.text) == ["first", "second", "third"])
    }

    @Test("clear(userID:) wipes only the requested partition")
    func clearScopedToPartition() throws {
        let store = try makeStore()
        store.insert(CoachChatMessage(userID: "user-A", role: .user, text: "A1"))
        store.insert(CoachChatMessage(userID: "user-A", role: .assistant, text: "A2"))
        store.insert(CoachChatMessage(userID: "user-B", role: .user, text: "B1"))

        store.clear(userID: "user-A")

        #expect(store.fetch(userID: "user-A").isEmpty)
        // user-B partition stays intact — the clear did NOT spill.
        #expect(store.fetch(userID: "user-B").count == 1)
        #expect(store.fetch(userID: "user-B").first?.text == "B1")
    }

    @Test("clearAll wipes every partition")
    func clearAllWipesEverything() throws {
        let store = try makeStore()
        store.insert(CoachChatMessage(userID: "user-A", role: .user, text: "A1"))
        store.insert(CoachChatMessage(userID: "user-B", role: .user, text: "B1"))

        store.clearAll()

        #expect(store.fetch(userID: "user-A").isEmpty)
        #expect(store.fetch(userID: "user-B").isEmpty)
    }

    @Test("standalone sentinel partitions just like a user id")
    func standaloneSentinelPartitionsCleanly() throws {
        let store = try makeStore()
        let sentinel = CoachChatMessage.standaloneUserID
        store.insert(CoachChatMessage(userID: sentinel, role: .user, text: "standalone Q"))
        store.insert(CoachChatMessage(userID: "user-A", role: .user, text: "paired Q"))

        let standaloneRows = store.fetch(userID: sentinel)
        let pairedRows = store.fetch(userID: "user-A")

        #expect(standaloneRows.count == 1)
        #expect(standaloneRows.first?.text == "standalone Q")
        #expect(pairedRows.count == 1)
        #expect(pairedRows.first?.text == "paired Q")
        // Sentinel must NOT collide with any plausible UUID-shaped user id.
        #expect(sentinel != UUID().uuidString)
    }

    @Test("role accessor round-trips through roleRaw storage")
    func roleAccessorRoundTripsThroughRaw() throws {
        let store = try makeStore()
        store.insert(CoachChatMessage(userID: "u", role: .user, text: "u-text"))
        store.insert(CoachChatMessage(userID: "u", role: .assistant, text: "a-text"))

        let rows = store.fetch(userID: "u")
        #expect(rows.contains(where: { $0.role == .user }))
        #expect(rows.contains(where: { $0.role == .assistant }))
        // Underlying raw storage matches the enum's rawValue contract —
        // pinned because a future enum rename would silently break
        // hydrated rows otherwise.
        #expect(rows.contains(where: { $0.roleRaw == "user" }))
        #expect(rows.contains(where: { $0.roleRaw == "assistant" }))
    }
}
