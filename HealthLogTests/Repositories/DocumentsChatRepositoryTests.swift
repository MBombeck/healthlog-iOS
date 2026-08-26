import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// Vault Phase 4 — document chat (server v1.27.33, iOS issue #43) DATA layer:
/// history (detail XOR list) tolerant decode, the notIndexed 422 + consent 403
/// gate discriminators, and the SSE `token` / `done` / `error` frame handling —
/// all over the REAL `APIClient` + stub `URLProtocol` (no mock server, per
/// PROJECT_GUIDE.md). The streaming POST rides the same `streamLines` transport the Coach
/// turn uses; the stub delivers a `text/event-stream` body the parser walks.
@Suite("Documents chat data layer", .serialized)
struct DocumentsChatRepositoryTests {
    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.17.0",
            buildNumber: "1"
        )
        let kc = InMemoryKeychain()
        try? kc.setString("token", forKey: KeychainKey.authToken)
        return APIClient(environment: env, keychain: kc, sessionConfiguration: .mock())
    }

    private func makeRepo() -> DocumentsRepository {
        let lease = DocumentAIConsentLease(
            ownerUserID: "test-user",
            bearerToken: "token",
            scope: .serverManaged
        )
        return DocumentsRepository(
            api: makeAPI(),
            externalAIConsent: DocumentAIConsentLeaseProvider { lease }
        )
    }

    private func ok(_ request: URLRequest, _ body: String, status: Int = 200) -> (HTTPURLResponse, Data?) {
        (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
    }

    // MARK: - History decode (thread detail XOR list)

    @Test("History detail decodes messages oldest-first; role/content tolerant")
    func historyDetailDecode() async throws {
        MockURLProtocol.handler = { req in
            #expect(req.url?.path == "/api/documents/inbound/d1/chat")
            #expect(req.url?.query?.contains("conversationId=c-1") == true)
            return ok(req, #"""
            {"data":{"id":"c-1","title":"Laborwerte","createdAt":"2026-03-04T09:00:00.000Z",
             "updatedAt":"2026-03-04T09:05:00.000Z","messageCount":2,"summary":null,
             "messages":[
               {"id":"m1","role":"user","content":"Was ist mein CRP?","createdAt":"2026-03-04T09:00:00.000Z",
                "providerType":null,"tokensUsed":null,"model":null},
               {"id":"m2","role":"assistant","content":"CRP steht mit 5,4 mg/l im Dokument.",
                "createdAt":"2026-03-04T09:00:05.000Z","providerType":"openai","tokensUsed":42,"model":"gpt-4o-mini"}
             ]},"error":null}
            """#)
        }
        let history = try await makeRepo().chatHistory(id: "d1", conversationId: "c-1")
        let detail = try #require(history.detail)
        #expect(detail.id == "c-1")
        #expect(detail.messages.count == 2)
        #expect(detail.messages.first?.role == .user)
        #expect(detail.messages.last?.role == .assistant)
        #expect(detail.messages.last?.content == "CRP steht mit 5,4 mg/l im Dokument.")
    }

    @Test("History list decodes the document's threads newest-first")
    func historyListDecode() async throws {
        MockURLProtocol.handler = { req in
            #expect(req.url?.query?.contains("conversationId") != true)
            return ok(req, #"""
            {"data":{"conversations":[
               {"id":"c-2","title":"Neueste Frage","createdAt":"2026-03-05T09:00:00.000Z",
                "updatedAt":"2026-03-05T09:00:00.000Z","messageCount":4},
               {"id":"c-1","title":"Ältere Frage","createdAt":"2026-03-04T09:00:00.000Z",
                "updatedAt":"2026-03-04T09:00:00.000Z","messageCount":2}
             ],"nextCursor":null},"error":null}
            """#)
        }
        let history = try await makeRepo().chatHistory(id: "d1")
        #expect(history.detail == nil)
        #expect(history.conversations.count == 2)
        #expect(history.conversations.first?.id == "c-2")
        #expect(history.conversations.first?.messageCount == 4)
    }

    @Test("An unknown role decodes to .assistant (forward-tolerant)")
    func roleTolerant() throws {
        let json = Data(#"{"id":"m9","role":"system","content":"x","createdAt":"z"}"#.utf8)
        let msg = try JSONDecoder.hlDefault.decode(DocumentChatMessageDTO.self, from: json)
        #expect(msg.role == .assistant)
    }

    // MARK: - Gate discriminators

    @Test("isNotIndexed / isConsentRequired discriminate the typed server errors")
    func gateDiscriminators() {
        let notIndexed = HLError.server(status: 422, code: "documents.inbound.notIndexed", message: "")
        let consent = HLError.server(status: 403, code: "consent.ai.required", message: "")
        let other = HLError.server(status: 422, code: "documents.inbound.providerUnsupported", message: "")
        #expect(DocumentsRepository.isNotIndexed(notIndexed))
        #expect(DocumentsRepository.isConsentRequired(consent))
        #expect(DocumentsRepository.isNotIndexed(other) == false)
        #expect(DocumentsRepository.isConsentRequired(notIndexed) == false)
    }

    @Test("A 422 notIndexed POST maps the stream to DocumentChatError.notIndexed")
    func streamNotIndexed() async {
        MockURLProtocol.handler = { req in
            ok(
                req,
                #"{"data":null,"error":"not indexed","meta":{"errorCode":"documents.inbound.notIndexed"}}"#,
                status: 422
            )
        }
        await #expect(throws: DocumentChatError.notIndexed) {
            for try await _ in makeRepo().chatStream(id: "d1", message: "Hallo") {}
        }
    }

    @Test("A 403 consent.ai.required POST maps the stream to DocumentChatError.consentRequired")
    func streamConsentRequired() async {
        MockURLProtocol.handler = { req in
            ok(
                req,
                #"{"data":null,"error":"consent","meta":{"errorCode":"consent.ai.required"}}"#,
                status: 403
            )
        }
        await #expect(throws: DocumentChatError.consentRequired) {
            for try await _ in makeRepo().chatStream(id: "d1", message: "Hallo") {}
        }
    }

    // MARK: - SSE frames

    @Test("A token/done SSE stream yields the tokens in order + the done frame")
    func streamTokensAndDone() async throws {
        MockURLProtocol.handler = { req in
            #expect(req.httpMethod == "POST")
            #expect(req.url?.path == "/api/documents/inbound/d1/chat")
            let sse = """
            data: {"type":"token","token":"Dein "}

            data: {"type":"token","token":"CRP ist 5,4."}

            data: {"type":"done","conversationId":"c-1","messageId":"m-1"}

            """
            return ok(req, sse)
        }
        var tokens: [String] = []
        var doneConversation: String?
        for try await frame in makeRepo().chatStream(id: "d1", message: "CRP?") {
            switch frame {
            case let .token(t): tokens.append(t)
            case let .done(conversationId, _): doneConversation = conversationId
            }
        }
        #expect(tokens == ["Dein ", "CRP ist 5,4."])
        #expect(doneConversation == "c-1")
    }

    @Test("A budget-exhaustion error frame throws DocumentChatError.limitReached")
    func streamBudgetErrorFrame() async {
        MockURLProtocol.handler = { req in
            let sse = """
            data: {"type":"error","code":"documents.chat.budgetExceeded","message":"budget"}

            """
            return ok(req, sse)
        }
        await #expect(throws: DocumentChatError.limitReached) {
            for try await _ in makeRepo().chatStream(id: "d1", message: "Hallo") {}
        }
    }

    @Test("A generic provider error frame throws DocumentChatError.provider(code)")
    func streamProviderErrorFrame() async {
        MockURLProtocol.handler = { req in
            let sse = """
            data: {"type":"error","code":"documents.chat.providerUnavailable","message":"x"}

            """
            return ok(req, sse)
        }
        await #expect(throws: DocumentChatError.provider("documents.chat.providerUnavailable")) {
            for try await _ in makeRepo().chatStream(id: "d1", message: "Hallo") {}
        }
    }

    @Test("A stream with only a done frame (no tokens) throws emptyReply")
    func streamEmptyReply() async {
        MockURLProtocol.handler = { req in
            ok(req, "data: {\"type\":\"done\",\"conversationId\":\"c-1\"}\n\n")
        }
        await #expect(throws: DocumentChatError.emptyReply) {
            for try await _ in makeRepo().chatStream(id: "d1", message: "Hallo") {}
        }
    }
}
