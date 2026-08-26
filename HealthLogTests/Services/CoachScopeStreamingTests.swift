// swiftlint:disable force_unwrapping force_try
import Foundation
@testable import HealthLog
import Testing

#if canImport(SpeziChat)
    import SpeziChat
#endif

/// **A360 (v0156)** — coverage for the three coach upgrades that consume the
/// server's v1.21.0 work:
///   1. `ChatRequestBody` encodes the `scope` ({ sources, window }) + `prefill`.
///   2. The server-arm path consumes the SSE stream PROGRESSIVELY — tokens are
///      surfaced via `onToken` as they arrive and appended incrementally, with the
///      final provenance / usage / suggestion frame handling intact.
///   3. The new error copy for a transport 429 + `coach.budget.exceeded`.
@Suite("Coach scope hand-off + progressive streaming + error copy (A360)")
struct CoachScopeStreamingTests {
    // MARK: - 1. ChatRequestBody encodes scope + prefill

    @Test("ChatRequestBody encodes scope { sources, window } + prefill")
    func chatRequestBodyEncodesScope() throws {
        let body = ChatRequestBody(
            conversationId: "c-1",
            message: "How is my BP?",
            locale: "en",
            scope: CoachScopeWire(sources: ["bp", "compliance"], window: "last30days"),
            prefill: "Walk me through my blood pressure."
        )
        let data = try JSONEncoder().encode(body)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(obj["conversationId"] as? String == "c-1")
        #expect(obj["message"] as? String == "How is my BP?")
        #expect(obj["locale"] as? String == "en")
        #expect(obj["prefill"] as? String == "Walk me through my blood pressure.")
        let scope = try #require(obj["scope"] as? [String: Any])
        #expect(scope["sources"] as? [String] == ["bp", "compliance"])
        #expect(scope["window"] as? String == "last30days")
    }

    @Test("ChatRequestBody omits scope + prefill when nil (back-compat)")
    func chatRequestBodyOmitsScopeWhenNil() throws {
        let body = ChatRequestBody(conversationId: nil, message: "Hi", locale: "de")
        let data = try JSONEncoder().encode(body)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["scope"] == nil)
        #expect(obj["prefill"] == nil)
        #expect(obj["conversationId"] == nil)
        #expect(obj["message"] as? String == "Hi")
    }

    @Test("CoachScopeWire omits empty sources but keeps window")
    func wireScopeOmitsEmptySources() throws {
        let wire = CoachScopeWire(sources: [], window: "last7days")
        let data = try JSONEncoder().encode(wire)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["sources"] == nil)
        #expect(obj["window"] as? String == "last7days")
    }

    @Test("CoachLaunchScope.wireScope de-dups [metric, ...also] preserving order")
    func launchScopeWireDedups() {
        let scope = CoachLaunchScope(metric: .bp, also: [.compliance, .bp, .weight], window: .last90days)
        let wire = scope.wireScope
        #expect(wire.sources == ["bp", "compliance", "weight"])
        #expect(wire.window == "last90days")
    }

    @Test("MetricKind maps to the expected coach scope source tokens")
    func metricKindScopeSourceMapping() {
        #expect(MetricKind.bloodPressure.coachScopeSource == .bp)
        #expect(MetricKind.weight.coachScopeSource == .weight)
        #expect(MetricKind.hrv.coachScopeSource == .hrv)
        #expect(MetricKind.sleep.coachScopeSource == .sleep)
        // A kind with no dedicated server scope source → nil (default snapshot).
        #expect(MetricKind.falls.coachScopeSource == nil)
    }

    // MARK: - 2. Progressive streaming — tokens append incrementally

    @Test("respond() streams tokens progressively via onToken, in order")
    func respondStreamsTokensProgressively() async throws {
        // A multi-frame SSE byte sequence delivered as discrete lines. The
        // progressive parser must surface each token the instant its frame lands.
        let api = ScriptedStreamAPIClient(lines: [
            #"data: {"type":"token","token":"Dein "}"#,
            #"data: {"type":"token","token":"Blutdruck "}"#,
            #"data: {"type":"token","token":"ist stabil."}"#,
            #"data: {"type":"provenance","metricSource":{"windows":["last30days"],"metrics":["bp"],"counts":{"bp":7}}}"#,
            #"data: {"type":"suggestion","suggestion":{"cadenceId":"bp_7_2_2","measurementType":"BLOOD_PRESSURE_SYS","label":"coach.reminderSuggestion.cadence.bp722"}}"#,
            #"data: {"type":"done","conversationId":"c-1","messageId":"m-1","usage":{"totalTokens":42,"model":"gpt-4o-mini"}}"#
        ])
        let service = CoachServerService(api: api)
        let collector = TokenCollector()

        let reply = try await service.respond(
            message: "Wie ist mein Blutdruck?",
            conversationId: nil,
            locale: "de",
            scope: CoachScopeWire(sources: ["bp"], window: nil),
            onToken: { token in await collector.append(token) }
        )

        // Tokens were surfaced one frame at a time, in order, as a growing prefix.
        let progressive = await collector.snapshots
        #expect(progressive == ["Dein ", "Blutdruck ", "ist stabil."])

        // The final reply carries the concatenated text + every non-token frame.
        #expect(reply.text == "Dein Blutdruck ist stabil.")
        #expect(reply.conversationId == "c-1")
        #expect(reply.messageId == "m-1")
        #expect(reply.provenance?.metrics == ["bp"])
        #expect(reply.provenance?.counts?["bp"] == 7)
        #expect(reply.suggestion?.cadenceId == "bp_7_2_2")
        #expect(reply.usage?.totalTokens == 42)
        #expect(reply.usage?.model == "gpt-4o-mini")
    }

    @Test("respond() surfaces an error frame as CoachServerError.provider even when streamed")
    func respondStreamingSurfacesErrorFrame() async {
        let api = ScriptedStreamAPIClient(lines: [
            #"data: {"type":"error","code":"coach.budget.exceeded","message":"coach.budget.exceeded"}"#
        ])
        let service = CoachServerService(api: api)
        await #expect(throws: CoachServerError.provider("coach.budget.exceeded")) {
            _ = try await service.respond(message: "Hi", conversationId: nil, locale: "en")
        }
    }

    @MainActor
    @Test("a streamed server turn grows the assistant bubble token-by-token")
    func storeServerTurnStreamsIntoTranscript() async {
        let service = LocalLLMService()
        guard !service.isReady else { return }

        let api = ScriptedStreamAPIClient(lines: [
            #"data: {"type":"token","token":"Alles "}"#,
            #"data: {"type":"token","token":"gut."}"#,
            #"data: {"type":"done","conversationId":"c-1","messageId":"m-1"}"#
        ])
        let server = CoachServerService(api: api)
        let store = CoachConversationStore(
            service: service,
            serverService: server,
            serverConsentGate: { true }
        )
        await store.send("Wie geht es mir?")

        #expect(store.lastError == nil)
        #if canImport(SpeziChat)
            // One user turn + one assistant turn, the assistant text fully settled.
            #expect(store.chat.count == 2)
            #expect(store.chat.last?.role == .assistant)
            #expect(store.chat.last?.content == "Alles gut.")
        #endif
    }

    @MainActor
    @Test("the launch scope is sent on the FIRST server turn only")
    func launchScopeSentOnFirstTurnOnly() async {
        let service = LocalLLMService()
        guard !service.isReady else { return }

        let api = ScriptedStreamAPIClient(lines: [
            #"data: {"type":"token","token":"ok"}"#,
            #"data: {"type":"done","conversationId":"c-1","messageId":"m-1"}"#
        ])
        let server = CoachServerService(api: api)
        let store = CoachConversationStore(
            service: service,
            serverService: server,
            serverConsentGate: { true }
        )
        store.setLaunchScope(CoachLaunchScope(metric: .bp, also: [.compliance]))

        // First turn → scope present.
        await store.send("first")
        let firstScope = await api.lastScope
        #expect(firstScope?.sources == ["bp", "compliance"])

        // Second turn (same thread, conversationId latched) → scope omitted.
        await store.send("second")
        let secondScope = await api.lastScope
        #expect(secondScope == nil)
    }

    // MARK: - 3. Error copy (A360 M2/M3)

    @MainActor
    @Test("transport 429 → honest 'busy' copy (not generic retry)")
    func rateLimitedCopy() {
        let sheet = AskCoachSheet()
        let copy = sheet.serverErrorCopy(HLError.rateLimited(retryAfter: 12))
        #expect(copy == String(localized: "The Coach is busy right now. Try again in a moment."))
        // Must NOT be the generic fallback.
        #expect(copy != String(localized: "Response failed. Please try again."))
    }

    @MainActor
    @Test("budget-exceeded provider frame → honest budget copy")
    func budgetExceededCopy() {
        let sheet = AskCoachSheet()
        let copy = sheet.serverErrorCopy(CoachServerError.provider("coach.budget.exceeded"))
        #expect(copy == String(localized: "You've used today's AI budget. It resets tomorrow."))
        #expect(copy != String(localized: "Response failed. Please try again."))
    }

    @MainActor
    @Test("credential-expired provider frame → reconnect copy")
    func credentialExpiredCopy() {
        let sheet = AskCoachSheet()
        let copy = sheet.serverErrorCopy(CoachServerError.provider("coach.provider.credential_expired"))
        #expect(copy == String(localized: "Your AI provider needs reconnecting. Check Settings → Assistant."))
    }
}

