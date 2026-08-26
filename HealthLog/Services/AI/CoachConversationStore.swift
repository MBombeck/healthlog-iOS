import Foundation
import Observation

#if canImport(SpeziChat)
    import SpeziChat
#endif

#if canImport(FoundationModels)
    import FoundationModels
#endif

/// **v0.5.7 G.3** — `@MainActor @Observable` driver behind the
/// `AskCoachSheet` chat surface. Wraps a `SpeziChat.Chat` transcript
/// (an ordered array of `ChatEntity`s) plus the bridge to
/// `LocalLLMService.respond(prompt:)` (G.2) so the SwiftUI view layer
/// can render a turn-by-turn conversation backed by Apple
/// FoundationModels.
///
/// **Architecture choice — store-owned `Chat` + `LocalLLMService`:**
/// The store owns the chat array as a stored property; the view binds
/// to it through `SpeziChat.ChatView($store.chat)`. `LocalLLMService`
/// also lives here so the FoundationModels availability re-probe runs
/// on the same actor SwiftUI is already on (no actor hops on send).
///
/// **Hoisted `LanguageModelSession` (v0.12 W8-2, completed via #14):** the
/// session lives on `LocalLLMService` for the store's lifetime, so transcript
/// context persists across turns and the cold-start is paid once (pre-warmed
/// on sheet appear). The G.3↔G.5 seam is closed: `reset()` / `clearOnLogout`
/// drop the session alongside the transcript, availability flips re-create it
/// on the next turn, and a context-window overflow rebuilds it with a
/// condensed transcript + retries the turn once (`runOnDeviceTurn`).
///
/// **Why `@MainActor @Observable` (not an `actor`)?** SwiftUI views
/// need synchronous reads of `chat` + `isResponding` on every body pass
/// — an actor would force an `await` hop per read, which violates the
/// `body` synchronicity contract. The store does no blocking work on
/// the main thread; `send(_:)` awaits the FoundationModels call via
/// `async`/`await` and the only mutation is the cheap append on
/// completion.
///
/// **Streaming (v0.12 W8-1):** `runOnDeviceTurn` consumes
/// `LocalLLMService.streamResponse` and renders each
/// `CoachInsight.PartiallyGenerated` snapshot in place via
/// `upsertStreamingAssistant`, so the bubble grows progressively.
///
/// **v0.5.7 G.5 — SwiftData persistence:** the store now hydrates the
/// transcript from `CoachChatStore` on init and persists both the
/// user + assistant turns of every `send(_:)` (and the assistant turn
/// of every `respondToLastUserTurn(prompt:)` — the user-append happens
/// view-side via SpeziChat). The persisted rows are partitioned by
/// `userIDProvider()` so a second account on the same device sees an
/// empty transcript. `reset()` wipes both the in-memory chat AND the
/// persisted rows for the current partition. Logout cleanup goes
/// through `AppContainer.handleLocalLogout` which calls
/// `clearAll(includingPartition:)` so the partition the user was
/// signed in under is wiped before the keychain `userID` is removed.
@MainActor
@Observable
public final class CoachConversationStore {
    #if canImport(SpeziChat)
        /// Chat transcript exposed to SwiftUI through
        /// `SpeziChat.ChatView($store.chat)`. `Chat` is a typealias for
        /// `[ChatEntity]` upstream, so we can mutate it the same way we
        /// would any `@Published` array. The `Binding<Chat>` produced by
        /// `$store.chat` survives across body re-evaluations because
        /// `@Observable` synthesises a stable backing for stored
        /// properties.
        public var chat: Chat = []
    #else
        /// Fallback when SpeziChat is not linkable in this build
        /// configuration. Kept as `[String]` so unit tests can still
        /// exercise the append / reset contract without importing
        /// SpeziChat. The AskCoach view never reaches this branch
        /// because the view itself sits behind the same `canImport`
        /// gate; the test binary, however, may run on a SpeziChat-less
        /// configuration (rare — currently every target links the
        /// product — but the fallback keeps the type compilable
        /// regardless).
        public var chat: [String] = []
    #endif

    /// `true` while a `send(_:)` call is in flight. Drives the SpeziChat
    /// `MessagesView.TypingIndicatorDisplayMode.manual(shouldDisplay:)`
    /// flag so the typing-dot animation only paints during model
    /// generation. SwiftUI re-reads on every observable change.
    public private(set) var isResponding: Bool = false

    /// Last error surfaced by `send(_:)`. Drives a kill-card / banner on
    /// the AskCoach sheet when FoundationModels is unavailable mid-flow
    /// (e.g. the user toggled Apple Intelligence off between sheet-open
    /// and submit). Reset to `nil` on the next successful turn.
    public private(set) var lastError: LocalLLMError?

