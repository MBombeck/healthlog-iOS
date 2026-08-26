import Foundation

// W-B187 COACH-3 — outbox payloads for the coach clarifying-question loop
// (adopt / dismiss). Split out of `OutboxQueue.swift` (file_length +
// type_body_length discipline). Both shapes are `Codable` (the
// `Encodable`-only wire structs `CoachAboutMeAdoptWrite` /
// `CoachAboutMeDismissWrite` can't be persisted directly), and reconstruct the
// wire body via `write` for the replay path.

public extension OutboxQueue.Payloads {
    /// `coachAboutMeAdopt` payload. Replay re-issues
    /// `POST /api/coach/about-me/adopt` under the persisted key. The server
    /// dedupes a replayed adoption against the stored prose, so a replay after
    /// the original landed is a harmless no-op.
    struct CoachAboutMeAdopt: Codable, Sendable {
        public let question: String?
        public let answer: String

        public init(write: CoachAboutMeAdoptWrite) {
            question = write.question
            answer = write.answer
        }

        public var write: CoachAboutMeAdoptWrite {
            CoachAboutMeAdoptWrite(question: question, answer: answer)
        }
    }

    /// `coachAboutMeDismissQuestion` payload. Replay re-issues
    /// `DELETE /api/coach/about-me/questions` under the persisted key.
    /// `question == nil` ⇒ dismiss-all (naturally idempotent).
    struct CoachAboutMeDismissQuestion: Codable, Sendable {
        public let question: String?

        public init(write: CoachAboutMeDismissWrite) {
            question = write.question
        }

        public var write: CoachAboutMeDismissWrite {
            CoachAboutMeDismissWrite(question: question)
        }
    }
}
