// swiftlint:disable force_unwrapping
import Foundation
@testable import HealthLog
import Testing

#if canImport(SpeziChat)
    import SpeziChat
#endif

/// v0.5.7 G.3 smoke coverage for `CoachConversationStore`.
///
/// G.3 ties `SpeziChat.Chat` + `LocalLLMService` together behind a
/// `@MainActor @Observable` store. Three contracts the AskCoachSheet
/// view depends on:
///
/// 1. The store instantiates without throwing on every supported
///    runtime — same fail-fast bar as `LocalLLMService` itself.
/// 2. `send(_:)` appends the user turn synchronously + records an
///    error on runtimes that cannot serve a response (covers the
///    iOS 18 / 25 simulator floor where FoundationModels is not
///    linkable, and the iOS 26.5 sim where the model catalog has no
///    assets). On both the user-append happens; the assistant turn
///    only lands on the eligible-device path.
/// 3. `reset()` clears both the transcript + the error slot so the
///    operator can start a fresh conversation without re-mounting
///    the sheet.
///
/// **Why not a live FoundationModels round-trip?** The
/// `LocalLLMServiceResponseTests` suite already covers that path
/// (`structured-output round-trip`). The store-level suite only needs
/// to assert the orchestration glue — the user-append, the
/// error-write, the reset. Re-running the live call here would
/// double the simulator-flakiness surface for no extra coverage.
///
/// **22-02 (D-14-04-A) — and yet, until this plan, it did.** Seven cases
/// constructed a bare `LocalLLMService()` and awaited a turn, so on a gate
/// simulator with an eligible model every one of them drove the REAL on-device
/// runtime: ~132 s under load, with an outcome the case could not predict. Each
/// was written as an either/or over two branches — an answer, or a documented
/// error — which is exactly why the runtime's THIRD outcome (neither) went
/// unnoticed for as long as it did. the release pipeline has no resume path,
/// so a coach turn that hangs is a build number.
///
/// Every turn-driving case now routes through the SERVER arm against a stubbed
/// `APIClientProtocol` that answers with SSE bytes: the shipped decision gate
/// (`prefersServerArm` + a granted consent gate) picks the arm, the reply is
/// whatever the case seeded, and no live model is touched. Milliseconds, and
/// the outcome is chosen rather than observed.
@MainActor
@Suite("CoachConversationStore — chat orchestration smoke")
struct CoachConversationStoreTests {
    @Test("store instantiates without throwing on every supported runtime")
    func storeInitDoesNotThrow() {
        let service = LocalLLMService()
        _ = CoachConversationStore(service: service)
    }

    @Test("initial state: empty transcript, not responding, no error")
    func initialStateIsEmpty() {
        let store = CoachConversationStore(service: LocalLLMService())
        #expect(store.chat.isEmpty)
        #expect(store.isResponding == false)
        #expect(store.lastError == nil)
    }

    @Test("send appends a user turn synchronously before awaiting the model")
    func sendAppendsUserTurn() async {
        let store = Self.makeServerArmStore(.answer("Kurz und ruhig."))
        let prompt = "Was bedeutet mein Blutdruck?"
        await store.send(prompt)

        // The user-append is the load-bearing contract: SwiftUI binds
        // to `store.chat` and paints the user message as soon as it
        // lands, regardless of whether the assistant response arrives.
        #expect(store.chat.count >= 1)
        #if canImport(SpeziChat)
            #expect(store.chat.first?.role == .user)
            #expect(store.chat.first?.content == prompt)
        #else
            #expect(store.chat.first?.contains(prompt) == true)
        #endif
    }

    @Test("send no-ops on empty / whitespace-only input")
    func sendIgnoresEmptyInput() async {
        let store = Self.makeServerArmStore(.answer("nie erreicht"))
        await store.send("")
        await store.send("   \n  ")
        #expect(store.chat.isEmpty)
        #expect(store.lastError == nil)
    }

    // MARK: - 22-02 (D-14-04-A) — three outcomes, three assertions

    /// Outcome 1 of 3: an answer. Deterministic because the reply is seeded,
    /// not because the device happened to be eligible.
    @Test("Outcome 1 — eine Antwort landet als zweiter Zug, ohne Fehler")
    func answerOutcomeAppendsAssistantTurn() async {
        let store = Self.makeServerArmStore(.answer("Dein Blutdruck ist stabil."))
        await store.send("Was bedeutet ein Blutdruck von 138/92?")

        #expect(store.chat.count == 2)
        #expect(store.lastError == nil)
        #if canImport(SpeziChat)
            #expect(store.chat.first?.role == .user)
            #expect(store.chat.last?.role == .assistant)
            #expect(store.chat.last?.content == "Dein Blutdruck ist stabil.")
        #endif
        #expect(store.isResponding == false, "isResponding must clear after send completes (defer)")
    }

