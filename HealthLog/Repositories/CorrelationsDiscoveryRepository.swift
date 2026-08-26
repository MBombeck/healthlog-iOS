import Foundation

/// Wraps `GET /api/insights/correlations` (server v1.10.0, route at
/// `src/app/api/insights/correlations/route.ts`, envelope
/// `CorrelationDiscoveryResponseEnvelope`).
///
/// **What it serves.** FDR-controlled correlation *discovery* over a curated
/// behaviour × outcome matrix — lag-joined behaviour-day → next-day outcome,
/// Pearson `r` + exact Student-t `p`, Benjamini-Hochberg FDR `q` across all
/// pairs. Only statistically-defensible pairs (`n ≥ minPairs`, `p < 0.05`,
/// BH-FDR controlled) come back in `discovered`. **HONEST-ONLY:** the
/// repository surfaces ONLY what the server returns; it never fabricates a
/// correlation.
///
/// **Cache strategy:** daily SWR. The matrix is recomputed ~once per Berlin
/// day server-side, so the read routes through the Berlin-day-anchored
/// `.correlations` cache row (cache-first on disk, single-flighted
/// revalidation) — the block paints cache-first on launch + the row flips to
/// a structural miss on day rollover.
///
/// **Operator-gated / `nil` arms.** The endpoint sits behind an operator
/// `correlations` assistant surface; a feature-off response is served as
/// `404`/`422`. Both map to `nil` so the block hides GRACEFULLY (not an error,
/// not a crash) — mirroring `DerivedMetricsRepository`'s "an absent surface
/// never errors the block" guarantee.
public actor CorrelationsDiscoveryRepository {
    private let api: APIClientProtocol
    private let swr: SWRCoordinator?

    public init(api: APIClientProtocol, swr: SWRCoordinator? = nil) {
        self.api = api
        self.swr = swr
    }

    /// Fetches the discovery response, or `nil` when the surface is gated off
    /// (`404`/`422`) so the caller hides the block instead of erroring.
    public func fetch() async throws -> CorrelationDiscoveryResponse? {
        let api = api
        @Sendable func networkFetch() async throws -> CorrelationDiscoveryResponse {
            let req: APIRequest<CorrelationDiscoveryResponse> = .get("/api/insights/correlations")
            return try await api.send(req)
        }
        do {
            if let swr {
                return try await swr.fetchCachingFirst(
                    .correlations,
                    decoding: CorrelationDiscoveryResponse.self,
                    fetch: networkFetch
                )
            }
            return try await networkFetch()
        } catch let HLError.server(status, code, _)
            where status == 404 || status == 422
            || (status == 403 && (code?.hasPrefix("assistant.disabled") ?? false))
        {
            // Operator-gated surface off / route not deployed → hide the block,
            // never error it. v0141 W-DATAPARITY (P10): `requireAssistantSurface`
            // answers a disabled `correlations` surface with `403` +
            // `errorCode: "assistant.disabled.correlations"`
            // (`src/lib/feature-flags/index.ts:137-145`) — folding that into the
            // graceful arm hides the block quietly instead of erroring it. A
            // genuine auth `403` (no `assistant.disabled.*` code) still throws.
            return nil
        }
    }

    /// Drops the persistent SWR cache row so a logout never lets the next user
    /// paint the previous user's discovered correlations.
    public func invalidateCache() async {
        await swr?.invalidate([.correlations])
    }
}
