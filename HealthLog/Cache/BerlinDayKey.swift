import Foundation

/// Berlin-calendar-day discriminator for the daily-generated Insights cache
/// (W3 / v0.11 Wave #22).
///
/// The server regenerates per-metric assessments + the comprehensive digest +
/// the advisor briefing roughly **once per day**, keyed by the **Berlin
/// calendar day** (web ref `src/lib/insights/status-cache.ts:63-113`). A
/// today-miss SWR-serves *yesterday's* good text while the server enqueues a
/// fresh generation out-of-band.
///
/// iOS mirrors that cadence by **anchoring the cache key to the Berlin day**.
/// When the Berlin day rolls over at local midnight the key string changes
/// (`2026-06-02` → `2026-06-03`), so the previous day's `CachedSnapshot` row
/// no longer matches the new key — the next read is a structural cache-miss
/// that forces a refetch of the freshly-generated content. Within a single
/// Berlin day the row matches and the short `staleAfter` window governs
/// background revalidation (mirroring the web `staleTime`), so a quick
/// background→foreground bounce paints from cache with no redundant round-trip.
///
/// This is intentionally a *pure value* (a `yyyy-MM-dd` string) with no actor
/// isolation — it is computed on the call-site's thread from a deterministic
/// `Date` + a fixed `Europe/Berlin` calendar, so it is trivially `Sendable`.
public enum BerlinDayKey {
    /// Fixed `Europe/Berlin` Gregorian calendar. Falls back to the device
    /// calendar's zone only if the (always-present) identifier somehow fails
    /// to resolve — the fallback keeps the key deterministic-per-process even
    /// in that impossible case rather than crashing the cache layer.
    static let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Berlin") ?? cal.timeZone
        return cal
    }()

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// `yyyy-MM-dd` string for `date` in the Berlin calendar. Stable for any
    /// instant within the same Berlin day; flips at Berlin local midnight.
    public static func string(for date: Date = .now) -> String {
        formatter.string(from: date)
    }

    /// Seconds remaining until the next Berlin local midnight from `date`.
    /// Used as the day-anchored `staleAfter` ceiling for the daily caches so a
    /// cached row is treated as fresh through the rest of *today* (the server
    /// won't regenerate again until tomorrow) but never beyond the rollover.
    /// Clamped to `[0, 24h]` so a DST fold can't produce a negative or absurd
    /// interval.
    public static func secondsUntilNextMidnight(from date: Date = .now) -> TimeInterval {
        guard let nextMidnight = calendar.nextDate(
            after: date,
            matching: DateComponents(hour: 0, minute: 0, second: 0),
            matchingPolicy: .nextTime
        ) else {
            return 60 * 60 // impossible fallback — one hour
        }
        let delta = nextMidnight.timeIntervalSince(date)
        return min(max(delta, 0), 24 * 60 * 60)
    }
}
