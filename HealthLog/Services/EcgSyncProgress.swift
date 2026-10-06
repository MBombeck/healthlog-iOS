import Foundation

// S2 (#115, server comments of 2026-10-01) — the ECG sweep makes progress at
// any server limit.
//
// Build 287 held ONE cursor for the whole stream: the HealthKit anchor moved
// only once every recording of a fetch had come back as a success. A 429 in
// the middle stopped the sweep and held that anchor, so the next wake re-read
// the same recordings and re-posted every one of them from the first — the
// ones the server had already confirmed came back `updated` / `duplicate`
// again, and the request that broke the budget last time broke it again. With
// more pending recordings than the per-minute limit the sweep could never
// finish, and the newest ECG, at the end of the insertion-ordered list, never
// arrived.
//
// Three pieces close that loop for every limit, without touching the anchor
// rule that keeps delivery fail-closed:
//
//   * ``EcgConfirmedLedger`` — a per-account set of recording ids the server
//     has confirmed. A confirmed recording is never posted again while the
//     anchor still covers it, so a held anchor costs a cheap metadata read,
//     not a replay. The ids are cleared from the ledger once the anchor moves
//     past them, and the whole ledger goes with the anchor on logout, account
//     switch or opt-out.
//   * newest first — within one fetch the recordings are sent by `recordedAt`,
//     newest first. The anchor still advances only when every recording of the
//     fetch is confirmed, so the order cannot open a gap.
//   * ``EcgRateLimitPacer`` + ``EcgSyncPause`` — a 429 names its wait
//     (`Retry-After`, read by `RateLimitDelay`). The sweep sits it out inside
//     its own pause budget and re-sends the SAME recording; a longer wait ends
//     the sweep and keeps the next wake from knocking before the named instant.

/// One account's confirmed ECG recordings, persisted next to its anchor.
///
/// Holds `HKSample.uuid` strings only — opaque identifiers, never a value, a
/// verdict or a timestamp. The partition token is the anchor's, so the two can
/// never belong to different accounts.
struct EcgConfirmedLedger {
    let defaults: UserDefaults
    let key: String

    /// The ids confirmed so far. An unreadable value reads as empty, which
    /// costs at worst a re-post the server answers `updated` / `duplicate`.
    func load() -> Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }

    /// Remember one confirmed recording. Written immediately, so a sweep that
    /// dies on the next request keeps this one.
    func insert(_ id: String) {
        var ids = load()
        guard ids.insert(id).inserted else { return }
        store(ids)
    }

    /// Drop ids the anchor has moved past: HealthKit will not hand them out
    /// again, so remembering them would only grow the list.
    func remove(_ consumed: some Sequence<String>) {
        var ids = load()
        let before = ids.count
        ids.subtract(consumed)
        guard ids.count != before else { return }
        store(ids)
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }

    private func store(_ ids: Set<String>) {
        if ids.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(ids.sorted(), forKey: key)
        }
    }
}

/// How the ECG sweep waits out a 429. Task-local so a test binds an instant,
/// recording sleeper (and a throwing one for a background window that ends)
/// instead of waiting on the wall clock. Same seam as ``OutboxReplayPause``.
enum EcgSyncPause {
    @TaskLocal static var sleep: @Sendable (TimeInterval) async throws -> Void = { seconds in
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

/// The sweep's memory of the server's last 429. Lives as long as the
/// coordinator (one per process); a relaunch simply asks the server again.
struct EcgRateLimitPacer {
    /// Total seconds one sweep may pause for 429s before it hands the wait to
    /// the next wake. One window of the server's per-minute bucket.
    static let pauseBudget: TimeInterval = 60
    /// 429s one sweep re-sends after, whatever their waits added up to.
    static let maxRetriesPerSweep = 5
    /// First fallback wait when a 429 names none; doubles per consecutive 429.
    static let fallbackBase: TimeInterval = 30
    static let fallbackCeiling: TimeInterval = 600
    /// Ceiling of any hold, so a garbled header cannot park ECG for days.
    static let holdCeiling: TimeInterval = 3600

    /// No recording is sent before this instant.
    private(set) var holdUntil: Date?
    /// 429s in a row without a confirmed recording in between.
    private(set) var consecutive = 0

    /// Record a 429 and the wait it named (or the fallback when it named none).
    mutating func recordRateLimit(retryAfter: TimeInterval?, now: Date) {
        consecutive += 1
        let wait: TimeInterval
        if let retryAfter, retryAfter.isFinite {
            wait = min(max(retryAfter, 1), Self.holdCeiling)
        } else {
            let exponent = Double(min(max(consecutive - 1, 0), 10))
            wait = min(Self.fallbackBase * pow(2, exponent), Self.fallbackCeiling)
        }
        holdUntil = now.addingTimeInterval(wait)
    }

    /// A confirmed recording: the bucket is open again.
    mutating func recordDelivery() {
        consecutive = 0
        holdUntil = nil
    }

    /// Seconds still to wait at `now`, or `nil` when nothing holds the sweep.
    func remainingHold(now: Date) -> TimeInterval? {
        guard let holdUntil, now < holdUntil else { return nil }
        return holdUntil.timeIntervalSince(now)
    }
}
