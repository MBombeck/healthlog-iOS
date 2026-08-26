import Foundation

/// **v1.35.0 (GH #83) — read and write which pillars count toward the Health
/// Score.** `GET`/`PATCH /api/auth/me/health-score-config`.
///
/// The route authenticates on cookie **or** bearer, so unlike the MFA
/// management surface (#57) iOS can genuinely operate it.
///
/// **The first save is the unconditional one.** The `GET` omits `updatedAt`
/// entirely for an account that never chose — there is nothing for a guarded
/// write to guard against. ``OptimisticWriteBody`` mirrors that faithfully: a
/// `nil` token leaves the key out of the body, where a `null` would earn a
/// `422 invalid_base_updated_at`. Every save after the first carries the token
/// the previous response echoed.
///
/// **A refused selection is not an error to retry.** A `422
/// health_score_config.too_narrow` arrives as
/// ``HLError/refusedWithReason(code:reason:)`` and is handed straight to the
/// caller: the reason is the surface's to explain, and this repository neither
/// predicts the refusal nor rewords it.
public actor HealthScoreConfigRepository {
    private let api: APIClientProtocol
    /// The optimistic-concurrency token from the last read or write. `nil`
    /// means "no selection has ever been written" — see the type doc.
    private var baseUpdatedAt: String?

    private static let path = "/api/auth/me/health-score-config"

    public init(api: APIClientProtocol) {
        self.api = api
    }

    /// Test/diagnostic accessor for the held token — the same affordance the
    /// other eight guarded repositories expose.
    public func currentConfigToken() -> String? {
        baseUpdatedAt
    }

    /// The resolved composition the account's score runs on.
    public func fetch() async throws -> HealthScoreConfig {
        let req: APIRequest<HealthScoreConfig> = .get(Self.path)
        let fresh = try await api.send(req)
        baseUpdatedAt = fresh.updatedAt
        return fresh
    }

    /// Write the pillars that should count. Sends the **positive** selection;
    /// the server stores its complement.
    @discardableResult
    public func update(pillars: [HealthScorePillar]) async throws -> HealthScoreConfig {
        let body = HealthScoreConfigPatchDTO(pillars: pillars)
        return try await withOptimisticConflictRetry(
            conflictCode: OptimisticConflictCode.healthScoreConfig,
            token: baseUpdatedAt
        ) { token in
            let req: APIRequest<HealthScoreConfig> = try .patch(
                Self.path,
                body: OptimisticWriteBody(payload: body, baseUpdatedAt: token)
            )
            let echoed = try await api.send(req)
            baseUpdatedAt = echoed.updatedAt
            return echoed
        } reread: {
            try await refreshToken()
        }
    }

    /// Re-read after a `409` and adopt the fresh token.
    private func refreshToken() async throws -> String? {
        let req: APIRequest<HealthScoreConfig> = .get(Self.path)
        let fresh = try await api.send(req)
        baseUpdatedAt = fresh.updatedAt
        return fresh.updatedAt
    }
}
