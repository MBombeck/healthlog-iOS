import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// Locks `GET | PUT /api/auth/me/report-selection` (CU-01).
///
/// The route is **not in the OpenAPI** — the shape asserted here is the one
/// named in the catch-up brief (block A2) and nothing more:
/// `PUT` body `{ v: 2, leaves, format, rangeDays, includeCharts }`, strict,
/// full replace; `GET`/`PUT` answer `{ profile: … | null }`.
///
/// `.serialized` — every case installs the process-global
/// ``MockURLProtocol/handler``, and the round-trip case depends on seeing only
/// its own requests, in order.
@Suite("ReportSelectionRepository — /api/auth/me/report-selection", .serialized)
struct ReportSelectionRepositoryTests {
    private func makeRepo() -> ReportSelectionRepository {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.5.0",
            buildNumber: "1"
        )
        return ReportSelectionRepository(
            api: APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
        )
    }

    private static func ok(_ req: URLRequest, _ json: String) -> (HTTPURLResponse, Data?) {
        (
            HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
            Data(json.utf8)
        )
    }

    private static func failure(_ req: URLRequest, status: Int, code: String) -> (HTTPURLResponse, Data?) {
        // The server route throws `HttpError(422, "<code>")` and the handler
        // serialises the message verbatim into the envelope's top-level `error`
        // string — there is no `meta.errorCode` on this shape.
        (
            HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
            Data(#"{"data":null,"error":"\#(code)"}"#.utf8)
        )
    }

    private static let sampleProfile = SavedReportProfile(
        selection: ReportSelection(leaves: ["PATIENT_IDENTITY", "WEIGHT", "LAB_RESULTS"]),
        format: .pdf,
        rangeDays: 90,
        includeCharts: true
    )

    // MARK: - Round-trip

    @Test("round-trip: GET (never saved) → PUT → GET returns the saved profile")
    func roundTrip() async throws {
        let repo = makeRepo()
        nonisolated(unsafe) var calls: [(method: String, path: String)] = []
        nonisolated(unsafe) var stored: String?
        nonisolated(unsafe) var putBody: Data?

        MockURLProtocol.handler = { req in
            calls.append((req.httpMethod ?? "?", req.url?.path ?? ""))
            if req.httpMethod == "PUT" {
                putBody = req.materializedBody()
                let persisted = #"""
                {"v":2,"leaves":["PATIENT_IDENTITY","WEIGHT","LAB_RESULTS"],
                "format":"pdf","rangeDays":90,"includeCharts":true}
                """#
                stored = persisted
                return Self.ok(req, #"{"data":{"profile":\#(persisted)},"error":null}"#)
            }
            guard let stored else {
                // The honest "this account has never saved one" answer.
                return Self.ok(req, #"{"data":{"profile":null},"error":null}"#)
            }
            return Self.ok(req, #"{"data":{"profile":\#(stored)},"error":null}"#)
        }

        // 1 — empty
        #expect(try await repo.fetch() == nil)

        // 2 — write
        let echoed = try await repo.replace(Self.sampleProfile)
        #expect(echoed == Self.sampleProfile)

        // 3 — read back
        let reloaded = try await repo.fetch()
        #expect(reloaded == Self.sampleProfile)
        #expect(reloaded?.selection.leaves == ["PATIENT_IDENTITY", "WEIGHT", "LAB_RESULTS"])

        #expect(calls.map(\.method) == ["GET", "PUT", "GET"])
        #expect(calls.allSatisfy { $0.path == "/api/auth/me/report-selection" })
        #expect(calls.contains { $0.method == "PATCH" } == false, "replace, never merge")

        // The body is exactly the five strict-schema keys.
        let sentBody = try #require(putBody)
        let object = try #require(
            JSONSerialization.jsonObject(with: sentBody) as? [String: Any]
        )
        #expect(object.keys.sorted() == ["format", "includeCharts", "leaves", "rangeDays", "v"])
        #expect(object["v"] as? Int == 2)
        #expect(object["leaves"] as? [String] == ["PATIENT_IDENTITY", "WEIGHT", "LAB_RESULTS"])
        #expect(object["format"] as? String == "pdf")
        #expect(object["rangeDays"] as? Int == 90)
        #expect(object["includeCharts"] as? Bool == true)
    }

    @Test("a missing `profile` key reads as 'never saved', same as an explicit null")
    func missingProfileKeyIsNil() async throws {
        let repo = makeRepo()
        MockURLProtocol.handler = { req in Self.ok(req, #"{"data":{},"error":null}"#) }
        #expect(try await repo.fetch() == nil)
    }

    @Test("the server's canonical leaf ordering is adopted, not the caller's")
    func adoptsServerOrdering() async throws {
        let repo = makeRepo()
        MockURLProtocol.handler = { req in
            Self.ok(req, #"""
            {"data":{"profile":{"v":2,"leaves":["PATIENT_IDENTITY","WEIGHT"],
            "format":"pdf","rangeDays":30,"includeCharts":false}},"error":null}
            """#)
        }
        let echoed = try await repo.replace(
            SavedReportProfile(
                selection: ReportSelection(leaves: ["WEIGHT", "PATIENT_IDENTITY"]),
                format: .pdf,
                rangeDays: 30,
                includeCharts: false
            )
        )
        #expect(echoed.selection.leaves == ["PATIENT_IDENTITY", "WEIGHT"])
    }

    // MARK: - The three 422 classes

    @Test(
        "each documented 422 surfaces as its own typed error",
        arguments: [
            ("report-selection.body.invalid_json", ReportSelectionError.invalidJSON),
            ("report-selection.body.invalid_shape", ReportSelectionError.invalidShape),
            ("report-selection.leaves.unknown", ReportSelectionError.unknownLeaves)
        ]
    )
    func typed422s(wireCode: String, expected: ReportSelectionError) async {
        let repo = makeRepo()
        MockURLProtocol.handler = { req in Self.failure(req, status: 422, code: wireCode) }
        await #expect(throws: expected) {
            try await repo.replace(Self.sampleProfile)
        }
        #expect(expected.wireCode == wireCode)
    }

    @Test("the three classes are distinguishable from one another")
    func classesAreDistinct() {
        let all: [ReportSelectionError] = [.invalidJSON, .invalidShape, .unknownLeaves]
        #expect(Set(all.map(\.wireCode)).count == 3)
        #expect(ReportSelectionError.invalidJSON != .invalidShape)
        #expect(ReportSelectionError.invalidShape != .unknownLeaves)
    }

    @Test("the code is also honoured if a later server promotes it into meta.errorCode")
    func metaErrorCodeIsHonoured() async {
        let repo = makeRepo()
        MockURLProtocol.handler = { req in
            (
                HTTPURLResponse(url: req.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!,
                Data(#"""
                {"data":null,"error":"Unprocessable",
                "meta":{"errorCode":"report-selection.leaves.unknown"}}
                """#.utf8)
            )
        }
        await #expect(throws: ReportSelectionError.unknownLeaves) {
            try await repo.replace(Self.sampleProfile)
        }
    }

    @Test("an unrelated 422 passes through untouched — no class is invented")
    func unrelated422PassesThrough() async {
        let repo = makeRepo()
        MockURLProtocol.handler = { req in Self.failure(req, status: 422, code: "something.else") }
        await #expect(throws: HLError.server(status: 422, code: nil, message: "something.else")) {
            try await repo.replace(Self.sampleProfile)
        }
    }

    @Test("a non-422 carrying one of the codes is NOT reclassified")
    func wrongStatusIsNotReclassified() async {
        let repo = makeRepo()
        MockURLProtocol.handler = { req in
            Self.failure(req, status: 403, code: "report-selection.leaves.unknown")
        }
        do {
            _ = try await repo.replace(Self.sampleProfile)
            Issue.record("expected the 403 to throw")
        } catch let error as ReportSelectionError {
            Issue.record("403 was reclassified as \(error)")
        } catch {
            #expect(error is HLError)
        }
    }

    @Test("GET maps the unknown-leaf 422 too")
    func getAlsoMaps422() async {
        let repo = makeRepo()
        MockURLProtocol.handler = { req in
            Self.failure(req, status: 422, code: "report-selection.body.invalid_shape")
        }
        await #expect(throws: ReportSelectionError.invalidShape) {
            try await repo.fetch()
        }
    }
}

// swiftlint:enable force_unwrapping

private extension URLRequest {
    /// `URLProtocol` moves `httpBody` onto `httpBodyStream`; re-materialize
    /// either (same helper the auth-flow suites carry).
    func materializedBody() -> Data? {
        if let httpBody { return httpBody }
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
        return data.isEmpty ? nil : data
    }
}
