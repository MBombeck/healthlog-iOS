import Foundation
@testable import HealthLog
import Testing

/// Vault Phase 4 — document chat (server v1.27.33, iOS issue #43) STORE layer: the
/// streaming state machine (tokens grow the assistant bubble, `done` latches the
/// conversation id), history hydration, and the honest gate / limit surfaces
/// (notIndexed / consentRequired / limitReached → a calm `errorState`, never a
/// crash or a half bubble). Drives a real ``DocumentsRepository`` over a scripted
/// ``APIClientProtocol`` stub so the store↔repo↔SSE parse path is exercised end to
/// end.
@MainActor
@Suite("Document chat store")
struct DocumentChatStoreTests {
    private func makeStore(_ stub: StubChatAPIClient) -> DocumentChatStore {
        let lease = DocumentAIConsentLease(
            ownerUserID: "test-user",
            bearerToken: "test-token",
            scope: .serverManaged
        )
        let repository = DocumentsRepository(
            api: stub,
            externalAIConsent: DocumentAIConsentLeaseProvider { lease }
        )
        return DocumentChatStore(repository: repository, documentId: "d1")
    }

    @Test("send streams tokens into an assistant turn and latches the conversation id")
    func sendStreamsTokens() async {
        let stub = StubChatAPIClient(streamLines: [
            #"data: {"type":"token","token":"Dein "}"#,
            #"data: {"type":"token","token":"CRP ist 5,4."}"#,
            #"data: {"type":"done","conversationId":"c-1","messageId":"m-1"}"#
        ])
        let store = makeStore(stub)
        await store.send("Was ist mein CRP?")

        #expect(store.errorState == nil)
        #expect(store.isResponding == false)
        #expect(store.streamingText.isEmpty)
        #expect(store.messages.count == 2)
        #expect(store.messages.first?.role == .user)
        #expect(store.messages.last?.role == .assistant)
        #expect(store.messages.last?.text == "Dein CRP ist 5,4.")
        #expect(store.messages.last?.id == "m-1")
        #expect(store.conversationId == "c-1")
    }

    @Test("an SSE error frame surfaces a calm limitReached state, no assistant bubble")
    func errorFrameSurfacesLimit() async {
        let stub = StubChatAPIClient(streamLines: [
            #"data: {"type":"error","code":"documents.chat.budgetExceeded","message":"budget"}"#
        ])
        let store = makeStore(stub)
        await store.send("Hallo")

        #expect(store.errorState == .limitReached)
        #expect(store.isResponding == false)
        // The user turn stays visible; no assistant bubble was appended.
        #expect(store.messages.count == 1)
        #expect(store.messages.first?.role == .user)
        #expect(store.streamingText.isEmpty)
    }

    @Test("a 422 notIndexed gate makes chat unavailable (errorState .notIndexed)")
    func gateNotIndexed() async {
        let stub = StubChatAPIClient(
            streamError: HLError.server(status: 422, code: "documents.inbound.notIndexed", message: "")
        )
        let store = makeStore(stub)
        await store.send("Hallo")
        #expect(store.errorState == .notIndexed)
        #expect(store.isResponding == false)
    }

    @Test("a 403 consent gate surfaces the consent CTA state")
    func gateConsentRequired() async {
        let stub = StubChatAPIClient(
            streamError: HLError.server(status: 403, code: "consent.ai.required", message: "")
        )
        let store = makeStore(stub)
        await store.send("Hallo")
        #expect(store.errorState == .consentRequired)
    }

    @Test("loadHistory hydrates the newest thread's messages")
    func loadHistoryHydrates() async {
        let stub = StubChatAPIClient(
            listJSON: #"""
            {"conversations":[
              {"id":"c-1","title":"Frage","createdAt":"z","updatedAt":"z","messageCount":2}
            ],"nextCursor":null}
            """#,
            detailJSON: #"""
            {"id":"c-1","title":"Frage","createdAt":"z","updatedAt":"z","messageCount":2,"summary":null,
             "messages":[
               {"id":"m1","role":"user","content":"Was ist mein CRP?","createdAt":"z"},
               {"id":"m2","role":"assistant","content":"5,4 mg/l.","createdAt":"z"}
             ]}
            """#
        )
        let store = makeStore(stub)
        await store.loadHistory()
        #expect(store.conversationId == "c-1")
        #expect(store.messages.count == 2)
        #expect(store.messages.last?.text == "5,4 mg/l.")
        #expect(store.didLoadHistory)
    }

    @Test("send is a no-op on empty input")
    func sendIgnoresEmpty() async {
        let store = makeStore(StubChatAPIClient(streamLines: []))
        await store.send("   ")
        #expect(store.messages.isEmpty)
        #expect(store.isResponding == false)
    }
}

// MARK: - Scripted APIClientProtocol stub

/// Delivers a scripted SSE line sequence for `streamLines` (the chat POST) and a
/// canned history payload for `send` (the chat GET). Immutable after init so it is
/// safely `Sendable` across the repository actor hop.
private final class StubChatAPIClient: APIClientProtocol, @unchecked Sendable {
    private let streamScript: [String]
    private let streamError: Error?
    private let listJSON: String?
    private let detailJSON: String?

    init(
        streamLines: [String] = [],
        streamError: Error? = nil,
        listJSON: String? = nil,
        detailJSON: String? = nil
    ) {
        streamScript = streamLines
        self.streamError = streamError
        self.listJSON = listJSON
        self.detailJSON = detailJSON
    }

    func send<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> T {
        // Route the history GET by whether a conversationId query is present: the
        // list call carries none, the detail call carries the resolved id. The stub
        // decodes the inner `data` object directly (bypassing the envelope strip).
        let hasConversation = request.query.contains { $0.0 == "conversationId" }
        let json = hasConversation ? detailJSON : listJSON
        guard let json, let data = json.data(using: .utf8) else {
            throw HLError.unknown("send not stubbed")
        }
        return try JSONDecoder.hlDefault.decode(T.self, from: data)
    }

    func sendVoid(_: APIRequest<EmptyPayload>) async throws {
        throw HLError.unknown("sendVoid not stubbed")
    }

    func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
        throw HLError.unknown("download not stubbed")
    }

    func streamLines(_: APIRequest<Data>) async throws -> AsyncThrowingStream<String, Error> {
        if let streamError { throw streamError }
        let lines = streamScript
        return AsyncThrowingStream { continuation in
            for line in lines {
                continuation.yield(line)
            }
            continuation.finish()
        }
    }
}
