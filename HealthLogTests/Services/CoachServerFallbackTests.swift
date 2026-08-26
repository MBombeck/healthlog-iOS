// swiftlint:disable force_unwrapping force_try
import Foundation
@testable import HealthLog
import Testing

#if canImport(SpeziChat)
    import SpeziChat
#endif

/// **v0.7.1 W-COACH-FALLBACK** — coverage for the server-Coach fallback
/// path that replaces the kill-card on non-Apple-Intelligence iPhones.
///
/// Two seams under test:
///   1. ``CoachServerService/parseSSE(_:)`` — the SSE-frame decoder that
///      turns the buffered `POST /api/insights/chat` body into a reply.
///   2. ``CoachConversationStore`` availability → fallback decision —
///      whether a send routes to the server, asks for consent, or falls
///      back to the on-device kill-card.
@Suite("Coach server fallback — SSE parse + decision gate")
struct CoachServerFallbackTests {
    // MARK: - SSE parsing

    @Test("parseSSE accumulates token frames and captures conversationId")
    func parseHappyPath() throws {
        let body = """
        data: {"type":"token","token":"Dein "}

        data: {"type":"token","token":"Blutdruck "}

        data: {"type":"token","token":"ist stabil."}

        data: {"type":"provenance","metricSource":{"windows":["last30days"],"metrics":["bp"]}}

        data: {"type":"done","conversationId":"conv-123","messageId":"msg-9"}

        """
        let reply = try CoachServerService.parseSSE(Data(body.utf8))
        #expect(reply.text == "Dein Blutdruck ist stabil.")
        #expect(reply.conversationId == "conv-123")
        // Server-parity: the done frame's messageId feeds the feedback route.
        #expect(reply.messageId == "msg-9")
    }

    @Test("parseSSE tolerates a done frame without messageId (older servers)")
    func parseDoneWithoutMessageID() throws {
        let body = """
        data: {"type":"token","token":"ok"}

        data: {"type":"done","conversationId":"c-1"}

        """
        let reply = try CoachServerService.parseSSE(Data(body.utf8))
        #expect(reply.text == "ok")
        #expect(reply.messageId == nil)
    }