// MARK: - Test helpers

/// Collects the progressive token snapshots `onToken` surfaces so a test can
/// assert tokens arrived one frame at a time, in order.
private actor TokenCollector {
    private(set) var snapshots: [String] = []
    func append(_ token: String) {
        snapshots.append(token)
    }
}

/// An `APIClientProtocol` stub that overrides `streamLines` to deliver a scripted
/// sequence of SSE lines one at a time (modelling a live stream), and records the
/// `scope` the request carried so the first-turn-only contract can be verified.
private actor ScriptedStreamAPIClient: APIClientProtocol {
    private let lines: [String]
    private(set) var lastScope: CoachScopeWire?

    init(lines: [String]) {
        self.lines = lines
    }

    func send<T: Decodable & Sendable>(_: APIRequest<T>) async throws -> T {
        throw HLError.unknown("send not stubbed")
    }

    func sendVoid(_: APIRequest<EmptyPayload>) async throws {
        throw HLError.unknown("sendVoid not stubbed")
    }

    func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
        throw HLError.unknown("download not stubbed — use streamLines")
    }

    func streamLines(_ request: APIRequest<Data>) async throws -> AsyncThrowingStream<String, Error> {
        // Decode the scope the service encoded into the request body so the
        // first-turn-only contract can be asserted.
        if let body = request.body,
           let parsed = try? JSONDecoder().decode(RecordedBody.self, from: body)
        {
            lastScope = parsed.scope
        }
        let lines = lines
        return AsyncThrowingStream { continuation in
            for line in lines {
                continuation.yield(line)
                // Blank-line frame separators are tolerated by the parser; the
                // service splits on its own newlines, so yielding bare data lines
                // is sufficient to model discrete frames arriving over time.
            }
            continuation.finish()
        }
    }

    /// Mirror of `ChatRequestBody` for decoding the recorded request scope.
    private struct RecordedBody: Decodable {
        let scope: CoachScopeWire?
    }
}
