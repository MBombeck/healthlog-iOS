import Foundation
@testable import HealthLog
import Testing

/// Contract tests for `UndoCoordinator`. The coordinator is the single
/// `@MainActor @Observable` that mediates between optimistic-delete store
/// paths and the `HLUndoToast` the shell renders.
///
/// We exercise the three transitions the host depends on:
///
/// 1. `enqueue` → `performUndo` → undo closure runs, slot clears.
/// 2. `enqueue` with a tiny TTL → auto-expire clears the slot without
///    invoking the undo closure.
/// 3. `enqueue` while a previous action is live → previous countdown
///    cancels; the previous action's undo never fires.
/// 4. `dismiss(.userDismissed)` clears the slot without invoking undo.
///
/// The race-y `enqueue → sleep past TTL → enqueue again before the host
/// observes the expiry` case is intentionally NOT covered with a wall-clock
/// race — Swift Testing doesn't give us a clock-stub for `Task.sleep`. The
/// identity-check in `scheduleExpiration` is asserted via the
/// "replacement cancels previous expiry" test which proves the cancellation
/// path, not by waiting for an explicit race.
@MainActor
@Suite("UndoCoordinator")
struct UndoCoordinatorTests {
    /// `enqueue` then `performUndo`: closure runs, slot clears,
    /// `lastDismissReason` flips to `.undone`.
    @Test("performUndo fires the closure and clears current")
    func performUndoRunsClosure() async {
        let coordinator = UndoCoordinator()
        let counter = AsyncCounter()

        coordinator.enqueue(message: "Messung entfernt") {
            await counter.increment()
        }
        #expect(coordinator.current != nil)
        #expect(coordinator.current?.message == "Messung entfernt")

        await coordinator.performUndo()
        #expect(coordinator.current == nil)
        #expect(coordinator.lastDismissReason == .undone)
        #expect(await counter.value == 1)
    }

    /// Auto-expire: when the TTL elapses we clear the slot but do NOT call
    /// the undo closure. We use a 50ms TTL so the test stays inside the
    /// default Swift Testing time budget on CI.
    @Test("auto-expire drops the action without invoking undo")
    func autoExpireDoesNotInvokeUndo() async throws {
        let coordinator = UndoCoordinator()
        let counter = AsyncCounter()

        coordinator.enqueue(message: "Messung entfernt", ttl: 0.05) {
            await counter.increment()
        }
        #expect(coordinator.current != nil)
        // Wait twice the TTL so the auto-expire has comfortably fired.
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(coordinator.current == nil)
        #expect(coordinator.lastDismissReason == .expired)
        #expect(await counter.value == 0)
    }

    /// Replace-on-enqueue: the previous action's countdown is cancelled and
    /// its undo never fires. The replacement becomes the new `current`.
    @Test("replacing the action cancels the previous countdown")
    func replaceCancelsPreviousCountdown() async throws {
        let coordinator = UndoCoordinator()
        let firstCounter = AsyncCounter()
        let secondCounter = AsyncCounter()

        coordinator.enqueue(message: "Erste Aktion", ttl: 0.05) {
            await firstCounter.increment()
        }
        let firstID = coordinator.current?.id
        coordinator.enqueue(message: "Zweite Aktion", ttl: 0.05) {
            await secondCounter.increment()
        }
        let secondID = coordinator.current?.id

        #expect(firstID != secondID)
        #expect(coordinator.current?.message == "Zweite Aktion")

        // Wait past both TTLs. The first closure must NOT have fired
        // because its countdown was cancelled; the second auto-expires
        // and drops to nil.
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(coordinator.current == nil)
        #expect(await firstCounter.value == 0)
        #expect(await secondCounter.value == 0)
    }