    /// Outcome 2 of 3: a documented error. The user turn stays for a retry.
    @Test("Outcome 2 — ein benannter Fehler laesst den Nutzerzug stehen")
    func errorOutcomeRecordsDocumentedFailure() async {
        let store = Self.makeServerArmStore(.providerError("coach.provider.none"))
        await store.send("Was bedeutet ein Blutdruck von 138/92?")

        #expect(store.chat.count == 1, "no assistant turn on a failed generation")
        switch store.lastError {
        case .foundationModelsUnavailable, .modelResponseFailed, .byoFailed, .serverFailed:
            break
        case .none:
            Issue.record("lastError must be a documented LocalLLMError case when the assistant turn is missing")
        }
        #expect(store.isResponding == false)
    }

    /// Outcome 3 of 3 — the one that was UNREPRESENTABLE and therefore
    /// unnoticed: the runtime completes having produced neither an answer nor
    /// an error. On this arm it is already honest (`CoachServerError.emptyReply`
    /// since v0.7.1), and that is pinned here so it stays honest. The on-device
    /// arm's equivalent is `emptyGenerationOutcome(didRenderAnything:)` below —
    /// it has no seam in the gate, so its decision is driven directly and its
    /// wiring is pinned in source.
    @Test("Outcome 3 — eine leere Generierung ist ein Fehler, kein stilles Nichts")
    func emptyGenerationIsAnErrorNotSilence() async {
        let store = Self.makeServerArmStore(.emptyAnswer)
        await store.send("Was bedeutet ein Blutdruck von 138/92?")

        #expect(store.chat.count == 1, "an empty generation must not leave a blank assistant bubble")
        #expect(store.lastError != nil, "a turn that produced nothing must say so")
        #expect(store.isResponding == false)
    }

