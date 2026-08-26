import Foundation

#if canImport(SpeziChat)
    import SpeziChat
#endif

/// v0.13 W4 — the persistence + transcript-append helpers, split out of
/// `CoachConversationStore.swift` to keep that file under the SwiftLint
/// 600-line ceiling. All `@MainActor`-isolated instance methods that only touch
/// the public `chat` array + the injected `persistence` / `userIDProvider`.
/// **A360 H3 (v0156)** — accumulates the server-arm SSE token stream so the
/// turn runner can render it progressively. `@MainActor` because every mutation
/// happens inside the store's MainActor-isolated `onToken` callback (and the
/// `upsertStreamingAssistant` render it drives is MainActor too). Tracks whether
/// the trailing assistant turn has been appended yet so the first token appends a
/// new bubble and later tokens replace it in place — mirroring the on-device
/// arm's `didAppend` / `isFirstPartial` contract.
@MainActor
final class ServerStreamRender {
    private(set) var text = ""
    private(set) var didAppend = false

    /// `true` until the first token has been rendered, so the first
    /// `upsertStreamingAssistant` appends a fresh assistant bubble.
    var isFirstPartial: Bool {
        !didAppend
    }

    func append(_ token: String) {
        text += token
    }

    /// Marks that the accumulated text has been rendered into the transcript, so
    /// subsequent tokens replace the trailing bubble rather than appending a new
    /// one.
    func markAppended() {
        didAppend = true
    }
}

extension CoachConversationStore {
    // MARK: - Cadence-suggestion bridge (#30)

    /// **#30** — bridge the app-side inline
    /// ``CoachServerService/CoachReminderSuggestion`` (SSE-frame twin) to the
    /// render-surface ``CoachCadenceSuggestion`` value model the proactive
    /// Insights card consumes. The inline frame carries no distinct row id, so the
    /// model keys on `cadenceId`; the non-optional inline `measurementType` widens
    /// to the model's tolerant `String?`. `nonisolated static` — a pure value
    /// transform with no store state.
    nonisolated static func bridgeCadenceSuggestion(
        _ inline: CoachServerService.CoachReminderSuggestion
    ) -> CoachCadenceSuggestion {
        CoachCadenceSuggestion(
            id: inline.cadenceId,
            cadenceId: inline.cadenceId,
            measurementType: inline.measurementType,
            label: inline.label
        )
    }

    // MARK: - Prompt composition

    /// Compose the final on-device prompt: enrich the raw user text
    /// with the current `HealthSnapshot` via
    /// `PrivacyFirstPromptBuilder.compose`. When no provider is wired,
    /// falls back to `HealthSnapshot.empty` — the composer still
    /// produces a valid (context-less) prompt in that branch.
    ///
    /// **Internal** so tests can pin the composition path without
    /// going through `send(_:)`.
    ///
    /// **Deterministic clock (v0.6.0.7 B2-M3):** `now` is passed
    /// explicitly so the composer is a pure function of its inputs.
    /// Production sites pass `.now`; tests pin a fixture date through
    /// the optional `nowProvider`-equivalent if needed in future.
    func composePrompt(userText: String) -> String {
        let snapshot = snapshotProvider?() ?? HealthSnapshot.empty
        return PrivacyFirstPromptBuilder.compose(userText: userText, snapshot: snapshot, now: .now)
    }

    // MARK: - Hydrate

    /// Re-hydrates `chat` from the SwiftData persistence layer for the
    /// current partition. Called from `init` automatically; safe to
    /// invoke again (e.g. after a partition switch) since
    /// `chat` is wholesale replaced with the fetch result.
    public func hydrate() {
        guard let persistence else { return }
        let userID = userIDProvider()
        let messages = persistence.fetch(userID: userID)
        #if canImport(SpeziChat)
            chat = messages.map { row in
                let role: ChatEntity.Role = switch row.role {
                case .user: .user
                case .assistant: .assistant
                }
                return ChatEntity(role: role, content: row.text)
            }
        #else
            chat = messages.map { row in
                let rolePrefix = row.role == .user ? "user: " : "assistant: "
                return rolePrefix + row.text
            }
        #endif
    }

