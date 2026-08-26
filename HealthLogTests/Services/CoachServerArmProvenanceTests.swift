// swiftlint:disable force_unwrapping
import Foundation
@testable import HealthLog
import Testing

#if canImport(SpeziChat)
    import SpeziChat
#endif

/// **b199 walkthrough — Coach C1 (provenance pill) + C3 (typed server error).**
///
/// Split from `CoachServerFallbackTests` to keep that suite under the
/// `type_body_length` ceiling. Covers two new store seams:
///   - C1: ``CoachConversationStore/seedIntendedArm()`` resolves the egress arm
///     BEFORE the first turn so the provenance pill is honest from first paint.
///   - C3: ``CoachConversationStore`` preserves the typed server failure as
///     ``LocalLLMError/serverFailed(_:)`` instead of the flat
///     `.modelResponseFailed`, so the banner can render an actionable message.
@Suite("Coach server arm — provenance seeding + typed error")
struct CoachServerArmProvenanceTests {
    // MARK: - C1: intended-arm seeding (provenance pill before first turn)

    @MainActor
    @Test("seedIntendedArm flips usingServerFallback before the first turn (server arm)")
    func seedIntendedArmServer() {
        // L-1 (v0153) — force the not-ready (no on-device AI) arm deterministically
        // via the `forcedAvailability` test seam, so the assertions run on EVERY
        // host. The earlier `guard !service.isReady else { return }` silently
        // no-op'd the whole test on an AI-capable machine (the server arm only
        // wins when on-device can't serve), so it asserted nothing there.
        let service = LocalLLMService(forcedAvailability: .unsupported)

        let api = StubProvenanceAPIClient()
        let server = CoachServerService(api: api)
        let store = CoachConversationStore(
            service: service,
            serverService: server,
            serverConsentGate: { true }
        )
        // Before any send the pill would have defaulted to on-device; seeding
        // resolves the real (server) arm so the egress pill shows from first paint.
        #expect(store.usingServerFallback == false)
        store.seedIntendedArm()
        #expect(store.usingServerFallback == true)
        #expect(store.usingBYO == false)
    }

    @MainActor
    @Test("seedIntendedArm leaves both flags false for the private on-device arm")
    func seedIntendedArmOnDevice() {
        // L-1 — deterministic not-ready host (see `seedIntendedArmServer`).
        let service = LocalLLMService(forcedAvailability: .unsupported)

        // No server / BYO wired → private on-device arm; no egress flags.
        let store = CoachConversationStore(service: service)
        store.seedIntendedArm()
        #expect(store.usingServerFallback == false)
        #expect(store.usingBYO == false)
    }

    // MARK: - C3: typed server-arm error preserved as .serverFailed

    @MainActor
    @Test("server send maps a provider error frame to .serverFailed (not the flat .modelResponseFailed)")
    func serverSendPreservesTypedProviderError() async {
        // L-1 — deterministic not-ready host so the server arm is exercised
        // regardless of the test machine's on-device AI capability.
        let service = LocalLLMService(forcedAvailability: .unsupported)

        let api = StubProvenanceAPIClient()
        // An `error` frame → CoachServerError.provider — must surface typed.
        let sse = """
        data: {"type":"error","code":"coach.provider.none","message":"coach.provider.none"}

        """
        await api.setDownloadResponse(Data(sse.utf8))

        let server = CoachServerService(api: api)
        let store = CoachConversationStore(
            service: service,
            serverService: server,
            serverConsentGate: { true }
        )
        await store.send("Wie ist mein Blutdruck?")

        guard case let .serverFailed(error) = store.lastError else {
            Issue.record("expected .serverFailed, got \(String(describing: store.lastError))")
            return
        }
        #expect((error as? CoachServerError) == .provider("coach.provider.none"))
    }

    @MainActor
    @Test("server send maps an empty reply to .serverFailed wrapping CoachServerError.emptyReply")
    func serverSendPreservesEmptyReplyError() async {
        // L-1 — deterministic not-ready host (see `serverSendPreservesTypedProviderError`).
        let service = LocalLLMService(forcedAvailability: .unsupported)

        let api = StubProvenanceAPIClient()
        // A done frame with no token frames → emptyReply.
        let sse = """
        data: {"type":"done","conversationId":"c-1","messageId":"m-1"}

        """
        await api.setDownloadResponse(Data(sse.utf8))

        let server = CoachServerService(api: api)
        let store = CoachConversationStore(
            service: service,
            serverService: server,
            serverConsentGate: { true }
        )
        await store.send("Hallo")

        guard case let .serverFailed(error) = store.lastError else {
            Issue.record("expected .serverFailed, got \(String(describing: store.lastError))")
            return
        }
        #expect((error as? CoachServerError) == .emptyReply)
    }
}

// MARK: - Test stub

/// Minimal `APIClientProtocol` stub for the provenance / typed-error tests.
private actor StubProvenanceAPIClient: APIClientProtocol {
    private var downloadResponse: Data = .init()

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
        let response = HTTPURLResponse(
            url: URL(string: "https://example.test\(request.path)")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        return (downloadResponse, response)
    }
}