    /// The on-device arm's half of outcome 3, as a decision.
    @Test("Die geraeteseitige Entscheidung: nichts gerendert heisst Fehler")
    func onDeviceEmptyGenerationDecidesAnError() throws {
        try #require(
            CoachConversationStore.emptyGenerationOutcome(didRenderAnything: false) != nil,
            """
            EXPECTED_RED: an on-device turn whose stream rendered nothing ends with the user message \
            alone and lastError nil, which reads exactly like a deliberate non-answer
            """
        )
        #expect(
            CoachConversationStore.emptyGenerationOutcome(didRenderAnything: true) == nil,
            "a turn that rendered something is not an empty generation"
        )
    }

    /// The wiring, pinned where it lives — a decision nothing calls is a
    /// decision that has not been made.
    @Test("Der geraeteseitige Zug fragt die Entscheidung wirklich ab")
    func onDeviceTurnConsultsTheEmptyGenerationDecision() throws {
        let source = try Self.source("HealthLog/Services/AI/CoachConversationStore.swift")
        try #require(
            source.contains("emptyGenerationOutcome(didRenderAnything:"),
            """
            EXPECTED_RED: CoachConversationStore's on-device turn never consults the empty-generation \
            decision, so the third outcome stays silent in the arm it actually happens in
            """
        )
    }

    @Test("respondToLastUserTurn fires assistant generation without re-appending the user message")
    func respondToLastUserTurnDoesNotDoubleAppend() async {
        // SpeziChat's `MessageInputView` appends the user entity to
        // the bound array directly; the view-side delta observer then
        // calls `respondToLastUserTurn(prompt:)` to fire the model.
        // The contract is that this path never adds a second user
        // entry — only the assistant turn (or an error) follows.
        let store = Self.makeServerArmStore(.answer("Dein Schlaf sieht ruhig aus."))
        let prompt = "Wie geht's meinem Schlaf?"
        #if canImport(SpeziChat)
            store.chat.append(ChatEntity(role: .user, content: prompt))
        #else
            store.chat.append("user: " + prompt)
        #endif
        let countBefore = store.chat.count

        await store.respondToLastUserTurn(prompt: prompt)

        // 22-02 — deterministic: the seeded arm answers, so exactly one
        // assistant turn is added and no second user entry appears. The
        // either/or this case used to carry existed only because the outcome
        // depended on the device the gate happened to run on.
        #expect(store.lastError == nil)
        #expect(store.chat.count == countBefore + 1, "only the assistant turn should be added")
        #if canImport(SpeziChat)
            #expect(store.chat.last?.role == .assistant)
        #endif
    }

    @Test("reset clears the transcript + error state")
    func resetClearsState() async {
        let store = Self.makeServerArmStore(.answer("Kurz."))
        await store.send("Was bedeutet mein Blutdruck?")
        // Whether the assistant turn lands or not, the user-append put
        // at least one entry in the transcript.
        #expect(store.chat.isEmpty == false)

        store.reset()
        #expect(store.chat.isEmpty)
        #expect(store.lastError == nil)
        #expect(store.isResponding == false)
    }

    // MARK: - v0.5.7 G.4 — privacy-first prompt composition

    @Test("composePrompt enriches user text with the snapshot provider's bullets")
    func composePromptUsesSnapshotProvider() {
        let store = CoachConversationStore(
            service: LocalLLMService(),
            snapshotProvider: {
                HealthSnapshot(
                    latestBP: .init(sys: 122, dia: 76, date: Date()),
                    recentMoodAvg: 4
                )
            }
        )
        let composed = store.composePrompt(userText: "Was sagst du dazu?")
        // The raw user text is preserved verbatim …
        #expect(composed.contains("Was sagst du dazu?"))
        // … and the snapshot bullets enrich the body.
        #expect(composed.contains("• Blutdruck: 122/76 mmHg"))
        #expect(composed.contains("• Stimmung Ø: 4/5"))
        // The German preamble + disclaimer round-trip.
        #expect(composed.contains("Du bist HealthLog Coach"))
        #expect(composed.contains("Du gibst KEINE Diagnose"))
    }

    @Test("composePrompt without a provider falls back to empty snapshot — no bullets")
    func composePromptWithoutProviderFallsBackToEmpty() {
        let store = CoachConversationStore(service: LocalLLMService())
        let composed = store.composePrompt(userText: "Hallo")
        // No context block when the snapshot is empty …
        #expect(composed.contains("Kontext über letzte Vitalwerte") == false)
        #expect(composed.contains("•") == false)
        // … but the preamble + user question + disclaimer still render.
        #expect(composed.contains("HealthLog Coach"))
        #expect(composed.contains("Hallo"))
        #expect(composed.contains("KEINE Diagnose"))
    }

    // MARK: - v0.6.1 F6 — double-response guard

    @Test("programmaticSendInFlight starts false and stays false outside send")
    func programmaticSendInFlightDefault() {
        let store = CoachConversationStore(service: LocalLLMService())
        #expect(store.programmaticSendInFlight == false)
    }

    @Test("send clears programmaticSendInFlight after completion (success or unavailable)")
    func programmaticSendInFlightClearsAfterSend() async {
        // The contract under test: regardless of whether the runtime
        // is eligible for FoundationModels, the flag flips back to
        // `false` once `send(_:)` returns — the `defer` in `send(_:)`
        // owns the reset. Without this, a chip-tap on an unavailable
        // runtime would leave the flag stuck and silently swallow the
        // next view-initiated text-input send.
        let store = Self.makeServerArmStore(.answer("Kurz."))
        await store.send("Was bedeutet mein Blutdruck?")
        #expect(store.programmaticSendInFlight == false)
    }

    @Test("send does not double-append when the chat-delta observer would dispatch respondToLastUserTurn")
    func sendDoesNotDoubleAppendUnderObserverDispatch() async {
        // Simulates the v0.6.1 F6 bug shape: the suggestion-chip path
        // calls `send(_:)`, which appends a user turn. The AskCoachSheet
        // `onChange(of: store.chat)` observer fires on that same user-
        // append and — pre-fix — dispatched `respondToLastUserTurn`,
        // yielding a second assistant turn. The fix exposes
        // `programmaticSendInFlight` so the observer can skip its
        // dispatch. We mimic the observer's guard here and assert the
        // dispatch would be skipped during the in-flight window.
        //
        // We can't directly observe `programmaticSendInFlight == true`
        // mid-flight from the test (the `defer` clears it on the same
        // MainActor turn the `await store.send(...)` resumes). Instead
        // we pin the orchestration contract that matters end-to-end:
        // exactly one user-append per send + the in-flight flag is
        // reset post-await + the chat count never grows by more than 2
        // entries (user + at most one assistant).
        let store = Self.makeServerArmStore(.answer("Kurz."))
        let countBefore = store.chat.count
        await store.send("Was bedeutet mein Blutdruck?")
        let countAfter = store.chat.count
        // At most 2 new entries: one user (always) + one assistant
        // (only on eligible runtimes). Pre-fix this would have been 3
        // (user + assistant + assistant from the observer re-dispatch).
        #expect(countAfter - countBefore <= 2)
        #if canImport(SpeziChat)
            // Exactly one user entry was added — pre-fix `send(_:)`
            // appended one and the observer pathway would not have
            // added another (it only fires assistant turns), so this
            // bound stays accurate even before the fix. The
            // load-bearing pin is the `<= 2` total above.
            let newUserEntries = store.chat.dropFirst(countBefore).filter { $0.role == .user }
            #expect(newUserEntries.count == 1)
            let newAssistantEntries = store.chat.dropFirst(countBefore).filter { $0.role == .assistant }
            // At most one assistant entry — this is the F6 pin. Pre-fix
            // this would have been 2 because the observer re-dispatched.
            #expect(newAssistantEntries.count <= 1)
        #endif
        #expect(store.programmaticSendInFlight == false)
    }

    /// **22-02** — this case used to assert `counter.count <= 2`, which is true
    /// at zero and therefore said nothing on the runtimes where the early
    /// return fired. Driven through the server arm it can assert the honest,
    /// privacy-relevant fact instead: a SERVER turn composes NO client-side
    /// health snapshot at all (the server already holds the user's data), so
    /// the provider is never consulted on this arm. The on-device arm's
    /// per-send composition is pinned by `composePromptUsesSnapshotProvider`
    /// against the pure builder, where it is deterministic.
    @Test("Der Server-Zug liest keinen lokalen Gesundheits-Snapshot")
    func serverTurnComposesNoLocalSnapshot() async {
        let counter = ProviderCallCounter()
        let store = Self.makeServerArmStore(
            .answer("Kurz."),
            snapshotProvider: {
                counter.increment()
                return .empty
            }
        )
        await store.send("Test 1")
        await store.send("Test 2")
        #expect(counter.invocations.isEmpty, "a server turn must not compose a local snapshot")
        #expect(store.chat.count == 4, "both turns landed")
    }

    // MARK: - The seam (22-02 / D-14-04-A)

    /// What the seeded arm answers with. Three shapes, because a coach turn has
    /// three outcomes — see the outcome cases above.
    enum SeededReply: Sendable {
        case answer(String)
        case emptyAnswer
        case providerError(String)

        var sseBody: Data {
            switch self {
            case let .answer(text):
                Data("""
                data: {"type":"token","token":"\(text)"}

                data: {"type":"done","conversationId":"conv-22-02","messageId":"msg-22-02"}

                """.utf8)
            case .emptyAnswer:
                // A well-formed turn that produced no tokens at all — the
                // runtime's third outcome, expressed on the wire.
                Data("""
                data: {"type":"done","conversationId":"conv-22-02","messageId":"msg-22-02"}

                """.utf8)
            case let .providerError(code):
                Data("""
                data: {"type":"error","code":"\(code)","message":"\(code)"}

                """.utf8)
            }
        }
    }

    /// A store whose sends route through the SERVER arm against seeded bytes.
    /// Uses only shipped seams: the explicit-arm pick (`prefersServerArm`, the
    /// user's "External AI" choice) plus a granted consent gate. No live model,
    /// no process-global handler, no sleep.
    static func makeServerArmStore(
        _ reply: SeededReply,
        snapshotProvider: (@MainActor () -> HealthSnapshot)? = nil
    ) -> CoachConversationStore {
        let store = CoachConversationStore(
            service: LocalLLMService(),
            snapshotProvider: snapshotProvider,
            serverService: CoachServerService(api: CoachSeededSSEClient(body: reply.sseBody)),
            serverConsentGate: { true }
        )
        store.prefersServerArm = { true }
        return store
    }

    static func source(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}

