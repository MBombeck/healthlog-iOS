import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// v0141 W-DATAPARITY (P3) — pins `DoctorReportService.downloadPDF` against the
/// *real* `APIClient` with a stubbed `URLSession` (`MockURLProtocol`) — never a
/// mock server (PROJECT_GUIDE.md).
///
/// The legacy `POST /api/doctor-report/pdf` route was removed server-side, so
/// the server render 404'd and the screen silently fell back to the poorer
/// on-device renderer. The PDF now comes from the canonical
/// `POST /api/export/health-record` with `format: "pdf"` (strict
/// `exportSelectionSchema`).
///
/// **CU-11 — the second live break.** This call then sent `{format, range,
/// locale}` with **no `selection`**, which the v1.32.39 schema makes mandatory,
/// so every server render 422'd and the screen fell back for the wrong reason.
/// The suite now pins the required `selection` on the wire. Covers:
///   - the POST path + `format: "pdf"` + `selection` + `range.days` + `locale`,
///   - that `range` and `locale` are still sent (both remain `.optional()` on
///     the strict schema — verified against `health-record-export.ts` and the
///     OpenAPI, which is the gap the brief left open),
///   - the `application/pdf` Accept + Content-Type guard,
///   - a network error still bubbles as `HLError` so the screen's genuine
///     on-device fallback (`DoctorReportScreen.generate()`) can take over,
///   - `422 export.selection.unknown_leaf` arriving as the typed contract
///     mismatch rather than a generic server error.
@Suite("DoctorReportService — P3 canonical server-PDF route", .serialized)
struct DoctorReportServiceTests {
    private func makeAPI(keychain: InMemoryKeychain = InMemoryKeychain()) -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.14.1",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock())
    }

    /// URLProtocol moves `httpBody` onto `httpBodyStream`; re-materialize either.
    private static func body(of req: URLRequest) -> Data {
        req.httpBody ?? req.httpBodyStream.map { stream in
            stream.open()
            defer { stream.close() }
            var data = Data()
            let size = 4096
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            defer { buf.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buf, maxLength: size)
                if read <= 0 { break }
                data.append(buf, count: read)
            }
            return data
        } ?? Data()
    }

    /// Fixture leaf ids. **Test-only vocabulary** — production reads
    /// `capabilities.share.leaves` and never a list like this one.
    private static let fixtureLeaves = ["WEIGHT", "PULSE", "MEDICATION_LIST"]

    @Test("downloadPDF posts to /api/export/health-record with format:pdf, selection, range.days, locale")
    func postsToCanonicalRoute() async throws {
        let kc = InMemoryKeychain()
        try kc.setString("hlk_test", forKey: KeychainKey.authToken)
        let api = makeAPI(keychain: kc)

        nonisolated(unsafe) var capturedPath: String?
        nonisolated(unsafe) var capturedMethod: String?
        nonisolated(unsafe) var capturedAccept: String?
        nonisolated(unsafe) var capturedBody: Data?
        MockURLProtocol.handler = { req in
            capturedPath = req.url?.path
            capturedMethod = req.httpMethod
            capturedAccept = req.value(forHTTPHeaderField: "Accept")
            capturedBody = Self.body(of: req)
            let http = HTTPURLResponse(
                url: req.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/pdf"]
            )!
            return (http, Data("%PDF-1.7 bytes".utf8))
        }

        let service = DoctorReportService(api: api)
        let data = try await service.downloadPDF(
            days: 90,
            locale: "de",
            selection: ReportSelection(leaves: Self.fixtureLeaves)
        )

        #expect(!data.isEmpty)
        #expect(capturedPath == "/api/export/health-record")
        #expect(capturedMethod == "POST")
        #expect(capturedAccept == "application/pdf")

        let json = try #require(
            JSONSerialization.jsonObject(with: capturedBody ?? Data()) as? [String: Any]
        )
        #expect(json["format"] as? String == "pdf")
        #expect(json["locale"] as? String == "de")
        let range = try #require(json["range"] as? [String: Any])
        #expect(range["days"] as? Int == 90)

        // CU-11 — the required v2 selection, exactly `{ v, leaves }`.
        let selection = try #require(json["selection"] as? [String: Any])
        #expect(Set(selection.keys) == ["v", "leaves"])
        #expect(selection["v"] as? Int == 2)
        #expect(selection["leaves"] as? [String] == Self.fixtureLeaves)

        // Strict schema: no smuggled userId, no stray top-level `days`, and
        // none of the keys v1.32.39 removed.
        #expect(json["userId"] == nil)
        #expect(json["days"] == nil)
        #expect(json["sections"] == nil)
        #expect(json["includeAiSummary"] == nil)
        #expect(Set(json.keys) == ["format", "selection", "range", "locale"])
    }

    @Test("an empty selection is sent as-is — 'no health data' is a legal answer")
    func emptySelectionIsSent() async throws {
        let api = makeAPI()
        nonisolated(unsafe) var capturedBody: Data?
        MockURLProtocol.handler = { req in
            capturedBody = Self.body(of: req)
            let http = HTTPURLResponse(
                url: req.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/pdf"]
            )!
            return (http, Data("%PDF-1.7".utf8))
        }

        let service = DoctorReportService(api: api)
        _ = try await service.downloadPDF(days: 30, selection: .empty)

        let json = try #require(
            JSONSerialization.jsonObject(with: capturedBody ?? Data()) as? [String: Any]
        )
        let selection = try #require(json["selection"] as? [String: Any])
        #expect((selection["leaves"] as? [String])?.isEmpty == true)
    }

    @Test("422 export.selection.unknown_leaf surfaces as the typed contract mismatch")
    func unknownLeafIsTyped() async {
        let api = makeAPI()
        MockURLProtocol.handler = { req in
            let http = HTTPURLResponse(url: req.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!
            let body = """
            {"error":"Unknown selection leaf: NOPE","meta":{"errorCode":"export.selection.unknown_leaf"}}
            """
            return (http, Data(body.utf8))
        }
        let service = DoctorReportService(api: api)
        await #expect(throws: HealthRecordExportError.unknownLeaf) {
            _ = try await service.downloadPDF(days: 30, selection: ReportSelection(leaves: ["NOPE"]))
        }
    }

    @Test("non-pdf Content-Type is rejected (guards a drifted response)")
    func contentTypeGuard() async {
        let api = makeAPI()
        MockURLProtocol.handler = { req in
            let http = HTTPURLResponse(
                url: req.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html"]
            )!
            return (http, Data("<html>".utf8))
        }
        let service = DoctorReportService(api: api)
        await #expect(throws: HLError.self) {
            _ = try await service.downloadPDF(days: 30, selection: .empty)
        }
    }

    @Test("a server error bubbles as HLError so the on-device fallback can take over")
    func serverErrorBubbles() async {
        let api = makeAPI()
        MockURLProtocol.handler = { req in
            let http = HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (http, Data("{}".utf8))
        }
        let service = DoctorReportService(api: api)
        await #expect(throws: HLError.self) {
            _ = try await service.downloadPDF(days: 30, selection: .empty)
        }
    }
}

// swiftlint:enable force_unwrapping
