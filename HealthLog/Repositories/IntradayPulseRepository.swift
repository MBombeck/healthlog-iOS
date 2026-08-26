import Foundation

/// Wraps `GET /api/insights/pulse/intraday` — one local day's intraday pulse
/// shape (server route `src/app/api/insights/pulse/intraday/route.ts`).
///
/// A thin read-only `actor` over the shared `APIClient`, mirroring
/// ``SleepInsightsRepository``: no outbox `Kind` (reads are never queued), no
/// disk SWR.
///
/// **Why no disk cache.** The server answers `no-store` deliberately (the day
/// shape is volatile and "today" keeps growing), so a persisted snapshot would
/// paint a stale morning for the rest of the day. Instead the actor keeps an
/// in-session memo for PAST days only — those are finished and immutable, so
/// paging back and forth through the day navigator costs one round-trip per
/// day — while today is always re-fetched.
///
/// **`nil` arms (fail-closed + calm).** `403` (the `insights` module is off),
/// `404` (older server without the route) and `422` (a malformed date the
/// server rejects) all resolve to `nil` so the block renders NOTHING. A gated
/// or absent surface is "there is nothing here", never an error card — the
/// recovery-bug lesson: no dead card bodies.
public actor IntradayPulseRepository {
    private let api: APIClientProtocol

    /// In-session memo, keyed by `dateKey`. Only PAST days land here; today is
    /// volatile and always re-read.
    private var memo: [String: IntradayPulseDTO] = [:]
    /// Sticky "the server told us this surface is off" flag. Once a gate or a
    /// missing route answered, the block stops re-asking on every appearance.
    private var unavailable = false

    public init(api: APIClientProtocol) {
        self.api = api
    }

    /// Fetches one day.
    ///
    /// - Parameters:
    ///   - dateKey: the `yyyy-MM-dd` local day to read, or `nil` to let the
    ///     SERVER resolve "today" in the profile timezone (the route's own
    ///     default — no `date` parameter is sent).
    ///   - todayKey: the caller's notion of today. A `dateKey` equal to it (or
    ///     a `nil` `dateKey`) bypasses + skips the memo, so the live day never
    ///     freezes mid-morning.
    /// - Returns: the day, or `nil` when the surface is gated off / absent.
    public func fetch(dateKey: String?, todayKey: String) async throws -> IntradayPulseDTO? {
        if unavailable { return nil }
        let isToday = dateKey == nil || dateKey == todayKey
        if !isToday, let dateKey, let cached = memo[dateKey] { return cached }

        let request: APIRequest<IntradayPulseDTO> = .get(
            "/api/insights/pulse/intraday",
            query: dateKey.map { [("date", $0)] } ?? []
        )
        do {
            let payload = try await api.send(request)
            if !isToday, let dateKey { memo[dateKey] = payload }
            return payload
        } catch let HLError.server(status, _, _) where status == 403 || status == 404 || status == 422 {
            // Module off / route absent / rejected → the block hides. Never an
            // error, never a fabricated day.
            unavailable = true
            return nil
        }
    }

    /// Drops the per-day memo (logout / account switch).
    public func invalidateCache() {
        memo.removeAll()
        unavailable = false
    }
}
