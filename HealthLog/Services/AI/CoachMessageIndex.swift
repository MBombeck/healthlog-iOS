import Foundation

/// Maps a transcript answer to the id the server gave the persisted
/// assistant message, so the trail behind that answer can be fetched later
/// (`CoachConversationStore+Reasoning.swift`).
///
/// Only server-arm replies are registered: the `done` SSE frame carries the
/// message id. On-device and BYO replies are never persisted server-side, and
/// rows hydrated from SwiftData carry no server id. The store owns one index
/// and clears it on `reset()` and `clearOnLogout`.
@MainActor
public final class CoachMessageIndex {
    /// Transcript entity id (`ChatEntity.id`) → server message id.
    private var messageIDsByEntity: [UUID: String] = [:]

    public init() {}

    /// Records the server message id for a freshly appended assistant entity.
    func register(messageID: String, forEntity entityID: UUID) {
        messageIDsByEntity[entityID] = messageID
    }

    func messageID(forEntity entityID: UUID) -> String? {
        messageIDsByEntity[entityID]
    }

    /// Drops every mapping; the entity ids it keyed left with the transcript.
    func clear() {
        messageIDsByEntity = [:]
    }
}
