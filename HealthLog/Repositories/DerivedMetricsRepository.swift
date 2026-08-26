import Foundation

/// Wraps `GET /api/insights/derived?metric=<ID>` (server v1.10.0, route at
/// `src/app/api/insights/derived/route.ts`, envelope
/// `src/lib/insights/derived/types.ts`).
///
/// **What it serves.** The compute-once `Derived<T>` value for a single
/// registered metric id — personal-typical-range bands, cardio-fitness /
/// vascular-age re-frames, HRV balance, the composite scores (Readiness /
/// Sleep / Recovery / Stress / Strain) — each with a coverage / confidence /
/// provenance envelope so iOS can render the same award-tier transparency the
/// web does. **HONEST-ONLY:** the repository surfaces ONLY what the server
/// returns; it never fabricates a band or score (`status: insufficient`
/// passes through so the caller renders the gating state, not a value).
///
/// **Cache strategy:** daily SWR per metric. Each id's value is recomputed
/// ~once per Berlin day server-side, so the read routes through the
/// Berlin-day-anchored `.derivedMetric(metric:day:)` ladder (cache-first on
/// disk, single-flighted revalidation) — the derived block paints cache-first
/// on launch + the key flips to a structural miss on day rollover.
///
/// **`nil` arms:** a `404` (route not deployed) or `422` (the closed registry
/// rejects an id this client build does not know) maps to `nil` so a single
/// unknown id never errors the whole block. (`status: insufficient` is NOT
/// `nil` — it is a valid gating envelope and is returned.)
///
/// **Forward-compatible.** The set of ids requested is the client's choice;
/// new server ids are simply not requested until a later client build wires
/// them, and an id the server drops 422s → `nil` → that row is skipped.
public actor DerivedMetricsRepository {
    private let api: APIClientProtocol
    private let swr: SWRCoordinator?

    public init(api: APIClientProtocol, swr: SWRCoordinator? = nil) {
        self.api = api
        self.swr = swr
    }

    /// Fetches one derived metric envelope, or `nil` on a `404`/`422`.
    /// - Parameters:
    ///   - metric: the UPPER_SNAKE derived id (e.g. `"READINESS"`).
    ///   - type: optional sub-target for the typed metrics — the vital for
    ///     `VITALS_BASELINE`, the cumulative type for `SAME_TIME_BASELINE`;
    ///     ignored by the other ids. It participates in the cache key, so two
    ///     types of the same metric never share a row.
    ///   - cached: `false` bypasses the daily SWR ladder and always hits the
    ///     network. Required for `SAME_TIME_BASELINE`, whose `asOfHour` and
    ///     numbers move EVERY hour — a Berlin-day-anchored cache row would pin
    ///     the card to whatever hour it was first read at. (The server's own
    ///     batch route caches for the same reason the single route does not;
    ///     the single route is the fresh one.)
    public func fetch(
        metric: String,
        type: String? = nil,
        cached: Bool = true
    ) async throws -> DerivedMetricDTO? {
        let api = api
        let query: [(String, String)] = {
            var q: [(String, String)] = [("metric", metric)]
            if let type { q.append(("type", type)) }
            return q
        }()
        @Sendable func networkFetch() async throws -> DerivedMetricDTO {
            let req: APIRequest<DerivedMetricDTO> = .get("/api/insights/derived", query: query)
            return try await api.send(req)
        }
        // The cache token mirrors the server's own batch token grammar
        // (`<metric>` or `<metric>:<type>`) so a typed read never collides with
        // the untyped one.
        let cacheToken = type.map { "\(metric):\($0)" } ?? metric
        do {
            if cached, let swr {
                return try await swr.fetchCachingFirst(
                    .derivedMetric(metric: cacheToken, day: BerlinDayKey.string()),
                    decoding: DerivedMetricDTO.self,
                    fetch: networkFetch
                )
            }
            return try await networkFetch()
        } catch let HLError.server(status, _, _) where status == 404 || status == 422 {
            // Route absent / unknown id rejected by the closed registry → skip
            // this row, never error the block.
            return nil
        }
    }

    /// **CU-30 / C5.** Fetches the Same-Time-Baseline envelope for one of the
    /// four cumulative types (`GET /api/insights/derived?metric=SAME_TIME_BASELINE&type=…`).
    ///
    /// Deliberately the SINGLE route, uncached: the batch route is served from
    /// a 60 s SWR cell server-side, so an `asOfHour` read through it can lag
    /// the wall clock — and this card names the hour. The gated arms
    /// (`learning_usual_day`, `no_intraday_today`, `day_too_young`,
    /// `unsupported_baseline_type`) come back as ordinary `insufficient`
    /// envelopes and are returned as-is: they are honest states, not errors,
    /// and the caller renders them calmly. Only `404`/`422` map to `nil`.
    public func fetchSameTimeBaseline(
        type: SameTimeBaselineType = .default
    ) async throws -> DerivedMetricDTO? {
        try await fetch(metric: SameTimeBaselineMetric.id, type: type.rawValue, cached: false)
    }

    /// Fetches the whole derived grid in ONE request
    /// (`GET /api/insights/derived/batch?metrics=<CSV>`), collapsing the
    /// per-metric fan-out the server flags as Prisma-pool starvation
    /// (hang-then-recover). Returns the same `DerivedMetricDTO` envelopes
    /// ``fetchAll`` does (order NOT guaranteed; caller orders for display).
    ///
    /// **Resilience.** The batch route 422s the WHOLE request if ANY token is
    /// unknown (vs. the single route, which drops just that arm). To keep the
    /// repo's forward-compatible "an unknown id never errors the block"
    /// guarantee, a `404` (route not deployed) or `422` (a token this client
    /// build requested that the server's registry rejects) transparently falls
    /// back to the per-id ``fetchAll``. Any other transport error self-suppresses
    /// to `[]` (the block hides; the next refresh / SWR revalidate retries) —
    /// SWR still paints a cached grid first when one exists.
    ///
    /// Dedups + caps at the server's 24-token limit; caches the grid under one
    /// Berlin-day key (the sorted token set), so the same overview hits a single
    /// cache row.
    public func fetchBatch(_ metrics: [String]) async -> [DerivedMetricDTO] {
        var seen = Set<String>()
        var tokens: [String] = []
        for metric in metrics where seen.insert(metric).inserted {
            tokens.append(metric)
        }
        tokens = Array(tokens.prefix(24))
        guard !tokens.isEmpty else { return [] }

        let csv = tokens.joined(separator: ",")
        let cacheToken = tokens.sorted().joined(separator: ",")
        let api = api

        @Sendable func networkFetch() async throws -> DerivedBatchResponse {
            let req: APIRequest<DerivedBatchResponse> = .get(
                "/api/insights/derived/batch",
                query: [("metrics", csv)]
            )
            return try await api.send(req)
        }

        do {
            let response: DerivedBatchResponse = if let swr {
                try await swr.fetchCachingFirst(
                    .derivedBatch(token: cacheToken, day: BerlinDayKey.string()),
                    decoding: DerivedBatchResponse.self,
                    fetch: networkFetch
                )
            } else {
                try await networkFetch()
            }
            return Array(response.metrics.values)
        } catch let HLError.server(status, _, _) where status == 404 || status == 422 {
            // Batch route absent / an unknown token 422'd the whole request →
            // fall back to the resilient per-id fan-out (drops only the unknown
            // arm). The common case (all known ids) never reaches here.
            return await fetchAll(metrics)
        } catch {
            // Transient transport error → self-suppress; SWR serves a cached
            // grid first when present, and the next refresh retries.
            return []
        }
    }

    /// Fetches a set of derived metrics concurrently, dropping the `nil`
    /// (404/422) arms. Order of the returned array is NOT guaranteed; the
    /// caller orders for display. The per-id fallback for ``fetchBatch`` + the
    /// hydrator for clients/builds without the batch route.
    public func fetchAll(_ metrics: [String]) async -> [DerivedMetricDTO] {
        await withTaskGroup(of: DerivedMetricDTO?.self) { group in
            for metric in metrics {
                group.addTask { [self] in
                    try? await fetch(metric: metric)
                }
            }
            var out: [DerivedMetricDTO] = []
            for await result in group {
                if let result { out.append(result) }
            }
            return out
        }
    }
}
