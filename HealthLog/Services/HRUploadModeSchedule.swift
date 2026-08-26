import Foundation

/// Which shape heart rate takes on its way to the server.
///
/// The two shapes are mutually exclusive **per UTC day** — see
/// ``HRUploadModeSchedule`` for why, and for the machinery that guarantees it.
public enum HRUploadMode: String, Codable, Sendable, Equatable {
    /// One row per completed 10-minute UTC bucket
    /// (`stats:HKQuantityTypeIdentifierHeartRate:<bucket-start>`), average bpm
    /// plus the bucket low/high. The shape since GH #34, and the default.
    case buckets
    /// One row per HealthKit measurement, `externalId = sample uuid`. The shape
    /// before GH #34; reachable again through the operator switch.
    case raw
}

/// Per-User, device-local **schedule** of which HR upload shape applies to which
/// UTC day.
///
/// **What this adds to ``HRBucketCutoverStore``.** That store answers one
/// question, once: "from which UTC day on does this device upload buckets?" It
/// arms a single boundary, and every day on-or-after it is bucketed forever.
/// The operator experiment (GH #34 follow-up — "let's just send everything and
/// see") needs the same answer to be able to change again, in both directions,
/// as often as the operator likes. So the boundary becomes a *step function*:
/// the armed cutover is the first step, and every operator switch appends one
/// more.
///
/// **The invariant is unchanged and is the whole point.** The server's nightly
/// PULSE consolidation folds raw per-sample rows and ignores `stats:` rows, so a
/// UTC day that carried BOTH would be counted twice. Therefore:
///
/// - ``mode(at:userId:now:defaults:)`` is the single predicate. The per-sample
///   gate in `HealthLogStandard` drops a heartRate sample iff its mode is
///   `.buckets`; the bucket sweep in `HealthKitHRBucketSyncCoordinator` emits a
///   bucket iff its mode is `.buckets`. One function, two readers, no
///   disagreement possible.
/// - Every `effectiveFrom` is a **UTC midnight**
///   (``HRBucketCutoverStore/nextUTCMidnight(after:)``), so the step function is
///   constant across each UTC day. A switch can never split a day.
/// - A switch requested at time *t* takes effect at the next UTC midnight
///   **strictly after** *t*, in both directions. The day the operator taps on is
///   already partly uploaded in the old shape and keeps it.
///
/// **The past is never rewritten.** Days that have already been uploaded keep
/// the mode they were uploaded under, because their mode is decided by the steps
/// that were already settled back then, and switching only ever appends a step
/// in the future. There is deliberately no backfill: re-sending a bucketed day
/// as raw measurements would produce exactly the double count the whole
/// construction exists to prevent.
///
/// **Storage** mirrors ``HRBucketCutoverStore`` — JSON in `UserDefaults` under
/// `hl.healthkit.hrUploadModeSchedule.<userId-token>`, same partition token, and
/// cleared by the same logout cleanup. The schedule is a statement about *one
/// account's* server rows; letting it survive into a different account would
/// silently multiply that account's upload volume without anyone choosing it
/// there.
enum HRUploadModeSchedule {
    static let defaultsKeyPrefix = "hl.healthkit.hrUploadModeSchedule."

    /// One step of the schedule: from `effectiveFrom` (a UTC midnight) onwards,
    /// heart rate uploads in `mode` — until a later step says otherwise.
    struct Change: Codable, Sendable, Equatable {
        let effectiveFrom: Date
        let mode: HRUploadMode
    }

    static func key(for userId: String?) -> String {
        defaultsKeyPrefix + HealthKitBackfillWindowStore.partitionToken(for: userId)
    }

    /// The persisted steps, ascending. A corrupt/absent payload reads as "no
    /// operator override" — the base cutover then decides, which is the
    /// shipping default and therefore the safe fallback.
    static func changes(userId: String?, defaults: UserDefaults = .standard) -> [Change] {
        guard let data = defaults.data(forKey: key(for: userId)),
              let decoded = try? JSONDecoder().decode([Change].self, from: data) else
        {
            return []
        }
        return decoded.sorted { $0.effectiveFrom < $1.effectiveFrom }
    }

    /// **THE predicate.** Which shape does a sample / bucket dated `date` belong
    /// to? The latest step at-or-before `date` wins; with no step, the armed
    /// cutover decides (pre-cutover ⇒ `.raw`, on-or-after ⇒ `.buckets`).
    ///
    /// Arms the cutover on first call, exactly like
    /// ``HRBucketCutoverStore/isOnOrAfterCutover(_:userId:now:defaults:)`` did
    /// before — the arm-on-read shape is what makes the boundary deterministic
    /// without a bootstrap call anyone could forget.
    static func mode(
        at date: Date,
        userId: String?,
        now: Date = Date(),
        defaults: UserDefaults = .standard,
        rawExperimentAvailable: Bool = FeatureFlags.rawHeartRateExperimentAvailable
    ) -> HRUploadMode {
        reconcileProductionPolicy(
            userId: userId,
            now: now,
            defaults: defaults,
            rawExperimentAvailable: rawExperimentAvailable
        )
        return mode(
            at: date,
            in: changes(userId: userId, defaults: defaults),
            userId: userId,
            now: now,
            defaults: defaults
        )
    }

