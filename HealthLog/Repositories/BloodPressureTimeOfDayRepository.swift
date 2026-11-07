import Foundation

/// **1.5 BP-TOD** — wraps `GET /api/measurements/blood-pressure/time-of-day`
/// (server v1.47.0, route `src/app/api/measurements/blood-pressure/time-of-day/route.ts`).
///
/// A thin read-only `actor` like ``IntradayPulseRepository``: no outbox kind
/// (reads are never queued) and no disk cache. The answer depends on "today"
/// in the record's zone and on readings that arrive all day, so a persisted
/// copy would paint yesterday's averages; the section keeps the per-range
/// answers of the open page in memory instead (``BloodPressureTimeOfDayModel``).
///
/// `/api/measurements` is the measurements section of the record, so a
/// delegate without that grant gets the local sharing denial (403) from
/// `APIClient` before anything goes out.
public actor BloodPressureTimeOfDayRepository {
    /// The first server that ships the route (#1331).
    public static let minimumServerVersion = "1.47.0"
    /// The server's own bounds for `days`.
    public static let daysRange = 1 ... 3650

    private let api: APIClientProtocol

    public init(api: APIClientProtocol) {
        self.api = api
    }

    /// Reads one window. `days` is the chart's range in days, so the section
    /// and the chart read the same window; it is clamped to the server bounds.
    public func fetch(days: Int) async throws -> BloodPressureTimeOfDay {
        let clamped = min(max(days, Self.daysRange.lowerBound), Self.daysRange.upperBound)
        let request: APIRequest<BloodPressureTimeOfDay> = .get(
            "/api/measurements/blood-pressure/time-of-day",
            query: [("days", String(clamped))]
        )
        return try await api.send(request)
    }
}
