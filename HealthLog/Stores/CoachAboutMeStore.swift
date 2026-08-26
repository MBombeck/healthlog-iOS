import Foundation
import Observation

/// **Server-parity v1.16** — `@MainActor @Observable` driver behind the
/// Settings → Assistant → "About me" self-context editor
/// (`SettingsAboutMeScreen`). Thin load/save state machine over
/// ``CoachAboutMeRepository`` — no SWR cache, the editor reads fresh on open
/// and the four drafts live here so they survive body re-evaluations.
@MainActor
@Observable
public final class CoachAboutMeStore: BoxBackedPHIStore {
    /// Editor drafts — bound to the form fields.
    public var aboutMe: String = ""
    public var conditions: String = ""
    public var allergies: String = ""
    public var coachFocus: String = ""

    /// Server-derived clarifying questions (read-only display).
    public private(set) var pendingQuestions: [String] = []

    /// Server caps; refreshed from every GET/PUT echo. Defaults mirror
    /// v1.16.3 so the counter renders sanely before the first load.
    public private(set) var maxChars: Int = 4000
    public private(set) var fieldMaxChars: Int = 500

    public private(set) var isLoading = false
    public private(set) var isSaving = false
    /// `true` after the first successful GET — gates the form render so the
    /// drafts never flash empty over stored content.
    public private(set) var didLoad = false
    /// `true` when the initial GET failed (calm retry surface).
    public private(set) var loadFailed = false

    public enum SaveOutcome: Equatable, Sendable {
        case idle
        case saved
        case failed
    }

    /// **COACH-3** — questions currently being adopted/dismissed (drives the
    /// per-row spinner + disables double-taps). Keyed by the exact question
    /// text (server identifies questions by text, not id).
    public private(set) var inFlightQuestions: Set<String> = []

    /// **COACH-3** — outcome of the most recent clarifying-question action,
    /// for an inline confirmation / error note. Reset on the next action.
    public enum QuestionActionOutcome: Equatable, Sendable {
        case idle
        /// An adopt landed (or deduped). `field` is the self-context field the
        /// answer joined (nil for a dedupe with no field echo).
        case adopted(field: String?)
        /// A dismiss landed.
        case dismissed
        /// The action failed (it was queued for replay if offline).
        case failed
    }

    public private(set) var questionOutcome: QuestionActionOutcome = .idle

    /// Outcome of the most recent save — drives the inline confirmation /
    /// error footnote. Reset to `.idle` whenever a draft changes.
    public private(set) var saveOutcome: SaveOutcome = .idle

    /// Snapshot of the last server state, for change detection.
    private var lastServerState: CoachAboutMeWrite?

    private let repository: CoachAboutMeRepository

    public init(repository: CoachAboutMeRepository) {
        self.repository = repository
    }

    /// `true` when the trimmed drafts differ from the last server state —
    /// enables the Save button.
    public var hasChanges: Bool {
        guard let lastServerState else { return false }
        return currentWrite() != lastServerState
    }

    /// Initial fetch (and retry path). Hydrates the drafts from the server.
    public func load() async {
        isLoading = true
        loadFailed = false
        defer { isLoading = false }
        do {
            try await apply(repository.get())
            didLoad = true
        } catch {
            HLLog.api.error(
                "CoachAboutMe load failed: \(LogSanitizer.redact(String(describing: error)), privacy: .public)"
            )
            loadFailed = true
        }
    }

