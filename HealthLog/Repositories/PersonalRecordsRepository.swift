import Foundation

/// Wraps `GET /api/personal-records` (server v1.4.25 W8d, schema-only).
///
/// Production currently returns `[]` for every user — the detection
/// worker that populates the table lands in v1.4.26 / v1.5. The repo
/// + cache are wired now so the UI can render the empty state today
/// and start populating the moment the worker ships, without an iOS
/// re-release.
///
/// **SWR strategy:** 5-minute TTL (PRs change rarely once the worker
/// is running; latency budget is generous). Cache slot per
/// `(metricType?, limit)` tuple so the "all PRs" view and the
/// per-metric drill-down don't share state.
///
/// **Stale-on-error:** standard ladder. A failing refresh returns the
/// last successful snapshot if any, otherwise throws.
public actor PersonalRecordsRepository {
    private let api: APIClientProtocol
    private let cacheTTL: TimeInterval
    private let clock: @Sendable () -> Date

    private struct CachedEntry {
        let payload: [PersonalRecordDTO]
        let cachedAt: Date
    }

    private var cache: [String: CachedEntry] = [:]

    public init(
        api: APIClientProtocol,
        cacheTTL: TimeInterval = 300,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.api = api
        self.cacheTTL = cacheTTL
        self.clock = clock
    }

    /// Lists records. `metricType` filters server-side (passed as the
    /// `?metricType=…` query param). `limit` defaults to the server's
    /// own default (100) and the server clamps the max (500).
    public func list(metricType: String? = nil, limit: Int = 100) async throws -> [PersonalRecordDTO] {
        let key = "\(metricType ?? "*")|\(limit)"
        if let entry = cache[key], clock().timeIntervalSince(entry.cachedAt) < cacheTTL {
            return entry.payload
        }
        do {
            var query: [(String, String)] = [("limit", String(limit))]
            if let metricType {
                query.append(("metricType", metricType))
            }
            let req: APIRequest<[PersonalRecordDTO]> = .get("/api/personal-records", query: query)
            let payload = try await api.send(req)
            cache[key] = CachedEntry(payload: payload, cachedAt: clock())
            return payload
        } catch {
            if let stale = cache[key]?.payload {
                HLLog.api.warning(
                    "PersonalRecordsRepository.list fetch failed; returning stale cache: \(String(describing: error), privacy: .private)"
                )
                return stale
            }
            throw error
        }
    }

    /// Test hook.
    public func invalidateCache() {
        cache.removeAll()
    }
}