    /// **v0.6.1 F6 — double-response guard.** Set to `true` for the
    /// duration of a `send(_:)` call so the AskCoachSheet's
    /// `onChange(of: store.chat)` observer can distinguish a
    /// programmatic suggestion-chip / `send(_:)` user-append (which the
    /// store itself already follows with an assistant turn) from a
    /// view-initiated SpeziChat `MessageInputView` user-append (which
    /// still needs `respondToLastUserTurn(prompt:)` to fire the model).
    ///
    /// **Why a dedicated flag instead of leaning on `isResponding`?**
    /// `isResponding` only flips to `true` after the availability gate
    /// passes (post-iOS-26 check). On unavailable runtimes the chat
    /// would mutate via `appendUser` without `isResponding` ever
    /// flipping — the view observer would then see `isResponding ==
    /// false` and dispatch a second round-trip. A standalone flag set
    /// BEFORE the user-append (and cleared in a `defer`) is the
    /// minimum-surprise contract: the view observer always sees the
    /// flag in the same MainActor turn as the chat mutation.
    public private(set) var programmaticSendInFlight: Bool = false

    /// The on-device LLM service. Held by the store so the
    /// availability re-probe runs on the same actor SwiftUI is on, and
    /// so the hoisted `LanguageModelSession` (G.5 seam, resolved via #14)
    /// lives alongside for the store's lifetime — reused across turns,
    /// dropped on `reset()` / `clearOnLogout` / availability change.
    public let service: LocalLLMService

    /// **v0.5.7 G.4** — snapshot provider invoked once per send to
    /// build a sanitized `HealthSnapshot` for prompt enrichment. Held
    /// as a closure (not a direct `AppContainer` reference) so:
    ///   1. Unit tests can inject a hand-rolled snapshot without
    ///      spinning up the full composition root.
    ///   2. The store stays unit-testable in isolation — the
    ///      AppContainer is the only object that knows how to read
    ///      every store at once, and the closure shape mirrors
    ///      `PrivacyFirstPromptBuilder.snapshot(from:)` exactly.
    ///   3. When `nil`, the store falls back to the raw-user-text path
    ///      (`HealthSnapshot.empty`) so existing tests that don't
    ///      supply a provider keep passing.
    ///
    /// **Privacy seam:** the snapshot is read on every send so the
    /// model gets the freshest possible local context. The closure
    /// itself does NO network I/O — see `PrivacyFirstPromptBuilder`
    /// doc-header invariants 1-4.
    public var snapshotProvider: (@MainActor () -> HealthSnapshot)?

    /// **v0.5.7 G.5** — partition key resolver. Injected as a closure
    /// (not a direct `KeychainStore` ref) so tests can pin a
    /// deterministic user id without spinning up the keychain. Returns
    /// `CoachChatMessage.standaloneUserID` when no keychain user is
    /// present so cold-launch / standalone-mode turns still partition
    /// under a stable sentinel.
    public var userIDProvider: @MainActor () -> String

    /// **v0.5.7 G.5** — SwiftData persistence shim. `nil` in unit-tests
    /// that don't care about disk replay; production wiring in
    /// `AppContainer+SpeziLLM.swift` always supplies one. Made
    /// `var` rather than `let` so the in-memory test path can swap an
    /// alternate store post-init without re-instantiating the
    /// `@Observable` host (Observable types don't tolerate
    /// re-instantiation across body re-evaluations).
    public var persistence: CoachChatStore?

    /// **v0.7.1 W-COACH-FALLBACK** — server Coach used when the
    /// on-device model is unavailable (no Apple Intelligence, pre-iOS-26,
    /// model still downloading, device ineligible). `nil` in unit tests
    /// that only exercise the on-device path; production wiring in
    /// `AppContainer+SpeziLLM.swift` always supplies one.
    public var serverService: CoachServerService?

    /// **v0.7.1 W-COACH-FALLBACK** — synchronous gate the store consults
    /// to decide whether the server fallback may run. Production wires
    /// this to `AIConsentStore.hasConsent(for:)` against the active
    /// server provider so we never transmit health data off-device
    /// without the explicit per-provider consent (Apple Guideline
    /// 5.1.2(i)). Returns `true` when consent is granted. `nil` →
    /// permissive in tests that don't care about the gate.
    public var serverConsentGate: (@MainActor () -> Bool)?

    /// **v0.11 marathon (AI-1)** — `true` when the user *explicitly* chose the
    /// server ("External AI" / `.online`) arm. Production wires this to
    /// `AIConsentStore.aiMode == .online`; `nil` → legacy on-device-first
    /// fallback (the unit tests pre-dating the explicit-pick path).
    ///
    /// Before AI-1 arm selection was purely capability-driven — `service.isReady`
    /// won before the server arm, so a deliberate "External AI" pick on a capable
    /// device was silently overridden onto on-device. Consulting the explicit
    /// pick lets `.online` win there, exactly as the BYO-key arm already does.
    /// Consent stays fail-closed: this only *prefers* the arm, never bypasses
    /// `serverConsentGate`.
    public var prefersServerArm: (@MainActor () -> Bool)?

    /// **v0.7.1 W-COACH-FALLBACK** — `true` while the conversation is
    /// being served by the server fallback rather than the on-device
    /// model. Drives the AskCoach sheet's "läuft auf dem Server"
    /// disclosure so the user knows their data leaves the device on this
    /// path (the on-device path is private; the server path is not).
    public private(set) var usingServerFallback: Bool = false

