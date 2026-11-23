import Foundation
@testable import HealthLog
import Testing

/// The answer-to-server-message mapping the trail of an answer is loaded
/// through. Only server-arm replies are registered; the transcript wipes take
/// the mapping with them.
@MainActor
@Suite("Coach message index")
struct CoachMessageIndexTests {
    @Test("a registered answer maps to its server message id")
    func registeredAnswerMaps() {
        let index = CoachMessageIndex()
        let entityID = UUID()
        index.register(messageID: "msg-9", forEntity: entityID)
        #expect(index.messageID(forEntity: entityID) == "msg-9")
        #expect(index.messageID(forEntity: UUID()) == nil)
    }

    @Test("an answer without a server id maps to nothing")
    func unregisteredAnswerMapsToNothing() {
        let store = CoachConversationStore(service: LocalLLMService())
        #expect(store.messageIndex.messageID(forEntity: UUID()) == nil)
    }

    @Test("reset clears the index alongside the transcript")
    func resetClears() {
        let store = CoachConversationStore(service: LocalLLMService())
        let entityID = UUID()
        store.messageIndex.register(messageID: "msg-9", forEntity: entityID)
        store.reset()
        #expect(store.messageIndex.messageID(forEntity: entityID) == nil)
    }

    @Test("logout clears the index alongside the transcript")
    func logoutClears() {
        let store = CoachConversationStore(service: LocalLLMService())
        let entityID = UUID()
        store.messageIndex.register(messageID: "msg-9", forEntity: entityID)
        store.clearOnLogout(partition: "user-1")
        #expect(store.messageIndex.messageID(forEntity: entityID) == nil)
    }
}
