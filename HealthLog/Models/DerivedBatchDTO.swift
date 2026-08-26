import Foundation

/// Wire-form mirror of `GET /api/insights/derived/batch?metrics=<CSV>` (server
/// v1.10.0, route `src/app/api/insights/derived/batch/route.ts`, schema
/// `DerivedBatchResponse` in `docs/api/openapi.yaml`).
///
/// **One request resolves the whole derived-overview grid.** The server loads
/// the profile once, fans out the requested metrics under a bounded limiter,
/// and returns a map keyed by the per-request token (`<ID>` or `<ID>:<type>`).
/// Each value is the SAME flat `Derived<T>` envelope the single-metric route
/// returns (``DerivedMetricDTO``), so iOS decodes one shape. This collapses the
/// 8–14 concurrent single-metric requests the Insights cold-mount used to fan
/// out — the shared-Prisma-pool starvation the server flags as a
/// hang-then-recover.
///
/// `api.send` unwraps the `{ data, error, meta }` envelope, so this type
/// mirrors only the inner `data` object (`{ metrics: { … } }`).
public struct DerivedBatchResponse: Codable, Sendable, Equatable {
    /// Map keyed by the per-request token; each value is the standard
    /// single-metric envelope.
    public let metrics: [String: DerivedMetricDTO]

    public init(metrics: [String: DerivedMetricDTO]) {
        self.metrics = metrics
    }
}
