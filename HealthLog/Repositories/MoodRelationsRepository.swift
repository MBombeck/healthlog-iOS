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
/// **HONEST-ONLY.** The repository surfaces ONLY what the server returns. A
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

    /// Drops the persistent SWR cache row so a logout never lets the next user
    /// paint the previous user's mood relations.
    public func invalidateCache() async {
        await swr?.invalidate([.moodInsights])
    }
}
