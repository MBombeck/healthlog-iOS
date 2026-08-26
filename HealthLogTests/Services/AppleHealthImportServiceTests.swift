import Foundation
import Synchronization

// swiftlint:disable force_unwrapping force_try
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// Tests for the Apple-Health one-shot `export.zip` import path. They drive the
/// **real** ``APIClient`` over a stub `URLProtocol` (per PROJECT_GUIDE.md: never a mock
/// server for these paths) so DTO decoding catches server schema drift.
///
/// The fixtures mirror the live server shapes verbatim:
/// - kickoff `202` → `{ data: { jobId, status } }`
///   (`src/app/api/import/apple-health-export/route.ts`)
/// - status → `{ data: { jobId, status, startedAt, completedAt, uploadBytes,
///   exportedAt, progress, result, failureReason } }`
///   (`.../[jobId]/status/route.ts`, `ImportJobStatusResponse`)
@Suite("AppleHealthImportService", .serialized)
struct AppleHealthImportServiceTests {
    /// The transport seam (issue #82 / Plan 09-11). Both halves come from the
    /// caller's retained session, so every request this client makes is answered
    /// by that session's handler or by nothing at all.
    ///
    /// `baseURL: session.baseURL` is the load-bearing half. `APIClient.init`
    /// assigns `config.httpAdditionalHeaders` **wholesale** on the configuration
    /// object it is handed, before its `URLSession` exists, so the session token
    /// is gone by the time the first request is built. Keeping the old
    /// hard-coded host while passing `session.configuration` would leave the
    /// handlers below installed and never reached, answered instead by the
    /// legacy process-global slot —
    /// `MockURLProtocolIsolationTests.aSessionConfigurationAloneDoesNotMigrateAClient`
    /// pins that trap.
    ///
    /// **Plan 09-02 note.** This file is locked to 09-11 for the transport
    /// migration; 09-02 alone owns the later upload/redirect/temp-file edits and
    /// inherits this seam rather than re-deriving one.
    private func makeClient(session: MockURLProtocolSession) -> APIClient {
        let env = AppEnvironment(
            baseURL: session.baseURL,
            cfAccessClientID: nil,
            cfAccessClientToken: nil,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        return APIClient(
            environment: env,
            keychain: InMemoryKeychain(),
            sessionConfiguration: session.configuration
        )
    }

    // MARK: - Multipart body

    @Test("multipart body carries the `file` field with zip content-type")
    func multipartBodyShape() throws {
        let payload = Data("ZIPBYTES".utf8)
        let body = AppleHealthImportService.multipartBody(
            fileData: payload,
            fileName: "export.zip",
            fieldName: "file",
            boundary: "BOUND"
        )
        let text = try #require(String(bytes: body, encoding: .utf8))
        #expect(text.contains("--BOUND\r\n"))
        #expect(text.contains("name=\"file\"; filename=\"export.zip\""))
        #expect(text.contains("Content-Type: application/zip"))
        #expect(text.contains("ZIPBYTES"))
        #expect(text.hasSuffix("--BOUND--\r\n"))
    }

    // MARK: - Upload decode (real 202 envelope)

    @Test("upload decodes the kickoff 202 envelope")
    func uploadDecodesKickoff() async throws {
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let api = makeClient(session: session)
        // The capture used to be an unsafely-nonisolated `var` written from a
        // `@Sendable` closure on the process-global slot: unsynchronized, and
        // movable by any suite running in parallel. It is now `Mutex`-backed,
        // gated on this endpoint, and reachable only through this test's own
        // session.
        let capturedContentType = HeaderBox()
        let calls = Counter()
        session.install { req in
            guard req.targets("/api/import/apple-health-export", method: "POST") else {
                return respond(req, "{}")
            }
            calls.bump()
            capturedContentType.record(req.value(forHTTPHeaderField: "Content-Type"))
            let body = #"{"data":{"jobId":"ij-1","status":"queued"}}"#
            return (
                HTTPURLResponse(url: req.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!,
                Data(body.utf8)
            )
        }

        // A throwaway temp file stands in for the picked export.zip.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ahi-test-\(UUID().uuidString).zip")
        try Data("PK\u{03}\u{04}zip".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let service = AppleHealthImportService(api: api)
        let kickoff = try await service.upload(fileURL: tmp)

        #expect(kickoff.jobId == "ij-1")
        #expect(kickoff.status == "queued")
        #expect(capturedContentType.value?.hasPrefix("multipart/form-data; boundary=") == true)
        // The upload endpoint, once, on this test's own session. A `nil` capture
        // reads the same whether the header was absent or the request never
        // arrived; the count separates them.
        #expect(calls.value == 1)
    }

    @Test("upload surfaces the idempotent re-upload flag")
    func uploadIdempotentHit() async throws {
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let api = makeClient(session: session)
        session.install { req in
            let body = #"{"data":{"jobId":"ij-prev","status":"done","idempotent":true}}"#
            return (
                HTTPURLResponse(url: req.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!,
                Data(body.utf8)
            )
        }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ahi-test-\(UUID().uuidString).zip")
        try Data("zip".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let kickoff = try await AppleHealthImportService(api: api).upload(fileURL: tmp)
        #expect(kickoff.idempotent == true)
        #expect(kickoff.jobId == "ij-prev")
    }

    // MARK: - Status decode (real envelope)

    @Test("status decodes the full ImportJobStatusResponse envelope")
    func statusDecodesFullShape() async throws {
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let api = makeClient(session: session)
        session.install { req in
            let body = """
            {"data":{"jobId":"ij-1","status":"parsing","startedAt":"2026-05-15T10:00:00.000Z",
            "completedAt":null,"uploadBytes":12345,"exportedAt":null,
            "progress":{"currentPhase":"parsing","recordsRead":100,"rowsUpserted":0,"percent":null,"elapsedMs":1500},
            "result":null,"failureReason":null}}
            """
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(body.utf8)
            )
        }
        let req = APIRequest<AppleHealthImportStatusDTO>.get("/api/import/apple-health-export/ij-1/status")
        let status = try await api.send(req)
        #expect(status.status == .parsing)
        #expect(status.uploadBytes == 12345)
        #expect(status.progress?.recordsRead == 100)
        #expect(status.progress?.percent == nil)
        #expect(status.result == nil)
    }

    @Test("status decodes the terminal `done` result with per-type stats")
    func statusDecodesDoneResult() async throws {
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let api = makeClient(session: session)
        session.install { req in
            let body = """
            {"data":{"jobId":"ij-1","status":"done","startedAt":"2026-05-15T10:00:00.000Z",
            "completedAt":"2026-05-15T10:05:00.000Z","uploadBytes":999,"exportedAt":"2026-05-14T00:00:00.000Z",
            "progress":{"currentPhase":"upserting","recordsRead":500,"rowsUpserted":480,"percent":100,"elapsedMs":300000},
            "result":{"perType":{"HKQuantityTypeIdentifierHeartRate":{"read":200,"inserted":190,"updated":10,"durationMs":1200}},
            "totals":{"recordsRead":500,"rowsUpserted":480,"durationMs":300000}},
            "failureReason":null}}
            """
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(body.utf8)
            )
        }
        let req = APIRequest<AppleHealthImportStatusDTO>.get("/api/import/apple-health-export/ij-1/status")
        let status = try await api.send(req)
        #expect(status.status == .done)
        #expect(status.status.isTerminal)
        #expect(status.result?.totals?.recordsRead == 500)
        #expect(status.result?.totals?.rowsUpserted == 480)
        #expect(status.result?.perType?["HKQuantityTypeIdentifierHeartRate"]?.inserted == 190)
    }

    @Test("unknown server phase decodes to .other without throwing")
    func unknownPhaseTolerated() throws {
        let json = #"{"jobId":"x","status":"reticulating","startedAt":"t","uploadBytes":0}"#
        let dto = try JSONDecoder().decode(AppleHealthImportStatusDTO.self, from: Data(json.utf8))
        #expect(dto.status == .other)
        #expect(!dto.status.isTerminal)
    }

    // MARK: - Poll termination

    @Test("poll terminates on `done`")
    func pollTerminatesOnDone() async throws {
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let api = makeClient(session: session)
        session.install { req in
            let body = """
            {"data":{"jobId":"ij-1","status":"done","startedAt":"t","completedAt":"t2","uploadBytes":1,
            "exportedAt":null,"progress":{},"result":{"totals":{"recordsRead":3,"rowsUpserted":3,"durationMs":1}},
            "failureReason":null}}
            """
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(body.utf8)
            )
        }
        // Tiny interval so the test is instant.
        let service = AppleHealthImportService(api: api, maxPolls: 5, pollIntervalNanos: 1)
        let terminal = try await service.poll(jobId: "ij-1") { _ in }
        #expect(terminal.status == .done)
    }

    @Test("poll terminates on `failed` and carries the failure reason")
    func pollTerminatesOnFailed() async throws {
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let api = makeClient(session: session)
        session.install { req in
            let body = """
            {"data":{"jobId":"ij-1","status":"failed","startedAt":"t","completedAt":"t2","uploadBytes":1,
            "exportedAt":null,"progress":{},"result":null,"failureReason":"export.xml not found in archive"}}
            """
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(body.utf8)
            )
        }
        let service = AppleHealthImportService(api: api, maxPolls: 5, pollIntervalNanos: 1)
        let terminal = try await service.poll(jobId: "ij-1") { _ in }
        #expect(terminal.status == .failed)
        #expect(terminal.failureReason == "export.xml not found in archive")
    }

    @Test("poll throws timedOut when the budget is exhausted on a non-terminal phase")
    func pollTimesOut() async throws {
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let api = makeClient(session: session)
        session.install { req in
            let body = """
            {"data":{"jobId":"ij-1","status":"parsing","startedAt":"t","completedAt":null,"uploadBytes":1,
            "exportedAt":null,"progress":{"percent":40},"result":null,"failureReason":null}}
            """
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(body.utf8)
            )
        }
        let service = AppleHealthImportService(api: api, maxPolls: 2, pollIntervalNanos: 1)
        let updates = UpdateCounter()
        await #expect(throws: AppleHealthImportError.timedOut) {
            _ = try await service.poll(jobId: "ij-1") { _ in updates.bump() }
        }
        // Each non-terminal poll emits one snapshot; the budget is 2.
        #expect(updates.value == 2)
    }

    // MARK: - Transport ownership (issue #82 / Plan 09-11)

    @Test("a handler installed after ours cannot answer this suite's request")
    func aLaterInstallCannotAnswerThisSuite() async throws {
        // The failure this migration removes: a suite running in parallel
        // replaces the handler between our install and our request, so our
        // request is answered by a foreign closure and our capture stays nil.
        // Here the foreign install happens *after* ours — deterministically the
        // losing order under one process-global slot — and must still not be
        // reached.
        let session = MockURLProtocolSession()
        let foreign = MockURLProtocolSession()
        defer {
            session.invalidate()
            foreign.invalidate()
        }
        let mine = Counter()
        let theirs = Counter()
        session.install { req in
            guard req.targets(prefixedBy: "/api/import/apple-health-export") else {
                return respond(req, "{}")
            }
            mine.bump()
            return respond(req, #"{"data":{"jobId":"ij-session","status":"queued"}}"#, status: 202)
        }
        foreign.install { req in
            theirs.bump()
            return respond(req, "{}")
        }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ahi-session-\(UUID().uuidString).zip")
        try Data("zip".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // `try?`, deliberately: an unrouted request makes `upload` throw, and a
        // thrown error would fail the case *without* recording the reason this
        // property is about. Folding it into an optional keeps the failure an
        // assertion with exactly one stated reason.
        let kickoff = try? await AppleHealthImportService(api: makeClient(session: session)).upload(fileURL: tmp)

        // A positive count is the whole point: a thrown transport error and a
        // server refusal are indistinguishable from the decoded envelope alone.
        #expect(mine.value == 1, "EXPECTED_RED: AppleHealthImportServiceTests was not routed to its own session")
        #expect(theirs.value == 0)
        #expect(kickoff?.jobId == "ij-session")
    }
}

/// Thread-safe counter for the poll-callback in ``pollTimesOut`` — the callback
/// is `@Sendable` so a plain captured `var` trips strict concurrency. `Mutex`
/// rather than an `NSLock` behind an unchecked-`Sendable` conformance
/// (Plan 09-11): checked concurrency instead of a promise the compiler cannot
/// verify.
private final class UpdateCounter: Sendable {
    private let count = Mutex(0)

    func bump() {
        count.withLock { $0 += 1 }
    }

    var value: Int {
        count.withLock { $0 }
    }
}

/// Handler-side request counter, owned by the session that installs the handler
/// (Plan 09-11).
private final class Counter: Sendable {
    private let count = Mutex(0)

    func bump() {
        count.withLock { $0 += 1 }
    }

    var value: Int {
        count.withLock { $0 }
    }
}

/// Handler-side capture of one header value, owned by the session that installs
/// the handler. Replaces an unsafely-nonisolated `var` (Plan 09-11).
private final class HeaderBox: Sendable {
    private let stored = Mutex<String?>(nil)

    var value: String? {
        stored.withLock { $0 }
    }

    func record(_ header: String?) {
        stored.withLock { $0 = header }
    }
}

/// File-scope so a `@Sendable` handler closure running on the URL-loading queue
/// can call it without isolation ceremony.
private func respond(_ req: URLRequest, _ json: String, status: Int = 200) -> (HTTPURLResponse, Data?) {
    let http = HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    return (http, Data(json.utf8))
}

// swiftlint:enable force_unwrapping force_try
