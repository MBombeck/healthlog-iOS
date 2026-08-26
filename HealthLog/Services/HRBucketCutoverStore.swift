import Foundation

/// Per-User UTC-day boundary marking when the client switches heart-rate
/// upload from per-sample (raw) to hourly `stats:` buckets.
///
/// **Why a cutover boundary at all? (W-HR-BUCKET-UPLOAD / GH #34)**
/// The server's nightly PULSE consolidation folds raw per-sample HR rows and
/// *ignores* the hourly `stats:` rows. So a single UTC day must NOT carry BOTH
/// raw per-sample HR rows AND hourly `stats:` HR rows from the client — the
/// rollup mean would double-count. A clean per-day boundary is the only way to
/// guarantee that invariant: every day is either entirely raw (pre-cutover) or
/// entirely bucketed (on-or-after cutover), never both.
///
/// **The marker:** `hrBucketCutoverDayUTC` is the UTC start-of-day (`Date`,
/// `timeIntervalSinceReferenceDate`) of the FIRST day that uploads hourly
/// buckets. It is set ONCE — on the first launch that runs the feature — to the
/// **next** UTC midnight after `now`. That means:
/// - the partial current UTC day (between first-launch and the next UTC
///   midnight) keeps flowing per-sample → today never gets both raw + bucket;
/// - days strictly before the cutover stay per-sample (already uploaded raw;
///   server folds them) → no buckets are produced for them;
/// - days on-or-after the cutover upload hourly `stats:` buckets AND the
///   per-sample HR upload is suppressed for those days → bucket-only.
///
/// **Partition shape:** `hl.healthkit.hrBucketCutoverDayUTC.<userId-token>`,
/// mirroring ``HealthKitBackfillWindowStore`` (same UserDefaults trade-off — the
/// cutover day is not a secret and battery-cost of a Keychain roundtrip on every
/// HR sample wakeup is not worth paying). The partition token reuses
/// ``HealthKitBackfillWindowStore/partitionToken(for:)`` so a logout/relogin to a
/// different account does not inherit the previous user's cutover.
enum HRBucketCutoverStore {
    static let defaultsKeyPrefix = "hl.healthkit.hrBucketCutoverDayUTC."

    /// UTC calendar — the cutover boundary is TZ-stable (the `stats:` externalId
    /// hour key is UTC, so the per-day boundary that gates it must be UTC too;
    /// otherwise a user crossing time zones could flip a day from raw→bucket and
    /// double-count).
    static var utcCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        // swiftlint:disable:next force_unwrapping — "UTC" is a guaranteed system TZ.
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    static func key(for userId: String?) -> String {
        defaultsKeyPrefix + HealthKitBackfillWindowStore.partitionToken(for: userId)
    }

    /// Reads the persisted cutover boundary, arming it on first access.
    ///
    /// If no cutover has been persisted yet for this user, this sets it to the
    /// **next** UTC midnight after `now` and returns that value (run-once arm).
    /// Subsequent calls return the same persisted value. The arm-on-read shape
    /// means the very first HR sweep (or the first per-sample gate evaluation)
    /// pins the boundary deterministically — there is no separate bootstrap call
    /// to forget.
    ///
    /// Idempotent + side-effect-once. `nonisolated`-safe: only touches
    /// UserDefaults + a pure UTC calendar computation, so the actor-isolated
    /// `HealthLogStandard` gate and the off-main HR sweep can both call it.
    @discardableResult
    static func cutover(
        userId: String?,
        now: Date = Date(),
        defaults: UserDefaults = .standard
    ) -> Date {
        let key = key(for: userId)
        let stored = defaults.object(forKey: key) as? Date
        if let stored {
            return stored
        }
        let armed = nextUTCMidnight(after: now)
        defaults.set(armed, forKey: key)
        return armed
    }

    /// Pure peek — returns the persisted cutover WITHOUT arming it. Used by
    /// tests + diagnostics that must not mutate the marker.
    static func persistedCutover(
        userId: String?,
        defaults: UserDefaults = .standard
    ) -> Date? {
        defaults.object(forKey: key(for: userId)) as? Date
    }

    /// `true` if a sample/bucket dated at `date` is on-or-after the cutover
    /// boundary — i.e. it belongs to the bucket-only regime. Arms the cutover on
    /// first call (see ``cutover(userId:now:defaults:)``).
    ///
    /// This is THE single predicate that guarantees per-day exclusivity:
    /// - per-sample HR path drops a sample when `isOnOrAfterCutover(sample.endDate)`;
    /// - HR bucket sweep only emits buckets whose hour-start `isOnOrAfterCutover`.
    /// Both read the same boundary, so no UTC day can ever yield both shapes.
    static func isOnOrAfterCutover(
        _ date: Date,
        userId: String?,
        now: Date = Date(),
        defaults: UserDefaults = .standard
    ) -> Bool {
        let boundary = cutover(userId: userId, now: now, defaults: defaults)
        return date >= boundary
    }

    /// Clears the persisted cutover. Called by the logout cleanup so a re-login
    /// with a different account re-arms the boundary fresh.
    static func clear(for userId: String?, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(for: userId))
    }

    /// Start of the next UTC day strictly after `date`. If `date` is exactly at
    /// a UTC midnight, this returns the FOLLOWING midnight (24 h later) — the
    /// current day always stays per-sample, never both raw + bucket.
    static func nextUTCMidnight(after date: Date) -> Date {
        let cal = utcCalendar
        let startOfToday = cal.startOfDay(for: date)
        return cal.date(byAdding: .day, value: 1, to: startOfToday) ?? startOfToday
    }
}
