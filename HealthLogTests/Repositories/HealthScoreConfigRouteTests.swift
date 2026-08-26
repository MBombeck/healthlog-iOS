import Foundation

// swiftlint:disable force_unwrapping
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// **GH #83 / server v1.35.0 — the wire contract of
/// `GET`/`PATCH /api/auth/me/health-score-config`.**
///
/// Real `APIClient` over `MockURLProtocol` (never a mock server), so a path,
/// method or body-shape drift is caught at the boundary rather than in a
/// stubbed repository that agrees with itself. `.serialized` because the mock
/// handler is process-global; every counter below is gated on
/// `URLRequest.targets(_:)` so a sibling suite's traffic can never be counted
/// into these numbers.
///
/// The three things worth pinning here, in order of how badly getting them
/// wrong would hurt:
///
///  1. **The first save is unconditional and the key is ABSENT, not `null`.**
///     A `GET` for an account that never chose omits `updatedAt`; the server
///     answers a literal `"baseUpdatedAt": null` with a `422`.
///  2. **A refusal is typed, and it keeps its reason.** A `422
///     health_score_config.too_narrow` has to reach the caller as
///     ``HLError/refusedWithReason(code:reason:)`` — the reason is the only
///     thing that distinguishes the two sentences the surface can show.
///  3. **A 409 is survivable exactly once.** Same bounded retry as the other
///     eight guarded routes.
@Suite("GH #83 — health-score-config route", .serialized)
struct HealthScoreConfigRouteTests {
    private static let path = "/api/auth/me/health-score-config"

    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
    }

    private static func ok(_ req: URLRequest, _ json: String) -> (HTTPURLResponse, Data?) {
        (
            HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
            Data("{\"data\":\(json)}".utf8)
        )
    }

    private static func error(
        _ req: URLRequest,
        status: Int,
        body: String
    ) -> (HTTPURLResponse, Data?) {
        (
            HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
            Data(body.utf8)
        )
    }

    /// A never-chose account: three counted pillars, no `updatedAt` key at all.
    private static let neverChose = """
    {"pillars":["BLOOD_PRESSURE","ACTIVITY","SLEEP"],"excludedPillars":[],\
    "hasSelection":false,"version":0,"changedAt":null}
    """

    /// Records what the write path actually put on the wire.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _writes: [(method: String, body: [String: Any])] = []
        private var _reads = 0
        var writes: [(method: String, body: [String: Any])] {
            lock.withLock { _writes }
        }

        var reads: Int {
            lock.withLock { _reads }
        }

        func noteRead() {
            lock.withLock { _reads += 1 }
        }

        func noteWrite(_ req: URLRequest) -> Int {
            let raw = req.bodyOrStream().flatMap { try? JSONSerialization.jsonObject(with: $0) }
            let body = raw as? [String: Any] ?? [:]
            return lock.withLock {
                _writes.append((req.httpMethod ?? "?", body))
                return _writes.count
            }
        }
    }

    // MARK: - GET

    @Test("GET decodes the resolved composition and keeps 'never chose' distinct from 'chose nothing'")
    func getDecodes() async throws {
        MockURLProtocol.handler = { req in
            Self.ok(req, Self.neverChose)
        }
        let config = try await HealthScoreConfigRepository(api: makeAPI()).fetch()
        #expect(config.pillars == [.bloodPressure, .activity, .sleep])
        #expect(config.excludedPillars.isEmpty)
        #expect(config.hasSelection == false)
        #expect(config.version == 0)
        #expect(config.updatedAt == nil)
    }

    @Test("GET tolerates a pillar id this build does not know")
    func getTolerantPillar() async throws {
        MockURLProtocol.handler = { req in
            Self.ok(req, #"{"pillars":["SLEEP","VO2MAX_NEXT"],"excludedPillars":[],"hasSelection":true,"version":3}"#)
        }
        let config = try await HealthScoreConfigRepository(api: makeAPI()).fetch()
        #expect(config.pillars == [.sleep, .unknown("VO2MAX_NEXT")])
        #expect(config.hasSelection)
    }

    // MARK: - The unconditional first write

    @Test("first save omits the baseUpdatedAt KEY entirely — a null would be a 422")
    func firstSaveIsUnconditional() async throws {
        let rec = Recorder()
        MockURLProtocol.handler = { req in
            if req.targets(Self.path, method: "GET") {
                rec.noteRead()
                return Self.ok(req, Self.neverChose)
            }
            guard req.targets(Self.path, method: "PATCH") else {
                return Self.ok(req, "{}")
            }
            _ = rec.noteWrite(req)
            return Self.ok(req, """
            {"pillars":["BLOOD_PRESSURE","SLEEP","FITNESS"],"excludedPillars":["GLYCAEMIA"],\
            "hasSelection":true,"version":1,"changedAt":"2026-08-01T00:00:00.000Z",\
            "updatedAt":"2026-08-01T00:00:00.000Z"}
            """)
        }
        let repo = HealthScoreConfigRepository(api: makeAPI())
        _ = try await repo.fetch()
        _ = try await repo.update(pillars: [.bloodPressure, .sleep, .fitness])

        let write = try #require(rec.writes.first)
        #expect(rec.writes.count == 1)
        #expect(write.method == "PATCH")
        // Absent, not present-and-null. `index(forKey:)` is the only assertion
        // that tells those two apart.
        #expect(write.body.index(forKey: "baseUpdatedAt") == nil)
        #expect(write.body["pillars"] as? [String] == ["BLOOD_PRESSURE", "SLEEP", "FITNESS"])
        // The token from the echo is adopted for the NEXT write.
        #expect(await repo.currentConfigToken() == "2026-08-01T00:00:00.000Z")
    }

    @Test("a save after a selection exists carries the token it was based on")
    func secondSaveIsGuarded() async throws {
        let rec = Recorder()
        MockURLProtocol.handler = { req in
            if req.targets(Self.path, method: "GET") {
                rec.noteRead()
                return Self.ok(req, """
                {"pillars":["SLEEP","ACTIVITY","LIPIDS"],"excludedPillars":[],"hasSelection":true,\
                "version":2,"changedAt":"2026-07-01T00:00:00.000Z","updatedAt":"T0"}
                """)
            }
            guard req.targets(Self.path, method: "PATCH") else { return Self.ok(req, "{}") }
            _ = rec.noteWrite(req)
            return Self.ok(req, """
            {"pillars":["SLEEP","ACTIVITY"],"excludedPillars":["LIPIDS"],"hasSelection":true,\
            "version":3,"updatedAt":"T1"}
            """)
        }
        let repo = HealthScoreConfigRepository(api: makeAPI())
        _ = try await repo.fetch()
        _ = try await repo.update(pillars: [.sleep, .activity])

        #expect(rec.writes.first?.body["baseUpdatedAt"] as? String == "T0")
        #expect(await repo.currentConfigToken() == "T1")
    }

    // MARK: - 409

    @Test("409 → re-read → the retry lands with the fresh token")
    func conflictRecovers() async throws {
        let rec = Recorder()
        MockURLProtocol.handler = { req in
            if req.targets(Self.path, method: "GET") {
                rec.noteRead()
                let token = rec.reads == 1 ? "T0" : "T1"
                return Self.ok(req, """
                {"pillars":["SLEEP","ACTIVITY","LIPIDS"],"excludedPillars":[],"hasSelection":true,\
                "version":2,"updatedAt":"\(token)"}
                """)
            }
            guard req.targets(Self.path, method: "PATCH") else { return Self.ok(req, "{}") }
            let attempt = rec.noteWrite(req)
            if attempt == 1 {
                return Self.error(req, status: 409, body: """
                {"data":null,"error":"The score selection changed since it was loaded",\
                "meta":{"errorCode":"health_score_config_conflict"}}
                """)
            }
            return Self.ok(req, """
            {"pillars":["SLEEP","ACTIVITY"],"excludedPillars":["LIPIDS"],"hasSelection":true,\
            "version":3,"updatedAt":"T2"}
            """)
        }
        let repo = HealthScoreConfigRepository(api: makeAPI())
        _ = try await repo.fetch()
        _ = try await repo.update(pillars: [.sleep, .activity])

        #expect(rec.writes.count == 2)
        #expect(rec.writes.map { $0.body["baseUpdatedAt"] as? String } == ["T0", "T1"])
        #expect(await repo.currentConfigToken() == "T2")
    }

    // MARK: - 422 refusal

    @Test(
        "422 too_narrow keeps its reason as a typed refusal, both arms",
        arguments: [
            ("three_domains_required", HealthScoreBreadthReason.threeDomainsRequired),
            ("measured_physiological_domain_required", HealthScoreBreadthReason.measuredPhysiologicalDomainRequired)
        ]
    )
    func tooNarrowIsTyped(rawReason: String, expected: HealthScoreBreadthReason) async throws {
        MockURLProtocol.handler = { req in
            guard req.targets(Self.path, method: "PATCH") else {
                return Self.ok(req, Self.neverChose)
            }
            return Self.error(req, status: 422, body: """
            {"data":null,"error":"A health score needs at least three different areas of health.",\
            "meta":{"errorCode":"health_score_config.too_narrow","reason":"\(rawReason)"}}
            """)
        }
        let repo = HealthScoreConfigRepository(api: makeAPI())
        await #expect(throws: HLError.refusedWithReason(
            code: "health_score_config.too_narrow",
            reason: rawReason
        )) {
            _ = try await repo.update(pillars: [.wellbeing])
        }
        #expect(HealthScoreBreadthReason(rawValue: rawReason) == expected)
    }

    @Test("a reason this build does not know still arrives typed, never silently generic")
    func unknownReasonStaysTyped() async throws {
        MockURLProtocol.handler = { req in
            guard req.targets(Self.path, method: "PATCH") else { return Self.ok(req, Self.neverChose) }
            return Self.error(req, status: 422, body: """
            {"data":null,"error":"nope","meta":{"errorCode":"health_score_config.too_narrow",\
            "reason":"two_measured_domains_required"}}
            """)
        }
        do {
            _ = try await HealthScoreConfigRepository(api: makeAPI()).update(pillars: [.sleep])
            Issue.record("expected a refusal")
        } catch let error as HLError {
            guard case let .refusedWithReason(_, reason) = error else {
                Issue.record("expected .refusedWithReason, got \(error)")
                return
            }
            #expect(HealthScoreBreadthReason(rawValue: reason) == .unknown("two_measured_domains_required"))
        }
    }

    @Test("a malformed body is NOT promoted to a refusal — it stays a plain server error")
    func invalidShapeStaysGeneric() async throws {
        MockURLProtocol.handler = { req in
            guard req.targets(Self.path, method: "PATCH") else { return Self.ok(req, Self.neverChose) }
            return Self.error(req, status: 422, body: """
            {"data":null,"error":"Validation failed","meta":{"errorCode":"health_score_config.invalid"}}
            """)
        }
        do {
            _ = try await HealthScoreConfigRepository(api: makeAPI()).update(pillars: [.sleep])
            Issue.record("expected a server error")
        } catch let error as HLError {
            #expect(error == .server(status: 422, code: "health_score_config.invalid", message: "Validation failed"))
        }
    }

    @Test("a 429 stays a rate-limit, not a refusal")
    func rateLimitStaysRateLimit() async throws {
        MockURLProtocol.handler = { req in
            guard req.targets(Self.path, method: "PATCH") else { return Self.ok(req, Self.neverChose) }
            return Self.error(req, status: 429, body: #"{"data":null,"error":"Too many requests"}"#)
        }
        do {
            _ = try await HealthScoreConfigRepository(api: makeAPI()).update(pillars: [.sleep])
            Issue.record("expected a rate-limit")
        } catch let error as HLError {
            #expect(error.isRetriable)
        }
    }

    // MARK: - The opt-in of the refusal promotion

    @Test("an unlisted errorCode with a meta.reason keeps arriving as .server")
    func unlistedReasonedCodeIsUntouched() async throws {
        // The document-inbox family has carried `meta.reason` for releases; its
        // callers read `.server`, and this branch must not change under them.
        MockURLProtocol.handler = { req in
            Self.error(req, status: 422, body: """
            {"data":null,"error":"File too large",\
            "meta":{"errorCode":"documents.inbound.rejected","reason":"fileTooLarge"}}
            """)
        }
        let api = makeAPI()
        do {
            let req: APIRequest<HealthScoreConfig> = .get("/api/documents/inbound")
            _ = try await api.send(req)
            Issue.record("expected a server error")
        } catch let error as HLError {
            #expect(error == .server(status: 422, code: "documents.inbound.rejected", message: "File too large"))
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

private extension URLRequest {
    /// URLSession moves the body onto `httpBodyStream` by the time it reaches
    /// the `URLProtocol`, so a plain `httpBody` read finds nothing.
    func bodyOrStream() -> Data? {
        if let body = httpBody { return body }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

// swiftlint:enable force_unwrapping
