import Foundation

/// **v1.18.6 — per-user diabetes opt-in (ADA glucose bands).**
///
/// Thin wire wrapper over the two `/api/auth/me/diabetes` verbs:
///
/// - `GET`   → current `{ hasDiabetes }` (default `false`).
/// - `PATCH` → sets the flag (`{ hasDiabetes }` body); idempotent server-side
///   (the audit-log row fires even when the value already matches). Always
///   returns the resolved next-state for optimistic-update consumers.
///
/// The `APIClient` auto-unwraps the `{ data, error, meta }` envelope, so both
/// calls decode straight to `DiabetesFlagDTO`. The server resolves the tighter
/// ADA glycemic GOAL bands when on — iOS renders server-resolved glucose status
/// and NEVER recomputes reference ranges from this flag.
public actor DiabetesRepository {
    private let api: APIClientProtocol

    public init(api: APIClientProtocol) {
        self.api = api
    }

    private static let path = "/api/auth/me/diabetes"

    /// `GET /api/auth/me/diabetes` — the owner's current opt-in flag.
    public func fetch() async throws -> DiabetesFlagDTO {
        let req: APIRequest<DiabetesFlagDTO> = .get(Self.path)
        return try await api.send(req)
    }

    /// `PATCH /api/auth/me/diabetes` — set the flag. Returns the resolved
    /// next-state echoed by the server.
    public func update(hasDiabetes: Bool) async throws -> DiabetesFlagDTO {
        let req: APIRequest<DiabetesFlagDTO> = try .patch(
            Self.path,
            body: DiabetesFlagDTO(hasDiabetes: hasDiabetes)
        )
        return try await api.send(req)
    }
}
