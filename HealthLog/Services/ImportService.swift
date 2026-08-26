import Foundation

/// Wraps the cold-start data-import routes (server v1.17.1). The self-hoster's
/// escape hatch for migrating from a spreadsheet or another tracker back into
/// their account.
///
/// - `POST /api/import/csv[?dryRun=1]` — a raw `text/csv` body (NOT JSON). With
///   `dryRun` the server parses + validates + returns the projected per-row
///   outcome WITHOUT writing — a trust win before a bulk restore. Response is
///   the JSON ``CSVImportResult`` envelope.
/// - `POST /api/import` — a JSON `{ measurements?, moodEntries? }` body matching
///   the export structure; restores the rows and returns ``JSONImportResult``.
///
/// Both share a 5/hour rate-limit bucket server-side (tighter than export's
/// 10/h — import writes have a higher blast radius). `APIClient` maps a 429 to
/// ``HLError/rateLimited`` so the screen surfaces it honestly.
public actor ImportService {
    private let api: APIClientProtocol

    public init(api: APIClientProtocol) {
        self.api = api
    }

    /// Import measurement rows from raw CSV text. Pass `dryRun: true` for the
    /// preview (no writes, projected counts); `dryRun: false` performs the
    /// restore. The body is sent verbatim as `text/csv` — the server owns the
    /// column parsing + per-row validation.
    public func importCSV(_ csv: String, dryRun: Bool) async throws -> CSVImportResult {
        let query: [(String, String)] = dryRun ? [("dryRun", "1")] : []
        let req = APIRequest<CSVImportResult>(
            method: .post,
            path: "/api/import/csv",
            query: query,
            body: Data(csv.utf8),
            // Override the default JSON Content-Type — the route reads
            // `request.text()`, so a JSON content-type would misroute the body.
            extraHeaders: ["Content-Type": "text/csv"]
        )
        return try await api.send(req)
    }

    /// Restore a JSON export (`{ measurements, moodEntries }`) back into the
    /// account. No dry-run on this route — the CSV route is the preview surface.
    public func importJSON(_ payload: Data) async throws -> JSONImportResult {
        let req = APIRequest<JSONImportResult>(
            method: .post,
            path: "/api/import",
            body: payload
        )
        return try await api.send(req)
    }
}
