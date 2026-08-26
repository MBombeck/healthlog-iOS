import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **v0.11 W9 — ExportService contract.**
///
/// Pins the per-domain CSV export against the *real* `APIClient` with a stubbed
/// `URLSession` (`MockURLProtocol`) — never a mock server (PROJECT_GUIDE.md: export
/// paths must exercise the real request-building + response-handling so schema
/// drift surfaces). Covers: path/Accept/auth wiring per domain, the medication
/// query passthrough, Content-Disposition filename parsing (+ fallback), the
/// Content-Type guard, and graceful 429 rate-limit surfacing.
@Suite("ExportService", .serialized)
struct ExportServiceTests {
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

    private func csvResponse(
        for req: URLRequest,
        filename: String? = "healthlog-measurements-u1-2026-06-02.csv",
        contentType: String = "text/csv; charset=utf-8"
    ) -> (HTTPURLResponse, Data) {
        var headers = ["Content-Type": contentType]
        if let filename {
            headers["Content-Disposition"] = "attachment; filename=\"\(filename)\""
        }
        let http = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!
        return (http, Data("date,value\n2026-06-02,72\n".utf8))
    }

    @Test("measurements → GET /api/export/measurements with text/csv Accept + Bearer")
    func measurementsRequest() async throws {
        let kc = InMemoryKeychain()
        try kc.setString("hlk_test", forKey: KeychainKey.authToken)
        let api = makeAPI(keychain: kc)

        nonisolated(unsafe) var capturedPath: String?
        nonisolated(unsafe) var capturedAccept: String?
        nonisolated(unsafe) var capturedAuth: String?
        MockURLProtocol.handler = { req in
            capturedPath = req.url?.path
            capturedAccept = req.value(forHTTPHeaderField: "Accept")
            capturedAuth = req.value(forHTTPHeaderField: "Authorization")
            return csvResponse(for: req)
        }

        let service = ExportService(api: api)
        let export = try await service.downloadCSV(.measurements)

        #expect(capturedPath == "/api/export/measurements")
        #expect(capturedAccept == "text/csv")
        #expect(capturedAuth == "Bearer hlk_test")
        #expect(!export.data.isEmpty)
    }

    @Test("mood + medications resolve their own paths")
    func domainPaths() async throws {
        let api = makeAPI()
        nonisolated(unsafe) var capturedPath: String?
        MockURLProtocol.handler = { req in
            capturedPath = req.url?.path
            return csvResponse(for: req)
        }
        let service = ExportService(api: api)

        _ = try await service.downloadCSV(.mood)
        #expect(capturedPath == "/api/export/mood")

        _ = try await service.downloadCSV(.medications)
        #expect(capturedPath == "/api/export/medications")
    }

    @Test("medications query filters pass through as URL query items")
    func medicationQueryPassthrough() async throws {
        let api = makeAPI()
        nonisolated(unsafe) var capturedQuery: String?
        MockURLProtocol.handler = { req in
            capturedQuery = req.url?.query
            return csvResponse(for: req)
        }
        let service = ExportService(api: api)
        _ = try await service.downloadCSV(.medications, query: [("medicationId", "med-1"), ("intake", "true")])

        let query = try #require(capturedQuery)
        #expect(query.contains("medicationId=med-1"))
        #expect(query.contains("intake=true"))
    }

    @Test("Content-Disposition filename is parsed from the response")
    func filenameFromDisposition() async throws {
        let api = makeAPI()
        MockURLProtocol.handler = { req in
            csvResponse(for: req, filename: "healthlog-mood-u9-2026-06-02.csv")
        }
        let service = ExportService(api: api)
        let export = try await service.downloadCSV(.mood)
        #expect(export.suggestedFilename == "healthlog-mood-u9-2026-06-02.csv")
    }