    @Test("parseSSE surfaces an error frame as CoachServerError.provider")
    func parseErrorFrame() throws {
        let body = """
        data: {"type":"error","code":"coach.provider.none","message":"coach.provider.none"}

        """
        #expect(throws: CoachServerError.provider("coach.provider.none")) {
            try CoachServerService.parseSSE(Data(body.utf8))
        }
    }

    @Test("parseSSE throws emptyReply when no token frames arrive")
    func parseEmptyReply() throws {
        let body = """
        data: {"type":"done","conversationId":"conv-7","messageId":"m"}

        """
        #expect(throws: CoachServerError.emptyReply) {
            try CoachServerService.parseSSE(Data(body.utf8))
        }
    }

    @Test("parseSSE throws decode for a body with no frames")
    func parseNoFrames() throws {
        #expect(throws: CoachServerError.decode("no SSE frames in body")) {
            try CoachServerService.parseSSE(Data("garbage without data prefix".utf8))
        }
    }

    // MARK: - BH-final-diff H5 — multi-`data:`-line frame reassembly

    @Test("parseSSE reassembles a frame split across multiple data: lines")
    func parseMultiLineDataFrame() throws {
        // A single SSE event whose JSON payload is split across two `data:`
        // lines (legitimate per spec; emitted by some gateways/proxies). The
        // two lines must be re-joined with `\n` before decoding — the previous
        // per-line decoder dropped both halves and lost the token.
        let body = "data: {\"type\":\"token\",\n"
            + "data: \"token\":\"joined\"}\n"
            + "\n"
            + "data: {\"type\":\"done\",\"conversationId\":\"c-ml\",\"messageId\":\"m-ml\"}\n"
            + "\n"
        let reply = try CoachServerService.parseSSE(Data(body.utf8))
        #expect(reply.text == "joined")
        #expect(reply.conversationId == "c-ml")
        #expect(reply.messageId == "m-ml")
    }

    @Test("parseSSE flushes a final event without a trailing blank line")
    func parseFinalEventWithoutTrailingBlankLine() throws {
        // No terminating blank line after the done frame — the reassembler must
        // flush the buffered event at end-of-stream.
        let body = "data: {\"type\":\"token\",\"token\":\"hi\"}\n"
            + "\n"
            + "data: {\"type\":\"done\",\"conversationId\":\"c-f\",\"messageId\":\"m-f\"}"
        let reply = try CoachServerService.parseSSE(Data(body.utf8))
        #expect(reply.text == "hi")
        #expect(reply.conversationId == "c-f")
    }

    @Test("parseSSE tolerates CRLF line endings")
    func parseCRLFLineEndings() throws {
        let body = "data: {\"type\":\"token\",\"token\":\"crlf\"}\r\n"
            + "\r\n"
            + "data: {\"type\":\"done\",\"conversationId\":\"c-r\",\"messageId\":\"m-r\"}\r\n"
            + "\r\n"
        let reply = try CoachServerService.parseSSE(Data(body.utf8))
        #expect(reply.text == "crlf")
        #expect(reply.conversationId == "c-r")
    }

    @Test("parseSSE ignores unknown frame types (additive evolution)")
    func parseUnknownFrame() throws {
        let body = """
        data: {"type":"future_frame","payload":"ignored"}

        data: {"type":"token","token":"ok"}

        data: {"type":"done","conversationId":"c","messageId":"m"}

        """
        let reply = try CoachServerService.parseSSE(Data(body.utf8))
        #expect(reply.text == "ok")
        #expect(reply.conversationId == "c")
    }

    // MARK: - v1.18.1 (§3) cadence suggestion frame

    @Test("parseSSE captures a suggestion frame alongside the reply")
    func parseSuggestionFrame() throws {
        let body = """
        data: {"type":"token","token":"Let’s track this."}

        data: {"type":"suggestion","suggestion":{"cadenceId":"bp_7_2_2","measurementType":"BLOOD_PRESSURE_SYS","label":"coach.reminderSuggestion.cadence.bp722"}}

        data: {"type":"done","conversationId":"c-1","messageId":"m-1"}

        """
        let reply = try CoachServerService.parseSSE(Data(body.utf8))
        #expect(reply.text == "Let’s track this.")
        #expect(reply.suggestion?.cadenceId == "bp_7_2_2")
        #expect(reply.suggestion?.measurementType == "BLOOD_PRESSURE_SYS")
        #expect(reply.suggestion?.label == "coach.reminderSuggestion.cadence.bp722")
    }

    @Test("parseSSE leaves suggestion nil on a normal turn")
    func parseNoSuggestion() throws {
        let body = """
        data: {"type":"token","token":"ok"}

        data: {"type":"done","conversationId":"c","messageId":"m"}

        """
        let reply = try CoachServerService.parseSSE(Data(body.utf8))
        #expect(reply.suggestion == nil)
    }

    @Test("parseSSE tolerates a malformed suggestion frame — reply still lands, suggestion nil")
    func parseMalformedSuggestionTolerated() throws {
        // The `suggestion` object is missing required fields → the optional
        // payload decodes to nil; the turn must still succeed.
        let body = """
        data: {"type":"token","token":"ok"}

        data: {"type":"suggestion","suggestion":{"cadenceId":"only-id"}}

        data: {"type":"done","conversationId":"c","messageId":"m"}

        """
        let reply = try CoachServerService.parseSSE(Data(body.utf8))
        #expect(reply.text == "ok")
        #expect(reply.suggestion == nil)
    }

    // MARK: - CO4 provenance + CO5 token-usage store stash (v0154)

    //
    // The pure `parseSSE` decode tests for the provenance + usage frames live in
    // `CoachProvenanceUsageTests.swift` (split out so this suite stays under the
    // 600-line ceiling). The two store-driven stash tests below stay here because
    // they reuse this file's `StubCoachAPIClient`.

    @MainActor
    @Test("CO4/CO5 — a server turn stashes provenance + usage keyed by the assistant entity")
    func serverTurnStashesProvenanceAndUsage() async {
        let service = LocalLLMService()
        guard !service.isReady else { return }

        let api = StubCoachAPIClient()
        let sse = """
        data: {"type":"token","token":"Dein Blutdruck ist stabil."}

        data: {"type":"provenance","metricSource":{"windows":["last7days"],"metrics":["bp"],"counts":{"bp":5}}}

        data: {"type":"done","conversationId":"c-1","messageId":"m-1","usage":{"totalTokens":777,"model":"gpt-4o-mini"}}

        """
        await api.setDownloadResponse(Data(sse.utf8))

        let server = CoachServerService(api: api)
        let store = CoachConversationStore(
            service: service,
            serverService: server,
            serverConsentGate: { true }
        )
        await store.send("Wie ist mein Blutdruck?")

        #expect(store.lastError == nil)
        #if canImport(SpeziChat)
            if let entityID = store.chat.last?.id {
                #expect(store.provenanceByEntity[entityID]?.metrics == ["bp"])
                #expect(store.provenanceByEntity[entityID]?.counts?["bp"] == 5)
                #expect(store.usageByEntity[entityID]?.totalTokens == 777)
                #expect(store.usageByEntity[entityID]?.model == "gpt-4o-mini")
            } else {
                Issue.record("expected a trailing assistant entity")
            }
        #endif
    }

    @MainActor
    @Test("CO4/CO5 — reset() clears the per-entity provenance + usage stashes")
    func resetClearsProvenanceAndUsage() async {
        let service = LocalLLMService()
        guard !service.isReady else { return }

        let api = StubCoachAPIClient()
        let sse = """
        data: {"type":"token","token":"ok"}

        data: {"type":"provenance","metricSource":{"windows":["last7days"],"metrics":["bp"]}}

        data: {"type":"done","conversationId":"c","messageId":"m","usage":{"totalTokens":10}}

        """
        await api.setDownloadResponse(Data(sse.utf8))
        let server = CoachServerService(api: api)
        let store = CoachConversationStore(
            service: service,
            serverService: server,
            serverConsentGate: { true }
        )
        await store.send("Wie ist mein Blutdruck?")
        #expect(store.provenanceByEntity.isEmpty == false)
        #expect(store.usageByEntity.isEmpty == false)

        store.reset()
        #expect(store.provenanceByEntity.isEmpty == true)
        #expect(store.usageByEntity.isEmpty == true)
    }

    // MARK: - AUD-5 H2 — turn cancellation on sheet teardown

    @MainActor
    @Test("cancelInFlightTurn() tears down a mid-stream server turn — no reply persisted")
    func cancelInFlightServerTurn() async {
        let service = LocalLLMService()
        guard !service.isReady else { return }

        // A download that suspends until the turn task is cancelled, modelling an
        // SSE stream the server hasn't finished. The store's held turn task wraps
        // this; cancelling it (sheet dismiss) makes the download throw
        // CancellationError, which the server arm catches + bails on without
        // persisting a dead-view reply.
        let api = BlockingCoachAPIClient()
        let server = CoachServerService(api: api)
        let store = CoachConversationStore(
            service: service,
            serverService: server,
            serverConsentGate: { true }
        )

        // Kick the turn off without awaiting it (the sheet's chip/submit Task).
        let sendTask = Task { await store.send("Wie ist mein Blutdruck?") }
        // Let the turn reach the suspended download.
        await api.waitUntilStarted()
        #expect(store.isResponding == true)

        // The user leaves the sheet mid-stream.
        store.cancelInFlightTurn()
        await sendTask.value

        #expect(store.isResponding == false)
        // Only the user turn is in the transcript — no assistant reply persisted.
        #if canImport(SpeziChat)
            #expect(store.chat.allSatisfy { $0.role == .user })
        #endif
        #expect(store.usageByEntity.isEmpty)
        // A cancellation is not a real failure — no retry banner.
        #expect(store.lastError == nil)
    }

    @MainActor
    @Test("reset() cancels an in-flight turn (New conversation mid-stream)")
    func resetCancelsInFlightTurn() async {
        let service = LocalLLMService()
        guard !service.isReady else { return }

        let api = BlockingCoachAPIClient()
        let server = CoachServerService(api: api)
        let store = CoachConversationStore(
            service: service,
            serverService: server,
            serverConsentGate: { true }
        )
        let sendTask = Task { await store.send("Wie ist mein Blutdruck?") }
        await api.waitUntilStarted()

        store.reset()
        await sendTask.value

        #expect(store.isResponding == false)
        #expect(store.chat.isEmpty) // reset wipes the transcript
        #expect(store.lastError == nil)
    }

    @Test("CoachSuggestionActionBody encodes exactly { cadenceId, action }")
    func suggestionActionBodyEncodes() throws {
        let data = try JSONEncoder().encode(
            CoachSuggestionActionBody(cadenceId: "bp_7_2_2", action: "accept")
        )
        let obj = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: String]
        )
        #expect(obj == ["cadenceId": "bp_7_2_2", "action": "accept"])
    }

    @MainActor
    @Test("actOnSuggestion is a no-op when nothing is pending")
    func actOnSuggestionNoOp() async {
        let store = CoachConversationStore(service: LocalLLMService())
        #expect(store.pendingSuggestion == nil)
        await store.actOnSuggestion(.accept) // must not crash / set state
        #expect(store.pendingSuggestion == nil)
        #expect(store.lastSuggestionAction == nil)
    }

    // MARK: - Store decision gate

    @MainActor
    @Test("on-device unavailable + server wired + consent → routes to server")
    func decisionRoutesToServer() {
        let service = LocalLLMService() // simulator → .unsupported / not ready
        // Only run the decision assertions when the local model is NOT
        // ready (the CI simulator floor). On an Apple-Intelligence host
        // this test is a no-op — the on-device path is authoritative.
        guard !service.isReady else { return }

        let api = StubCoachAPIClient()
        let server = CoachServerService(api: api)
        let store = CoachConversationStore(
            service: service,
            serverService: server,
            serverConsentGate: { true }
        )
        #expect(store.shouldUseServerFallback == true)
        #expect(store.serverFallbackNeedsConsent == false)
    }

    @MainActor
    @Test("on-device unavailable + server wired + NO consent → needs consent")
    func decisionNeedsConsent() {
        let service = LocalLLMService()
        guard !service.isReady else { return }

        let api = StubCoachAPIClient()
        let server = CoachServerService(api: api)
        let store = CoachConversationStore(
            service: service,
            serverService: server,
            serverConsentGate: { false }
        )
        #expect(store.shouldUseServerFallback == false)
        #expect(store.serverFallbackNeedsConsent == true)
    }

    @MainActor
    @Test("no server service wired → neither fallback nor consent path")
    func decisionNoServer() {
        let service = LocalLLMService()
        guard !service.isReady else { return }

        let store = CoachConversationStore(service: service)
        #expect(store.shouldUseServerFallback == false)
        #expect(store.serverFallbackNeedsConsent == false)
    }

    // MARK: - Explicit "External AI" pick honoured (AI-1)

    @MainActor
    @Test("explicit .online pick on an AI-capable device routes to the server arm, not on-device")
    func explicitOnlinePickWinsOnCapableDevice() {
        // Force an AI-capable device so `service.isReady == true`. Without the
        // AI-1 fix the arm selection would prefer on-device here regardless of
        // the user's explicit pick.
        let service = LocalLLMService(forcedAvailability: .available)
        #expect(service.isReady == true)

        let api = StubCoachAPIClient()
        let server = CoachServerService(api: api)
        let store = CoachConversationStore(
            service: service,
            serverService: server,
            serverConsentGate: { true }
        )
        // User explicitly chose "External AI" (`.online`).
        store.prefersServerArm = { true }

        // The explicit pick must win even though on-device IS ready.
        #expect(store.shouldUseServerFallback == true)
        #expect(store.serverFallbackNeedsConsent == false)
    }

    @MainActor
    @Test("explicit .online pick on a capable device but no consent → needs consent (not silent on-device)")
    func explicitOnlinePickWithoutConsentNeedsConsent() {
        let service = LocalLLMService(forcedAvailability: .available)
        #expect(service.isReady == true)

        let api = StubCoachAPIClient()
        let server = CoachServerService(api: api)
        let store = CoachConversationStore(
            service: service,
            serverService: server,
            serverConsentGate: { false } // fail-closed: no consent
        )
        store.prefersServerArm = { true }

        // Fail-closed consent: never transmit without the gate, but the
        // explicit pick still surfaces the consent CTA rather than silently
        // re-routing to on-device.
        #expect(store.shouldUseServerFallback == false)
        #expect(store.serverFallbackNeedsConsent == true)
    }

    @MainActor
    @Test("no explicit pick on an AI-capable device keeps on-device authoritative")
    func noExplicitPickOnCapableDeviceStaysOnDevice() {
        let service = LocalLLMService(forcedAvailability: .available)
        #expect(service.isReady == true)

        let api = StubCoachAPIClient()
        let server = CoachServerService(api: api)
        let store = CoachConversationStore(
            service: service,
            serverService: server,
            serverConsentGate: { true }
        )
        // No `prefersServerArm` resolver → not an explicit pick.
        #expect(store.shouldUseServerFallback == false)
        #expect(store.serverFallbackNeedsConsent == false)
    }

    @MainActor
    @Test("explicit .online pick on a capable device sends through the server endpoint")
    func explicitOnlinePickSendsToServer() async {
        let service = LocalLLMService(forcedAvailability: .available)
        #expect(service.isReady == true)

        let api = StubCoachAPIClient()
        let sse = """
        data: {"type":"token","token":"Server-Antwort trotz fähigem Gerät."}

        data: {"type":"done","conversationId":"c-2","messageId":"m-2"}

        """
        await api.setDownloadResponse(Data(sse.utf8))

        let server = CoachServerService(api: api)
        let store = CoachConversationStore(
            service: service,
            serverService: server,
            serverConsentGate: { true }
        )
        store.prefersServerArm = { true }

        await store.send("Wie ist mein Blutdruck?")

        #expect(store.usingServerFallback == true)
        #expect(store.lastError == nil)
        // The request hit the server coach endpoint — the explicit pick was
        // honoured rather than served on-device.
        #expect(await api.downloadedPaths == ["/api/insights/chat"])
    }

    @MainActor
    @Test("server send appends the assistant reply and flips usingServerFallback")
    func serverSendAppendsReply() async {
        let service = LocalLLMService()
        guard !service.isReady else { return }

        let api = StubCoachAPIClient()
        // The store routes through CoachServerService → APIClient.download.
        // Stub the download to return a single SSE token + done frame.
        let sse = """
        data: {"type":"token","token":"Antwort vom Server."}

        data: {"type":"done","conversationId":"c-1","messageId":"m-1"}

        """
        await api.setDownloadResponse(Data(sse.utf8))

        let server = CoachServerService(api: api)
        let store = CoachConversationStore(
            service: service,
            serverService: server,
            serverConsentGate: { true }
        )
        await store.send("Wie ist mein Blutdruck?")

        #expect(store.usingServerFallback == true)
        #expect(store.lastError == nil)
        // Two visible turns: the user ask + the server reply.
        #expect(store.chat.count == 2)
        #if canImport(SpeziChat)
            #expect(store.chat.first?.role == .user)
            #expect(store.chat.first?.content == "Wie ist mein Blutdruck?")
            #expect(store.chat.last?.role == .assistant)
            #expect(store.chat.last?.content == "Antwort vom Server.")
        #else
            #expect(store.chat.first?.contains("Wie ist mein Blutdruck?") == true)
            #expect(store.chat.last?.contains("Antwort vom Server.") == true)
        #endif
        // The POST hit the coach endpoint exactly once.
        #expect(await api.downloadedPaths == ["/api/insights/chat"])
    }

    @MainActor
    @Test("#30 — a server turn with a suggestion frame routes the bridged suggestion into onSuggestion")
    func serverSuggestionRoutesToOnSuggestion() async {
        let service = LocalLLMService()
        guard !service.isReady else { return }

        let api = StubCoachAPIClient()
        let sse = """
        data: {"type":"token","token":"Dein Blutdruck schwankt diese Woche."}

        data: {"type":"suggestion","suggestion":{"cadenceId":"bp_7_2_2","measurementType":"BLOOD_PRESSURE_SYS","label":"coach.reminderSuggestion.cadence.bp722"}}

        data: {"type":"done","conversationId":"c-9","messageId":"m-9"}

        """
        await api.setDownloadResponse(Data(sse.utf8))

        let server = CoachServerService(api: api)
        let store = CoachConversationStore(
            service: service,
            serverService: server,
            serverConsentGate: { true }
        )
        // Capture the bridged suggestion handed to the proactive card surface.
        let captured = CapturedSuggestion()
        store.onSuggestion = { captured.set($0) }

        await store.send("Wie ist mein Blutdruck?")

        // The in-chat card still surfaces it…
        #expect(store.pendingSuggestion?.cadenceId == "bp_7_2_2")
        // …AND it was routed to the proactive Insights card surface (bridged to
        // the render-model: keyed on cadenceId, measurementType widened, no
        // rationale on the wire).
        let bridged = captured.value
        #expect(bridged?.cadenceId == "bp_7_2_2")
        #expect(bridged?.id == "bp_7_2_2")
        #expect(bridged?.measurementType == "BLOOD_PRESSURE_SYS")
        #expect(bridged?.label == "coach.reminderSuggestion.cadence.bp722")
    }

    @MainActor
    @Test("#30 — a server turn with NO suggestion frame does not fire onSuggestion")
    func serverNoSuggestionDoesNotRoute() async {
        let service = LocalLLMService()
        guard !service.isReady else { return }

        let api = StubCoachAPIClient()
        let sse = """
        data: {"type":"token","token":"Alles im grünen Bereich."}

        data: {"type":"done","conversationId":"c-10","messageId":"m-10"}

        """
        await api.setDownloadResponse(Data(sse.utf8))

        let server = CoachServerService(api: api)
        let store = CoachConversationStore(
            service: service,
            serverService: server,
            serverConsentGate: { true }
        )
        let captured = CapturedSuggestion()
        store.onSuggestion = { captured.set($0) }

        await store.send("Wie ist mein Blutdruck?")

        #expect(store.pendingSuggestion == nil)
        #expect(captured.value == nil, "no suggestion frame ⇒ no proactive-card hand-off")
    }
}

