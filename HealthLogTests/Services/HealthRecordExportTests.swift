import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **CU-11 — health-record export request contract (server v1.32.39).**
///
/// Pins `POST /api/export/health-record` against the *real* `APIClient` with a
/// stubbed `URLSession` (`MockURLProtocol`) — never a mock server (PROJECT_GUIDE.md) —
/// so schema drift surfaces here rather than as a `422` on a user's phone.
///
/// The live break this suite locks down: the strict schema lost the grouped
/// `sections` object and `includeAiSummary`, and gained a **required**
/// `selection`. Sending the old body 422'd on the unknown-key check; sending no
/// selection 422s on the required-field check. Both are asserted, so
/// reintroducing either shape fails a test instead of a download.
@Suite("HealthRecordExport", .serialized)
struct HealthRecordExportTests {
    private func makeAPI(keychain: InMemoryKeychain = InMemoryKeychain()) -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            cfAccessClientID: nil,
            cfAccessClientToken: nil,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock())
    }

    /// URLProtocol moves `httpBody` onto `httpBodyStream`; re-materialize either.
    private nonisolated static func body(of req: URLRequest) -> Data {
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
    private static let fixtureLeaves = ["WEIGHT", "BLOOD_PRESSURE_SYS", "LAB_RESULTS", "MEDICATION_LIST"]

    // MARK: - Request encode (strict)

    @Test("package request encodes exactly the documented keys, selection included")
    func packageRequestStrictEncode() throws {
        let request = HealthRecordExportRequest(
            format: .package,
            selection: ReportSelection(leaves: Self.fixtureLeaves),
            range: HealthRecordExportRequest.Range(days: 90),
            includeCharts: true
        )
        let data = try JSONEncoder.hlDefault.encode(request)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(Set(json.keys) == ["format", "selection", "range", "includeCharts"])
        #expect(json["format"] as? String == "package")
        #expect(json["includeCharts"] as? Bool == true)

        let selection = try #require(json["selection"] as? [String: Any])
        #expect(Set(selection.keys) == ["v", "leaves"])
        #expect(selection["v"] as? Int == 2)
        #expect(selection["leaves"] as? [String] == Self.fixtureLeaves)

        let range = try #require(json["range"] as? [String: Any])
        #expect(range["days"] as? Int == 90)
        #expect(range["startDate"] == nil)
        #expect(json["userId"] == nil)
    }

    /// **The regression guard for the live 422.** Every key the v1.32.39 schema
    /// removed must be absent from the encoded body — reintroducing `sections`
    /// (or `includeAiSummary`) fails right here.
    @Test("the retired sections tree and includeAiSummary never reach the wire")
    func retiredKeysAreGone() throws {
        for format in ReportFormat.allCases {
            let request = HealthRecordExportRequest(
                format: format,
                selection: ReportSelection(leaves: Self.fixtureLeaves),
                range: HealthRecordExportRequest.Range(days: 30),
                locale: "de",
                practiceName: "Praxis Muster",
                includeCharts: false,
                germanAtc: true
            )
            let data = try JSONEncoder.hlDefault.encode(request)
            let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(json["sections"] == nil)
            #expect(json["includeAiSummary"] == nil)
            // Everything that IS still accepted by `exportSelectionSchema`.
            #expect(Set(json.keys) == [
                "format", "selection", "range", "locale", "practiceName", "includeCharts", "germanAtc"
            ])
        }
    }

    @Test("an empty selection is legal and encodes as an empty leaves array")
    func emptySelectionIsLegal() throws {
        let request = HealthRecordExportRequest(format: .pdf, selection: .empty)
        let data = try JSONEncoder.hlDefault.encode(request)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(json.keys) == ["format", "selection"])
        let selection = try #require(json["selection"] as? [String: Any])
        #expect(selection["v"] as? Int == 2)
        #expect((selection["leaves"] as? [String])?.isEmpty == true)
    }

    // MARK: - Download

    @Test("package download posts to /api/export/health-record with application/zip Accept")
    func packageDownload() async throws {
        let kc = InMemoryKeychain()
        try kc.setString("hlk_test", forKey: KeychainKey.authToken)
        let api = makeAPI(keychain: kc)

        nonisolated(unsafe) var capturedPath: String?
        nonisolated(unsafe) var capturedAccept: String?
        nonisolated(unsafe) var capturedMethod: String?
        nonisolated(unsafe) var capturedBody: Data?
        MockURLProtocol.handler = { req in
            capturedPath = req.url?.path
            capturedAccept = req.value(forHTTPHeaderField: "Accept")
            capturedMethod = req.httpMethod
            capturedBody = Self.body(of: req)
            let headers = [
                "Content-Type": "application/zip",
                "Content-Disposition": "attachment; filename=\"healthlog-health-record-2026-06-05.zip\""
            ]
            let http = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!
            return (http, Data("PK\u{03}\u{04}zipbytes".utf8))
        }

        let service = ExportService(api: api)
        let export = try await service.downloadHealthRecordPackage(
            HealthRecordExportRequest(
                format: .package,
                selection: ReportSelection(leaves: Self.fixtureLeaves),
                range: .init(days: 30)
            )
        )

        #expect(capturedPath == "/api/export/health-record")
        #expect(capturedMethod == "POST")
        #expect(capturedAccept == "application/zip")
        #expect(export.suggestedFilename == "healthlog-health-record-2026-06-05.zip")
        #expect(!export.data.isEmpty)

        // The body that actually left the client carries the strict shape.
        let json = try #require(
            JSONSerialization.jsonObject(with: capturedBody ?? Data()) as? [String: Any]
        )
        #expect(Set(json.keys) == ["format", "selection", "range"])
        #expect(json["sections"] == nil)
    }

    @Test("non-zip Content-Type is rejected")
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
        let service = ExportService(api: api)
        await #expect(throws: HLError.self) {
            _ = try await service.downloadHealthRecordPackage(
                HealthRecordExportRequest(format: .package, selection: .empty)
            )
        }
    }

    @Test("missing Content-Disposition → deterministic local filename")
    func filenameFallback() async throws {
        let api = makeAPI()
        MockURLProtocol.handler = { req in
            let http = HTTPURLResponse(
                url: req.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/zip"]
            )!
            return (http, Data("PKzip".utf8))
        }
        let service = ExportService(api: api)
        let export = try await service.downloadHealthRecordPackage(
            HealthRecordExportRequest(format: .package, selection: .empty)
        )
        #expect(export.suggestedFilename.hasPrefix("healthlog-health-record-"))
        #expect(export.suggestedFilename.hasSuffix(".zip"))
    }

    @Test("429 surfaces as HLError.rateLimited (shared export bucket)")
    func rateLimited() async {
        let api = makeAPI()
        MockURLProtocol.handler = { req in
            let http = HTTPURLResponse(url: req.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!
            return (http, Data("{}".utf8))
        }
        let service = ExportService(api: api)
        await #expect(throws: HLError.self) {
            _ = try await service.downloadHealthRecordPackage(
                HealthRecordExportRequest(format: .package, selection: .empty)
            )
        }
    }

    // MARK: - 422 export.selection.unknown_leaf

    @Test("422 export.selection.unknown_leaf maps to the typed contract mismatch")
    func unknownLeafIsTyped() async {
        let api = makeAPI()
        MockURLProtocol.handler = { req in
            let http = HTTPURLResponse(url: req.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!
            let body = """
            {"error":"Unknown selection leaf: NOT_A_LEAF",
             "meta":{"errorCode":"export.selection.unknown_leaf"}}
            """
            return (http, Data(body.utf8))
        }
        let service = ExportService(api: api)
        await #expect(throws: HealthRecordExportError.unknownLeaf) {
            _ = try await service.downloadHealthRecordPackage(
                HealthRecordExportRequest(
                    format: .package,
                    selection: ReportSelection(leaves: ["NOT_A_LEAF"])
                )
            )
        }
    }

    /// Belt and braces for the wire-shape difference CU-01 surfaced: the
    /// sibling `report-selection` routes `throw HttpError(422, "<code>")`, which
    /// `api-handler.ts` serialises as a bare `error` string with no `meta`. This
    /// route returns `apiError(…, { errorCode })` today, so the code arrives in
    /// `meta.errorCode` — but if it is ever rewritten to match its sibling, the
    /// code moves into the `error` string and iOS must still recognise it.
    @Test("the same code carried in the bare error string is recognised too")
    func unknownLeafInErrorString() async {
        let api = makeAPI()
        MockURLProtocol.handler = { req in
            let http = HTTPURLResponse(url: req.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!
            return (http, Data(#"{"data":null,"error":"export.selection.unknown_leaf"}"#.utf8))
        }
        let service = ExportService(api: api)
        await #expect(throws: HealthRecordExportError.unknownLeaf) {
            _ = try await service.downloadHealthRecordPackage(
                HealthRecordExportRequest(format: .package, selection: ReportSelection(leaves: ["NOT_A_LEAF"]))
            )
        }
    }

    @Test("an unrelated 422 keeps its HLError identity — no over-claiming")
    func unrelated422PassesThrough() async {
        let api = makeAPI()
        MockURLProtocol.handler = { req in
            let http = HTTPURLResponse(url: req.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!
            return (http, Data(#"{"error":"Invalid range"}"#.utf8))
        }
        let service = ExportService(api: api)
        await #expect(throws: HLError.self) {
            _ = try await service.downloadHealthRecordPackage(
                HealthRecordExportRequest(format: .package, selection: .empty)
            )
        }
    }
}

// swiftlint:enable force_unwrapping
