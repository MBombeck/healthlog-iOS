import Foundation

// Coach self-context ("About me") DTOs — server `GET/PUT /api/coach/about-me`
// (v1.15.20 free text, v1.16.0 + three structured fields and the
// clarifying-questions loop).
//
// **Encryption is server-side.** The wire carries plain JSON; the server
// encrypts at rest (`aboutMeEncrypted` etc. via `encryptToBytes`) — the client
// never sees or handles key material.
//
// **PUT semantics (server zod `aboutMePutSchema`):** `aboutMe` is **no longer
// required** (CU-20 / #69 — the server relaxed it; every field is now
// optional). An empty/whitespace-only value CLEARS the stored text; an
// *omitted* field leaves the stored value untouched. iOS always sends all four
// fields explicitly (read-modify-write off the GET state), so neither the
// omitted-field branch nor the relaxation changes what we put on the wire —
// and there was never a client-side mandatory check on `aboutMe` to remove
// (`CoachAboutMeWrite.aboutMe` is a non-optional `String` that is always sent,
// and neither `CoachAboutMeStore.save()` nor `AboutMeScreen` gates on it).
//
// **PUT concurrency (CU-20 / #69):** the write carries `baseUpdatedAt` — see
// `CoachAboutMeRepository.update(_:)`. This route is the only one of the eight
// guarding its OWN column (`UserHealthProfile.updatedAt`) rather than the
// shared `User.updatedAt`.
//
// **Auth:** `requireAuth()` only — deliberately NOT coach-gated (no
// `requireAssistantSurface`), so no `assistantDisabled` mapping is needed.
// PUT is rate-limited 30/min per user (429 handled by `APIClient`).

/// Response of `GET /api/coach/about-me` and the PUT echo. Field caps arrive
/// from the server (`maxChars` = about-me cap, `fieldMaxChars` = per
/// structured field) so the editor never hardcodes them.
public struct CoachAboutMeDTO: Decodable, Sendable, Equatable {
    /// Free-text self-description; `nil` when nothing is stored.
    public let aboutMe: String?
    /// Chronic conditions, short free text.
    public let conditions: String?
    /// Allergies / intolerances, short free text.
    public let allergies: String?
    /// What the coach should pay attention to.
    public let coachFocus: String?
    /// Up to 3 server-derived clarifying questions (web renders them as
    /// composer chips; iOS shows them read-only on the editor for now).
    public let pendingQuestions: [String]
    /// ISO-8601 timestamp of the last save, `nil` before the first one.
    public let updatedAt: String?
    /// Server cap for `aboutMe` (4000 at v1.16.3).
    public let maxChars: Int
    /// Server cap per structured field (500 at v1.16.3).
    public let fieldMaxChars: Int

    public init(
        aboutMe: String?,
        conditions: String?,
        allergies: String?,
        coachFocus: String?,
        pendingQuestions: [String],
        updatedAt: String?,
        maxChars: Int,
        fieldMaxChars: Int
    ) {
        self.aboutMe = aboutMe
        self.conditions = conditions
        self.allergies = allergies
        self.coachFocus = coachFocus
        self.pendingQuestions = pendingQuestions
        self.updatedAt = updatedAt
        self.maxChars = maxChars
        self.fieldMaxChars = fieldMaxChars
    }
}

/// Body of `PUT /api/coach/about-me`. All four fields are always sent
/// (empty string = clear) — deterministic read-modify-write, no reliance on
/// the server's omitted-leaves-untouched branch.
public struct CoachAboutMeWrite: Encodable, Sendable, Equatable {
    public let aboutMe: String
    public let conditions: String
    public let allergies: String
    public let coachFocus: String

    public init(aboutMe: String, conditions: String, allergies: String, coachFocus: String) {
        self.aboutMe = aboutMe
        self.conditions = conditions
        self.allergies = allergies
        self.coachFocus = coachFocus
    }
}

// MARK: - Clarifying-question loop (server v1.16.4 / v1.16.8 — COACH-3)

/// Body of `POST /api/coach/about-me/adopt` — fold a clarifying-question
/// answer (or a "remember this" chat statement) back into the matching
/// structured self-context field. The server picks the field from the
/// `question` wording when present, otherwise from the `answer` text itself
/// (the message-remember path), dedupes against the stored text, and appends
/// encrypted. `question == nil` ⇒ the remember-from-chat path (server v1.16.8).
public struct CoachAboutMeAdoptWrite: Encodable, Sendable, Equatable {
    /// The clarifying question the answer belongs to (drives field matching).
    /// Omitted (`nil`) for the message-remember path — the field is then
    /// matched from the answer text. Encoded only when non-nil.
    public let question: String?
    /// The user's answer / the statement to remember. Required, 1…500 chars
    /// (server `aboutMeAdoptSchema`).
    public let answer: String

    public init(question: String?, answer: String) {
        self.question = question
        self.answer = answer
    }

    private enum CodingKeys: String, CodingKey {
        case question
        case answer
    }

    /// Omit `question` entirely when `nil` — the server zod treats it as
    /// `.optional()` (undefined), and a `null` value would fail validation.
    /// The remember-from-chat path relies on the field being *absent* so the
    /// server matches on the answer text.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(question, forKey: .question)
        try container.encode(answer, forKey: .answer)
    }
}

/// Response of `POST /api/coach/about-me/adopt`. `adopted` is `false` for a
/// deduped no-op (the answer was already present — `reason == "duplicate"`).
/// `field` is the structured field the answer landed on
/// (`conditions` / `allergies` / `coachFocus` / `aboutMe`).
public struct CoachAboutMeAdoptResult: Decodable, Sendable, Equatable {
    public let adopted: Bool
    public let field: String?
    public let reason: String?

    public init(adopted: Bool, field: String?, reason: String?) {
        self.adopted = adopted
        self.field = field
        self.reason = reason
    }
}

/// Body of `DELETE /api/coach/about-me/questions` — dismiss one pending
/// clarifying question by its exact text. An omitted `question` (`nil`)
/// dismisses **all** pending questions (server `dismissSchema`).
public struct CoachAboutMeDismissWrite: Encodable, Sendable, Equatable {
    public let question: String?

    public init(question: String?) {
        self.question = question
    }

    private enum CodingKeys: String, CodingKey {
        case question
    }

    /// Omit `question` when `nil` so the body is `{}` — the server reads an
    /// absent question as "dismiss all". A `null` value would fail the
    /// `z.string().optional()` schema.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(question, forKey: .question)
    }
}

/// Response of `DELETE /api/coach/about-me/questions` — the remaining pending
/// questions after the dismissal.
public struct CoachAboutMeQuestionsResult: Decodable, Sendable, Equatable {
    public let questions: [String]

    public init(questions: [String]) {
        self.questions = questions
    }
}
