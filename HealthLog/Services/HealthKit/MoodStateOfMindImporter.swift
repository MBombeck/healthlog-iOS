import Foundation
#if canImport(HealthKit)
    import HealthKit
#endif

#if canImport(HealthKit)

    /// **v0.10.0 W-Mood-B — import `HKStateOfMind` logged elsewhere into
    /// HealthLog mood.**
    ///
    /// A small, dedicated, direct-`HKHealthStore` observe path (State of Mind
    /// is NOT expressible in the SpeziHealthKit `CollectSamples` DSL — R-Mood-3
    /// §4). Runs an `HKObserverQuery` (long-running, low-volume) + an
    /// `HKAnchoredObjectQuery` batch over `stateOfMindType()`.
    ///
    /// **Anti-dupe (PROJECT_GUIDE.md mandate):** every sample we ourselves wrote
    /// carries `HKMetadataKeyExternalUUID = entry.id`. On import we **skip any
    /// sample that carries that key** — it's our own write echoing back. Only
    /// foreign samples (Apple Health slider, Journal, Mindfulness, other apps)
    /// — which have no HealthLog external id — are mapped to a `MoodEntry` and
    /// POSTed through the standard `MoodRepository` (outbox-backed).
    ///
    /// Lossy by design: foreign valence is bucketed to our 5-level score;
    /// `note` is left empty (no HK source); labels/associations are NOT
    /// round-tripped into our free-text tags (would pollute with enum names).
    ///
    /// Gated entirely behind the Settings toggle — the owner only constructs +
    /// starts this when `syncMoodWithAppleHealth` is on.
    ///
    /// **Phase 07 / plan 07-05 — owner-bound, write-ahead durable.** Three
    /// things changed and they are one change:
    ///
    ///   * The sweep is admitted. One ``HealthSyncAuthenticatedLease`` is taken
    ///     before the query and revalidated around every wire call and every
    ///     anchor write, and the partition it may write is derived from that
    ///     lease's ``HealthSyncOwnerLease`` rather than from the user id the
    ///     importer happened to be built with.
    ///   * The anchor is committed through ``HealthSyncCursorPolicy``, not saved
    ///     at the tail of the sweep. A per-item failure used to be logged and
    ///     dropped while the anchor moved on regardless, so a sample whose
    ///     durable copy never existed became unreachable.
    ///   * Retry identity comes from the HealthKit sample. Each foreign sample's
    ///     `uuid` becomes a ``HealthSyncRetryEnvelope``, which derives both the
    ///     optimistic local id and the idempotency key — so a relaunch that
    ///     re-reads the same sample replays as the same operation.
    ///
    /// Observer work is owned: every signal becomes a registered task, the
    /// signals coalesce onto one sweep, and `stop()` cancels **and drains** them,
    /// so an account teardown cannot leave a sweep running under the account
    /// that just went away.
    actor MoodStateOfMindImporter {
        /// The HealthKit type this importer's cursor partition is keyed on.
        static let cursorTypeIdentifier = "HKStateOfMindType"

        private let store: HKHealthStore
        private let repo: MoodRepository
        private let anchorKey: String
        /// The partition token the importer was constructed for. An admitted
        /// owner whose token differs is a different account, and this importer
        /// refuses to sweep for it rather than writing into the wrong anchor.
        private let partitionToken: String
        private let defaults: UserDefaults
        private let admission: (@Sendable () throws -> HealthSyncAuthenticatedLease)?
        private let cursors: DurableHealthCursorStore?
        private var observerQuery: HKObserverQuery?
        /// One sweep at a time per importer, with exactly one trailing re-run —
        /// an observer burst is one pass, not one pass per callback.
        private let coalescer = SweepCoalescer()
        /// Owned observer work. Not fire-and-forget: `stop()` cancels every entry
        /// and waits for it, which is what makes the teardown a fact rather than
        /// a request.
        private var observerTasks: [UUID: Task<Void, Never>] = [:]
        /// Owners whose cursor partition has already been established in this
        /// process. The store refuses a repeated migration anyway.
        private var migratedOwners: Set<String> = []

        /// **Logout-race invariant (audit M4).** `anchorKey` is captured HERE,
        /// at construction, from the user-id the importer was built for.
        /// `resetAnchor()` operates ONLY on this cached key — it must never
        /// re-resolve `KeychainKey.userID`. The 401 bridge wipes the keychain
        /// user-id inside `AuthStore.handleUnauthorized()` and dispatches the HK
        /// cleanup via `Task.detached`, so a reset that re-read the keychain
        /// could observe a half-wiped (`_anonymous`) id and clear the WRONG
        /// partition. The cached key closes that race;
        /// `HKImporterResetIsolationTests` pins it.
        init(
            store: HKHealthStore,
            repo: MoodRepository,
            userID: String?,
            defaults: UserDefaults = .standard,
            admission: (@Sendable () throws -> HealthSyncAuthenticatedLease)? = nil,
            cursors: DurableHealthCursorStore? = nil
        ) {
            self.store = store
            self.repo = repo
            self.defaults = defaults
            self.admission = admission
            self.cursors = cursors
            partitionToken = HealthKitService.partitionToken(for: userID)
            anchorKey = "hl.mood.stateOfMind.anchor." + partitionToken
        }

        /// Start the long-running observer + run an initial anchored sweep.
        /// Idempotent — a second call is a no-op while one observer is live.
        func start() async {
            guard #available(iOS 18.0, *) else { return }
            guard observerQuery == nil else { return }
            let type = HKObjectType.stateOfMindType()
            let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, error in
                if let error {
                    HLLog.healthKit.error(
                        "state-of-mind observer error: \(LogSanitizer.redact(String(describing: error)), privacy: .public)"
                    )
                } else {
                    // The signal is registered as owned work on the actor and the
                    // observer's completion handler is told "done" immediately:
                    // HealthKit must not be kept waiting on a network round-trip,
                    // and the sweep must not outlive a teardown unobserved. Both,
                    // rather than either.
                    Task { [weak self] in await self?.enqueueObservedSweep() }
                }
                completion()
            }
            observerQuery = query
            store.execute(query)
            await runCoalescedSweep()
        }

        /// One user-requested anchored sweep without replacing the observer.
        func refresh() async {
            guard #available(iOS 18.0, *) else { return }
            await runCoalescedSweep()
        }

        /// Stop the observer (toggle flipped off / logout) and drain every sweep
        /// it started.
        ///
        /// Cancellation alone is a request; the drain is what makes the teardown
        /// true. A cancelled sweep commits nothing — the commit rule holds on
        /// `wasCancelled` — so the drain costs a wait, never a write.
        func stop() async {
            if let observerQuery {
                store.stop(observerQuery)
            }
            observerQuery = nil
            let draining = observerTasks
            observerTasks.removeAll()
            for task in draining.values {
                task.cancel()
            }
            for task in draining.values {
                await task.value
            }
        }

        /// **v0.10.0 W10 M2 — reset the per-user import anchor.**
        ///
        /// On logout / user-change the device-local sync toggle is forced off,
        /// but the persisted anchor (partitioned by user id) would otherwise
        /// survive. A *different* user signing in on the same device — or the
        /// same user re-enabling sync — must start from a clean anchor so the
        /// importer re-imports from `nil` only against a deliberate re-opt-in,
        /// never silently sweeping the full HKStateOfMind history into whoever
        /// happens to be logged in. Clearing the anchor here is safe because the
        /// toggle is simultaneously forced off: nothing re-imports until the
        /// user explicitly re-confirms.
        ///
        /// **Invariant (audit M4):** clears the `anchorKey` captured at `init`.
        /// Does NOT re-read `KeychainKey.userID` — the keychain may already be
        /// wiped by the concurrent logout cascade.
        ///
        /// **Phase 07 / plan 07-05:** the Phase-07 cursor partition is
        /// deliberately *not* cleared. It hashes its owner into its storage key,
        /// so no other account can read it, and deleting a partition on an owner
        /// this method is forbidden from re-resolving is exactly the M4 race the
        /// cached key exists to avoid.
        func resetAnchor() {
            defaults.removeObject(forKey: anchorKey)
        }

        // MARK: - Owned observer work

        /// Registers one observer signal as owned, coalesced work.
        @available(iOS 18.0, *)
        private func enqueueObservedSweep() {
            let id = UUID()
            observerTasks[id] = Task { [weak self] in
                await self?.runCoalescedSweep()
                await self?.retireObserverTask(id)
            }
        }

        private func retireObserverTask(_ id: UUID) {
            observerTasks[id] = nil
        }

        @available(iOS 18.0, *)
        private func runCoalescedSweep() async {
            await coalescer.run(key: Self.cursorTypeIdentifier) { [weak self] in
                await self?.runAnchoredSweep()
            }
        }

        // MARK: - The sweep

        /// One anchored batch: admit an account, fetch new State-of-Mind samples
        /// since the committed anchor, import the foreign ones, and commit the
        /// new anchor only if the shared rule says the page is accounted for.
        @available(iOS 18.0, *)
        private func runAnchoredSweep() async {
            guard let lease = try? admission?() else {
                HLLog.healthKit.info("state-of-mind sweep refused — no admitted account")
                return
            }
            // The anchor key this importer owns belongs to the account it was
            // built for. An admitted owner that hashes to a different partition
            // is a different person, and the correct response is to do nothing.
            guard HealthKitService.partitionToken(for: lease.ownerID) == partitionToken else {
                HLLog.healthKit.error("state-of-mind sweep refused — admitted owner is not this importer's partition")
                return
            }
            await establishCursorPartitionIfNeeded(requiring: lease)

            let type = HKObjectType.stateOfMindType()
            let anchor = await committedAnchor(requiring: lease)
            do {
                // Fence 1 of 3 — before the query.
                try lease.requireCurrent()
                let result = try await fetch(type: type, anchor: anchor)
                // Fence 2 of 3 — an account replacement that landed during the
                // read must not let this page reach the wire under the new owner.
                try lease.requireCurrent()
                let page = await consume(result.samples, requiring: lease)
                await commitAnchor(result.newAnchor, page: page, requiring: lease)
            } catch {
                // Nothing is committed. A read that failed says nothing about the
                // window it was going to cover, so the anchor stays where it was.
                HLLog.healthKit.error(
                    "state-of-mind anchored sweep failed: \(LogSanitizer.redact(String(describing: error)), privacy: .public)"
                )
            }
        }

        /// Imports every foreign sample of one page and reports what was proved.
        @available(iOS 18.0, *)
        private func consume(
            _ samples: [HKStateOfMind],
            requiring lease: HealthSyncAuthenticatedLease
        ) async -> HealthSyncPageOutcome {
            var entries: [HealthSyncEntryOutcome] = []
            var retryPersisted = false
            var retryFailed = false

            for sample in samples {
                // Anti-dupe (W-HK-RELIABILITY G-7): skip only OUR own echo —
                // carries our externalUUID AND authored by this app's HK source.
                // A third-party state-of-mind sample that happens to carry an
                // externalUUID now flows in instead of being silently dropped.
                if HealthKitSampleOwnership.isOwnEcho(sample) { continue }
                let identity = sample.uuid.uuidString
                let outcome = await importForeign(sample, identity: identity, requiring: lease)
                switch outcome {
                case .queued:
                    retryPersisted = true
                case .enqueueLost:
                    retryFailed = true
                case .accepted, .rejected:
                    break
                }
                entries.append(
                    HealthSyncEntryOutcome(
                        index: entries.count,
                        stableIdentity: identity,
                        classification: Self.classification(of: outcome)
                    )
                )
            }

            return HealthSyncPageOutcome(
                postedCount: entries.count,
                entries: entries,
                transportThrew: false,
                durableRetryPersisted: retryPersisted,
                durableRetryFailed: retryFailed,
                leaseIsCurrent: lease.isCurrent,
                wasCancelled: Task.isCancelled
            )
        }

        /// How one repository outcome bears on the anchor.
        ///
        /// `rejected` is terminal, and that is a decision rather than an
        /// oversight: it is the server refusing this sample in a way a retry
        /// cannot fix, so holding the anchor would turn one malformed sample into
        /// a permanently stalled importer. It is the same rule the medication
        /// path applies to `unstable_external_id`, and the opposite of the rule
        /// for `enqueueLost`, which is precisely a failure a retry *would* fix.
        static func classification(of outcome: MoodWriteOutcome) -> HealthSyncAcceptanceClass {
            switch outcome {
            case .accepted, .queued:
                .terminalAccepted
            case .rejected:
                .terminalAccepted
            case .enqueueLost:
                .nonterminal
            }
        }

        /// Import a single foreign sample under a restart-stable identity.
        @available(iOS 18.0, *)
        private func importForeign(
            _ sample: HKStateOfMind,
            identity: String,
            requiring lease: HealthSyncAuthenticatedLease
        ) async -> MoodWriteOutcome {
            guard let envelope = HealthSyncRetryEnvelope(
                ownerID: lease.ownerID,
                source: lease.source,
                stableIdentity: identity
            ) else {
                return .rejected(.unknown("state-of-mind sample carried no stable identity"))
            }
            guard lease.isCurrent else {
                return .enqueueLost(.notPersisted("admission lost before the mood write"))
            }
            let score = MoodStateOfMindMapping.score(forValence: sample.valence)
            let outcome = await repo.logDurable(
                score: score,
                tags: [],
                note: nil,
                recordedAt: sample.startDate,
                retryIdentity: envelope
            )
            // Fence 3 of 3 — a write that completed after the account changed is
            // not this account's progress, whatever the server said.
            guard lease.isCurrent else {
                return .enqueueLost(.notPersisted("admission lost during the mood write"))
            }
            if case let .rejected(error) = outcome {
                HLLog.healthKit.error(
                    "state-of-mind import refused: \(LogSanitizer.redact(String(describing: error)), privacy: .public)"
                )
            }
            return outcome
        }

        /// Bridge the anchored query into async/await.
        @available(iOS 18.0, *)
        private func fetch(
            type: HKSampleType,
            anchor: HKQueryAnchor?
        ) async throws -> (samples: [HKStateOfMind], newAnchor: HKQueryAnchor?) {
            try await withCheckedThrowingContinuation { continuation in
                let query = HKAnchoredObjectQuery(
                    type: type,
                    predicate: nil,
                    anchor: anchor,
                    limit: HKObjectQueryNoLimit
                ) { _, samples, _, newAnchor, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    let moods = (samples as? [HKStateOfMind]) ?? []
                    continuation.resume(returning: (moods, newAnchor))
                }
                store.execute(query)
            }
        }

        // MARK: - Anchor persistence

        /// The partition this admission may write. Owner-bound by construction:
        /// there is no path here that yields another account's key.
        private static func cursorKey(for lease: HealthSyncAuthenticatedLease) -> HealthSyncCursorKey? {
            let owner: HealthSyncOwnerLease = lease.owner
            return owner.cursorKey(typeIdentifier: cursorTypeIdentifier)
        }

        /// Adopts the pre-Phase-07 per-user anchor into the owner partition, once.
        ///
        /// `.provenOwner` is the honest ownership claim here and the first
        /// production use of that arm: the legacy key is
        /// `hl.mood.stateOfMind.anchor.<partitionToken(userID)>`, and the sweep
        /// has already refused unless the admitted owner hashes to exactly this
        /// importer's token. That equality *is* the proof. The adoption runs
        /// through the store's verified write, so an unverifiable migration fails
        /// closed and the partition collects nothing.
        private func establishCursorPartitionIfNeeded(requiring lease: HealthSyncAuthenticatedLease) async {
            guard let cursors,
                  let key = Self.cursorKey(for: lease),
                  !migratedOwners.contains(lease.ownerID) else { return }
            _ = try? await cursors.migrate(
                key,
                legacyKey: anchorKey,
                ownership: .provenOwner(lease.ownerID),
                requiring: lease
            )
            migratedOwners.insert(lease.ownerID)
        }

        /// The anchor this account's partition committed, or the legacy per-user
        /// value when no durable store is wired.
        @available(iOS 18.0, *)
        private func committedAnchor(requiring lease: HealthSyncAuthenticatedLease) async -> HKQueryAnchor? {
            if let cursors, let key = Self.cursorKey(for: lease) {
                return await cursors.queryAnchor(for: key)
            }
            // W-HK-RELIABILITY H-2 — surface decode failures + controlled reset.
            return HealthKitAnchorArchive.loadAnchor(forKey: anchorKey, from: defaults, label: "stateOfMind")
        }

        /// Commits the new anchor if — and only if — the shared rule permits it.
        ///
        /// There is no path here that writes an anchor without a decision. The
        /// durable store applies ``HealthSyncCursorPolicy/required`` internally;
        /// the un-wired fallback consults ``HealthSyncCursorPolicy/installed``
        /// directly, so a context without a cursor store is never *more*
        /// permissive than production — which is exactly how the pre-Phase-07
        /// sweep lost samples.
        @available(iOS 18.0, *)
        private func commitAnchor(
            _ anchor: HKQueryAnchor?,
            page: HealthSyncPageOutcome,
            requiring lease: HealthSyncAuthenticatedLease
        ) async {
            guard let anchor else { return }
            guard let cursors, let key = Self.cursorKey(for: lease) else {
                let decision = HealthSyncCursorPolicy.installed.decide(page)
                guard decision == .commit else {
                    Self.logHold(decision)
                    return
                }
                HealthKitAnchorArchive.saveAnchor(anchor, forKey: anchorKey, to: defaults, label: "stateOfMind")
                return
            }
            guard let blob = HealthKitAnchorArchive.encodeAnchor(anchor, label: "stateOfMind") else {
                // An anchor that cannot be archived is an anchor that cannot be
                // proved on read-back, and the store would refuse it anyway.
                return
            }
            let decision = await cursors.commit(page: page, anchor: blob, for: key, requiring: lease)
            Self.logHold(decision)
        }

        private static func logHold(_ decision: HealthSyncCommitDecision) {
            guard case let .hold(reason) = decision else { return }
            // A fixed enum case naming why the anchor did not move — operator-grade
            // by construction, and it carries no sample, value, or account.
            // swiftlint:disable:next hllog_public_privacy_interpolation
            HLLog.healthKit.info(
                "state-of-mind anchor holds — \(reason.rawValue, privacy: .public)"
            )
        }
    }

#endif
