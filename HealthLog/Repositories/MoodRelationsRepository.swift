import Foundation

/// SWR client for the **mood "relations"** slices of `GET /api/mood/insights`
/// (server v1.11.5, route `src/app/api/mood/insights/route.ts`, payload
/// `MoodAggregates`).
///
/// **What it serves.** The two new observational slices the Daylio mood-tag
/// work pays off into: per-tag with-vs-without mood `tagInfluence` and the
/// ranked `betterDays` board. The response is decoded tolerantly via
/// ``MoodRelationsResponse`` — only those two keys are read, the rest of the
/// aggregate (heatmap / distribution / narratives, all computed client-side off
/// raw entries) is ignored.
///
/// **Cache strategy.** Routes through the shared `SWRCoordinator` on the
/// `.moodInsights` row (cache-first on disk, single-flighted revalidation),
/// mirroring the server's ~60s `cached()` window so the Mood-page cards paint
/// from disk on launch + revalidate in the background — the same SWR posture as
/// `CorrelationsDiscoveryRepository`.
///
/// The repository surfaces ONLY what the server returns. A
/// payload that pre-dates v1.11.5 (no relations slices) decodes to an empty
/// ``MoodRelationsResponse`` so the cards self-suppress; it never fabricates a
/// correlation.
public actor MoodRelationsRepository {
    private let api: APIClientProtocol
    private let swr: SWRCoordinator?

    public init(api: APIClientProtocol, swr: SWRCoordinator? = nil) {
        self.api = api
        self.swr = swr
    }

    /// Fetches the relations slices. Routes through the `.moodInsights` SWR row
    /// when a coordinator is wired; otherwise a direct fetch (unit tests).
    public func fetch() async throws -> MoodRelationsResponse {
        let api = api
        @Sendable func networkFetch() async throws -> MoodRelationsResponse {
            let req: APIRequest<MoodRelationsResponse> = .get("/api/mood/insights")
            return try await api.send(req)
        }
        if let swr {
            return try await swr.fetchCachingFirst(
                .moodInsights,
                decoding: MoodRelationsResponse.self,
                fetch: networkFetch
            )
        }
        return try await networkFetch()
    }

    /// #126 P2 (server v1.42.0) — `GET /api/mood/insights?days=N`: `stability`
    /// (and since v1.43 `patterns`, #136) cut to the period the page shows
    /// (30, 90, 180 or 365; any other value is a 422 server-side, so it is
    /// never sent). Routed through its own SWR row per window
    /// (``CacheKey/moodInsightsWindow(days:)``), never through `.moodInsights`,
    /// so one window can never serve another window's answer.
    public func stability(days: Int) async throws -> MoodRelationsResponse {
        let api = api
        @Sendable func networkFetch() async throws -> MoodRelationsResponse {
            let req: APIRequest<MoodRelationsResponse> = .get("/api/mood/insights", query: [("days", String(days))])
            return try await api.send(req)
        }
        if let swr {
            return try await swr.fetchCachingFirst(
                .moodInsightsWindow(days: days),
                decoding: MoodRelationsResponse.self,
                fetch: networkFetch
            )
        }
        return try await networkFetch()
    }

    /// Drops the persistent SWR cache rows (the default and every period) so a logout never lets the next user
    /// paint the previous user's mood relations.
    public func invalidateCache() async {
        await swr?.invalidate([.moodInsights] + [30, 90, 180, 365].map { CacheKey.moodInsightsWindow(days: $0) })
    }
}
