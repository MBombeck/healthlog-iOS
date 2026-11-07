import Foundation
@testable import HealthLog
import Synchronization
import Testing

// swiftlint:disable force_unwrapping

/// **POLISH-B B7 (1.5, SRV-REQ H, server v1.40).** "Suggest details" and the
/// summary prefer a background run like `extract` and `index`: from v1.40 the
/// server takes `Prefer: respond-async` on both, answers 202 with a run id,
/// and `GET /api/ai-runs/{id}` serves the same body as the run's `result`.
/// The preference rides only on a server known to be v1.40 or later
/// (rule 10: unknown means no); without it the request is byte-for-byte the
/// 1.4 one. A 200 answer is used as before either way.
@Suite(
    "POLISH-B B7 — suggest and summary prefer a background run (v1.40)",
    .serialized,
    .mockURLSession,
    .timeLimit(.minutes(1))
)
struct DocumentsAssistRunTests {
    private func makeRepo() -> DocumentsRepository {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "1.5.0",
            buildNumber: "1"
        )
        let keychain = InMemoryKeychain()
        try? keychain.setString("token", forKey: KeychainKey.authToken)
        let lease = DocumentAIConsentLease(ownerUserID: "user-A", bearerToken: "lease-token", scope: .serverManaged)
        return DocumentsRepository(
            api: APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock()),
            externalAIConsent: DocumentAIConsentLeaseProvider { lease }
        )
    }

    private func reply(_ request: URLRequest, _ json: String, status: Int = 200) -> (HTTPURLResponse, Data?) {
        (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
    }

    private static let accepted = #"{"data":{"runId":"run-7","status":"QUEUED","pollAfterMs":0},"error":null}"#

    private static func run(_ status: String, kind: String, result: String = "null", error: String = "null") -> String {
        #"""
        {"data":{"id":"run-7","kind":"\#(kind)","documentId":"d1","status":"\#(status)",
         "result":\#(result),"error":\#(error),"createdAt":"2026-11-01T09:00:00.000Z",
         "startedAt":null,"finishedAt":null,"queuedForMs":null,"retryAfterMs":0},"error":null}
        """#
    }

    private static let suggestBody = #"{"suggestions":{"title":"Blutbild","kind":"LAB_RESULT","documentDate":"2026-10-30"}}"#

    // MARK: - suggest

    @Test("suggest on a v1.40 server: Prefer respond-async, 202, polled run, the run's body is the draft")
    func suggestBackgroundRun() async throws {
        let headers = Mutex<[String?]>([])
        let polls = Mutex(0)
        MockURLProtocol.install { req in
            switch req.url?.path ?? "" {
            case "/api/documents/inbound/d1/suggest":
                headers.withLock { $0.append(req.value(forHTTPHeaderField: "Prefer")) }
                // VISION still sends no body, so it reaches the vision handler.
                #expect(req.value(forHTTPHeaderField: "Content-Type") == nil)
                return reply(req, Self.accepted, status: 202)
            case "/api/ai-runs/run-7":
                let count = polls.withLock { value -> Int in
                    value += 1
                    return value
                }
                return count == 1
                    ? reply(req, Self.run("RUNNING", kind: "DOCUMENT_SUGGEST"))
                    : reply(req, Self.run("SUCCEEDED", kind: "DOCUMENT_SUGGEST", result: Self.suggestBody))
            default:
                Issue.record("unexpected \(req.url?.path ?? "")")
                return reply(req, "{}", status: 404)
            }
        }
        let draft = try await makeRepo().suggest(id: "d1", preferRun: true)
        #expect(headers.withLock { $0 } == ["respond-async"])
        #expect(draft.title == "Blutbild")
        #expect(polls.withLock { $0 } == 2)
    }

    @Test("suggest on an older or unknown server: no preference, the 200 body as in 1.4")
    func suggestOlderServer() async throws {
        let headers = Mutex<[String?]>([])
        MockURLProtocol.install { req in
            headers.withLock { $0.append(req.value(forHTTPHeaderField: "Prefer")) }
            return reply(req, #"{"data":\#(Self.suggestBody),"error":null}"#)
        }
        let draft = try await makeRepo().suggest(id: "d1", preferRun: false)
        #expect(headers.withLock { $0 } == [nil])
        #expect(draft.title == "Blutbild")
    }

    @Test("a v1.40 server that answers 200 anyway: the synchronous body is used")
    func suggestPreferenceAnswered200() async throws {
        MockURLProtocol.install { req in
            reply(req, #"{"data":\#(Self.suggestBody),"error":null}"#)
        }
        let draft = try await makeRepo().suggest(id: "d1", preferRun: true)
        #expect(draft.kind == .labResult)
    }

    @Test("a failed suggest run throws the same typed error the route would have answered")
    func suggestRunFailed() async throws {
        MockURLProtocol.install { req in
            if req.url?.path == "/api/ai-runs/run-7" {
                return reply(req, Self.run(
                    "FAILED",
                    kind: "DOCUMENT_SUGGEST",
                    error: #"{"code":"documents.inbound.providerUnsupported","message":"no provider","status":422}"#
                ))
            }
            return reply(req, Self.accepted, status: 202)
        }
        await #expect {
            try await makeRepo().suggest(id: "d1", preferRun: true)
        } throws: { error in
            DocumentsRepository.isProviderUnsupported(error)
        }
    }

    // MARK: - summary

    @Test("summary on a v1.40 server: the mode stays in the query, the run's body is the summary")
    func summaryBackgroundRun() async throws {
        let triggers = Mutex<[String]>([])
        MockURLProtocol.install { req in
            switch req.url?.path ?? "" {
            case "/api/documents/inbound/d1/summary":
                let query = req.url?.query ?? ""
                triggers.withLock { $0.append("\(req.value(forHTTPHeaderField: "Prefer") ?? "-") \(query)") }
                return reply(req, Self.accepted, status: 202)
            case "/api/ai-runs/run-7":
                return reply(req, Self.run("SUCCEEDED", kind: "DOCUMENT_SUMMARY", result: #"{"text":"Hämoglobin 14,1"}"#))
            default:
                return reply(req, "{}", status: 404)
            }
        }
        let summary = try await makeRepo().summary(id: "d1", mode: .text, preferRun: true)
        #expect(triggers.withLock { $0 } == ["respond-async mode=text"])
        #expect(summary.prose == "Hämoglobin 14,1")
    }

    @Test("summary on an older or unknown server: no preference, 200 as in 1.4")
    func summaryOlderServer() async throws {
        let headers = Mutex<[String?]>([])
        MockURLProtocol.install { req in
            headers.withLock { $0.append(req.value(forHTTPHeaderField: "Prefer")) }
            return reply(req, #"{"data":{"summary":"Ein Laborbefund."},"error":null}"#)
        }
        let summary = try await makeRepo().summary(id: "d1", preferRun: false)
        #expect(headers.withLock { $0 } == [nil])
        #expect(summary.prose == "Ein Laborbefund.")
    }

    // MARK: - Version gate

    @Test("the preference follows the recorded server version; unknown means no", arguments: [
        (nil, false), ("1.39.9", false), ("1.40.0", true), ("1.47.0", true)
    ] as [(String?, Bool)])
    func versionGate(version: String?, expected: Bool) throws {
        let suite = "polish-b-b7-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        if let version {
            KnownServerVersion.record(ServerVersionInfo(version: version), defaults: defaults)
        }
        #expect(DocumentsRepository.assistPrefersRun(defaults: defaults) == expected)
    }
}

// swiftlint:enable force_unwrapping
