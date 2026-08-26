import Foundation

/// Wraps the three v1.25 read-only "clinical signals" awareness reads (server
/// `release/v1.25.0`, GH iOS #38):
///   - `GET /api/insights/health-status`      → ``InsightsHealthStatusDTO``
///   - `GET /api/insights/breathing-screening` → ``InsightsBreathingScreeningDTO``
///   - `GET /api/insights/labs-changes`        → ``InsightsLabsChangesDTO``
///
/// **Server-authoritative, no client recompute.** Each read is pure server
/// compute over an existing engine (personal-baseline + changepoint, the
/// sleep-breathing index, the lab-panel pairing). The repository fetches +
/// decodes verbatim and never re-derives a band / trend / delta on-device.
///
/// **Cache strategy:** daily SWR (same posture as `RecoveryInsightsRepository`).
/// All three are recomputed at most ~once per day server-side, so each routes
/// through a Berlin-day-anchored key (cache-first on disk, single-flighted
/// revalidation) — the cards paint cache-first on launch + flip to a structural
/// miss on day rollover.
///
/// **`nil` arm (graceful).** A `404` (route not deployed on an older server) or
/// `422` maps to `nil` so the host card simply self-suppresses; any other
/// transport error self-suppresses to `nil` too (SWR still serves a cached
/// payload first when one exists).
public actor ClinicalSignalsRepository {
    private let api: APIClientProtocol
    private let swr: SWRCoordinator?

    public init(api: APIClientProtocol, swr: SWRCoordinator? = nil) {
        self.api = api
        self.swr = swr
    }

    /// Baseline-drift health status, or `nil` on `404`/`422`/transport error.
    public func fetchHealthStatus() async -> InsightsHealthStatusDTO? {
        await fetch(
            path: "/api/insights/health-status",
            key: .insightsHealthStatus(day: BerlinDayKey.string()),
            as: InsightsHealthStatusDTO.self
        )
    }

    /// Sleep-breathing screening signal, or `nil` on `404`/`422`/transport error.
    public func fetchBreathingScreening() async -> InsightsBreathingScreeningDTO? {
        await fetch(
            path: "/api/insights/breathing-screening",
            key: .insightsBreathingScreening(day: BerlinDayKey.string()),
            as: InsightsBreathingScreeningDTO.self
        )
    }

    /// "What changed since your last panel", or `nil` on `404`/`422`/transport error.
    public func fetchLabsChanges() async -> InsightsLabsChangesDTO? {
        await fetch(
            path: "/api/insights/labs-changes",
            key: .insightsLabsChanges(day: BerlinDayKey.string()),
            as: InsightsLabsChangesDTO.self
        )
    }

    /// Drops every cached clinical-signal payload (logout cache-wipe).
    public func invalidateCache() async {
        let day = BerlinDayKey.string()
        await swr?.invalidate([
            .insightsHealthStatus(day: day),
            .insightsBreathingScreening(day: day),
            .insightsLabsChanges(day: day)
        ])
    }

    // MARK: - Shared fetch

    private func fetch<T: Codable & Sendable>(
        path: String,
        key: CacheKey,
        as _: T.Type
    ) async -> T? {
        let api = api
        @Sendable func networkFetch() async throws -> T {
            let req: APIRequest<T> = .get(path)
            return try await api.send(req)
        }
        do {
            if let swr {
                return try await swr.fetchCachingFirst(key, decoding: T.self, fetch: networkFetch)
            }
            return try await networkFetch()
        } catch let HLError.server(status, _, _) where status == 404 || status == 422 {
            // Route absent / rejected → graceful: the card self-suppresses.
            return nil
        } catch {
            // Transient transport error → self-suppress; SWR serves a cached
            // payload first when present, and the next refresh retries.
            return nil
        }
    }
}