    @Test("missing Content-Disposition → deterministic local filename")
    func filenameFallback() async throws {
        let api = makeAPI()
        MockURLProtocol.handler = { req in
            csvResponse(for: req, filename: nil)
        }
        let service = ExportService(api: api)
        let export = try await service.downloadCSV(.measurements)
        #expect(export.suggestedFilename.hasPrefix("healthlog-measurements-"))
        #expect(export.suggestedFilename.hasSuffix(".csv"))
    }

    @Test("non-CSV Content-Type is rejected (schema-drift guard)")
    func contentTypeGuard() async throws {
        let api = makeAPI()
        MockURLProtocol.handler = { req in
            let http = HTTPURLResponse(
                url: req.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (http, Data(#"{"error":"nope"}"#.utf8))
        }
        let service = ExportService(api: api)
        await #expect(throws: HLError.self) {
            _ = try await service.downloadCSV(.measurements)
        }
    }

    @Test("429 surfaces as HLError.rateLimited (10/h limit), not a crash")
    func rateLimitSurfacing() async throws {
        let api = makeAPI()
        MockURLProtocol.handler = { req in
            // Reset already elapsed → retryAfter floors to 0, no long sleep;
            // after maxRetries the client throws .rateLimited.
            let http = HTTPURLResponse(
                url: req.url!,
                statusCode: 429,
                httpVersion: nil,
                headerFields: ["X-RateLimit-Reset": "2000-01-01T00:00:00Z"]
            )!
            return (http, Data())
        }
        let service = ExportService(api: api)
        do {
            _ = try await service.downloadCSV(.measurements)
            Issue.record("expected rateLimited throw")
        } catch let error as HLError {
            guard case .rateLimited = error else {
                Issue.record("expected .rateLimited, got \(error)")
                return
            }
        }
    }

    // MARK: - AUD-7 H3 — full backup (POST /api/export) is service-owned

    @Test("full backup → POST /api/export with format body + Accept (AUD-7 H3)")
    func fullBackupRequest() async throws {
        let kc = InMemoryKeychain()
        try kc.setString("hlk_test", forKey: KeychainKey.authToken)
        let api = makeAPI(keychain: kc)

        nonisolated(unsafe) var capturedPath: String?
        nonisolated(unsafe) var capturedMethod: String?
        nonisolated(unsafe) var capturedAccept: String?
        MockURLProtocol.handler = { req in
            capturedPath = req.url?.path
            capturedMethod = req.httpMethod
            capturedAccept = req.value(forHTTPHeaderField: "Accept")
            let http = HTTPURLResponse(
                url: req.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (http, Data(#"{"measurements":[]}"#.utf8))
        }

        let service = ExportService(api: api)
        let export = try await service.downloadFullBackup(.json)

        // The exact path that 404'd before (W2a-A2 §8) must be `/api/export`,
        // never `/api/data/export`.
        #expect(capturedPath == "/api/export")
        #expect(capturedMethod == "POST")
        #expect(capturedAccept == "application/json")
        #expect(export.fileExtension == "json")
        #expect(!export.data.isEmpty)
    }

    @Test("full backup CSV format sends text/csv Accept (AUD-7 H3)")
    func fullBackupCSVFormat() async throws {
        let api = makeAPI()
        nonisolated(unsafe) var capturedAccept: String?
        MockURLProtocol.handler = { req in
            capturedAccept = req.value(forHTTPHeaderField: "Accept")
            let http = HTTPURLResponse(
                url: req.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "text/csv"]
            )!
            return (http, Data("a,b\n1,2\n".utf8))
        }
        let service = ExportService(api: api)
        let export = try await service.downloadFullBackup(.csv)
        #expect(capturedAccept == "text/csv")
        #expect(export.fileExtension == "csv")
    }

    @Test("RFC 5987 extended filename* form is decoded")
    func filenameExtendedForm() throws {
        let url = try #require(URL(string: "https://x"))
        let http = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Disposition": "attachment; filename*=UTF-8''healthlog-m%C3%A4ss.csv"]
        ))
        let name = ExportService.filename(from: http, domain: .measurements)
        #expect(name == "healthlog-mäss.csv")
    }
}

// swiftlint:enable force_unwrapping
