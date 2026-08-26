import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **CU-33** — locks the wire contract of the correlation-pattern decision
/// ledger (server v1.34.0):
/// `GET /api/insights/patterns` + `PATCH /api/insights/patterns/{id}`.
///
/// Real `APIClient` over `MockURLProtocol` (never a mock server), so a schema
/// drift on either route fails here rather than in the field.
///
/// Covers:
/// - the closed 13-field `CorrelationPattern` item shape, including the
///   nullable `qValue` and the nullable `dismissedAt`
/// - that the route returns DISMISSED rows too (no server-side filter)
/// - the gated arms (`403 module.disabled`, `404`) → `nil` → surface hides
/// - the PATCH: exact path, method, and the **actually-sent body** — the server
///   validates with a `strictObject`, so `{ "dismissed": … }` and nothing else
/// - that dismissal is REVERSIBLE (`dismissed: false` is accepted the same way)
/// - that a withdrawn pattern's `404` is thrown, not swallowed
@Suite("PatternsRepository — Muster-Ledger + Verwerfen ist umkehrbar (CU-33)", .serialized)
struct PatternsRepositoryTests {
    private func makeRepo() -> PatternsRepository {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.12.0",
            buildNumber: "1"
        )
        return PatternsRepository(
            api: APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
        )
    }

    /// `URLRequest.httpBody` is nil for a stream-backed body; drain the stream.
    private nonisolated static func consumeStream(_ stream: InputStream) -> Data? {
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

    // MARK: - GET /api/insights/patterns

    @Test("fetch — dekodiert die geschlossene 13-Feld-Shape inkl. verworfener Zeile")
    func fetchDecodesFullItemShape() async throws {
        nonisolated(unsafe) var capturedPath: String?
        nonisolated(unsafe) var capturedMethod: String?
        MockURLProtocol.handler = { req in
            capturedPath = req.url?.path
            capturedMethod = req.httpMethod
            let body = Data(#"""
            {"data":{"patterns":[
              {"id":"clx1pattern0000aaaa","canonicalKey":"p1:aaaa1111","family":"DISCOVERY_RETROSPECTIVE",
               "factorKey":"TIME_IN_DAYLIGHT","outcomeKey":"SLEEP_DURATION","lagDays":1,
               "sampleSize":34,"effectSize":0.41,"pValue":0.012,"qValue":0.06,
               "evidenceHash":"9f2b","lastComputedAt":"2026-07-30T03:15:00.000Z","dismissedAt":null},
              {"id":"clx2pattern0000bbbb","canonicalKey":"p1:bbbb2222","family":"MOOD_TAG_CROSSTAB",
               "factorKey":"MOOD","outcomeKey":"HEART_RATE_VARIABILITY","lagDays":1,
               "sampleSize":28,"effectSize":-0.33,"pValue":0.04,"qValue":null,
               "evidenceHash":"1c7d","lastComputedAt":"2026-07-29T03:15:00.000Z",
               "dismissedAt":"2026-07-29T18:04:11.000Z"}
            ]},"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let patterns = try #require(try await makeRepo().fetch())
        #expect(capturedPath == "/api/insights/patterns")
        #expect(capturedMethod == "GET")
        #expect(patterns.count == 2)

        let live = try #require(patterns.first { $0.id == "clx1pattern0000aaaa" })
        #expect(live.canonicalKey == "p1:aaaa1111")
        #expect(live.family == "DISCOVERY_RETROSPECTIVE")
        #expect(live.knownFamily == .discoveryRetrospective)
        #expect(live.factorKey == "TIME_IN_DAYLIGHT")
        #expect(live.outcomeKey == "SLEEP_DURATION")
        #expect(live.lagDays == 1)
        #expect(live.sampleSize == 34)
        #expect(live.effectSize == 0.41)
        #expect(live.pValue == 0.012)
        #expect(live.qValue == 0.06)
        #expect(live.evidenceHash == "9f2b")
        #expect(live.dismissedAt == nil)
        #expect(live.isDismissed == false)

        // The route applies NO `dismissedAt` filter — dismissed rows come back
        // inline and the client distinguishes on the timestamp.
        let setAside = try #require(patterns.first { $0.id == "clx2pattern0000bbbb" })
        #expect(setAside.isDismissed)
        #expect(setAside.dismissedAt != nil)
        // `qValue` is genuinely nullable (Float? in the schema).
        #expect(setAside.qValue == nil)
        #expect(setAside.knownFamily == .moodTagCrosstab)
    }

    @Test("fetch — unbekanntes family-Literal bricht die Zeile nicht (offener String)")
    func fetchToleratesUnknownFamily() async throws {
        MockURLProtocol.handler = { req in
            let body = Data(#"""
            {"data":{"patterns":[
              {"id":"p1","canonicalKey":"p1:cccc","family":"SOME_FUTURE_FAMILY",
               "factorKey":"STEPS","outcomeKey":"MOOD","lagDays":1,
               "sampleSize":40,"effectSize":0.2,"pValue":0.03,"qValue":0.08,
               "evidenceHash":"ab","lastComputedAt":"2026-07-30T03:15:00.000Z","dismissedAt":null}
            ]},"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let patterns = try #require(try await makeRepo().fetch())
        let row = try #require(patterns.first)
        #expect(row.family == "SOME_FUTURE_FAMILY")
        // Postgres stores a bare string, so an unknown literal must decode.
        #expect(row.knownFamily == nil)
    }

    @Test("fetch — 403 module.disabled (insights aus) → nil → Fläche versteckt sich")
    func fetchModuleDisabledIsNil() async throws {
        MockURLProtocol.handler = { req in
            let body = Data(#"""
            {"data":null,"error":"Module disabled","meta":{"errorCode":"module.disabled","module":"insights"}}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!, body)
        }
        #expect(try await makeRepo().fetch() == nil)
    }

    @Test("fetch — 404 (Route nicht deployed) → nil, kein Fehler")
    func fetch404IsNil() async throws {
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }
        #expect(try await makeRepo().fetch() == nil)
    }

    @Test("fetch — echter 500 wirft (keine stille Leermenge)")
    func fetchServerErrorThrows() async {
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        await #expect(throws: HLError.self) {
            _ = try await makeRepo().fetch()
        }
    }

    // MARK: - PATCH /api/insights/patterns/{id}

    @Test("setDismissed(true) — Pfad, Methode und der TATSÄCHLICH gesendete Body")
    func patchSendsExactDismissBody() async throws {
        nonisolated(unsafe) var capturedPath: String?
        nonisolated(unsafe) var capturedMethod: String?
        nonisolated(unsafe) var capturedBody: Data?
        MockURLProtocol.handler = { req in
            capturedPath = req.url?.path
            capturedMethod = req.httpMethod
            capturedBody = req.httpBody ?? req.httpBodyStream.flatMap(Self.consumeStream(_:))
            let body = Data(#"""
            {"data":{"id":"clx2pattern0000bbbb","canonicalKey":"p1:bbbb2222","dismissed":true,
             "dismissedAt":"2026-07-30T09:00:00.000Z","evidenceHash":"1c7d"},"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let delta = try await makeRepo().setDismissed(true, patternId: "clx2pattern0000bbbb")

        // The path parameter is the ROW ID (cuid) — never the canonicalKey.
        #expect(capturedPath == "/api/insights/patterns/clx2pattern0000bbbb")
        #expect(capturedMethod == "PATCH")
        let raw = try #require(capturedBody)
        let json = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        #expect(json["dismissed"] as? Bool == true)
        // `strictObject` on the server: any extra key is a 422, so the body must
        // carry EXACTLY one field.
        #expect(json.count == 1)

        // The 200 is a five-field delta, not the full pattern row.
        #expect(delta.id == "clx2pattern0000bbbb")
        #expect(delta.canonicalKey == "p1:bbbb2222")
        #expect(delta.dismissed)
        #expect(delta.dismissedAt != nil)
        #expect(delta.evidenceHash == "1c7d")
    }

    @Test("setDismissed(false) — dieselbe Route nimmt das Verwerfen zurück (umkehrbar)")
    func patchIsReversible() async throws {
        nonisolated(unsafe) var capturedBody: Data?
        MockURLProtocol.handler = { req in
            capturedBody = req.httpBody ?? req.httpBodyStream.flatMap(Self.consumeStream(_:))
            let body = Data(#"""
            {"data":{"id":"p9","canonicalKey":"p1:dddd","dismissed":false,
             "dismissedAt":null,"evidenceHash":"ff"},"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let delta = try await makeRepo().setDismissed(false, patternId: "p9")
        let raw = try #require(capturedBody)
        let json = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        // Reversal is a first-class server operation, not a client-side hack:
        // the same route + the same single boolean clears the whole baseline.
        #expect(json["dismissed"] as? Bool == false)
        #expect(json.count == 1)
        #expect(delta.dismissed == false)
        #expect(delta.dismissedAt == nil)
    }

    @Test("setDismissed — 404 (zurückgezogenes Muster) wirft, wird nicht verschluckt")
    func patchWithdrawnPatternThrows() async {
        // `where: { id, userId, isCurrent: true }` — a withdrawn pattern can be
        // neither dismissed nor restored. A write that did not happen must never
        // look like one that did.
        MockURLProtocol.handler = { req in
            let body = Data(#"{"data":null,"error":"Correlation pattern not found"}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, body)
        }
        await #expect(throws: HLError.self) {
            _ = try await makeRepo().setDismissed(true, patternId: "gone")
        }
    }
}

// swiftlint:enable force_unwrapping
