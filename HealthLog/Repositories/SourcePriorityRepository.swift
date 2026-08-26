import Foundation

/// Wraps `GET / PUT /api/auth/me/source-priority` (server v1.4.25
/// W5e + W8c, route at `src/app/api/auth/me/source-priority/route.ts`).
///
/// The route backs the iOS Settings → Sources & Devices two-axis
/// editor (still pending UI per the server contributor brief §6).
/// The repository is wired now so the editor screen can land in a
/// future patch without a server-coordination round-trip.
///
/// **Wire shape:** the server emits a fully-defaulted payload —
/// missing keys fill from `DEFAULT_SOURCE_PRIORITY`. iOS sees both the
/// flat-W5e shape AND the nested-W8c shape on every GET.
///
/// **Cache strategy:** small payload, low write rate (operator edits
/// it from Settings on the rare "switch device" event). Keep an
/// in-memory snapshot per repo instance. PUT invalidates + re-emits
/// the fresh shape returned by the server response.
public actor SourcePriorityRepository {
    private let api: APIClientProtocol
    private let cacheTTL: TimeInterval
    private let clock: @Sendable () -> Date

    private var cached: SourcePriorityDTO?
    private var cachedAt: Date?

    public init(
        api: APIClientProtocol,
        cacheTTL: TimeInterval = 300,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.api = api
        self.cacheTTL = cacheTTL
        self.clock = clock
    }

    /// Reads the current ladder. Cache fresh → return. Stale or absent
    /// → network. Network fails with stale present → return stale.
    public func fetch() async throws -> SourcePriorityDTO {
        if let cached, let cachedAt, clock().timeIntervalSince(cachedAt) < cacheTTL {
            return cached
        }
        do {
            let req: APIRequest<SourcePriorityDTO> = .get("/api/auth/me/source-priority")
            let payload = try await api.send(req)
            cached = payload
            cachedAt = clock()
            return payload
        } catch {
            if let stale = cached {
                HLLog.api.warning(
                    "SourcePriorityRepository.fetch failed; returning stale cache: \(String(describing: error), privacy: .private)"
                )
                return stale
            }
            throw error
        }
    }

    /// Replaces the persisted ladder. Server validates the full shape
    /// via `sourcePrioritySchema.safeParse` and 422s on bad input.
    /// Returns the parsed echo so the caller learns what the server
    /// actually persisted (defaults merged in).
    ///
    /// V0.5.2 R2 / M1: the `Idempotency-Key` is generated explicitly per
    /// call (instead of relying on `APIRequest.put`'s default). Two
    /// reasons:
    ///   1. PROJECT_GUIDE.md "Idempotency-Keys auf jedem POST/PUT" is the
    ///      contract — making the key visible at the call site keeps the
    ///      invariant reviewable.
    ///   2. The wrapper-overload `update(payload:idempotencyKey:)` lets a
    ///      future outbox-driven retry replay the *same* key on the wire
    ///      so the server-side dedupe works after restart. (Outbox-kind
    ///      for source-priority is not wired today — this is the seam.)
    @discardableResult
    public func update(_ payload: SourcePriorityDTO) async throws -> SourcePriorityDTO {
        try await update(payload, idempotencyKey: IdempotencyKey())
    }

    /// Replay-friendly overload — accepts the explicit key so an outbox
    /// replay can reuse it. Server route is the same; the only difference
    /// is the wire-side `Idempotency-Key` header.
    @discardableResult
    public func update(_ payload: SourcePriorityDTO, idempotencyKey: IdempotencyKey) async throws -> SourcePriorityDTO {
        let req: APIRequest<SourcePriorityDTO> = try .put(
            "/api/auth/me/source-priority",
            body: payload,
            idempotencyKey: idempotencyKey
        )
        let echoed = try await api.send(req)
        cached = echoed
        cachedAt = clock()
        return echoed
    }

    /// Test hook.
    public func invalidateCache() {
        cached = nil
        cachedAt = nil
    }
}