    /// PUT the current drafts. The server echo (including freshly derived
    /// `pendingQuestions`) re-hydrates the editor.
    public func save() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await apply(repository.update(currentWrite()))
            saveOutcome = .saved
        } catch {
            HLLog.api.error(
                "CoachAboutMe save failed: \(LogSanitizer.redact(String(describing: error)), privacy: .public)"
            )
            saveOutcome = .failed
        }
    }

    /// Clears the save outcome — called by the view when a draft edits so a
    /// stale "Saved" note never lingers next to new changes.
    public func clearSaveOutcome() {
        saveOutcome = .idle
    }

    // MARK: - Clarifying-question loop (COACH-3)

    /// **COACH-3** — adopt a pending clarifying-question answer into the
    /// matching self-context field. The user types the answer in their own
    /// words (`answer`); the server picks the target field from the question
    /// wording, appends, and dedupes. We dismiss the question optimistically
    /// (it has been answered), then re-`get()` to pull in the freshly appended
    /// field text + any newly derived questions. On failure the optimistic
    /// removal is rolled back.
    public func adoptQuestion(_ question: String, answer: String) async {
        let trimmedAnswer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAnswer.isEmpty, !inFlightQuestions.contains(question) else { return }
        inFlightQuestions.insert(question)
        questionOutcome = .idle
        defer { inFlightQuestions.remove(question) }

        let priorQuestions = pendingQuestions
        // Optimistic: an answered question leaves the pending list immediately.
        pendingQuestions.removeAll { $0 == question }
        do {
            let result = try await repository.adopt(
                CoachAboutMeAdoptWrite(question: question, answer: trimmedAnswer)
            )
            // The adopt route doesn't echo the self-context — re-read so the
            // editor reflects the appended field + server-refreshed questions.
            await refreshAfterAction()
            questionOutcome = .adopted(field: result.field)
        } catch {
            pendingQuestions = priorQuestions
            HLLog.api.error(
                "CoachAboutMe adopt failed: \(LogSanitizer.redact(String(describing: error)), privacy: .public)"
            )
            questionOutcome = .failed
        }
    }

    /// **COACH-3** — dismiss a pending clarifying question without answering
    /// it. Optimistic removal from the list; the server returns the remaining
    /// set, which we adopt as the source of truth. On failure the question is
    /// restored.
    public func dismissQuestion(_ question: String) async {
        guard !inFlightQuestions.contains(question) else { return }
        inFlightQuestions.insert(question)
        questionOutcome = .idle
        defer { inFlightQuestions.remove(question) }

        let priorQuestions = pendingQuestions
        pendingQuestions.removeAll { $0 == question }
        do {
            let result = try await repository.dismissQuestion(
                CoachAboutMeDismissWrite(question: question)
            )
            pendingQuestions = result.questions
            questionOutcome = .dismissed
        } catch {
            pendingQuestions = priorQuestions
            HLLog.api.error(
                "CoachAboutMe dismiss failed: \(LogSanitizer.redact(String(describing: error)), privacy: .public)"
            )
            questionOutcome = .failed
        }
    }

    /// **COACH-3** — "remember this": fold a user's own chat statement into the
    /// self-context. No `question` is sent — the server matches the target
    /// field from the statement text itself (v1.16.8). Returns the adopt
    /// result so the chat surface can show a quiet confirmation ("Gemerkt"),
    /// or `nil` on failure (the write is still queued for replay if offline).
    @discardableResult
    public func remember(_ statement: String) async -> CoachAboutMeAdoptResult? {
        let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            let result = try await repository.adopt(
                CoachAboutMeAdoptWrite(question: nil, answer: trimmed)
            )
            // If the editor store is live, keep it consistent with the server.
            if didLoad {
                await refreshAfterAction()
            }
            return result
        } catch {
            HLLog.api.error(
                "CoachAboutMe remember failed: \(LogSanitizer.redact(String(describing: error)), privacy: .public)"
            )
            return nil
        }
    }

    /// **W-B187 (AUDIT-SEC-b187 B1)** — wipe the cached self-context PHI so the
    /// next user on the same device never inherits the previous user's medical
    /// conditions / allergies / coach-focus through the container-lifetime
    /// store. Resets `didLoad` so `SettingsAboutMeScreen`'s
    /// `if !s.didLoad { await s.load() }` guard re-fetches fresh against the
    /// new partition instead of rendering the predecessor's drafts.
    public func clearOnLogout() {
        aboutMe = ""
        conditions = ""
        allergies = ""
        coachFocus = ""
        pendingQuestions = []
        inFlightQuestions = []
        questionOutcome = .idle
        saveOutcome = .idle
        lastServerState = nil
        isLoading = false
        isSaving = false
        loadFailed = false
        didLoad = false
    }

    /// **W-PHI-HARDENING (G5)** — box-backed PHI conformance so the
    /// ``MiniCoachBox`` logout registry can clear this store generically and the
    /// completeness suite can verify it. Forwards to ``clearOnLogout()``.
    public func clearPHIOnLogout() async {
        clearOnLogout()
    }

    /// Re-read the self-context after an adopt — the adopt endpoint mutates a
    /// single field server-side without echoing the new state. Failures here
    /// are non-fatal (the write already landed); we just keep the stale view.
    private func refreshAfterAction() async {
        do {
            try await apply(repository.get())
            didLoad = true
        } catch {
            HLLog.api.error(
                "CoachAboutMe post-action refresh failed: \(LogSanitizer.redact(String(describing: error)), privacy: .public)"
            )
        }
    }

    // MARK: - Internals

    private func currentWrite() -> CoachAboutMeWrite {
        CoachAboutMeWrite(
            aboutMe: aboutMe.trimmingCharacters(in: .whitespacesAndNewlines),
            conditions: conditions.trimmingCharacters(in: .whitespacesAndNewlines),
            allergies: allergies.trimmingCharacters(in: .whitespacesAndNewlines),
            coachFocus: coachFocus.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Test-only — simulate a completed initial load (drafts hydrated +
    /// `didLoad` flipped) without a network round-trip, so the logout-wipe
    /// suite can prove the cached PHI is cleared. Production code reaches this
    /// state only through ``load()`` / ``save()``.
    func seedLoadedStateForTesting(
        aboutMe: String,
        conditions: String,
        allergies: String,
        coachFocus: String,
        pendingQuestions: [String] = []
    ) {
        self.aboutMe = aboutMe
        self.conditions = conditions
        self.allergies = allergies
        self.coachFocus = coachFocus
        self.pendingQuestions = pendingQuestions
        lastServerState = currentWrite()
        didLoad = true
    }

    private func apply(_ dto: CoachAboutMeDTO) {
        aboutMe = dto.aboutMe ?? ""
        conditions = dto.conditions ?? ""
        allergies = dto.allergies ?? ""
        coachFocus = dto.coachFocus ?? ""
        pendingQuestions = dto.pendingQuestions
        maxChars = dto.maxChars
        fieldMaxChars = dto.fieldMaxChars
        lastServerState = currentWrite()
    }
}