    /// The mode in effect *right now* — what the surface reports as the live
    /// state.
    static func currentMode(
        userId: String?,
        now: Date = Date(),
        defaults: UserDefaults = .standard
    ) -> HRUploadMode {
        mode(at: now, userId: userId, now: now, defaults: defaults)
    }

    /// The scheduled-but-not-yet-effective step, if the operator has flipped the
    /// switch today. `nil` once it has taken effect (or when nothing is
    /// pending).
    static func pendingChange(
        userId: String?,
        now: Date = Date(),
        defaults: UserDefaults = .standard
    ) -> Change? {
        changes(userId: userId, defaults: defaults).last { $0.effectiveFrom > now }
    }

    /// Record the operator's choice. Returns the scheduled step, or `nil` when
    /// the desired mode is already the one in effect (nothing to schedule).
    ///
    /// Two rules do the work:
    ///
    /// 1. **Settled steps are frozen.** Anything whose `effectiveFrom` has
    ///    already passed stays — those days are uploaded, their shape is
    ///    history.
    /// 2. **A pending step is replaced, not stacked.** Flipping the switch twice
    ///    before midnight leaves at most one step for that midnight; flipping it
    ///    back leaves none, so the day arrives unchanged. The operator can
    ///    change their mind all day for free.
    @discardableResult
    static func setDesiredMode(
        _ desired: HRUploadMode,
        userId: String?,
        now: Date = Date(),
        defaults: UserDefaults = .standard,
        rawExperimentAvailable: Bool = FeatureFlags.rawHeartRateExperimentAvailable
    ) -> Change? {
        if desired == .raw, !rawExperimentAvailable {
            reconcileProductionPolicy(
                userId: userId,
                now: now,
                defaults: defaults,
                rawExperimentAvailable: false
            )
            return nil
        }
        let settled = changes(userId: userId, defaults: defaults).filter { $0.effectiveFrom <= now }
        let effective = mode(at: now, in: settled, userId: userId, now: now, defaults: defaults)
        guard desired != effective else {
            persist(settled, userId: userId, defaults: defaults)
            return nil
        }
        let change = Change(
            effectiveFrom: HRBucketCutoverStore.nextUTCMidnight(after: now),
            mode: desired
        )
        persist(settled + [change], userId: userId, defaults: defaults)
        return change
    }

    /// Drops the schedule. Called by the logout cleanup alongside
    /// ``HRBucketCutoverStore/clear(for:defaults:)`` — the next account arms its
    /// own boundary and starts from the shipping default.
    static func clear(for userId: String?, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(for: userId))
    }

    // MARK: - Internals

    /// Release builds cannot continue or schedule the undocumented raw-HR
    /// experiment. Existing, already-settled days are preserved so the bucket
    /// path never re-emits a day that may already contain raw rows. Any pending
    /// raw step is removed; when raw is currently effective, buckets begin at
    /// the next UTC midnight so the in-progress day remains single-shaped.
    private static func reconcileProductionPolicy(
        userId: String?,
        now: Date,
        defaults: UserDefaults,
        rawExperimentAvailable: Bool
    ) {
        guard !rawExperimentAvailable else { return }
        let allChanges = changes(userId: userId, defaults: defaults)
        let settled = allChanges.filter { $0.effectiveFrom <= now }
        let effective = mode(at: now, in: settled, userId: userId, now: now, defaults: defaults)
        if effective == .raw {
            let bucketStep = Change(
                effectiveFrom: HRBucketCutoverStore.nextUTCMidnight(after: now),
                mode: .buckets
            )
            persist(settled + [bucketStep], userId: userId, defaults: defaults)
        } else if settled != allChanges {
            persist(settled, userId: userId, defaults: defaults)
        }
    }

    private static func mode(
        at date: Date,
        in changes: [Change],
        userId: String?,
        now: Date,
        defaults: UserDefaults
    ) -> HRUploadMode {
        if let step = changes.last(where: { $0.effectiveFrom <= date }) {
            return step.mode
        }
        return HRBucketCutoverStore.isOnOrAfterCutover(
            date,
            userId: userId,
            now: now,
            defaults: defaults
        ) ? .buckets : .raw
    }

    private static func persist(_ changes: [Change], userId: String?, defaults: UserDefaults) {
        guard !changes.isEmpty else {
            defaults.removeObject(forKey: key(for: userId))
            return
        }
        guard let data = try? JSONEncoder().encode(changes) else {
            HLLog.healthKit.error("HR-UPLOAD-MODE schedule could not be encoded — keeping the previous one")
            return
        }
        defaults.set(data, forKey: key(for: userId))
    }
}
