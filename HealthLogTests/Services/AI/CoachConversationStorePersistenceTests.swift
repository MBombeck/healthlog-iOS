import Foundation
@testable import HealthLog
import SwiftData
import Testing

#if canImport(SpeziChat)
    import SpeziChat
#endif

/// v0.5.7 G.5 — SwiftData persistence coverage for
/// `CoachConversationStore`.
///
/// Five contracts the AskCoachSheet view + the logout cleanup hooks
/// rely on:
///
/// 1. **Hydrate-after-restart.** Persist a transcript via one store
///    instance, drop the instance, spin up a fresh store wired to
///    the SAME in-memory container + the SAME user id, assert the
///    chat array re-hydrates with the persisted rows in
///    chronological order.
/// 2. **Persist on send (user turn).** `send(text)` writes a `.user`
///    row to the persistence layer synchronously before awaiting the
///    LocalLLMService, so an app crash mid-LLM-call still has the
///    user's input on disk for the next hydrate.
/// 3. **Reset wipes both in-memory + persisted.** `reset()` clears
///    the in-memory chat array AND drops every persisted row under
///    the current user partition.
/// 4. **Partition by userID.** A store under user-A and a store
///    under user-B sharing the same persistence container do NOT
///    see each other's transcripts.
/// 5. **clearOnLogout wipes the in-memory chat + persisted rows.**
///    Used by the 401-bridge + the logout cleanup hook to drop the
///    transcript before the next user signs in.
///
/// Tests run against `CoachChatStore.makeInMemory()` so no disk I/O
/// fires during the suite.
@MainActor
@Suite("CoachConversationStore — SwiftData persistence")
struct CoachConversationStorePersistenceTests {
    private func makePersistence() throws -> CoachChatStore {
        let container = try CoachChatStore.makeInMemory()
        return CoachChatStore(container: container)
    }

    @Test("hydrate after restart restores the persisted transcript in chronological order")
    func hydrateAfterRestartRestoresTranscript() throws {
        let persistence = try makePersistence()
        let userID = "user-A"
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        // Seed three rows directly through the persistence layer —
        // simulates the prior session's `send(_:)` writes.
        persistence.insert(
            CoachChatMessage(userID: userID, role: .user, text: "Hallo Coach", createdAt: base)
        )
        persistence.insert(
            CoachChatMessage(
                userID: userID,
                role: .assistant,
                text: "Hallo! Wie kann ich helfen?",
                createdAt: base.addingTimeInterval(1)
            )
        )
        persistence.insert(
            CoachChatMessage(
                userID: userID,
                role: .user,
                text: "Mein Blutdruck?",
                createdAt: base.addingTimeInterval(2)
            )
        )

        // Spin up a fresh conversation store wired to the same
        // persistence container — `init` hydrates from disk
        // synchronously, so the chat array reflects the seeded rows
        // by the time we read it.
        let store = CoachConversationStore(
            service: LocalLLMService(),
            persistence: persistence,
            userIDProvider: { userID }
        )

        #expect(store.chat.count == 3)
        #if canImport(SpeziChat)
            #expect(store.chat[0].role == .user)
            #expect(store.chat[0].content == "Hallo Coach")
            #expect(store.chat[1].role == .assistant)
            #expect(store.chat[1].content == "Hallo! Wie kann ich helfen?")
            #expect(store.chat[2].role == .user)
            #expect(store.chat[2].content == "Mein Blutdruck?")
        #endif
    }

    @Test("send persists the user turn before awaiting the model")
    func sendPersistsUserTurn() async throws {
        let persistence = try makePersistence()
        let userID = "user-A"
        let store = CoachConversationStore(
            service: LocalLLMService(),
            persistence: persistence,
            userIDProvider: { userID }
        )

        await store.send("Was bedeutet mein Blutdruck?")

        // The user turn must land on disk regardless of whether the
        // assistant turn returns (unavailable runtimes don't append
        // an assistant row, but they DO append + persist the user
        // turn so the operator's input never disappears).
        let persisted = persistence.fetch(userID: userID)
        let userRows = persisted.filter { $0.role == .user }
        #expect(userRows.count >= 1)
        #expect(userRows.contains(where: { $0.text == "Was bedeutet mein Blutdruck?" }))
    }

    @Test("reset wipes both in-memory chat AND persisted rows")
    func resetWipesInMemoryAndPersisted() throws {
        let persistence = try makePersistence()
        let userID = "user-A"
        // Pre-seed the partition with a row to make the assertion
        // unambiguous — `reset()` must drop it.
        persistence.insert(CoachChatMessage(userID: userID, role: .user, text: "old turn"))

        let store = CoachConversationStore(
            service: LocalLLMService(),
            persistence: persistence,
            userIDProvider: { userID }
        )
        // hydrate populated `chat` from the seed.
        #expect(store.chat.isEmpty == false)
        #expect(persistence.fetch(userID: userID).isEmpty == false)

        store.reset()

        #expect(store.chat.isEmpty)
        #expect(persistence.fetch(userID: userID).isEmpty)
    }

