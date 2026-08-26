import Foundation

/// A2-M4 — appear-revalidation freshness gate for list stores.
///
/// The list screens (Workouts / Achievements / Mood / PersonalRecords /
/// MeasurementList) historically guarded their `.task` reload on
/// `if data.isEmpty`. That correctly covers the empty + pure-failure cases, but
/// a *partial-then-stale* screen (a prior load partially succeeded, then the
/// data went stale or a later refresh errored) would NOT auto-refresh on
/// re-entry — the user had to pull-to-refresh manually. This mirrors the
/// TTL-driven revalidate-on-appear contract that Dashboard / Insights already
/// honour: a re-appear within the window is a no-op (cache stays warm), past the
/// window it re-validates.
///
/// Pure value type with an injected `now` seam so the staleness decision is
/// unit-testable without standing up a store. The underlying repositories are
/// themselves SWR-cached, so a re-validate that lands inside the repo's own TTL
/// is served from cache (no redundant network) — this gate only decides whether
/// the store should *ask*.
struct RevalidationGate {
    /// Freshness window. A re-appear within this interval of the last recorded
    /// load is considered fresh and skipped.
    let ttl: TimeInterval

    /// Wall-clock of the last recorded successful load. `nil` until the first.
    private(set) var lastLoadedAt: Date?

    init(ttl: TimeInterval) {
        self.ttl = ttl
    }

    /// Records a completed load so subsequent `isStale` checks measure from now.
    mutating func markLoaded(now: Date = .now) {
        lastLoadedAt = now
    }

    /// `true` when the data has never loaded or the freshness window elapsed.
    func isStale(now: Date = .now) -> Bool {
        guard let last = lastLoadedAt else { return true }
        return now.timeIntervalSince(last) >= ttl
    }
}
