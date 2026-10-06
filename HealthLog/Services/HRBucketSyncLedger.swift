import Foundation
import Synchronization

/// Why the heart-rate bucket path did — or did not — upload, named after the
/// gate that decided it (#12).
///
/// The raw values are the words a tester reads in Sync Diagnostics and greps
/// for in Console (`HR-BUCKET … gate=<rawValue>`). They are fixed enum cases,
/// never data, so they are safe to log `.public`.
enum HRBucketGate: String, Codable, Sendable, CaseIterable {
    /// The sweep posted buckets and the server accepted every one of them.
    case uploaded
    /// The sweep ran and every bucket it found was already accepted.
    case upToDate
    /// Offline mode: there is no server to upload to.
    case standalone
    /// No bearer token in the Keychain (signed out).
    case noAuthToken
    /// `healthkit.enableHRBuckets` is off; heart rate stays per sample.
    case flagOff
    /// The bucket regime starts at the next UTC midnight; nothing is due yet.
    case cutoverPending
    /// HealthKit refused the statistics query because the device is locked.
    case healthDataLocked
    /// The statistics query failed for another reason.
    case queryFailed
    /// The upload hit a transient condition (offline, throttled, 5xx). The
    /// next sweep retries; the raw path keeps handing heart rate over.
    case uploadDeferred
    /// The server did not accept the buckets (a non-terminal skip, a 4xx, an
    /// undecodable answer). The raw path falls back for days without buckets.
    case uploadFailed
    /// Raw fallback: the last sweep failed, so a heart-rate sample on a day
    /// without accepted buckets went up per sample instead of being dropped.
    case rawFallbackSweepFailed
    /// Raw fallback: heart rate was handed to the bucket path more than
    /// ``HRBucketSyncLedger/starvationLimit`` ago and no sweep has run since.
    case rawFallbackSweepStarved

    /// `true` for the outcomes that prove the bucket path works end to end.
    var isSuccess: Bool {
        self == .uploaded || self == .upToDate || self == .cutoverPending
    }
}

/// Per-account, device-local record of what the heart-rate bucket path has
/// proven to the server, one UTC day at a time (#12).
///
/// **Why a ledger and not a cursor.** Until 1.1.0 (289) the sweep kept one
/// cursor — the newest uploaded bucket — and re-read HealthKit from just before
/// it. Two things fell through that shape. A sample HealthKit receives after
/// the sweep (a Withings or Watch sync hours later) lands before the cursor and
/// was never read again. And a sweep that never ran left no trace at all, while
/// the per-sample path had already dropped the day's heart rate: a day with
/// neither raw rows nor buckets.
///
/// The ledger answers per UTC day instead:
/// - ``bucketDays`` — at least one bucket of the day was accepted. The day
///   belongs to the bucket shape; the per-sample path never falls back on it.
/// - ``rawDays`` — the per-sample path fell back for the day. The sweep never
///   buckets it, so the server never sees both shapes on one day.
/// - ``settledDays`` — a closed day that a successful sweep read in full. It is
///   not read again unless the per-sample path saw a late sample for it
///   (``dirtyDays``).
/// - ``accepted`` — for the open days (today and yesterday, UTC), the
///   fingerprint of every bucket the server accepted, so a sweep posts only
///   new or changed buckets.
///
/// **Partition** mirrors ``HRBucketCutoverStore``: one JSON value in
/// `UserDefaults` under `hl.healthkit.hrBucketLedger.<userId-token>`. Like the
/// bucket cursor it survives a logout, because it describes what this
/// account's server rows already are; another account reads its own key.
struct HRBucketSyncLedger: Codable, Equatable, Sendable {
    /// How long heart rate may wait for a sweep before the per-sample path
    /// stops trusting the bucket path for days that have no buckets yet.
    static let starvationLimit: TimeInterval = 3600

    /// Days kept in the sets; older entries are pruned on every write.
    static let retainedDays = 120

    var bucketDays: Set<Int> = []
    var rawDays: Set<Int> = []
    var settledDays: Set<Int> = []
    var dirtyDays: Set<Int> = []
    /// Open day → bucket start (whole seconds since the reference date) →
    /// fingerprint of the accepted values.
    var accepted: [Int: [Int: String]] = [:]

    /// Start of the newest bucket the server accepted.
    var lastAcceptedBucket: Date?
    /// When a sweep last completed without a failure.
    var lastSuccessAt: Date?
    /// When a sweep last ended in ``HRBucketGate/queryFailed`` or
    /// ``HRBucketGate/uploadFailed``.
    var lastFailureAt: Date?
    /// Set when the per-sample path drops heart rate and no sweep is owed yet;
    /// cleared by the next successful sweep that started after it.
    var owedSince: Date?

    /// The latest outcome of either path.
    var lastEvent: Event?
    /// The latest outcome that was not an upload — the gate that suppressed
    /// the sweep or the raw fallback that replaced it.
    var lastSuppression: Event?

    struct Event: Codable, Equatable, Sendable {
        var gate: HRBucketGate
        var at: Date
        var count: Int
    }

    /// Whether the per-sample path may hand heart rate to the bucket sweep.
    ///
    /// `false` when the last sweep failed (and nothing succeeded since), or
    /// when heart rate has been waiting for a sweep longer than
    /// ``starvationLimit``. Never `false` for lack of history: a fresh ledger
    /// trusts the path, and the first hand-off kicks the first sweep.
    func isBucketPathHealthy(now: Date) -> Bool {
        unhealthyReason(now: now) == nil
    }

    /// The raw-fallback gate that applies right now, or `nil` while the path
    /// is healthy.
    func unhealthyReason(now: Date) -> HRBucketGate? {
        if let failure = lastFailureAt, lastSuccessAt.map({ $0 < failure }) ?? true {
            return .rawFallbackSweepFailed
        }
        if let owedSince, now.timeIntervalSince(owedSince) > Self.starvationLimit {
            return .rawFallbackSweepStarved
        }
        return nil
    }