    /// Manual dismiss clears the slot, does NOT call undo, surfaces the
    /// `.userDismissed` reason.
    @Test("dismiss clears slot without invoking undo")
    func dismissDoesNotInvokeUndo() async {
        let coordinator = UndoCoordinator()
        let counter = AsyncCounter()

        coordinator.enqueue(message: "Messung entfernt") {
            await counter.increment()
        }
        coordinator.dismiss(reason: .userDismissed)
        #expect(coordinator.current == nil)
        #expect(coordinator.lastDismissReason == .userDismissed)
        #expect(await counter.value == 0)
    }

    /// `performUndo` when no action is queued must be a no-op (defensive
    /// against shell re-rendering edges where the host might fire undo
    /// twice in quick succession).
    @Test("performUndo on empty slot is a no-op")
    func performUndoEmptySlot() async {
        let coordinator = UndoCoordinator()
        await coordinator.performUndo()
        #expect(coordinator.current == nil)
        #expect(coordinator.lastDismissReason == nil)
    }

    /// Identity contract — `expiresAt` is set relative to enqueue time so
    /// `HLUndoToast` can render a remaining-time hint without re-reading
    /// the schedule.
    @Test("enqueue records ttl and absolute expiresAt")
    func enqueueRecordsTTL() {
        let coordinator = UndoCoordinator()
        let before = Date.now
        let action = coordinator.enqueue(message: "x", ttl: 5) {}
        let after = Date.now
        #expect(action.ttl == 5)
        // Expiry must sit between `before + 5s` and `after + 5s` (allow
        // for runloop slop on both ends).
        #expect(action.expiresAt >= before.addingTimeInterval(5))
        #expect(action.expiresAt <= after.addingTimeInterval(5))
    }
}

/// Small actor-backed counter so test closures can increment a value
/// without violating the Sendable contract on the undo closure.
private actor AsyncCounter {
    private(set) var value: Int = 0
    func increment() {
        value += 1
    }
}

/// Store-integration coverage — the `MoodStore.delete(_:)` path must
/// enqueue an undo affordance when an `UndoCoordinator` was injected.
/// We exercise the contract end-to-end: load → delete → undo enqueued →
/// performUndo restores the entry locally.
@MainActor
@Suite("MoodStore × UndoCoordinator")
struct MoodStoreUndoWiringTests {
    @Test("delete enqueues undo + performUndo re-inserts the entry locally")
    func deleteThenUndoRestores() async throws {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MoodRepository(api: api, outbox: outbox)
        let coordinator = UndoCoordinator()
        let store = MoodStore(repo: repo, undoCoordinator: coordinator)

        let entry = MoodEntry(
            id: "mood-1",
            recordedAt: .now,
            score: 4,
            tags: ["arbeit"],
            note: "ok day"
        )
        // Stub the recent-load to return one entry.
        let listPayload = MoodListResponse(entries: [entry], meta: nil)
        await api.setHandler { _ in listPayload }
        await store.load()
        #expect(store.entries.count == 1)

        // Switch the handler to a successful 204-equivalent for delete.
        await api.setHandler { _ in EmptyResponse() }
        _ = await store.delete(entry)
        #expect(coordinator.current != nil, "delete must enqueue an undo affordance")
        #expect(coordinator.current?.message == String(localized: "undo.mood.removed"))
        #expect(store.entries.isEmpty)

        // Stub `log` to echo a freshly-allocated server entry so the undo
        // closure's re-post lands successfully.
        let restored = MoodEntry(
            id: "mood-2",
            recordedAt: entry.recordedAt,
            score: entry.score,
            tags: entry.tags,
            note: entry.note
        )
        await api.setHandler { _ in restored }
        await coordinator.performUndo()
        #expect(coordinator.current == nil)
        #expect(coordinator.lastDismissReason == .undone)
        // After the re-post the store carries the freshly-allocated row
        // (new id) — the snapshot's original id is gone, but the data is
        // back, matching the brief's documented trade-off.
        #expect(store.entries.contains { $0.id == "mood-2" })
        #expect(!store.entries.contains { $0.id == "mood-1" })
    }
}
