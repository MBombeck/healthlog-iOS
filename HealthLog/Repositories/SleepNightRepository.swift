import Foundation

/// Reads the per-night reconstructed sleep object behind the hypnogram detail
/// screen (#124).
///
/// - `GET /api/sleep/night?date=YYYY-MM-DD` — the main night + naps for the
///   given local date. Returns ``SleepNightDTO`` with `main == nil` when the
///   night has no sleep data (the screen renders a clean empty state).
///
/// A thin, read-only `actor` over the shared `APIClient` — mirrors
/// ``WhoopRepository`` / ``MetricInsightsRepository``: no outbox `Kind` (reads
/// are never queued). The `data` envelope is unwrapped server-side convention
/// (`{ "data": { … } }`).
///
/// **W-B180 — SWR cache per day-key.** The night-navigation arrows (←/→ in
/// ``SleepHypnogramScreen``) revisit dates within one session; an in-memory
/// per-day-key cache lets the screen paint a previously seen night instantly
/// (``cachedNight(forDayKey:)``) while ``night(forDayKey:)`` revalidates
/// against the server and refreshes the entry. Memory-only by design — sleep
/// nights are small and the screen is the only consumer.
public actor SleepNightRepository {
    private let api: APIClientProtocol

    /// SWR store, keyed by `YYYY-MM-DD` day-key; the no-date "latest night"
    /// entry lives under ``latestCacheKey`` AND under its resolved day-key.
    private var cache: [String: SleepNightDTO] = [:]
    private static let latestCacheKey = "__latest__"

    public init(api: APIClientProtocol) {
        self.api = api
    }

    /// Fetches the reconstructed sleep night for `date` — or the server's
    /// MOST-RECENT night when `date == nil` (the default hypnogram entry).
    ///
    /// **v0.14.3 E1 — default omits the date.** The hypnogram screen used to
    /// pass `latestPoint.at` (a sleep SAMPLE instant in the device tz) as the
    /// day-key. The server keys nights on the local WAKE DAY computed with the
    /// server-resolved user timezone, so an evening segment (e.g. 23:30) or a
    /// device-tz ≠ server-tz mismatch produced an off-by-one day-key that missed
    /// every night → empty/422 → the "konnte nicht geladen werden" error card.
    /// Omitting `date` lets the server return the latest reconstructed night
    /// directly (`route.ts` "most recent night" path), which removes the
    /// tz/wake-day mismatch entirely for the default ("last night") entry.
    ///
    /// - Parameter date: the LOCAL calendar day whose night to load, formatted
    ///   `YYYY-MM-DD` against the user's current timezone, OR `nil` (default) to
    ///   let the server pick the most-recent night. The instants inside the
    ///   response are UTC.
    /// - Returns: the night envelope's payload; `main` is `nil` for a night with
    ///   no sleep data. A `404`/`422` (route absent / day-key rejected) maps to
    ///   an EMPTY night (`main == nil`) so the screen shows the calm empty state,
    ///   never the error card — mirroring `NarrativeRepository.fetch`.
    public func night(for date: Date?) async throws -> SleepNightDTO {
        try await night(forDayKey: date.map(Self.dayKey))
    }

    /// Same contract as ``night(for:)``, addressed by a raw `YYYY-MM-DD`
    /// day-key (`nil` = latest night). W-B180: the navigation arrows operate
    /// in day-key space (UTC-anchored wake days) so a midnight-UTC `night`
    /// instant can never shift a day through the device timezone. Successful
    /// loads land in the SWR cache; the latest night is additionally cached
    /// under its resolved day-key so navigating back to it is instant.
    public func night(forDayKey dayKey: String?) async throws -> SleepNightDTO {
        var query: [(String, String)] = []
        if let dayKey {
            query.append(("date", dayKey))
        }
        let req: APIRequest<SleepNightEnvelope> = .get(
            "/api/sleep/night",
            query: query
        )
        do {
            let envelope = try await api.send(req)
            store(envelope.data, forDayKey: dayKey)
            return envelope.data
        } catch let HLError.server(status, _, _) where status == 404 || status == 422 {
            // Route absent / day-key rejected by the server's strict refine →
            // treat as "no night for this key", a calm empty state (not error).
            //
            // v0.14.8 — the interim `500`-swallow (added in b157 for the known
            // sleep-reconstruction fault) is REMOVED: server v1.13.2 fixed both
            // the doubled `asleepMinutes` and guarded the reconstruction so the
            // route returns a valid/empty night instead of 500. A genuine 500 is
            // now a real outage and should surface (it falls through to the error
            // card), not be silently swallowed.
            let empty = SleepNightDTO(main: nil, naps: [])
            store(empty, forDayKey: dayKey)
            return empty
        }
    }

    /// The cached night for `dayKey` (`nil` = latest), if a load already
    /// landed this session — the stale half of stale-while-revalidate.
    public func cachedNight(forDayKey dayKey: String?) -> SleepNightDTO? {
        cache[dayKey ?? Self.latestCacheKey]
    }

    private func store(_ night: SleepNightDTO, forDayKey dayKey: String?) {
        cache[dayKey ?? Self.latestCacheKey] = night
        // The latest night doubles as its concrete day's entry, so ← then →
        // navigation back onto "today's" night is a cache hit.
        if dayKey == nil, let resolved = night.main.map({ Self.utcDayKey(for: $0.night) }) {
            cache[resolved] = night
        }
    }

    /// Formats `date` as the `YYYY-MM-DD` day-key the endpoint expects, anchored
    /// to the user's CURRENT timezone (the night is keyed on the local wake day).
    nonisolated static func dayKey(for date: Date) -> String {
        dayKeyFormatter.string(from: date)
    }

    /// Local-timezone `YYYY-MM-DD` formatter. POSIX locale so the format is
    /// stable regardless of the device's regional settings; `current` timezone
    /// so the day-key matches the user's calendar day, not UTC.
    private nonisolated static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    // MARK: - UTC day-key space (W-B180 night navigation)

    /// `YYYY-MM-DD` of a wake-day instant that is ALREADY a day-key anchor
    /// (the DTO's `night` decodes as midnight UTC). Formatted in UTC so the
    /// device timezone can never shift the key by a day.
    public nonisolated static func utcDayKey(for date: Date) -> String {
        utcDayKeyFormatter.string(from: date)
    }

    /// Parses a `YYYY-MM-DD` day-key back to its midnight-UTC anchor —
    /// the inverse of ``utcDayKey(for:)`` for ←/→ day arithmetic.
    public nonisolated static func date(fromDayKey dayKey: String) -> Date? {
        utcDayKeyFormatter.date(from: dayKey)
    }

    private nonisolated static let utcDayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