/// Captures the bridged ``CoachCadenceSuggestion`` the store hands to the
/// proactive card surface, so the routing test can assert on it after the turn.
@MainActor
private final class CapturedSuggestion {
    private(set) var value: CoachCadenceSuggestion?
    func set(_ s: CoachCadenceSuggestion) {
        value = s
    }
}

// MARK: - Test stub

/// Minimal `APIClientProtocol` stub for the coach-fallback path. Records
/// the downloaded request paths so the test can assert the coach
/// endpoint was hit, and replays a canned SSE body.
private actor StubCoachAPIClient: APIClientProtocol {
    private var downloadResponse: Data = .init()
    private(set) var downloadedPaths: [String] = []

    func setDownloadResponse(_ data: Data) {
        downloadResponse = data
    }

    func send<T: Decodable & Sendable>(_: APIRequest<T>) async throws -> T {
        throw HLError.unknown("send not stubbed")
    }

    func sendVoid(_: APIRequest<EmptyPayload>) async throws {
        throw HLError.unknown("sendVoid not stubbed")
    }

    func download(_ request: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
        downloadedPaths.append(request.path)
        let response = HTTPURLResponse(
            url: URL(string: "https://example.test\(request.path)")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        return (downloadResponse, response)
    }
}

/// AUD-5 H2 — a coach API stub whose `download` suspends until the calling task
/// is **cancelled**, modelling an in-flight SSE stream the server hasn't closed.
/// Signals when the download has started (so the test can cancel deterministically
/// instead of racing) and throws `CancellationError` on cancel, mirroring
/// `URLSession`'s cooperative-cancellation behaviour.
private actor BlockingCoachAPIClient: APIClientProtocol {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    private func markStarted() {
        started = true
        for waiter in startWaiters {
            waiter.resume()
        }
        startWaiters.removeAll()
    }

    /// Resolves once the (single) `download` call has begun suspending.
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func send<T: Decodable & Sendable>(_: APIRequest<T>) async throws -> T {
        throw HLError.unknown("send not stubbed")
    }

    func sendVoid(_: APIRequest<EmptyPayload>) async throws {
        throw HLError.unknown("sendVoid not stubbed")
    }

    func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
        markStarted()
        // Suspend in the CURRENT task until it is cancelled. `Task.sleep` is
        // cancellation-aware, so cancelling the store's held turn task throws
        // CancellationError here — mirroring URLSession's cooperative cancel.
        while true {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
