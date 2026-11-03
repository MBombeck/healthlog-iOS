import Foundation

// #145 / #146 (server v1.43.6 to v1.43.7) — a list page the server cut
// shorter than asked.
//
// `GET /api/measurements` takes `limit` up to 5000, but a sleep page
// (`type=SLEEP_DURATION`, one row per night) holds at most 1000 nights, and
// `meta.limit` echoes the value the server applied (`ListMeasurementsMeta` in
// `docs/api/openapi.yaml` at v1.43.10). Until v1.43.5 the server cut sleep to
// one year instead; since v1.43.6 it serves the newest 1000 nights and says so.
// The list's "All" read asks for up to 4000 rows, so an account with more than
// about 2.7 years of sleep lost its oldest nights without a word.
//
// The answer is the route's own paging: while the server applied a smaller
// page than asked and `meta.total` says more rows exist, the next page is read
// with `offset`. Nothing changes for a page the server served in full, which
// is every other type at every limit the app sends today.

extension MeasurementsRepository {
    /// Upper bound on follow-up pages for one read; at the 1000-night page
    /// that is 11 000 nights, far past the app's own 4000-row ceiling.
    static let maxFollowUpPages = 10

    /// Reads `/api/measurements` with `query` (which carries `limit`) and,
    /// when the server applied a smaller page, the following pages via
    /// `offset`, until `limit` rows, `meta.total`, or an empty page.
    nonisolated static func fetchListRows(
        api: APIClientProtocol,
        query: [(String, String)],
        limit: Int
    ) async throws -> [MeasurementWireDTO] {
        let firstRequest: APIRequest<MeasurementListWireResponse> = .get("/api/measurements", query: query)
        let first = try await api.send(firstRequest)
        var rows = first.measurements
        guard let applied = first.meta?.limit, applied > 0, applied < limit else { return rows }
        let total = first.meta?.total ?? limit
        var offset = applied
        var pages = 0
        while offset < min(limit, total), pages < maxFollowUpPages {
            pages += 1
            var pageQuery = query.filter { $0.0 != "limit" && $0.0 != "offset" }
            pageQuery.append(("limit", String(limit - offset)))
            pageQuery.append(("offset", String(offset)))
            let request: APIRequest<MeasurementListWireResponse> = .get("/api/measurements", query: pageQuery)
            let page = try await api.send(request)
            guard !page.measurements.isEmpty else { break }
            rows += page.measurements
            // The server's page size, not the decoded count: a row the tolerant
            // decoder dropped (a type this build does not know) still took a slot.
            offset += max(1, page.meta?.limit ?? page.measurements.count)
        }
        return rows
    }
}
