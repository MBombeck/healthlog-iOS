import Foundation

// swiftlint:disable force_unwrapping
import Testing

#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// Pins the server consent-receipt contract.
///
/// #143 (server v1.43.2): a receipt is recorded only from an Accept tap and
/// carries `confirm: true`; a 400 `consent.ai.confirmRequired` is not an error.
///
/// Server v1.12.1 enforcement fails the per-metric assessment family closed
/// without an active `ConsentReceipt` on file, and no client ever minted one
/// (`POST /api/consent/ai` had zero callers — the root cause of "Einschätzung
/// no longer loads on the Insights metric sub-pages"). These tests pin the
/// repository half: a tap mints at most once, the POST body matches the server
/// zod schema, and the master revoke targets the right route.
@Suite("ConsentReceiptRepository", .serialized, .mockURLSession)
struct ConsentReceiptRepositoryTests {
    /// One recorded wire call (struct, not 3-tuple, per `large_tuple`).
    private struct RecordedCall {
        let method: String
        let path: String
        let body: Data?
    }

    /// Thread-safe recorder for the requests the repo issues.
    private final class RequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [RecordedCall] = []

        func record(method: String, path: String, body: Data?) {
            lock.lock()
            defer { lock.unlock() }
            entries.append(RecordedCall(method: method, path: path, body: body))
        }

