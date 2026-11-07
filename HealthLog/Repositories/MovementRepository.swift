import Foundation

/// **1.5 MOVE (#133)** — the reads behind the "Unterwegs" section of the
/// environment screen and the Dawarich row in Settings › Integrations.
///
/// A thin read-only `actor` like ``EnvironmentRepository``: no outbox, no disk
/// cache. Movement is the owner's own: `/api/dawarich` and `/api/day` are not
/// admitted record routes, so with a delegate's record selected `APIClient`
/// refuses them locally (403) before anything goes out, and the server leaves
/// `movement` out for a delegate as well. Either way the section stays away.
public actor MovementRepository {
    private let api: APIClientProtocol

    public init(api: APIClientProtocol) {
        self.api = api
    }

    /// `GET /api/dawarich/status` — connection and the stored day range.
    public func status() async throws -> DawarichStatus {
        let req: APIRequest<DawarichStatus> = .get("/api/dawarich/status")
        return try await api.send(req)
    }

    /// `GET /api/day/{date}`, of which only `movement` is decoded. `nil` when
    /// the server sends no block for the day.
    public func movement(on day: String) async throws -> DayMovement? {
        let req: APIRequest<DayMovementPayload> = .get("/api/day/\(day)")
        return try await api.send(req).movement
    }

    /// The `dawarich` entry of `GET /api/integrations/status`, or `nil` when
    /// the server does not list it.
    func integrationEntry() async throws -> DawarichIntegrationPayload.Entry? {
        let req: APIRequest<DawarichIntegrationPayload> = .get("/api/integrations/status")
        return try await api.send(req).dawarich
    }
}
