import Foundation

/// Wraps `GET /api/feature-flags` (server v1.4.31 / brief §5).
///
/// **Response shape (server side):**
/// ```
/// { "data": { "flags": { "assistant.briefing": true,
///                        "assistant.coach": false,
///                        "assistant.trend": true,
///                        "assistant.insights": true } },
///   "error": null }
/// ```
///
/// The wire envelope is the standard `APIEnvelope<T>` shape — the
/// server fronts every JSON route with `{ data, error }`. The
/// repository decodes the inner `flags` map and hands it straight to
/// ``FeatureFlagsStore``.
///
/// **Caching:** none here. Per-session memoisation lives in the store
/// so refresh-on-foreground stays a single-source operation; this
/// actor is a thin GET wrapper.
public actor FeatureFlagsRepository {
    private let api: APIClientProtocol

    public init(api: APIClientProtocol) {
        self.api = api
    }

    /// Pulls the current operator-configured flag set.
    ///
    /// Returns the raw `[String: Bool]` map exactly as the server
    /// emits it — the store does the enum mapping so unknown keys
    /// (forward-compat: new surfaces the server ships before iOS
    /// knows about them) are simply ignored rather than throwing.
    public func fetch() async throws -> [String: Bool] {
        let req: APIRequest<FeatureFlagsResponseDTO> = .get("/api/feature-flags")
        let response = try await api.send(req)
        return response.flags
    }
}

/// Wire DTO for `GET /api/feature-flags`. Sits inside the standard
/// envelope; we ignore the outer envelope (APIClient unwraps it).
///
/// The inner `flags` is a `[String: Bool]` so the server can add new
/// surfaces without an iOS deploy — unknown keys are just ignored by
/// the store. iOS-known keys live in ``FeatureFlag``.
public struct FeatureFlagsResponseDTO: Decodable, Sendable {
    public let flags: [String: Bool]
}
