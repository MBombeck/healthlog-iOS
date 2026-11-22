import Foundation
#if canImport(HealthKit)
    import HealthKit
#endif

#if canImport(HealthKit)

    /// **Phase C2 — import Apple Health reproductive-category samples into the
    /// HealthLog cycle model.**
    ///
    /// A dedicated direct-`HKHealthStore` observe path (cycle category types are
    /// reproductive-health, not expressible in the SpeziHealthKit `CollectSamples`
    /// DSL), structurally mirroring ``MoodStateOfMindImporter``: one
    /// `HKObserverQuery` per cycle category type (long-running, low-volume) + an
    /// `HKAnchoredObjectQuery` batch per type, persisting per-type anchors in
    /// UserDefaults (battery rationale, per-user partition — PROJECT_GUIDE.md).
    ///
    /// **Echo guard (PROJECT_GUIDE.md mandate + contract §5).** Every sample
    /// ``CycleHealthKitWriter`` writes carries `HKMetadataKeyExternalUUID =
    /// dayLog.id`. On import we **skip any sample that carries that key** — it is
    /// our own write echoing back. Only foreign samples (Apple Health UI, Cycle
    /// app, other apps) map to a ``CycleDayLogWrite`` with `source:"APPLE_HEALTH"` +
    /// the HK sample UUID as `externalId`, drained through the bulk endpoint.
    ///
    /// **Flow.** Prefers `HKCategoryValueVaginalBleeding` (iOS 18 reproductive
    /// type) with a legacy `HKCategoryValueMenstrualFlow` fallback; both fold to
    /// the same contract flow enum via ``CycleHealthKitMapping``.
    ///
    /// **Same-date merge.** Multiple foreign samples on the same calendar day
    /// merge into ONE `CycleDayLogWrite` (one canonical row/date, server keys on
    /// date); the externalId is the date-stable `cycle-hk:<YYYY-MM-DD>` so a
    /// re-import upserts rather than duplicating.
    ///
    /// Gated by `CycleGate` — the owner only constructs + starts this once the gate passes (never for men).
    ///
    /// **Admitted, owner-partitioned, durable.**
    ///
    ///   * A sweep is admitted before it queries. The account comes from one
    ///     ``HealthSyncAuthenticatedLease`` captured before the first suspension
    ///     and revalidated around every wire call and every cursor write; the
    ///     partition it may write is derived from that lease's
    ///     ``HealthSyncOwnerLease`` rather than from the user id the importer
    ///     happened to be constructed with.
    ///   * The per-type anchor is committed through ``HealthSyncCursorPolicy``.
    ///     The bulk response is read **per index**: a row the server never
    ///     mentioned, or skipped, is not evidence, and the affected day-logs
    ///     become durable outbox rows under a restart-stable key before the
    ///     cursor for that type may move. A failed sibling type never rides a
    ///     successful one's commit — every type owns its own cursor.
    ///   * Observer work is owned: each signal becomes a registered, coalesced
    ///     task and `stop()` cancels **and drains** them, so a gate close or an
    ///     account teardown cannot leave a sweep running under the account that
    ///     just went away.
    actor CycleHealthKitImporter {
        let store: HKHealthStore
        let repo: CycleRepository
        let anchorPrefix: String
        /// The partition token the importer was constructed for. An admitted
        /// owner whose token differs is a different account, and this importer
        /// refuses to sweep for it rather than writing into the wrong anchor.
        let partitionToken: String
        let defaults: UserDefaults
        let admission: (@Sendable () throws -> HealthSyncAuthenticatedLease)?
        let cursors: DurableHealthCursorStore?
        /// The zone a sample's day is cut in: the account's
        /// (``ProfileDay``). Injectable for tests.
        let profileTimeZone: @Sendable () -> TimeZone
        /// Sample UUID to day, so a deletion in Apple Health finds its day-log
        /// (``CycleSampleDayMap``).
        let sampleDays: CycleSampleDayStore
        /// The outbox, asked for at the moment it is needed: the composition
        /// root binds it after this importer may already run. Queued day-logs
        /// of a deleted day leave it before the delete goes out.
        let retryQueue: (@Sendable () async -> (any HealthSyncBatchRetryEnqueuing)?)?
        /// Every sample of one type that starts in `[from, to)`, for the
        /// earliest temperature of a day and the rebuild of a day after a
        /// deletion. `nil` reads HealthKit; tests hand samples in.
        let rangeSamples: (@Sendable (HKSampleType, Date, Date) async throws -> [HKSample])?
        /// The one-time local seed of ``sampleDays`` in flight, so two
        /// interleaved sweeps read HealthKit for it only once.
        var sampleDaySeed: Task<Bool, Never>?
        private var observers: [HKObserverQuery] = []
        /// Serializes sweeps per category type: actor reentrancy would
        /// otherwise let two rapid observer fires interleave two sweeps from
        /// the same per-type anchor (server-deduped, but redundant network).
        /// A mid-sweep fire coalesces into one trailing re-run for that type.
        let sweepGate = SweepCoalescer(label: "cycle")
        /// Owned observer work. Not fire-and-forget: `stop()` cancels every
        /// entry and waits for it, which is what makes the teardown a fact
        /// rather than a request.
        private var observerTasks: [UUID: Task<Void, Never>] = [:]
        /// Per-call sweep results, handed back across the coalescer's `@Sendable`
        /// body (which cannot write a captured local).
        var sweepDispositions: [UUID: HealthSyncDisposition] = [:]
        /// Partitions whose migration record has already been established in
        /// this process. The store refuses a repeated migration anyway.
        var migratedPartitions: Set<String> = []

        /// **Logout-race invariant (audit M4).** `anchorPrefix` is captured
        /// HERE, at construction, from the user-id the importer was built for.
        /// `resetAnchors()` operates ONLY on this cached prefix — it must never
        /// re-resolve `KeychainKey.userID`. The 401 bridge wipes the keychain
        /// user-id inside `AuthStore.handleUnauthorized()` and dispatches the HK
        /// cleanup via `Task.detached`, so a reset that re-read the keychain
        /// could observe a half-wiped (`_anonymous`) id and clear the WRONG
        /// partition, stranding the previous user's anchor. The cached prefix
        /// closes that race; `HKImporterResetIsolationTests` pins it.
        init(
            store: HKHealthStore,
            repo: CycleRepository,
            userID: String?,
            defaults: UserDefaults = .standard,
            admission: (@Sendable () throws -> HealthSyncAuthenticatedLease)? = nil,
            cursors: DurableHealthCursorStore? = nil,
            profileTimeZone: @escaping @Sendable () -> TimeZone = { ProfileDay.timeZone },
            sampleDays: CycleSampleDayStore = .standard,
            retryQueue: (@Sendable () async -> (any HealthSyncBatchRetryEnqueuing)?)? = nil,
            rangeSamples: (@Sendable (HKSampleType, Date, Date) async throws -> [HKSample])? = nil
        ) {
            self.store = store
            self.repo = repo
            self.defaults = defaults
            self.admission = admission
            self.cursors = cursors
            self.profileTimeZone = profileTimeZone
            self.sampleDays = sampleDays
            self.retryQueue = retryQueue
            self.rangeSamples = rangeSamples
            partitionToken = HealthKitService.partitionToken(for: userID)
            anchorPrefix = "hl.cycle.hk.anchor." + partitionToken + "."
        }

        // MARK: - Lifecycle

        /// Start a long-running observer per cycle category type + run an initial
        /// anchored sweep. Idempotent — a second call is a no-op while live.
        @discardableResult
        func start() async -> HealthSyncDisposition {
            guard observers.isEmpty else { return .deferred }
            CycleBasalTemperature.recordCycleImport(active: true, defaults: defaults)
            for type in Self.readSampleTypes() {
                let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, error in
                    if let error {
                        HLLog.healthKit.error(
                            "cycle HK observer error: \(LogSanitizer.redact(String(describing: error)), privacy: .public)"
                        )
                    } else {
                        // The signal becomes owned work on the actor and the
                        // observer's completion handler is told "done"
                        // immediately: HealthKit must not be kept waiting on a
                        // network round-trip, and the sweep must not outlive a
                        // teardown unobserved. Both, rather than either.
                        Task { [weak self] in await self?.enqueueObservedSweep(type: type) }
                    }
                    completion()
                }
                observers.append(query)
                store.execute(query)
            }
            return await refresh()
        }

        /// One explicit, bounded sweep of every cycle type without replacing the
        /// observer — the entry point an orchestrated trigger calls.
        ///
        /// Bounded by construction: exactly one anchored page per type per call
        /// (the coalescer's trailing re-run is what an observer burst collapses
        /// into), and the result is a named disposition rather than "it ran".
        @discardableResult
        func refresh() async -> HealthSyncDisposition {
            var results: [HealthSyncDisposition] = []
            for type in Self.readSampleTypes() {
                // A teardown that lands mid-refresh stops the remaining types
                // rather than sweeping them under an account that is going away.
                guard !Task.isCancelled else {
                    results.append(.deferred)
                    break
                }
                await results.append(runAnchoredSweep(type: type))
            }
            return Self.aggregate(results)
        }

        /// Stop every observer (gate closed / logout) and drain every sweep it
        /// started.
        ///
        /// Cancellation alone is a request; the drain is what makes the teardown
        /// true. A cancelled sweep commits nothing — the commit rule holds on
        /// `wasCancelled` — so the drain costs a wait, never a write.
        func stop() async {
            for query in observers {
                store.stop(query)
            }
            observers.removeAll()
            CycleBasalTemperature.recordCycleImport(active: false, defaults: defaults)
            let draining = observerTasks
            observerTasks.removeAll()
            for task in draining.values {
                task.cancel()
            }
            for task in draining.values {
                await task.value
            }
        }

        /// Reset every per-type import anchor (logout / user-change). Mirrors the
        /// MoodStateOfMindImporter rationale: a different user signing in must
        /// start from a clean anchor, never silently sweeping prior history into
        /// whoever is logged in. Safe because the gate is simultaneously closed.
        ///
        /// **Invariant (audit M4):** clears keys derived from the `anchorPrefix`
        /// captured at `init`. Does NOT re-read `KeychainKey.userID` — the
        /// keychain may already be wiped by the concurrent logout cascade.
        func resetAnchors() {
            for type in Self.readSampleTypes() {
                defaults.removeObject(forKey: anchorKey(for: type))
            }
            sampleDays.remove(partitionToken: partitionToken)
        }

        // MARK: - Owned observer work

        /// Registers one observer signal as owned, coalesced work.
        func enqueueObservedSweep(type: HKSampleType) {
            let id = UUID()
            observerTasks[id] = Task { [weak self] in
                _ = await self?.runAnchoredSweep(type: type)
                await self?.retireObserverTask(id)
            }
        }

        func retireObserverTask(_ id: UUID) {
            observerTasks[id] = nil
        }

        /// One anchored read of `type`: the new samples, the UUIDs HealthKit
        /// deleted since `anchor`, and the anchor after them. The basal body
        /// temperature reads one bounded page; the reproductive categories read
        /// everything, as before.
        ///
        /// N5.4 (v0.14.8 tech audit) — the sample array crosses from HK's
        /// callback queue into this actor through the continuation. Sound under
        /// complete strict-concurrency checking (HK objects are immutable +
        /// `Sendable` in current SDKs; exactly one resume per query).
        func fetch(
            type: HKSampleType,
            anchor: HKQueryAnchor?
        ) async throws -> CycleAnchoredPage {
            let limit = type.identifier == CycleBasalTemperature.identifier ? CycleBasalTemperature.pageLimit : HKObjectQueryNoLimit
            return try await withCheckedThrowingContinuation { continuation in
                let query = HKAnchoredObjectQuery(
                    type: type,
                    predicate: nil,
                    anchor: anchor,
                    limit: limit
                ) { _, samples, deleted, newAnchor, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    continuation.resume(returning: CycleAnchoredPage(
                        samples: samples ?? [],
                        deletedIDs: (deleted ?? []).map(\.uuid.uuidString),
                        newAnchor: newAnchor
                    ))
                }
                store.execute(query)
            }
        }

        // MARK: - Mapping → writes

        /// Group foreign samples by calendar day → one ``CycleDayLogWrite`` each.
        /// Skips our own echoes (samples carrying `HKMetadataKeyExternalUUID`).
        /// No iOS-18 gate needed — uses only the pure mapping + base HK category
        /// sample API (the surrounding sweep is `#available`-guarded).
        func buildWrites(from samples: [HKCategorySample], identifier: String) -> [CycleDayLogWrite] {
            let timeZone = profileTimeZone()
            var byDate: [String: CycleDayLogWrite] = [:]
            for sample in samples {
                // Echo guard — skip only OUR own write
                // round-tripping back (our externalUUID AND this app's HK
                // source). A third-party cycle sample carrying an externalUUID
                // now flows in instead of being silently dropped.
                if HealthKitSampleOwnership.isOwnEcho(sample) { continue }
                let protection = sample.metadata?[CycleHealthKitMapping.sexualActivityProtectionMeta] as? Bool
                let route = CycleHealthKitMapping.route(
                    identifier: identifier,
                    value: sample.value,
                    protectionUsed: protection
                )
                guard case let .dayLog(fields) = route else { continue }
                let dateKey = Self.dayKey(start: sample.startDate, end: sample.endDate, timeZone: timeZone)
                let loggedAt = Self.isoFormatter.string(from: sample.startDate)
                var write = byDate[dateKey] ?? CycleDayLogWrite(
                    date: dateKey,
                    loggedAt: loggedAt,
                    source: "APPLE_HEALTH",
                    externalId: "cycle-hk:\(dateKey)"
                )
                Self.merge(fields, into: &write)
                byDate[dateKey] = write
            }
            return Array(byDate.values)
        }

        /// Fold a partial HK field set into the day's accumulating write. Last
        /// non-nil value wins per field (HK samples on one day rarely conflict).
        private static func merge(_ fields: CycleHealthKitMapping.DayLogFields, into write: inout CycleDayLogWrite) {
            if let flow = fields.flow { write.flow = flow }
            if let bleeding = fields.intermenstrualBleeding { write.intermenstrualBleeding = bleeding }
            if let test = fields.ovulationTest { write.ovulationTest = test }
            if let mucus = fields.cervicalMucus { write.cervicalMucus = mucus }
            if let active = fields.sexualActivity { write.sexualActivity = active }
            if let prot = fields.protectedSex { write.protectedSex = prot }
            if let preg = fields.pregnancyTest { write.pregnancyTest = preg }
            if let prog = fields.progesteroneTest { write.progesteroneTest = prog }
            if let contra = fields.contraceptive { write.contraceptive = contra }
            if let symptom = fields.symptom {
                var symptoms = write.symptoms ?? []
                if !symptoms.contains(where: { $0.key == symptom.key }) { symptoms.append(symptom) }
                write.symptoms = symptoms
            }
        }

        /// Every type the import observes and reads: the reproductive
        /// categories and, since 1.7, the basal body temperature.
        static func readSampleTypes() -> [HKSampleType] {
            let categories: [HKSampleType] = readCategoryTypes()
            return categories + [CycleBasalTemperature.sampleType].compactMap { $0 }
        }

        /// The cycle category types we observe + read. Vaginal bleeding is the
        /// iOS-18 reproductive type; menstrual flow is the legacy fallback. Both
        /// are present so a device that only carries the legacy type still syncs.
        static func readCategoryTypes() -> [HKCategoryType] {
            let identifiers: [String] = [
                "HKCategoryTypeIdentifierMenstrualFlow",
                "HKCategoryTypeIdentifierIntermenstrualBleeding",
                "HKCategoryTypeIdentifierCervicalMucusQuality",
                "HKCategoryTypeIdentifierOvulationTestResult",
                "HKCategoryTypeIdentifierSexualActivity",
                "HKCategoryTypeIdentifierPregnancyTestResult",
                "HKCategoryTypeIdentifierProgesteroneTestResult",
                "HKCategoryTypeIdentifierContraceptive"
            ] + Array(CycleHealthKitMapping.symptomKeyByIdentifier.keys)
            return identifiers.compactMap {
                HKObjectType.categoryType(forIdentifier: HKCategoryTypeIdentifier(rawValue: $0))
            }
        }

        /// **The day a cycle sample belongs to, and with it the
        /// `cycle-hk:<day>` externalId.**
        ///
        /// Cut in the ACCOUNT zone, the zone the server keys cycle days in. The
        /// old key used a formatter that froze the device zone at first use.
        ///
        /// A whole-day sample (what the Health app writes for flow, symptoms and
        /// most reproductive entries: local midnight to the next local midnight
        /// of the zone it was LOGGED in) is keyed by its MIDPOINT. Noon of the
        /// logged day lands on that same calendar day in any zone within ±12 h,
        /// so the day the person tapped survives a phone that has since moved
        /// zones — and it is exactly the key the old code produced whenever the
        /// import ran in the zone the sample was logged in, which is how nearly
        /// every existing `cycle-hk:` id was minted. That keeps existing ids
        /// stable: a re-import re-posts the same `(source, externalId)` and the
        /// server's upsert (`upsertCycleDayLog`, `userId_source_externalId`,
        /// falling back to the one-row-per-`(userId, date)` constraint) answers
        /// `duplicate`/`updated`, never a second row. A point-in-time sample
        /// (sexual activity, a test result) is keyed by its instant.
        static func dayKey(start: Date, end: Date, timeZone: TimeZone) -> String {
            let span = end.timeIntervalSince(start)
            let isWholeDay = span >= 20 * 3600 && span <= 28 * 3600
            let anchor = isWholeDay ? start.addingTimeInterval(span / 2) : start
            return ProfileDay.key(for: anchor, timeZone: timeZone)
        }

        /// Immutable after init + used read-only; the codebase annotates ISO8601
        /// statics `nonisolated(unsafe)` (e.g. ShareWithClinicianScreen).
        private nonisolated(unsafe) static let isoFormatter: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            return f
        }()
    }

    /// One anchored cycle read. Immutable after delivery.
    struct CycleAnchoredPage: @unchecked Sendable {
        let samples: [HKSample]
        let deletedIDs: [String]
        let newAnchor: HKQueryAnchor?
    }

#endif
