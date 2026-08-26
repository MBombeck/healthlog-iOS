import Foundation

/// Wraps `GET /api/insights/targets` (server v1.4.36 W1, route at
/// `src/app/api/insights/targets/route.ts`).
///
/// The route backs the personal-health-targets surface — current
/// readings + trends + consistency strips for every target the user
/// has configured. Chart-relevant: the consistency strip is the
/// dataset the iOS "Ziele" tile renders.
///
/// **Cache strategy:** in-memory SWR with a 60-second TTL — matches
/// the server-side `cached()` wrapper so iOS-side refresh after a
/// write surfaces the new shape on the first re-mount inside the
/// minute. The server invalidates its cache on any measurement /
/// mood / medication write; iOS-side caching never overshoots that.
///
/// **Stale-on-error:** standard ladder. A failing refresh returns the
/// last-known snapshot if present, otherwise throws.
public actor InsightsTargetsRepository {
    private let api: APIClientProtocol
    private let cacheTTL: TimeInterval
    private let clock: @Sendable () -> Date
    /// W3 (v0.11 #22) — optional persistent SWR cache. When wired,
    /// ``fetch()`` paints from the on-disk `CachedSnapshot` first (so the
    /// per-metric "Ziel" block survives an app restart and paints cache-first
    /// on launch) and revalidates in the background. `nil` (default) keeps the
    /// in-memory-only behaviour the existing unit tests assert.
    private let swr: SWRCoordinator?

    private var cached: InsightsTargetsResponseDTO?
    private var cachedAt: Date?

    public init(
        api: APIClientProtocol,
        cacheTTL: TimeInterval = 60,
        clock: @escaping @Sendable () -> Date = Date.init,
        swr: SWRCoordinator? = nil
    ) {
        self.api = api
        self.cacheTTL = cacheTTL
        self.clock = clock
        self.swr = swr
    }

    /// Fetches the targets payload. Cache fresh → return. Cache stale
    /// or absent → network. Network fails with stale present → return
    /// stale. Network fails with no cache → throw.
    ///
    /// W3 — when a `SWRCoordinator` is wired the read routes through the
    /// persistent `.insightsTargets` SWR ladder (cache-first on disk, single-
    /// flighted revalidation) so a launch/foreground prefetch warms the same
    /// row the per-metric screen reads. The in-memory TTL still short-circuits
    /// repeated reads within the same minute without a coordinator hop.
    public func fetch() async throws -> InsightsTargetsResponseDTO {
        if let cached, let cachedAt, clock().timeIntervalSince(cachedAt) < cacheTTL {
            return cached
        }
        let api = api
        @Sendable func networkFetch() async throws -> InsightsTargetsResponseDTO {
            let req: APIRequest<InsightsTargetsResponseDTO> = .get("/api/insights/targets")
            return try await api.send(req)
        }
        do {
            let payload: InsightsTargetsResponseDTO = if let swr {
                try await swr.fetchCachingFirst(.insightsTargets, decoding: InsightsTargetsResponseDTO.self, fetch: networkFetch)
            } else {
                try await networkFetch()
            }
            cached = payload
            cachedAt = clock()
            return payload
        } catch {
            if let stale = cached {
                HLLog.api.warning(
                    "InsightsTargetsRepository.fetch failed; returning stale cache: \(String(describing: error), privacy: .private)"
                )
                return stale
            }
            throw error
        }
    }

    /// Test hook: drop the cached snapshot.
    public func invalidateCache() {
        cached = nil
        cachedAt = nil
    }
}
