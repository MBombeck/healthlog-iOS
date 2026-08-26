import Foundation
import Observation

/// **v0.14.x server-parity** — per-message feedback state for the server-arm
/// Coach transcript (server route `POST /api/insights/chat/messages/{id}/feedback`,
/// v1.4.23 H7).
///
/// **Why a dedicated `@Observable` model instead of more stored properties on
/// `CoachConversationStore`?** The store file sits at the SwiftLint 600-line
/// ceiling; the feedback state is a self-contained little machine (entity→server
/// message-id mapping, submitted ratings, in-flight guard) that the transcript
/// view reads synchronously. The store owns exactly one reference
/// (`CoachConversationStore.feedback`) and clears it on `reset()` /
/// `clearOnLogout`.
///
/// **Which messages are ratable?** Only assistant replies served by the
/// **server arm** — the `done` SSE frame carries the persisted message id and
/// `runServerTurn` registers it here. On-device and BYO replies are never
/// persisted server-side, and transcript rows hydrated from SwiftData carry no
/// server id (the local `@Model` deliberately stores text only) — none of those
/// show a feedback affordance. Honest UI: a thumb only appears where the
/// contract can actually act on it.
///
/// **One-shot contract:** the server dedupes per `(user, message)` and answers
/// **409 `already_rated`** on a repeat. There is no un-rate, so a submitted
/// rating locks the row (`rating(forEntity:)` non-nil ⇒ buttons disabled).
@MainActor
@Observable
public final class CoachMessageFeedback {
    /// Transcript entity id (`ChatEntity.id`) → server message id, registered
    /// per server-arm assistant turn.
    private var messageIDsByEntity: [UUID: String] = [:]

    /// Server message id → the rating the user submitted (accepted by the
    /// server, or confirmed already-rated via 409).
    private var ratingsByMessageID: [String: CoachFeedbackRating] = [:]

    /// Server message ids with a submit in flight (double-tap guard).
    private var inFlightMessageIDs: Set<String> = []

    public init() {}

    // MARK: - Registration (store-side)

    /// Records the server message id for a freshly appended assistant entity.
    func register(messageID: String, forEntity entityID: UUID) {
        messageIDsByEntity[entityID] = messageID
    }

    // MARK: - View-facing reads

    /// `true` when the entity maps to a server-persisted message — the
    /// transcript renders the thumbs row exactly then.
    public func canRate(entityID: UUID) -> Bool {
        messageIDsByEntity[entityID] != nil
    }

    /// The submitted rating for this entity's message, `nil` while unrated.
    public func rating(forEntity entityID: UUID) -> CoachFeedbackRating? {
        messageIDsByEntity[entityID].flatMap { ratingsByMessageID[$0] }
    }

    /// `true` while a submit for this entity's message is in flight.
    public func isSubmitting(entityID: UUID) -> Bool {
        guard let id = messageIDsByEntity[entityID] else { return false }
        return inFlightMessageIDs.contains(id)
    }

    // MARK: - Mutations (store extension)

    func messageID(forEntity entityID: UUID) -> String? {
        messageIDsByEntity[entityID]
    }

    func markInFlight(_ messageID: String, _ inFlight: Bool) {
        if inFlight {
            inFlightMessageIDs.insert(messageID)
        } else {
            inFlightMessageIDs.remove(messageID)
        }
    }

    func markRated(_ messageID: String, _ rating: CoachFeedbackRating) {
        ratingsByMessageID[messageID] = rating
    }

    /// Drops all state — called from `reset()` / `clearOnLogout` alongside the
    /// transcript wipe so a fresh conversation (or the next user) never sees
    /// stale rating state.
    func clear() {
        messageIDsByEntity = [:]
        ratingsByMessageID = [:]
        inFlightMessageIDs = []
    }
}

// MARK: - Submit path

public extension CoachConversationStore {
    /// Submits a helpful/unhelpful rating for the server-persisted assistant
    /// message behind `entityID`. No-ops when the entity has no server id
    /// (on-device / BYO / hydrated rows), when a rating already landed, or
    /// while a submit is in flight.
    ///
    /// **409 handling:** the server's `already_rated` answer means a rating
    /// exists (a retried submit, or rated on web) — we lock the row with the
    /// tapped value rather than surfacing an error; the realistic iOS source
    /// of a 409 is a double-tap race where the direction matches anyway.
    /// Other failures stay silent-but-logged: the row remains ratable so the
    /// user can simply tap again (subtle affordance, no banner).
    func submitFeedback(_ rating: CoachFeedbackRating, forEntity entityID: UUID) async {
        guard let serverService,
              let messageID = feedback.messageID(forEntity: entityID),
              feedback.rating(forEntity: entityID) == nil,
              !feedback.isSubmitting(entityID: entityID) else { return }
        feedback.markInFlight(messageID, true)
        defer { feedback.markInFlight(messageID, false) }
        do {
            try await serverService.submitFeedback(messageID: messageID, rating: rating)
            feedback.markRated(messageID, rating)
        } catch {
            if case let HLError.server(status, _, _) = error, status == 409 {
                feedback.markRated(messageID, rating)
                return
            }
            HLLog.api.error(
                "Coach feedback submit failed: \(LogSanitizer.redact(String(describing: error)), privacy: .public)"
            )
        }
    }
}