    // MARK: - Persistence helper

    /// Persists one row. Quietly no-ops when no `persistence` is wired (covers
    /// the spin-up-without-disk test path).
    func persistMessage(role: CoachChatRole, text: String) {
        guard let persistence else { return }
        let userID = userIDProvider()
        let row = CoachChatMessage(
            userID: userID,
            role: role,
            text: text
        )
        persistence.insert(row)
    }

    // MARK: - Server-arm helpers

    /// Resolve the two-letter locale code the server Coach expects
    /// (`"de"` / `"en"`). Falls back to `"en"` for any other system
    /// language so the server's refusal copy never renders in an
    /// unsupported tongue.
    func serverLocaleCode() -> String {
        let code = Locale.current.language.languageCode?.identifier ?? "en"
        return code == "de" ? "de" : "en"
    }

    /// Id of the most recently appended transcript entity — used by the
    /// server arm to map the freshly appended assistant turn onto the server
    /// message id from the `done` frame (feedback registration). `nil` on the
    /// SpeziChat-less fallback configuration (plain strings carry no id).
    func lastEntityID() -> UUID? {
        #if canImport(SpeziChat)
            return chat.last?.id
        #else
            return nil
        #endif
    }

    // MARK: - Append helpers

    /// Appends a complete user turn to the transcript.
    func appendUser(_ text: String) {
        #if canImport(SpeziChat)
            chat.append(ChatEntity(role: .user, content: text))
        #else
            chat.append("user: " + text)
        #endif
    }

    /// Appends a complete assistant turn to the transcript.
    func appendAssistant(_ text: String) {
        #if canImport(SpeziChat)
            chat.append(ChatEntity(role: .assistant, content: text))
        #else
            chat.append("assistant: " + text)
        #endif
    }

    /// **v0.12 W8-1 — streaming render seam.** Appends a new assistant turn on
    /// the first partial, then replaces that same trailing turn in place on each
    /// later partial so the insight grows (headline → body → actions) instead of
    /// stacking fragments. Only the trailing stream-authored turn is replaced.
    func upsertStreamingAssistant(_ text: String, isFirstPartial: Bool) {
        #if canImport(SpeziChat)
            if isFirstPartial || chat.isEmpty || chat[chat.count - 1].role != .assistant {
                chat.append(ChatEntity(role: .assistant, content: text))
            } else {
                chat[chat.count - 1] = ChatEntity(role: .assistant, content: text)
            }
        #else
            let row = "assistant: " + text
            if isFirstPartial || chat.isEmpty || !chat[chat.count - 1].hasPrefix("assistant: ") {
                chat.append(row)
            } else {
                chat[chat.count - 1] = row
            }
        #endif
    }

    /// **22-02 (D-14-04-A) — what a turn that rendered nothing must say.**
    ///
    /// The on-device arm streams partials and appends them in place. When the
    /// stream completes having rendered nothing at all, the turn used to end
    /// with the user's message alone in the transcript and `lastError == nil` —
    /// a state that reads, to the operator and to the test suite alike, exactly
    /// like a deliberate non-answer. The suite could not even express the case,
    /// which is why it asserted an either/or over two branches and passed while
    /// the third outcome happened under load.
    ///
    /// A pure decision so it can be driven directly: the on-device runtime
    /// itself has no seam in the gate (`streamResponse` hands back a concrete
    /// `LanguageModelSession.ResponseStream`), so the DECISION is tested here
    /// and the WIRING is pinned in `CoachConversationStore.swift`'s source text
    /// — the same technique 22-01 used on `InsightsScreen`'s refresh block, for
    /// the same reason: a modelled fix must not be able to stand in for one.
    ///
    /// The other two arms have said this honestly for a while
    /// (`CoachServerError.emptyReply`, `BYOLLMError.decode` on an empty body);
    /// this is the on-device arm's word, folded into the existing
    /// `.modelResponseFailed` case so no error-copy switch changes shape.
    static func emptyGenerationOutcome(didRenderAnything: Bool) -> LocalLLMError? {
        didRenderAnything ? nil : .modelResponseFailed(LocalLLMEmptyGenerationError())
    }
}
