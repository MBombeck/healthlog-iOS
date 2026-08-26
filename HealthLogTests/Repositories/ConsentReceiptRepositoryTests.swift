import Foundation

// swiftlint:disable force_unwrapping
import Testing

#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// v0.14.10 W-INSIGHTSDATA — pins the server consent-receipt sync contract.
///
/// Server v1.12.1 enforcement fails the per-metric assessment family closed
/// without an active `ConsentReceipt` on file, and no client ever minted one
/// (`POST /api/consent/ai` had zero callers — the root cause of "Einschätzung
/// no longer loads on the Insights metric sub-pages"). These tests pin the
/// repository half of the fix: ensure mints exactly when no active master
/// receipt exists, the POST body matches the server zod schema, and the
/// master revoke targets the right route.
@Suite("ConsentReceiptRepository", .serialized)
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

    @Test("ensure mints ai_full when no receipt is on file — POST body matches the zod schema")
    func ensureMintsWhenAbsent() async throws {
        let repo = makeRepo()
        let log = RequestLog()
        MockURLProtocol.handler = Self.wireHandler(latest: Self.emptyLatestPayload(), log: log)

        let ok = await repo.ensureFullConsentReceipt(artefact: "{\"source\":\"test\"}")

        #expect(ok)
        let calls = log.snapshot
        #expect(calls.map(\.method) == ["GET", "POST"])
        #expect(calls.last?.path == "/api/consent/ai")
        let body = try #require(calls.last?.body)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["kind"] as? String == "ai_full")
        #expect((json["artefact"] as? String)?.isEmpty == false)
        // signedAt must be ISO-8601 WITH a timezone designator
        // (server zod: `z.iso.datetime({ offset: true })`).
        let signedAt = try #require(json["signedAt"] as? String)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        #expect(iso.date(from: signedAt) != nil)
    }

    @Test("ensure is a no-op when an active ai_full receipt exists")
    func ensureNoOpWhenActive() async {
        let repo = makeRepo()
        let log = RequestLog()
        MockURLProtocol.handler = Self.wireHandler(latest: Self.activeLatestPayload(revoked: false), log: log)

        let ok = await repo.ensureFullConsentReceipt(artefact: "{}")

        #expect(ok)
        #expect(log.snapshot.map(\.method) == ["GET"]) // no POST fired
    }

    @Test("ensure re-mints when the latest ai_full receipt is revoked")
    func ensureRemintsWhenRevoked() async {
        let repo = makeRepo()
        let log = RequestLog()
        MockURLProtocol.handler = Self.wireHandler(latest: Self.activeLatestPayload(revoked: true), log: log)

        let ok = await repo.ensureFullConsentReceipt(artefact: "{}")

        #expect(ok)
        #expect(log.snapshot.map(\.method) == ["GET", "POST"])
    }

    @Test("revokeAll issues the master DELETE")
    func revokeAllIssuesDelete() async {
        let repo = makeRepo()
        let log = RequestLog()
        MockURLProtocol.handler = Self.wireHandler(latest: Self.emptyLatestPayload(), log: log)

        await repo.revokeAll()

        let calls = log.snapshot
        #expect(calls.count == 1)
        #expect(calls.first?.method == "DELETE")
        #expect(calls.first?.path == "/api/consent/ai/latest")
    }

    @Test("ensure reports false on transport failure (best-effort, never throws)")
    func ensureBestEffortOnFailure() async {
        let repo = makeRepo()
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }

        let ok = await repo.ensureFullConsentReceipt(artefact: "{}")

        #expect(!ok)
    }
}

// swiftlint:enable force_unwrapping
