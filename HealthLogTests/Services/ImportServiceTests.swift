import Foundation
@testable import HealthLog
import Testing

/// 7.9 — the CSV/JSON data-import surface. Pins the dry-run envelope decode
/// (`{ inserted, updated, skipped, total, dryRun, rows }`) and the request the
/// ``ImportService`` builds for the CSV route: the POST path, the `dryRun=1`
/// query on preview, the `text/csv` Content-Type override (the route reads the
/// raw body, NOT JSON), and the verbatim CSV body.
@Suite("ImportService")
struct ImportServiceTests {
    /// Captures the `send` request and returns a canned result. `@unchecked
    /// Sendable` — actor-driven, serial.
    private final class CapturingSendClient: APIClientProtocol, @unchecked Sendable {
        var capturedPath: String?
        var capturedMethod: HTTPMethod?
        var capturedQuery: [(String, String)] = []
        var capturedContentType: String?
        var capturedBody: Data?
        let result: any Sendable

        init(result: any Sendable) {
            self.result = result
        }

        func send<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> T {
            capturedPath = request.path
            capturedMethod = request.method
            capturedQuery = request.query
            capturedContentType = request.extraHeaders["Content-Type"]
            capturedBody = request.body
            guard let typed = result as? T else {
                throw HLError.decoding("type mismatch")
            }
            return typed
        }

        func sendVoid(_: APIRequest<EmptyPayload>) async throws {}

        func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
            throw HLError.canceled
        }
    }

    private nonisolated static func cannedResult() -> CSVImportResult {
        CSVImportResult(inserted: 3, updated: 1, skipped: 2, total: 6, dryRun: true, rows: [])
    }

    // MARK: - Request shape

    @Test("Dry-run: POST /api/import/csv?dryRun=1 with text/csv body")
    func dryRunRequestShape() async throws {
        let client = CapturingSendClient(result: Self.cannedResult())
        let service = ImportService(api: client)

        let csv = "type,value,unit,measuredAt\nWEIGHT,80,kg,2026-07-01T08:00:00Z\n"
        let result = try await service.importCSV(csv, dryRun: true)

        #expect(client.capturedPath == "/api/import/csv")
        #expect(client.capturedMethod == .post)
        #expect(client.capturedContentType == "text/csv")
        #expect(client.capturedQuery.contains { $0.0 == "dryRun" && $0.1 == "1" })

        let body = try #require(client.capturedBody)
        #expect(String(data: body, encoding: .utf8) == csv)
        #expect(result.writeCount == 4)
    }

    @Test("Commit: no dryRun query is sent")
    func commitOmitsDryRun() async throws {
        let client = CapturingSendClient(
            result: CSVImportResult(inserted: 5, updated: 0, skipped: 0, total: 5, dryRun: false, rows: [])
        )
        let service = ImportService(api: client)
        _ = try await service.importCSV("a,b\n1,2\n", dryRun: false)
        #expect(client.capturedQuery.isEmpty)
    }

    // MARK: - DTO decode

    @Test("CSVImportResult decodes the dry-run envelope incl. per-row status")
    func csvResultDecode() throws {
        let json = Data(#"""
        {
            "inserted": 4,
            "updated": 2,
            "skipped": 1,
            "total": 7,
            "dryRun": true,
            "rows": [
                { "line": 2, "status": "inserted" },
                { "line": 3, "status": "skipped", "reason": "duplicate" }
            ]
        }
        """#.utf8)
        let result = try JSONDecoder.hlDefault.decode(CSVImportResult.self, from: json)
        #expect(result.inserted == 4)
        #expect(result.updated == 2)
        #expect(result.skipped == 1)
        #expect(result.total == 7)
        #expect(result.dryRun)
        #expect(result.rows.count == 2)
        #expect(result.rows.last?.reason == "duplicate")
        #expect(result.writeCount == 6)
    }

    @Test("CSVImportResult tolerates a missing rows array")
    func csvResultTolerantRows() throws {
        let json = Data(#"{ "inserted": 1, "updated": 0, "skipped": 0, "total": 1, "dryRun": false }"#.utf8)
        let result = try JSONDecoder.hlDefault.decode(CSVImportResult.self, from: json)
        #expect(result.rows.isEmpty)
        #expect(result.dryRun == false)
    }

    @Test("JSONImportResult decodes the restore stats")
    func jsonResultDecode() throws {
        let json = Data(#"{ "measurements": 120, "moodEntries": 30, "skipped": 5 }"#.utf8)
        let result = try JSONDecoder.hlDefault.decode(JSONImportResult.self, from: json)
        #expect(result.measurements == 120)
        #expect(result.moodEntries == 30)
        #expect(result.skipped == 5)
    }
}