    mutating func record(_ gate: HRBucketGate, at date: Date, count: Int = 0) {
        let event = Event(gate: gate, at: date, count: count)
        lastEvent = event
        if gate != .uploaded {
            lastSuppression = event
        }
    }

    mutating func prune(today: Int) {
        let floor = today - Self.retainedDays
        bucketDays = bucketDays.filter { $0 >= floor }
        rawDays = rawDays.filter { $0 >= floor }
        settledDays = settledDays.filter { $0 >= floor }
        dirtyDays = dirtyDays.filter { $0 >= floor }
        accepted = accepted.filter { $0.key >= floor }
    }

    // MARK: - UTC day arithmetic

    /// The reference date (2001-01-01T00:00:00Z) is itself a UTC midnight, so
    /// whole-day division of `timeIntervalSinceReferenceDate` is the UTC day.
    static func day(of date: Date) -> Int {
        Int((date.timeIntervalSinceReferenceDate / 86400).rounded(.down))
    }

    static func start(ofDay day: Int) -> Date {
        Date(timeIntervalSinceReferenceDate: Double(day) * 86400)
    }

    static func slot(of bucketStart: Date) -> Int {
        Int(bucketStart.timeIntervalSinceReferenceDate.rounded(.down))
    }

    /// The accepted values of one bucket, at a precision the server stores.
    static func fingerprint(_ row: HealthKitHRBucketRow) -> String {
        String(format: "%.3f|%.3f|%.3f", row.averageBpm, row.minBpm, row.maxBpm)
    }
}

/// Load / mutate / clear for ``HRBucketSyncLedger``.
///
/// Every mutation is one read-modify-write under a process-wide lock: the
/// per-sample gate (on the `HealthLogStandard` actor) and the sweep (on the
/// coordinator actor) both write, and a sweep that saved a ledger it loaded
/// before an upload would erase a raw fallback recorded in the meantime.
enum HRBucketSyncLedgerStore {
    static let defaultsKeyPrefix = "hl.healthkit.hrBucketLedger."

    private static let lock = Mutex(())

    static func key(for userId: String?) -> String {
        defaultsKeyPrefix + HealthKitBackfillWindowStore.partitionToken(for: userId)
    }

    static func load(userId: String?, defaults: UserDefaults = .standard) -> HRBucketSyncLedger {
        lock.withLock { _ in read(userId: userId, defaults: defaults) }
    }

    /// Applies `mutate` atomically and persists the result when it changed.
    @discardableResult
    static func update<Result>(
        userId: String?,
        defaults: UserDefaults = .standard,
        now: Date = Date(),
        _ mutate: (inout HRBucketSyncLedger) -> Result
    ) -> Result {
        lock.withLock { _ in
            var ledger = read(userId: userId, defaults: defaults)
            let before = ledger
            let result = mutate(&ledger)
            ledger.prune(today: HRBucketSyncLedger.day(of: now))
            if ledger != before, let data = try? JSONEncoder().encode(ledger) {
                defaults.set(data, forKey: key(for: userId))
            }
            return result
        }
    }

    private static func read(userId: String?, defaults: UserDefaults) -> HRBucketSyncLedger {
        guard let data = defaults.data(forKey: key(for: userId)),
              let ledger = try? JSONDecoder().decode(HRBucketSyncLedger.self, from: data) else
        {
            return HRBucketSyncLedger()
        }
        return ledger
    }
}

/// The per-sample half of the hand-off: may this heart-rate sample be dropped
/// because the bucket sweep owns its day? (#12)
///
/// Until 1.1.0 (289) the answer was "yes, whenever the day uploads as buckets",
/// whether or not a bucket ever reached the server. Now a sample is dropped
/// only while the bucket path is healthy, or when its day already carries
/// accepted buckets. Otherwise it goes up per sample and its day is recorded
/// as raw, so the sweep leaves that day alone and the server never holds both
/// shapes for it.
enum HRBucketRawGate {
    /// `true` ⇒ drop the sample from the per-sample batch.
    static func shouldDrop(
        sampleDate: Date,
        userId: String?,
        now: Date = Date(),
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard HRUploadModeSchedule.mode(at: sampleDate, userId: userId, now: now, defaults: defaults) == .buckets else {
            return false
        }
        let day = HRBucketSyncLedger.day(of: sampleDate)
        var fallback: HRBucketGate?
        let drop = HRBucketSyncLedgerStore.update(userId: userId, defaults: defaults, now: now) { ledger -> Bool in
            if ledger.rawDays.contains(day) { return false }
            let ownedByBuckets = ledger.bucketDays.contains(day) || ledger.settledDays.contains(day)
            if !ownedByBuckets, let gate = ledger.unhealthyReason(now: now) {
                // Recorded and logged once per day, not once per sample.
                ledger.rawDays.insert(day)
                ledger.dirtyDays.remove(day)
                ledger.accepted[day] = nil
                ledger.record(gate, at: now)
                fallback = gate
                return false
            }
            // A late sample for a day the sweep already closed: read it again.
            if ledger.settledDays.contains(day) {
                ledger.dirtyDays.insert(day)
            }
            if ledger.owedSince == nil {
                ledger.owedSince = now
            }
            return true
        }
        if let fallback {
            // The gate name is a fixed enum case and the day an index — no
            // sample, value or account. `.public` is correct here.
            // swiftlint:disable:next hllog_public_privacy_interpolation
            HLLog.healthKit.notice("HR-BUCKET raw fallback — gate=\(fallback.rawValue, privacy: .public)")
        }
        return drop
    }
}
