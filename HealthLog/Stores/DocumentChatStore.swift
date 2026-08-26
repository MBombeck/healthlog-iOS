import Foundation
import Observation

/// `@MainActor @Observable` store for one document's scoped chat. Loads the
/// document's active thread (GET) and streams new answers (POST → SSE) via
/// ``DocumentsRepository`` — grounded ONLY in this document's own figures.
///
/// One active thread per document (web parity): the list endpoint returns the
/// document's conversations newest-first, so the store resolves the newest one and
/// hydrates its messages; a first send with no `conversationId` opens a fresh one
/// and latches the id the server returns for follow-ups.
///
/// Gating is the caller's job (the detail screen ANDs `hasContentIndex` + server
/// assist + the app's remote-AI consent before ever opening the sheet); the store
/// additionally surfaces the server's honest gate outcomes — a mid-session
/// `notIndexed` / `consentRequired`, a `limitReached` budget bucket, or a generic
/// provider failure — as a calm ``ErrorState`` rather than a crash or a half bubble.
@MainActor
@Observable
public final class DocumentChatStore {
    /// One rendered turn. `text` is mutable so the streaming assistant tail can be
    /// finalised in place. Assistant prose is PLAIN text (no markdown) by contract.
    public struct Turn: Identifiable, Equatable, Sendable {
        public let id: String
        public let role: DocumentChatMessageRole
        public var text: String

        public init(id: String, role: DocumentChatMessageRole, text: String) {
            self.id = id
            self.role = role
            self.text = text
        }
    }

    /// Calm, honest failure surfaces. A gate rejection (`notIndexed` /
    /// `consentRequired`) is a dead-end explained in place; `limitReached` and
    /// `generic` offer a retry.
    public enum ErrorState: Equatable, Sendable {
        case notIndexed
        case consentRequired
        case limitReached
        case generic
    }

    public internal(set) var messages: [Turn] = []
    /// The live assistant reply as it streams in (empty between turns). Rendered as
    /// a growing bubble; folded into `messages` when the turn settles.
    public internal(set) var streamingText: String = ""
    public internal(set) var isResponding = false
    public internal(set) var isLoadingHistory = false
    public internal(set) var didLoadHistory = false
    public internal(set) var errorState: ErrorState?
    /// The (new-or-existing) conversation id — latched from the `done` frame so
    /// follow-up turns append to the same server thread.
    public internal(set) var conversationId: String?

    let repository: DocumentsRepository
    let documentId: String
    private var turnTask: Task<Void, Never>?

    public init(repository: DocumentsRepository, documentId: String) {
        self.repository = repository
        self.documentId = documentId
    }

    /// `true` when there is nothing to show yet (fresh thread, not loading) — drives
    /// the empty-state prompt.
    public var isEmpty: Bool {
        messages.isEmpty && streamingText.isEmpty && !isResponding
    }

    // MARK: - History

    /// Load the document's active thread once. Resolves the newest conversation and
    /// hydrates its messages; a document that has never been chatted about resolves
    /// to an empty thread (the panel starts fresh on first send). Failures are
    /// tolerated quietly — an unreachable history leaves an empty, still-usable panel.
    public func loadHistory() async {
        guard !didLoadHistory, !isLoadingHistory else { return }
        isLoadingHistory = true
        defer {
            isLoadingHistory = false
            didLoadHistory = true
        }
        do {
            let list = try await repository.chatHistory(id: documentId)
            guard let newest = list.conversations.first else { return }
            let detail = try await repository.chatHistory(id: documentId, conversationId: newest.id)
            guard let thread = detail.detail else { return }
            conversationId = thread.id
            messages = thread.messages.map {
                Turn(id: $0.id, role: $0.role, text: $0.content)
            }
        } catch {
            // A 404 (never chatted) / transient read failure just leaves an empty
            // thread — the user can still start one. No loud error for history.
        }
    }

    // MARK: - Send

    /// Send a user turn and stream the grounded reply. No-op on empty input or while
    /// a turn is already in flight.
    public func send(_ raw: String) async {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isResponding else { return }
        messages.append(Turn(id: UUID().uuidString, role: .user, text: trimmed))
        await runTurn(message: trimmed)
    }

    /// Retry the most recent user turn after a `limitReached` / `generic` failure —
    /// re-streams the same question without re-appending it.
    public func retry() async {
        guard !isResponding, let last = messages.last(where: { $0.role == .user }) else { return }
        await runTurn(message: last.text)
    }

    /// Cancel an in-flight turn — tears the socket down (the drive task's
    /// cancellation propagates to the stream's `onTermination`) and drops the
    /// partial tail. Safe to call when idle.
    public func cancel() {
        turnTask?.cancel()
    }

    /// Runs one turn on an owned, cancellable task and awaits it — cancellable via
    /// ``cancel()`` yet still deterministic for callers/tests that `await send(_:)`.
    private func runTurn(message: String) async {
        errorState = nil
        streamingText = ""
        isResponding = true
        defer {
            isResponding = false
            turnTask = nil
        }
        let task = Task { [self] in await drive(message: message) }
        turnTask = task
        await task.value
    }

    private func drive(message: String) async {
        var latestMessageId: String?
        let stream = repository.chatStream(
            id: documentId,
            message: message,
            conversationId: conversationId,
            locale: Self.localeCode
        )
        do {
            for try await token in stream {
                try Task.checkCancellation()
                switch token {
                case let .token(chunk):
                    streamingText += chunk
                case let .done(convId, messageId):
                    if let convId, !convId.isEmpty { conversationId = convId }
                    latestMessageId = messageId
                }
            }
            finaliseAssistantTurn(messageId: latestMessageId)
        } catch is CancellationError {
            streamingText = ""
        } catch {
            streamingText = ""
            applyStreamError(error)
        }
    }

    private func finaliseAssistantTurn(messageId: String?) {
        let text = streamingText.trimmingCharacters(in: .whitespacesAndNewlines)
        streamingText = ""
        guard !text.isEmpty else {
            errorState = .generic
            return
        }
        messages.append(Turn(id: messageId ?? UUID().uuidString, role: .assistant, text: text))
    }

    private func applyStreamError(_ error: Error) {
        if let typed = error as? DocumentChatError {
            switch typed {
            case .notIndexed: errorState = .notIndexed
            case .consentRequired: errorState = .consentRequired
            case .limitReached: errorState = .limitReached
            case .provider, .emptyReply, .decode: errorState = .generic
            }
            return
        }
        if case HLError.rateLimited = error { errorState = .limitReached
            return
        }
        if DocumentsRepository.isNotIndexed(error) { errorState = .notIndexed
            return
        }
        if DocumentsRepository.isConsentRequired(error) { errorState = .consentRequired
            return
        }
        errorState = .generic
    }

    // MARK: - Helpers

    /// The two-letter locale the server renders its refusal / limit copy in
    /// (`"de"` / `"en"`), mirroring the Coach's `serverLocaleCode()`.
    static var localeCode: String {
        Locale.current.language.languageCode?.identifier == "de" ? "de" : "en"
    }
}