/// The seeded coach transport. `CoachServerService` consumes the response as a
/// line stream; `APIClientProtocol`'s default `streamLines` buffers through
/// `download`, so answering there is enough and no byte-stream has to be
/// synthesised. Per-instance state — nothing process-global to be taken from
/// another suite mid-case.
private struct CoachSeededSSEClient: APIClientProtocol {
    let body: Data

    func send<T: Decodable & Sendable>(_: APIRequest<T>) async throws -> T {
        throw HLError.unknown("the coach seam only answers the chat route")
    }

    func sendVoid(_: APIRequest<EmptyPayload>) async throws {}

    func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
        let response = HTTPURLResponse(
            url: URL(string: "https://coach.seam.invalid/api/insights/chat")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (body, response)
    }
}

/// Tiny `@MainActor` helper because the provider closure runs on the
/// store's `@MainActor` context — we need a main-actor-isolated counter
/// to mutate it without a Sendable-warning.
@MainActor
final class ProviderCallCounter {
    private(set) var count: Int = 0
    /// 22-02 — the invocation ledger, so a case can assert "never consulted"
    /// without comparing a count to zero (SwiftLint `empty_count` is an ERROR
    /// in this repo, and the release lint gate is fail-closed on errors).
    private(set) var invocations: [Int] = []

    func increment() {
        count += 1
        invocations.append(count)
    }
}
