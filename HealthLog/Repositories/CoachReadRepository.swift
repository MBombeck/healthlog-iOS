import Foundation

/// **1.5 LAB-LINES, from COACH-R point 5** — `GET /api/insights/coach-read`.
///
/// Read-only, no cache: the answer moves with every new reading and with
/// "today". A manage-level read on the whole record, so a delegate with a
/// narrower grant is refused (locally by `APIClient` or by the server) and
/// the page simply shows no line.
public actor CoachReadRepository {
    private let api: APIClientProtocol

    public init(api: APIClientProtocol) {
        self.api = api
    }

    public func fetch(metric: String) async throws -> CoachReadStrip {
        let request: APIRequest<CoachReadStrip> = .get("/api/insights/coach-read", query: [("metric", metric)])
        return try await api.send(request)
    }

    /// The metrics whose page shows the line, with the server's name for each.
    /// Kinds whose stored unit the app does not print as is (sleep minutes,
    /// fractions, derived BMI) are left out rather than mislabelled.
    nonisolated static func metric(for kind: MetricKind) -> String? {
        switch kind {
        case .weight, .bloodPressure, .pulse, .restingHeartRate, .hrv, .glucose:
            kind.availabilitySummaryKey
        default:
            nil
        }
    }
}