    // The server-arm decision gate (`explicitlyPrefersServer`,
    // `serverFallbackNeedsConsent`, `shouldUseServerFallback`) lives in
    // `CoachConversationStore+ServerArm.swift` (split out v0.11 AI-1 to keep this
    // file under the 600-line SwiftLint ceiling).

    /// Server-side conversation id for the active server-fallback thread.
    /// `nil` until the first server turn returns one; reset on `reset()`
    /// so a fresh conversation starts a new server thread.
    private var serverConversationID: String?

    /// **A360 H1/H2 (v0156)** — the metric/correlation scope the user was looking
    /// at when they opened the Coach (per-tile "Ask the coach about this",
    /// per-metric page, correlation card). Set by the AskCoach sheet from its
    /// launch context; threaded into the server chat request's `scope` on the
    /// FIRST turn of a fresh server conversation only (web parity — a continued
    /// thread keeps its own established scope), then implicitly retired as the
    /// `serverConversationID` latches. Render-only off the wire; never logged.
    public var launchScope: CoachLaunchScope?

    /// Sets the launch scope for the next conversation. Called by the AskCoach
    /// sheet on appear; cleared on `reset()` so a later blank entry is unscoped.
    public func setLaunchScope(_ scope: CoachLaunchScope?) {
        launchScope = scope
    }

    /// **AUD-5 H2 — the in-flight turn task.** `send(_:)` /
    /// `respondToLastUserTurn(_:)` run their turn runner inside this held task so
    /// the view can cancel it on dismiss (``cancelInFlightTurn()``). Previously the
    /// send was an unstructured `Task { await store.send(…) }` in the view with no
    /// handle: dismissing the Coach sheet mid-stream let the server SSE turn run to
    /// its full 120s-idle / 600s-ceiling budget, holding the connection, wasting
    /// the health-context egress the user tried to abort, and on completion
    /// mutating + persisting an `@Observable` store whose view is gone. Holding the
    /// task here (plus the `Task.isCancelled` checks in the turn runners) tears the
    /// `URLSession` socket down on cancel and stops the turn from persisting a
    /// dead-view reply.
    private var turnTask: Task<Void, Never>?

    /// **AUD-5 H2 — cancel the in-flight Coach turn.** Called from the Coach
    /// sheet's `onDisappear` so leaving the sheet mid-stream tears the SSE socket
    /// down (cooperative `URLSession` cancellation) and the turn stops before it
    /// persists a reply whose view is gone. Idempotent + cheap when nothing is in
    /// flight. Clears `isResponding` so a re-open paints a clean state.
    public func cancelInFlightTurn() {
        turnTask?.cancel()
        turnTask = nil
        isResponding = false
    }

    /// Per-message feedback state for server-arm assistant replies (thumbs
    /// up/down → `POST /api/insights/chat/messages/{id}/feedback`). See
    /// ``CoachMessageFeedback`` for the registration + one-shot contract;
    /// the submit path lives in `CoachMessageFeedback.swift`'s store
    /// extension. Cleared alongside the transcript.
    public let feedback = CoachMessageFeedback()

    /// **CO4 (v0154)** — provenance envelopes keyed by the appended assistant
    /// transcript-entity id, so the bubble can look up its "what I'm looking at"
    /// disclosure. Server-arm only (on-device / BYO turns carry no provenance —
    /// the server never sees those). Session-lived (the transcript is the live
    /// `chat`); cleared alongside the transcript.
    public private(set) var provenanceByEntity: [UUID: CoachServerService.CoachProvenance] = [:]

    /// **CO5 (v0154)** — per-turn token usage keyed by the appended assistant
    /// transcript-entity id, so the bubble can paint the quiet token footer.
    /// Server-arm only; session-lived; cleared alongside the transcript.
    public private(set) var usageByEntity: [UUID: CoachServerService.CoachUsage] = [:]

    /// **v0.13 W4 — BYO-key (client-side device→provider) arm.** The actor that
    /// transmits the composed prompt straight from this device to the user's own
    /// LLM provider. `nil` in unit tests that only exercise the on-device /
    /// server arms; production wiring in `AppContainer+SpeziLLM.swift` always
    /// supplies one (with the consent gate baked into the service).
    public var byoService: BYOLLMService?

    /// **v0.13 W4** — resolves the active BYO provider, or `nil` when the BYO arm
    /// is not the user's chosen mode (no grant). Production wires this to
    /// `AIConsentStore` (the first granted `BYOProviderID`); `nil` → the BYO arm
    /// is never selected.
    public var byoProviderResolver: (@MainActor () -> BYOProviderID?)?

    /// `true` when the store should route sends through the BYO-key arm: a BYO
    /// service is wired AND the user's active mode resolves a granted BYO
    /// provider. Takes precedence over the on-device / server arms because it is
    /// the user's *explicit* AI-source choice (it works even on an
    /// AI-capable device, by design).
    public var shouldUseBYO: Bool {
        byoService != nil && byoProviderResolver?() != nil
    }