    @Test("partition by userID — two stores on the same persistence don't leak across users")
    func partitionPreventsCrossUserLeak() async throws {
        let persistence = try makePersistence()
        let userA = "user-A"
        let userB = "user-B"

        // Seed user-A's transcript via a store scoped to user-A.
        let storeA = CoachConversationStore(
            service: LocalLLMService(),
            persistence: persistence,
            userIDProvider: { userA }
        )
        await storeA.send("Frage von A")

        // Spin up user-B's store against the same persistence
        // container. Init-hydrate must yield an empty chat —
        // user-A's row is in the store but not in user-B's partition.
        let storeB = CoachConversationStore(
            service: LocalLLMService(),
            persistence: persistence,
            userIDProvider: { userB }
        )

        #expect(storeB.chat.isEmpty, "user-B must not see user-A's transcript on init-hydrate")

        // user-B sends their own message; user-A's persisted row
        // must still be there afterwards.
        await storeB.send("Frage von B")

        let aRows = persistence.fetch(userID: userA)
        let bRows = persistence.fetch(userID: userB)
        #expect(aRows.contains(where: { $0.text == "Frage von A" }))
        #expect(aRows.allSatisfy { $0.userID == userA })
        #expect(bRows.contains(where: { $0.text == "Frage von B" }))
        #expect(bRows.allSatisfy { $0.userID == userB })
        // Cross-partition negative: neither side's text leaks.
        #expect(aRows.contains(where: { $0.text == "Frage von B" }) == false)
        #expect(bRows.contains(where: { $0.text == "Frage von A" }) == false)
    }

    @Test("clearOnLogout wipes in-memory chat AND the supplied partition")
    func clearOnLogoutWipesEverything() throws {
        let persistence = try makePersistence()
        let userID = "previous-user"
        // Seed the previous user's transcript directly.
        persistence.insert(CoachChatMessage(userID: userID, role: .user, text: "private chat"))

        let store = CoachConversationStore(
            service: LocalLLMService(),
            persistence: persistence,
            // Simulate the post-logout keychain-wiped state: the
            // provider returns the standalone sentinel because the
            // keychain `userID` is already gone by the time the
            // cleanup hook fires. The CALLER (AppContainer) supplies
            // the previous user id explicitly via `partition:`.
            userIDProvider: { CoachChatMessage.standaloneUserID }
        )
        // The store init-hydrate ran against the standalone sentinel —
        // chat starts empty (sentinel partition has no rows).
        #expect(store.chat.isEmpty)
        // Manually re-hydrate against the previous-user partition so we
        // have something in-memory to assert the clear against.
        store.userIDProvider = { userID }
        store.hydrate()
        #expect(store.chat.isEmpty == false)

        // Flip back to the standalone provider before clearing — this
        // mirrors the real post-logout state where the keychain is
        // already wiped.
        store.userIDProvider = { CoachChatMessage.standaloneUserID }
        store.clearOnLogout(partition: userID)

        #expect(store.chat.isEmpty)
        #expect(persistence.fetch(userID: userID).isEmpty)
    }

    @Test("clearOnLogout falls back to userIDProvider when no partition is supplied")
    func clearOnLogoutFallsBackToProvider() throws {
        let persistence = try makePersistence()
        let sentinel = CoachChatMessage.standaloneUserID
        persistence.insert(CoachChatMessage(userID: sentinel, role: .user, text: "standalone chat"))

        let store = CoachConversationStore(
            service: LocalLLMService(),
            persistence: persistence,
            userIDProvider: { sentinel }
        )
        #expect(store.chat.isEmpty == false)

        store.clearOnLogout(partition: nil)

        #expect(store.chat.isEmpty)
        #expect(persistence.fetch(userID: sentinel).isEmpty)
    }

    @Test("hydrate is idempotent — second call yields the same transcript")
    func hydrateIsIdempotent() throws {
        let persistence = try makePersistence()
        let userID = "user-A"
        persistence.insert(CoachChatMessage(userID: userID, role: .user, text: "row 1"))
        persistence.insert(CoachChatMessage(userID: userID, role: .assistant, text: "row 2"))

        let store = CoachConversationStore(
            service: LocalLLMService(),
            persistence: persistence,
            userIDProvider: { userID }
        )
        let firstCount = store.chat.count
        store.hydrate()
        #expect(store.chat.count == firstCount)
    }
}
