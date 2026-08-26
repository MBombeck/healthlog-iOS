import Foundation

/// Thin actor wrapper around `GET /api/meta/capabilities` (CU-01).
///
/// The route is the server's live discovery surface: it serves the REAL id
/// vocabularies the routes accept and emit, each derived server-side from the
/// canonical registry it documents. The one this shipment needs is
/// ``ServerCapabilities/Share/leaves`` — the report-selection leaf vocabulary
/// that the export and share-link units must read live instead of hardcoding.
///
/// **No caching here.** Same division of labour as
/// ``FeatureFlagsRepository``: this actor is a GET wrapper; per-session
/// memoisation belongs to whatever store adopts it. Nothing in CU-01 keeps
/// state, deliberately — the two consuming units land later and will decide the
/// refresh cadence together rather than inheriting a guess made here.
public actor ServerCapabilitiesRepository {
    private let api: APIClientProtocol

    public init(api: APIClientProtocol) {
        self.api = api
    }

    /// Pull the current capability descriptor.
    ///
    /// Decoding is tolerant field-by-field (see ``ServerCapabilities``), so a
    /// server that adds or drops a key still resolves; only a non-2xx or a
    /// structurally broken envelope throws.
    public func fetch() async throws -> ServerCapabilities {
        let req: APIRequest<ServerCapabilities> = .get("/api/meta/capabilities")
        return try await api.send(req)
    }
}