    /// **v0.13 W4** — `true` while the active turn is being served by the BYO-key
    /// arm. Drives the AskCoach sheet's "direct from this device to your
    /// provider" disclosure so the user knows their data egresses to a third
    /// party on this path (distinct from the server path).
    public private(set) var usingBYO: Bool = false

    /// **v1.18.1 (§3)** — the cadence suggestion the latest server turn emitted,
    /// if any. Ephemeral (never persisted): the transcript renders an actionable
    /// card while it is non-nil; it clears when the user acts on it or starts a
    /// new turn / conversation. Only the server arm sets it — the on-device + BYO
    /// arms never produce suggestions.
    public private(set) var pendingSuggestion: CoachServerService.CoachReminderSuggestion?

    /// **v1.18.1 (§3)** — set after `actOnSuggestion` succeeds so the card can
    /// show a brief "reminder created" confirmation before it clears. `nil` once
    /// the suggestion is cleared.
    public private(set) var lastSuggestionAction: CoachServerService.SuggestionAction?

    /// **#30** — hook fired when a server turn surfaces an inline cadence
    /// suggestion, so the proactive Insights card surface
    /// (``CoachCadenceSuggestionsStore``) can present the *same* suggestion
    /// (bridged to ``CoachCadenceSuggestion``) outside an open chat. Wired in
    /// `AppContainer+SpeziLLM.swift`; `nil` in in-chat-only unit tests.
    public var onSuggestion: (@MainActor (CoachCadenceSuggestion) -> Void)?

    public init(
        service: LocalLLMService,
        snapshotProvider: (@MainActor () -> HealthSnapshot)? = nil,
        persistence: CoachChatStore? = nil,
        serverService: CoachServerService? = nil,
        serverConsentGate: (@MainActor () -> Bool)? = nil,
        byoService: BYOLLMService? = nil,
        byoProviderResolver: (@MainActor () -> BYOProviderID?)? = nil,
        userIDProvider: @escaping @MainActor () -> String = { CoachChatMessage.standaloneUserID }
    ) {
        self.service = service
        self.snapshotProvider = snapshotProvider
        self.persistence = persistence
        self.serverService = serverService
        self.serverConsentGate = serverConsentGate
        self.byoService = byoService
        self.byoProviderResolver = byoProviderResolver
        self.userIDProvider = userIDProvider
        // **G.5 hydrate on init:** the first read of `chat` after
        // construction reflects whatever was persisted under the
        // current partition. Done synchronously here rather than via
        // an async `.task` because SwiftData `mainContext.fetch` is
        // sub-millisecond for the bounded row-count we cap at (≤500)
        // — an async hydrate would risk an empty-chat frame between
        // sheet-open and the first refresh.
        hydrate()
    }

    // `composePrompt(userText:)` + `hydrate()` live in
    // `CoachConversationStore+Helpers.swift` (moved there for issue #14 to
    // keep this file under the 600-line SwiftLint ceiling). `seedIntendedArm()`
    // (C1 — provenance pill before the first turn) lives in
    // `CoachConversationStore+ServerArm.swift` next to the arm-decision gate it
    // reads.

    /// **C1 — set the egress provenance flags from the store.** The view-facing
    /// `seedIntendedArm()` resolves the derived arm; these setters keep the
    /// `usingServerFallback` / `usingBYO` mutation in the store (they are
    /// `private(set)`) so the extension can flip them without widening access.
    func setIntendedArm(server: Bool, byo: Bool) {
        usingServerFallback = server
        usingBYO = byo
    }

    /// Sends `text` as a user turn — appends a user entity to the
    /// transcript, calls `LocalLLMService.respond(prompt:)`, and
    /// appends the assistant response (joined `CoachInsight` rendering)
    /// on completion. No-op on empty / whitespace-only input.
    ///
    /// **Availability gate:** the call early-returns with an
    /// `.foundationModelsUnavailable` error written to `lastError` when
    /// `service.isReady == false` — the AskCoach view surfaces the
    /// unavailable kill-card before reaching this method in normal use,
    /// but a Settings-toggle race could still slip through.
    ///
    /// **Tests on iOS 18 / 25** (`canImport(FoundationModels) == false`):
    /// the call appends the user entity, then surfaces
    /// `.foundationModelsUnavailable` without invoking the service. The
    /// G.3 test suite asserts both the user-append and the error-write
    /// on those runtimes.
    ///
    /// **G.5 persistence:** the user turn is persisted immediately on
    /// append so an app crash mid-LLM-call still has the user's input
    /// on disk for the next hydrate. The assistant turn is persisted
    /// after the LocalLLMService returns successfully.
    public func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        lastError = nil
        // v1.18.1 (§3) — a new user turn supersedes any prior cadence card
        // (covers the on-device / BYO arms, which never set a new suggestion).
        pendingSuggestion = nil
        lastSuggestionAction = nil
        // **F6 guard:** flip BEFORE the user-append so the AskCoachSheet
        // `onChange` observer can detect "this user-append came from
        // store.send — don't dispatch a second LLM round-trip". Cleared
        // in a defer so every exit path (early return, throw, success)
        // resets the flag. The append + flag flip happen in the same
        // MainActor turn → SwiftUI's body re-eval observes both together.
        programmaticSendInFlight = true
        defer { programmaticSendInFlight = false }
        appendUser(trimmed)
        persistMessage(role: .user, text: trimmed)