        var snapshot: [RecordedCall] {
            lock.lock()
            defer { lock.unlock() }
            return entries
        }
    }

    private func makeRepo() -> ConsentReceiptRepository {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        let api = APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
        return ConsentReceiptRepository(api: api)
    }

    /// `URLProtocol` swaps `httpBody` for `httpBodyStream` — re-materialize.
    nonisolated static func consumeStream(_ stream: InputStream) -> Data? {
        stream.open()
        defer { stream.close() }
        var buf = Data()
        var raw = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&raw, maxLength: 4096)
            guard read > 0 else { break }
            buf.append(raw, count: read)
        }
        return buf.isEmpty ? nil : buf
    }

    private static func emptyLatestPayload() -> Data {
        Data("{\"data\":{\"ai_full\":null,\"ai_insights_only\":null,\"ai_coach\":null}}".utf8)
    }

    private static func activeLatestPayload(revoked: Bool) -> Data {
        let revokedAt = revoked ? "\"2026-06-10T09:00:00.000Z\"" : "null"
        return Data("""
        {"data":{"ai_full":{"id":"r1","userId":"u1","kind":"ai_full",\
        "signedAt":"2026-06-09T10:00:00.000Z","revokedAt":\(revokedAt),\
        "createdAt":"2026-06-09T10:00:00.000Z"},"ai_insights_only":null,"ai_coach":null}}
        """.utf8)
    }

    private static func mintedPayload() -> Data {
        Data("""
        {"data":{"id":"r2","receipt":{"id":"r2","userId":"u1","kind":"ai_full",\
        "signedAt":"2026-06-11T10:00:00.000Z","revokedAt":null,\
        "createdAt":"2026-06-11T10:00:00.000Z"}}}
        """.utf8)
    }

    private static func wireHandler(latest: Data, log: RequestLog) -> MockURLProtocol.Handler {
        { req in
            let url = req.url!
            let body = req.httpBody ?? req.httpBodyStream.flatMap(Self.consumeStream(_:))
            log.record(method: req.httpMethod ?? "?", path: url.path, body: body)
            let payload: Data = switch (req.httpMethod, url.path) {
            case ("GET", "/api/consent/ai/latest"): latest
            case ("POST", "/api/consent/ai"): Self.mintedPayload()
            case ("DELETE", "/api/consent/ai/latest"): Data("{\"data\":{\"revoked\":[]}}".utf8)
            default: Data("{\"data\":null}".utf8)
            }
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, payload)
        }
    }

    @Test("a tap after the server said needed: one POST, confirm true, body matches the zod schema")
    func tapPostsConfirmOnce() async throws {
        let repo = makeRepo()
        let log = RequestLog()
        MockURLProtocol.install(Self.wireHandler(latest: Self.emptyLatestPayload(), log: log))

        let outcome = await repo.recordAcceptedConsent(artefact: "{\"source\":\"test\"}", checkExisting: false)

        #expect(outcome == .recorded)
        let calls = log.snapshot
        #expect(calls.map(\.method) == ["POST"])
        #expect(calls.last?.path == "/api/consent/ai")
        let body = try #require(calls.last?.body)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        // #143 (server v1.43.2) — without it the server writes nothing (400).
        #expect(json["confirm"] as? Bool == true)
        #expect(json["kind"] as? String == "ai_full")
        #expect((json["artefact"] as? String)?.isEmpty == false)
        // signedAt must be ISO-8601 WITH a timezone designator
        // (server zod: `z.iso.datetime({ offset: true })`).
        let signedAt = try #require(json["signedAt"] as? String)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        #expect(iso.date(from: signedAt) != nil)
    }

    @Test("mintFullConsentReceipt always carries confirm true")
    func mintCarriesConfirm() async throws {
        let repo = makeRepo()
        let log = RequestLog()
        MockURLProtocol.install(Self.wireHandler(latest: Self.emptyLatestPayload(), log: log))

        try await repo.mintFullConsentReceipt(artefact: "{}")

        let body = try #require(log.snapshot.last?.body)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["confirm"] as? Bool == true)
    }

    @Test("older server: a tap reads the receipt first and sends nothing when one is active")
    func tapNoOpWhenActive() async {
        let repo = makeRepo()
        let log = RequestLog()
        MockURLProtocol.install(Self.wireHandler(latest: Self.activeLatestPayload(revoked: false), log: log))

        let outcome = await repo.recordAcceptedConsent(artefact: "{}", checkExisting: true)

        #expect(outcome == .alreadyOnFile)
        #expect(log.snapshot.map(\.method) == ["GET"]) // no POST fired
    }

    @Test("older server: a tap mints when the latest ai_full receipt is revoked")
    func tapMintsWhenRevoked() async {
        let repo = makeRepo()
        let log = RequestLog()
        MockURLProtocol.install(Self.wireHandler(latest: Self.activeLatestPayload(revoked: true), log: log))

        let outcome = await repo.recordAcceptedConsent(artefact: "{}", checkExisting: true)

        #expect(outcome == .recorded)
        #expect(log.snapshot.map(\.method) == ["GET", "POST"])
    }

    @Test("revokeAll issues the master DELETE")
    func revokeAllIssuesDelete() async {
        let repo = makeRepo()
        let log = RequestLog()
        MockURLProtocol.install(Self.wireHandler(latest: Self.emptyLatestPayload(), log: log))

        await repo.revokeAll()

        let calls = log.snapshot
        #expect(calls.count == 1)
        #expect(calls.first?.method == "DELETE")
        #expect(calls.first?.path == "/api/consent/ai/latest")
    }

    @Test("a tap reports failed on a transport failure (best-effort, never throws)")
    func tapBestEffortOnFailure() async {
        let repo = makeRepo()
        MockURLProtocol.install { req in
            (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }

        let outcome = await repo.recordAcceptedConsent(artefact: "{}", checkExisting: false)

        #expect(outcome == .failed)
    }

    @Test("400 consent.ai.confirmRequired maps to needsExplicitConsent, not a failure")
    func tapConfirmRequired() async {
        let repo = makeRepo()
        let log = RequestLog()
        MockURLProtocol.install { req in
            log.record(method: req.httpMethod ?? "?", path: req.url!.path, body: nil)
            let body = Data("""
            {"data":null,"error":"Consent is recorded only from an explicit confirmation",\
            "meta":{"errorCode":"consent.ai.confirmRequired","requestId":"r"}}
            """.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!, body)
        }

        let outcome = await repo.recordAcceptedConsent(artefact: "{}", checkExisting: false)

        #expect(outcome == .needsExplicitConsent)
        #expect(log.snapshot.count == 1) // no retry
    }
}

// swiftlint:enable force_unwrapping