        // AUD-5 H2 — run the turn inside a held, cancellable task so the view can
        // tear it down on dismiss. We still `await` it so callers (suggestion
        // chips / composer submit) keep their `async` contract; a `cancel()` makes
        // the awaited task return promptly (the runners check `Task.isCancelled`
        // and `URLSession` honours cooperative cancellation on the server arm).
        await runHeldTurn(userText: trimmed)
    }

    /// Runs the arm-routed turn inside the held ``turnTask`` so it is cancellable
    /// on sheet dismiss (AUD-5 H2). Shared by `send(_:)` + `respondToLastUserTurn`.
    private func runHeldTurn(userText: String) async {
        turnTask?.cancel()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            // **v0.13 W4 — BYO-key arm.** The user's explicit "Own key" choice
            // wins over both other arms: requests go straight from this device to
            // their provider. The service enforces the consent gate before
            // any transmit.
            if shouldUseBYO {
                await runBYOTurn(userText: userText)
                return
            }
            // **v0.7.1 W-COACH-FALLBACK** — when the on-device model is not ready
            // but a consented server service is wired, route the turn to the
            // server Coach instead of dead-ending on the kill-card.
            if shouldUseServerFallback {
                await runServerTurn(userText: userText)
                return
            }
            await runOnDeviceTurn(userText: userText)
        }
        turnTask = task
        await task.value
        // Only clear the handle if it's still ours (a newer turn may have
        // replaced it while we awaited).
        if turnTask == task { turnTask = nil }
    }

    /// Generates the assistant turn for a user message that was already
    /// appended to the transcript by the SpeziChat `MessageInputView`.
    /// Used by `AskCoachSheet`'s `onChange` observer where the
    /// user-append already happened — calling `send(_:)` would
    /// double-append. The wiring stays in the store so the
    /// FoundationModels availability + error-handling logic lives in
    /// exactly one place.
    ///
    /// **G.5 persistence:** the view-side append already happened in
    /// SpeziChat's `MessageInputView` — we mirror it onto disk here
    /// so the next launch hydrates the same row. The assistant turn
    /// follows on a successful LocalLLMService return.
    public func respondToLastUserTurn(prompt: String) async {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        lastError = nil
        // Persist the user turn the view-side already appended to the
        // in-memory `chat`. SpeziChat doesn't reach SwiftData itself —
        // we're the only writer to the persistence layer.
        persistMessage(role: .user, text: trimmed)

        // AUD-5 H2 — same held, cancellable turn path as `send(_:)`.
        await runHeldTurn(userText: trimmed)
    }

    // MARK: - BYO-key turn (v0.13 W4 — device→provider direct)

    /// Runs one assistant turn against the user's own LLM provider, directly
    /// from this device (the user turn was already appended + persisted by the
    /// caller). Reuses the SAME composed prompt as every other arm
    /// (`PrivacyFirstPromptBuilder` via ``composePrompt(userText:)``), so the
    /// snapshot + injection-guard carry over verbatim. Non-streaming (D11): the
    /// reply lands as a single assistant turn.
    ///
    /// **Consent enforcement (5.1.2(i)):** `BYOLLMService.generate` is wired with
    /// the per-provider consent gate, so it THROWS `.invalidConfiguration` before
    /// any network call if consent is absent — a request can never fire
    /// un-consented. On any ``BYOLLMError`` we fold an honest, mapped message into
    /// the existing `lastError` surface (no new error type, no crash).
    private func runBYOTurn(userText: String) async {
        guard let byoService, let provider = byoProviderResolver?() else {
            lastError = .foundationModelsUnavailable
            return
        }
        // v0.13 WR — the disclosure flags are mutually exclusive: this turn
        // egresses device→provider, so clear any stale server-fallback notice
        // from a prior arm. Renders exactly one honest egress disclosure.
        usingBYO = true
        usingServerFallback = false
        isResponding = true
        defer { isResponding = false }
        let composedPrompt = composePrompt(userText: userText)
        do {
            let text = try await byoService.generate(prompt: composedPrompt, provider: provider)
            // AUD-5 H2 — sheet dismissed mid-request: don't persist a dead-view turn.
            if Task.isCancelled { return }
            appendAssistant(text)
            persistMessage(role: .assistant, text: text)
        } catch let error as BYOLLMError {
            // Map onto the existing banner surface — the AskCoach error copy
            // renders an honest, key-checkable message per case (W4 errorCopy).
            // v0.13 WP (L2) — log the case label only, never the raw provider
            // `badRequest` payload (which could echo a request fragment).
            // loggableDescription is a curated enum label (L2 hardening) — never the
            // free-form provider payload.
            // swiftlint:disable:next hllog_public_privacy_interpolation
            HLLog.api.error(
                "BYO Coach turn failed: \(error.loggableDescription, privacy: .public)"
            )
            lastError = .byoFailed(error)
        } catch {
            HLLog.api.error(
                "BYO Coach turn failed: \(LogSanitizer.redact(String(describing: error)), privacy: .public)"
            )
            lastError = .modelResponseFailed(error)
        }
    }

    // MARK: - On-device turn (v0.12 W8-1 streaming)

    /// Runs one assistant turn against the on-device model (user turn already
    /// appended + persisted by the caller). **v0.12 W8-1:** streams the
    /// `CoachInsight.PartiallyGenerated` snapshots and renders them in place so
    /// the bubble grows (headline → body → actions) instead of popping in whole.
    /// Only the final text is persisted; a stream throw leaves the partial turn
    /// in place and sets `lastError` so the banner offers retry.
    private func runOnDeviceTurn(userText: String) async {
        // v0.13 WR — on-device is fully private: clear BOTH egress disclosures so
        // a prior server/BYO turn's notice never lingers on a private turn.
        usingServerFallback = false
        usingBYO = false
        #if canImport(FoundationModels)
            guard #available(iOS 26.0, *) else {
                lastError = .foundationModelsUnavailable
                return
            }
            isResponding = true
            defer { isResponding = false }
            // G.4 — the transcript shows the raw user text; the model receives
            // the privacy-first prompt enriched from the local HealthSnapshot
            // (transient: never stored, logged, or sent off-device).
            let composedPrompt = composePrompt(userText: userText)
            var didAppend = false
            var lastRendered = ""
            var didRecoverFromOverflow = false
            while true {
                do {
                    let stream = try service.streamResponse(prompt: composedPrompt)
                    for try await snapshot in stream {
                        // AUD-5 H2 — stop promptly if the sheet was dismissed
                        // mid-stream; don't keep mutating a gone view's transcript.
                        if Task.isCancelled { return }
                        let rendered = Self.renderPartial(snapshot.content)
                        guard !rendered.isEmpty else { continue }
                        lastRendered = rendered
                        upsertStreamingAssistant(rendered, isFirstPartial: !didAppend)
                        didAppend = true
                    }
                    // AUD-5 H2 — never persist a dead-view turn after a dismiss.
                    if Task.isCancelled { return }
                    // Persist only the final, complete assistant turn.
                    if didAppend {
                        persistMessage(role: .assistant, text: lastRendered)
                    } else {
                        // 22-02 (D-14-04-A) — the stream completed having
                        // rendered nothing. Saying nothing about that leaves the
                        // user turn standing alone with `lastError == nil`,
                        // which reads like a deliberate non-answer.
                        lastError = Self.emptyGenerationOutcome(didRenderAnything: false)
                    }
                    return
                } catch let error as LocalLLMError {
                    lastError = error
                    return
                } catch {
                    // **#14 — context-window overflow recovery.** The stream
                    // throws the raw `GenerationError`; when it is
                    // `exceededContextWindowSize` the service swaps the hoisted
                    // session for a fresh one carrying a condensed transcript
                    // (instructions + latest entry) and we retry the turn
                    // exactly once. The partially rendered bubble (if any)
                    // keeps growing in place on the retry.
                    if !didRecoverFromOverflow, service.recoverFromContextOverflow(error) {
                        didRecoverFromOverflow = true
                        continue
                    }
                    lastError = .modelResponseFailed(error)
                    return
                }
            }
        #else
            // FoundationModels not linkable — record the unavailable error so
            // the view can paint the kill-card. The user message stays in the
            // transcript so the operator still sees what they typed (helps when
            // toggling between runtimes during dev).
            _ = userText
            lastError = .foundationModelsUnavailable
        #endif
    }

    // MARK: - Server fallback turn (v0.7.1 W-COACH-FALLBACK)

    /// Runs one assistant turn against the server Coach. The user turn
    /// was already appended + persisted by the caller. On success the
    /// assistant reply is appended + persisted; on failure a
    /// `LocalLLMError` is written to `lastError` so the existing
    /// error-banner surfaces a retry CTA (no new error surface — the
    /// banner already covers `.foundationModelsUnavailable` /
    /// `.modelResponseFailed`).
    private func runServerTurn(userText: String) async {
        guard let serverService else {
            lastError = .foundationModelsUnavailable
            return
        }
        // v0.13 WR — mutual exclusivity: this turn runs on the server, so clear
        // any stale BYO notice from a prior arm.
        usingServerFallback = true
        usingBYO = false
        isResponding = true
        defer { isResponding = false }
        let priorConversationID = serverConversationID
        // **A360 H1/H2 (v0156)** — attach the launch scope to the FIRST turn of a
        // fresh server conversation only (web parity: a continued thread keeps its
        // established scope). `nil` once a thread id has latched or when the Coach
        // was opened without a metric context.
        let turnScope: CoachScopeWire? = priorConversationID == nil ? launchScope?.wireScope : nil
        // **A360 H3 (v0156)** — progressive streaming render seam. The accumulator
        // appends a new assistant turn on the first token, then replaces it in
        // place on each later token so the bubble grows token-by-token (same
        // `upsertStreamingAssistant` plumbing the on-device arm uses). Guarded so a
        // mid-stream dismiss (cancellation) stops mutating a gone view's transcript.
        let streamRender = ServerStreamRender()
        do {
            let reply = try await serverService.respond(
                message: userText,
                conversationId: priorConversationID,
                locale: serverLocaleCode(),
                scope: turnScope,
                onToken: { [weak self] token in
                    guard let self else { return }
                    if Task.isCancelled { return }
                    streamRender.append(token)
                    upsertStreamingAssistant(
                        streamRender.text,
                        isFirstPartial: streamRender.isFirstPartial
                    )
                    streamRender.markAppended()
                }
            )
            // AUD-5 H2 — the user dismissed the sheet while the SSE turn was in
            // flight. `URLSession` cancellation usually throws first (handled in
            // `catch`), but on a graceful late completion the response can still
            // arrive: do NOT mutate / persist a reply whose view is gone. Bail
            // before touching the @Observable transcript or the persistence layer.
            if Task.isCancelled { return }
            // BH-final-diff H4 — close the cancellation TOCTOU. `cancelInFlightTurn()`
            // can flip `Task.isCancelled` concurrently AFTER the guard above and
            // BEFORE we latch the conversation id / persist the reply. Re-check
            // immediately before the first irreversible mutation (latching the
            // server conversation id) AND again immediately before persisting, so
            // a dismissed turn can never commit a "complete" reply or latch a
            // conversation the user abandoned.
            if Task.isCancelled { return }
            serverConversationID = reply.conversationId ?? priorConversationID
            // If tokens streamed in, the trailing assistant turn already holds the
            // accumulated text; overwrite it with the server's final, cleaned reply
            // (trailing-whitespace-trimmed, provenance sentinels stripped) so the
            // bubble settles on the authoritative text rather than the raw token
            // concatenation. When NO token arrived (older server / refusal path
            // routed through `parseSSE`-style frames), append fresh as before.
            if streamRender.didAppend {
                upsertStreamingAssistant(reply.text, isFirstPartial: false)
            } else {
                appendAssistant(reply.text)
            }
            // v1.18.1 (§3) — surface the cadence suggestion (if the server emitted
            // one this turn) as an actionable card under the reply. A new turn
            // having no suggestion clears any stale one.
            pendingSuggestion = reply.suggestion
            lastSuggestionAction = nil
            // #30 — also route it into the proactive Insights card surface (the
            // overview store owns the opt-in / dismissed / Focus-filter gating).
            if let suggestion = reply.suggestion {
                onSuggestion?(Self.bridgeCadenceSuggestion(suggestion))
            }
            // Feedback registration + CO4/CO5 provenance + token stash: the
            // appended assistant turn is the last transcript entity; map the
            // server's `done` messageId (feedback) and the provenance / usage
            // envelopes onto it so the bubble can render the thumbs row, the
            // collapsed "what I'm looking at" disclosure, and the quiet token
            // footer. Provenance/usage are render-only; we never log them.
            if let entityID = lastEntityID() {
                if let messageID = reply.messageId {
                    feedback.register(messageID: messageID, forEntity: entityID)
                }
                if let provenance = reply.provenance, !provenance.isEmpty {
                    provenanceByEntity[entityID] = provenance
                }
                if let usage = reply.usage, usage.totalTokens != nil {
                    usageByEntity[entityID] = usage
                }
            }
            // BH-final-diff H4 — final cancellation re-check immediately before
            // the persist. If the user dismissed mid-block, do not write the
            // assistant reply as a completed message.
            if Task.isCancelled { return }
            persistMessage(role: .assistant, text: reply.text)
        } catch {
            // AUD-5 H2 — a dismiss-triggered cancellation surfaces here as a
            // URLError(.cancelled); it is not a real failure, so don't paint a
            // retry banner on a gone view.
            if Task.isCancelled { return }
            // C3 (b199 walkthrough) — PRESERVE the typed error rather than
            // collapsing every failure into `.modelResponseFailed`. The
            // `.serverFailed` case keeps the discriminating cause
            // (`CoachServerError.provider(code)`, `HLError.assistantDisabled` /
            // HTTP status, offline, missing consent receipt) so
            // `serverErrorCopy` can render an honest, actionable message instead
            // of the flat "Response failed. Please try again." The user turn
            // stays in the transcript for a retry.
            HLLog.api.error(
                "CoachServerService turn failed: \(LogSanitizer.redact(String(describing: error)), privacy: .public)"
            )
            lastError = .serverFailed(error)
        }
    }

    /// **v1.18.1 (§3)** — act on the pending coach cadence suggestion.
    /// `accept` creates a `MeasurementReminder` (origin COACH) server-side; the
    /// new reminder then appears in the native list (Settings → Notifications →
    /// Manage reminders). `dismiss`/`stop` just clear the card (the server records
    /// the disposition). On success the card shows a brief confirmation, then the
    /// suggestion clears. A failed action leaves the card so the user can retry.
    public func actOnSuggestion(_ action: CoachServerService.SuggestionAction) async {
        guard let suggestion = pendingSuggestion, let serverService else { return }
        do {
            try await serverService.actOnSuggestion(cadenceId: suggestion.cadenceId, action: action)
            lastSuggestionAction = action
            pendingSuggestion = nil
        } catch {
            // Reviewed (M-7): the only `.public` value is the action enum case
            // (operator-grade per the rule); the error detail is `.private` +
            // sanitizer-redacted. Mirrors the respond()-arm error log above.
            // swiftlint:disable:next hllog_public_privacy_interpolation
            HLLog.api.error(
                "Coach suggestion \(action.rawValue, privacy: .public) failed: \(LogSanitizer.redact(String(describing: error)), privacy: .private)"
            )
            lastError = .modelResponseFailed(error)
        }
    }

    // `bridgeCadenceSuggestion(_:)` (the inline-frame → render-model bridge for
    // #30) lives in `CoachConversationStore+Helpers.swift`.

    // `serverLocaleCode()` + `lastEntityID()` live in
    // `CoachConversationStore+Helpers.swift` (moved with the feedback wiring to
    // keep this file under the 600-line SwiftLint ceiling).

    /// Clears the transcript + error state for a fresh conversation.
    /// Triggered by:
    /// 1. The AskCoach sheet's "Neue Unterhaltung" toolbar action.
    /// 2. The new (v0.5.7 G.5) Settings → Coach → "Verlauf löschen"
    ///    affordance, which surfaces a confirmation alert first.
    ///
    /// **G.5 persistence:** in addition to wiping the in-memory chat
    /// the reset now also drops every persisted row under the current
    /// partition. If the user signs out next, `clearOnLogout` runs
    /// again for the new partition — idempotent, cheap.
    public func reset() {
        // AUD-5 H2 — a "New conversation" must not let a prior turn complete into
        // the freshly-cleared transcript.
        cancelInFlightTurn()
        chat = []
        lastError = nil
        isResponding = false
        // v1.18.1 (§3) — a fresh conversation drops any pending cadence card.
        pendingSuggestion = nil
        lastSuggestionAction = nil
        // **#14** — drop the hoisted on-device session so "Neue
        // Unterhaltung" really starts fresh: a kept session would leak
        // the cleared transcript into the model context of the next turn.
        service.resetSession()
        // v0.7.1 W-COACH-FALLBACK — start a fresh server thread on the
        // next server-backed turn so "Neue Unterhaltung" doesn't append
        // to the prior conversation server-side.
        serverConversationID = nil
        // A360 H1/H2 — a fresh conversation drops the prior metric scope so a
        // later unscoped open isn't narrowed to a stale metric.
        launchScope = nil
        usingServerFallback = false
        usingBYO = false
        feedback.clear()
        // CO4/CO5 — drop the per-entity provenance + token stashes (the entity
        // ids they keyed are gone with the transcript).
        provenanceByEntity = [:]
        usageByEntity = [:]
        // Wipe the persisted transcript for the current partition.
        // `userIDProvider` returns the keychain user (or the
        // standalone sentinel) so the right partition is hit.
        let userID = userIDProvider()
        persistence?.clear(userID: userID)
    }

    /// Logout-time wipe: clears both in-memory chat and persisted
    /// rows for the supplied partition. Distinct from `reset()`
    /// because the caller (AppContainer) knows the partition it was
    /// signed in under — when this runs, the keychain user id may
    /// already have been removed, so we can't rely on
    /// `userIDProvider()` to resolve it. Pass an explicit partition.
    ///
    /// When `partition` is `nil`, falls back to a partition resolve
    /// via `userIDProvider()` — covers the standalone-mode logout
    /// (where the sentinel partition is stable across the flip) and
    /// any caller that doesn't track the prior user explicitly.
    public func clearOnLogout(partition: String? = nil) {
        // AUD-5 H2 — cancel any in-flight turn so a logout never lets a prior
        // user's turn persist into the next partition.
        cancelInFlightTurn()
        chat = []
        lastError = nil
        isResponding = false
        // **#14** — the next signed-in user must never inherit the prior
        // user's on-device model context.
        service.resetSession()
        serverConversationID = nil
        launchScope = nil
        usingServerFallback = false
        usingBYO = false
        feedback.clear()
        provenanceByEntity = [:]
        usageByEntity = [:]
        let userID = partition ?? userIDProvider()
        persistence?.clear(userID: userID)
    }

    // The persistence + transcript-append helpers (`persistMessage`,
    // `appendUser`, `appendAssistant`, `upsertStreamingAssistant`) live in
    // `CoachConversationStore+Helpers.swift`; the `renderPartial(_:)` /
    // `render(_:)` Markdown helpers live in `CoachConversationStore+Render.swift`
    // (both split out v0.13 W4 to keep this file under the 600-line ceiling).
}
