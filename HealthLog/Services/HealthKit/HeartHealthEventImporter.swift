import Foundation
#if canImport(HealthKit)
    import HealthKit
#endif

#if canImport(HealthKit)

    /// **W-HKREAD — import HealthKit categorical EVENT-class samples the server
    /// classifies (heart-rhythm + mobility + audio-exposure events).**
    ///
    /// A dedicated direct-`HKHealthStore` observe path, modelled on
    /// ``MoodStateOfMindImporter``. These EVENT category types are NOT
    /// collected by the SpeziHealthKit `CollectSamples` pipeline — each one is
    /// a discrete on-device notification (the device's own FDA-cleared /
    /// CE-marked verdict), so we run a long-running `HKObserverQuery` +
    /// `HKAnchoredObjectQuery` batch per type, persisting one anchor per type
    /// in UserDefaults (battery rationale, per-user partition).
    ///
    /// **The seven event types** (server `APPLE_HEALTH_TYPE_MAP`):
    /// - `irregularHeartRhythmEvent` → IRREGULAR_RHYTHM_NOTIFICATION
    /// - `highHeartRateEvent` → HIGH_HEART_RATE_EVENT
    /// - `lowHeartRateEvent` → LOW_HEART_RATE_EVENT
    /// - `appleWalkingSteadinessEvent` → WALKING_STEADINESS_EVENT
    /// - `sleepApneaEvent` → BREATHING_DISTURBANCE_EVENT
    /// - `environmentalAudioExposureEvent` / `headphoneAudioExposureEvent`
    ///   → AUDIO_EXPOSURE_EVENT
    ///
    /// **Wire shape:** each fired event is one batch entry with `value = 1`,
    /// `unit = "event"`, and `categoryValue = sample.value` — the integer
    /// `HKCategoryValue` codepoint carrying the device's verdict / severity.
    /// The server resolves it to a `rhythmClassification` via
    /// `mapAppleHealthEntry`; iOS never re-classifies, never emits a diagnosis.
    ///
    /// **Anti-dupe (PROJECT_GUIDE.md mandate):** the app never writes these EVENT
    /// types back, but the `externalUUID`-skip filter is still applied for
    /// uniformity + future-proofing. Each `externalId = sample.uuid` is the
    /// server's dedup key, so a re-sweep of an already-uploaded event is a
    /// server-side `duplicate` (no double-count).
    ///
    /// **Anchor discipline — Phase 07 / plan 07-06.** The per-type anchor used to
    /// advance on anything that was not a raised transport error: the observer
    /// fired a detached, unowned sweep, a cancelled or logged-out sweep still
    /// reached `saveAnchor`, and a 200 that skipped rows counted as acceptance.
    /// Three things changed, and they are one change:
    ///
    ///   * The sweep is **admitted**. One ``HealthSyncAuthenticatedLease`` is
    ///     captured before the query and revalidated around the wire call, the
    ///     durable enqueue, and the cursor write; the partition it may write is
    ///     derived from that lease's ``HealthSyncOwnerLease``, never from the
    ///     ambient Keychain after a suspension.
    ///   * The anchor is **committed through ``HealthSyncCursorPolicy``** rather
    ///     than saved at the tail of the sweep, so cancellation, a lost lease, an
    ///     index the server never answered for, and a skip the server cannot map
    ///     all hold the cursor instead of consuming the window.
    ///   * A held page becomes a **durable, owner-bound outbox row** under a key
    ///     derived from ``HealthSyncRetryEnvelope`` — the page's own sample
    ///     UUIDs — so a process that dies between the enqueue and the cursor
    ///     write replays the same operation instead of writing a second one.
    ///
    /// Observer work is owned: every signal becomes a registered task, the
    /// signals coalesce per type onto one sweep, and `stop()` cancels **and
    /// drains** them.
    actor HeartHealthEventImporter {
        private let store: HKHealthStore
        private let uploader: MeasurementBatchUploader
        private let anchorKeyPrefix: String
        /// The partition token the importer was constructed for. An admitted
        /// owner whose token differs is a different account, and this importer
        /// refuses to sweep for it rather than writing into the wrong anchor.
        private let partitionToken: String
        private let defaults: UserDefaults
        private let admission: (@Sendable () throws -> HealthSyncAuthenticatedLease)?
        private let cursors: DurableHealthCursorStore?
        /// `nil` in contexts with no queue (tests, pre-composition). A page that
        /// needs a retry and has nowhere to write it reports `durableRetryFailed`,
        /// so the cursor holds rather than claiming ground it does not have.
        private let retry: (any HealthSyncBatchRetryEnqueuing)?
        private var observerQueries: [HKObserverQuery] = []
        /// One sweep at a time per type, with exactly one trailing re-run — an
        /// observer burst is one pass, not one pass per callback.
        private let coalescer = SweepCoalescer()
        /// Owned observer work. `stop()` cancels every entry and waits for it,
        /// which is what makes the teardown a fact rather than a request.
        private var observerTasks: [UUID: Task<Void, Never>] = [:]
        /// Per-call sweep results, handed back across the coalescer's `@Sendable`
        /// body (which cannot write a captured local).
        private var sweepDispositions: [UUID: HealthSyncDisposition] = [:]
        private var migratedPartitions: Set<String> = []

        /// The category-type identifiers we observe. iOS 18 is the floor, so
        /// every symbol below resolves on the build SDK; the HK runtime ignores
        /// any identifier a given device's OS doesn't surface.
        static func eventCategoryTypes() -> [HKCategoryType] {
            [
                HKCategoryType(.irregularHeartRhythmEvent),
                HKCategoryType(.highHeartRateEvent),
                HKCategoryType(.lowHeartRateEvent),
                HKCategoryType(.appleWalkingSteadinessEvent),
                HKCategoryType(.sleepApneaEvent),
                HKCategoryType(.environmentalAudioExposureEvent),
                HKCategoryType(.headphoneAudioExposureEvent)
            ]
        }

        init(
            store: HKHealthStore,
            uploader: MeasurementBatchUploader,
            userID: String?,
            defaults: UserDefaults = .standard,
            admission: (@Sendable () throws -> HealthSyncAuthenticatedLease)? = nil,
            cursors: DurableHealthCursorStore? = nil,
            retry: (any HealthSyncBatchRetryEnqueuing)? = nil
        ) {
            self.store = store
            self.uploader = uploader
            self.defaults = defaults
            self.admission = admission
            self.cursors = cursors
            self.retry = retry
            partitionToken = HealthKitService.partitionToken(for: userID)
            anchorKeyPrefix = "hl.hkevent.anchor." + partitionToken + "."
        }

        /// Start one long-running observer per event type + run an initial
        /// anchored sweep for each. Idempotent — a second call is a no-op while
        /// observers are live.
        @discardableResult
        func start() async -> HealthSyncDisposition {
            guard observerQueries.isEmpty else { return .deferred }
            for type in Self.eventCategoryTypes() {
                let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, error in
                    if let error {
                        HLLog.healthKit.error(
                            "hk-event observer error: \(LogSanitizer.redact(String(describing: error)), privacy: .public)"
                        )
                    } else {
                        // The signal becomes owned work on the actor and the
                        // observer's completion handler is told "done"
                        // immediately: HealthKit must not be kept waiting on a
                        // network round-trip, and the sweep must not outlive a
                        // teardown unobserved. Both, rather than either — the
                        // old detached task was neither owned nor drainable.
                        Task { [weak self] in await self?.enqueueObservedSweep(for: type) }
                    }
                    completion()
                }
                observerQueries.append(query)
                store.execute(query)
            }
            return await refresh()
        }

        /// One explicit, bounded sweep of every event type without replacing the
        /// observers — the entry point an orchestrated trigger calls.
        ///
        /// Bounded by construction: exactly one anchored page per type per call,
        /// and the result is a named disposition rather than "it ran".
        @discardableResult
        func refresh() async -> HealthSyncDisposition {
            var results: [HealthSyncDisposition] = []
            for type in Self.eventCategoryTypes() {
                // A teardown that lands mid-refresh stops the remaining types
                // rather than sweeping them under an account that is going away.
                guard !Task.isCancelled else {
                    results.append(.deferred)
                    break
                }
                await results.append(runAnchoredSweep(for: type))
            }
            return Self.aggregate(results)
        }

        /// Stop all observers (logout) and drain every sweep they started.
        /// Idempotent.
        ///
        /// Cancellation alone is a request; the drain is what makes the teardown
        /// true. A cancelled sweep commits nothing — the commit rule holds on
        /// `wasCancelled` — so the drain costs a wait, never a write.
        func stop() async {
            for query in observerQueries {
                store.stop(query)
            }
            observerQueries.removeAll()
            let draining = observerTasks
            observerTasks.removeAll()
            for task in draining.values {
                task.cancel()
            }
            for task in draining.values {
                await task.value
            }
        }

        /// Reset every per-type import anchor (logout / user-change). A
        /// different user signing in on the same device must start clean so we
        /// never sweep the prior user's event history into whoever is logged in.
        func resetAnchors() {
            for type in Self.eventCategoryTypes() {
                defaults.removeObject(forKey: anchorKey(for: type))
            }
        }

        // MARK: - Owned observer work

        /// Registers one observer signal as owned, coalesced work for its own
        /// signalled type — never a fan-out across the other six.
        private func enqueueObservedSweep(for type: HKCategoryType) {
            let id = UUID()
            observerTasks[id] = Task { [weak self] in
                _ = await self?.runAnchoredSweep(for: type)
                await self?.retireObserverTask(id)
            }
        }

        private func retireObserverTask(_ id: UUID) {
            observerTasks[id] = nil
        }

        /// our own write echoing back (anti-dupe).
        ///
        /// W-HK-RELIABILITY G-7: skip only OUR own echo (our externalUUID AND
        /// this app's HK source). A third-party heart-event sample carrying an
        /// externalUUID now flows in instead of being silently dropped.
        private func entry(from sample: HKCategorySample) -> HealthKitBatchEntryDTO? {
            if HealthKitSampleOwnership.isOwnEcho(sample) { return nil }
            return HealthKitBatchEntryDTO(
                hkIdentifier: sample.categoryType.identifier,
                value: 1,
                unit: "event",
                startDate: sample.startDate,
                endDate: sample.endDate,
                categoryValue: sample.value,
                externalId: sample.uuid.uuidString,
                externalSourceVersion: sample.sourceRevision.productType,
                deviceType: HealthKitWireConverter.deviceType(for: sample.device)
            )
        }

        /// Bridge the anchored query into async/await.
        private func fetch(
            type: HKCategoryType,
            anchor: HKQueryAnchor?
        ) async throws -> (samples: [HKCategorySample], newAnchor: HKQueryAnchor?) {
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
                    let events = (samples as? [HKCategorySample]) ?? []
                    continuation.resume(returning: (events, newAnchor))
                }
                store.execute(query)
            }
        }
    }

    // MARK: - The durable half

    ///
    /// An extension rather than more actor body: the lifecycle half above and
    /// the durability half below are two subjects and together they exceed the
    /// type budget in `PROJECT_GUIDE.md`. They stay in ONE file because the
    /// Wave-0 assertions name this file for the lease, the retry identity, the
    /// commit rule and the cancellation check — a sibling file would leave those
    /// clauses standing on a doc comment instead of on the code.
    extension HeartHealthEventImporter {
        // MARK: - Sweep

        /// One anchored batch for a single event type, serialized per type: a
        /// burst of observer fires becomes one pass plus one trailing re-run.
        private func runAnchoredSweep(for type: HKCategoryType) async -> HealthSyncDisposition {
            // One token per call. Only the first caller's body runs, so only that
            // caller's token is ever filled in; a coalesced trigger reads nothing
            // back and reports `.deferred` — which is exactly what happened to it.
            let token = UUID()
            await coalescer.run(key: type.identifier) { [weak self] in
                guard let self else { return }
                let disposition = await performAnchoredSweep(for: type)
                await record(disposition, for: token)
            }
            return takeDisposition(for: token) ?? .deferred
        }

        private func record(_ disposition: HealthSyncDisposition, for token: UUID) {
            sweepDispositions[token] = disposition
        }

        private func takeDisposition(for token: UUID) -> HealthSyncDisposition? {
            sweepDispositions.removeValue(forKey: token)
        }

        /// One anchored batch for a single event type: admit an account, fetch
        /// new samples since the committed anchor, post the foreign ones, and
        /// commit this type's cursor only if the shared rule says the page is
        /// accounted for.
        private func performAnchoredSweep(for type: HKCategoryType) async -> HealthSyncDisposition {
            guard let lease = try? admission?() else {
                HLLog.healthKit.info("hk-event sweep refused — no admitted account")
                return .disabled
            }
            guard HealthKitService.partitionToken(for: lease.ownerID) == partitionToken else {
                HLLog.healthKit.error("hk-event sweep refused — admitted owner is not this importer's partition")
                return .disabled
            }
            guard !Task.isCancelled else { return .deferred }
            await establishCursorPartitionIfNeeded(type, requiring: lease)

            let anchor = await committedAnchor(for: type, requiring: lease)
            do {
                // Fence 1 of 3 — before the query.
                try lease.requireCurrent()
                let result = try await fetch(type: type, anchor: anchor)
                // Fence 2 of 3 — an account replacement that landed during the
                // read must not let this page reach the wire under the new owner.
                try lease.requireCurrent()
                let entries = result.samples.compactMap(entry(from:))
                let page = await transmit(entries, requiring: lease)
                return await commitAnchor(result.newAnchor, for: type, page: page, requiring: lease)
            } catch let refusal as HealthSyncLeaseRefusal {
                return refusal == .cancelled ? .deferred : .expired
            } catch is CancellationError {
                return .deferred
            } catch {
                HLLog.healthKit.error(
                    "hk-event sweep failed (anchor held): \(LogSanitizer.redact(String(describing: error)), privacy: .public)"
                )
                return .failed
            }
        }

        /// Worst-of over the per-type dispositions: one held type makes the whole
        /// refresh incomplete.
        private static func aggregate(_ results: [HealthSyncDisposition]) -> HealthSyncDisposition {
            let ranked: [HealthSyncDisposition] = [
                .failed, .expired, .deferred, .retryPersisted, .disabled, .unsupported, .succeeded
            ]
            for candidate in ranked where results.contains(candidate) {
                return candidate
            }
            return results.first ?? .succeeded
        }

        /// Posts one page and reports what the server actually proved.
        ///
        /// The uploader already runs ``MeasurementBatchAcceptance`` against the
        /// deployed route, so a returned outcome means every posted index carried
        /// terminal evidence at the envelope level. Exactly one reason survives
        /// that gate and still is not progress for *this* index — the server
        /// cannot map the identifier yet — and it is held per index rather than
        /// per page, which is the rule `HealthSampleConsumption` already applies.
        ///
        /// Internal (not `private`) so the durability suite can drive the whole
        /// transmission half against the real `APIClient` over `MockURLProtocol`:
        /// the query half needs an authorized `HKHealthStore`, which a unit test
        /// does not have, and every rule this plan adds lives on this side.
        func transmit(
            _ entries: [HealthKitBatchEntryDTO],
            requiring lease: HealthSyncAuthenticatedLease
        ) async -> HealthSyncPageOutcome {
            guard !entries.isEmpty else { return Self.emptyPage }
            var transportThrew = false
            var nonterminalIndexes: Set<Int> = []
            do {
                // The actor-isolated form of `HealthSyncAuthenticatedLease
                // .admitting(_:)`: that fence takes a non-`Sendable` closure,
                // which an `actor` may not send. Same two-sided check, written
                // out (07-04's precedent in the statistics sweep).
                try lease.requireCurrent()
                let outcomes = try await uploader.upload(entries)
                try lease.requireCurrent()
                for outcome in outcomes {
                    for skipped in outcome.skipped
                        where skipped.reason == HealthKitServerSupportConfig.reasonUnmappableIdentifier
                    {
                        nonterminalIndexes.insert(skipped.index)
                    }
                }
            } catch let refusal as HealthSyncLeaseRefusal {
                return Self.refusedPage(refusal, postedCount: entries.count)
            } catch is CancellationError {
                return Self.refusedPage(.cancelled, postedCount: entries.count)
            } catch {
                // A raised transport says nothing about individual rows: the
                // batch may never have been seen at all. Every index is
                // non-terminal, and losing a flagged cardiac event to a transient
                // 500 is exactly what the durable retry below prevents.
                HLLog.healthKit.error(
                    "hk-event page not accepted: \(LogSanitizer.redact(String(describing: error)), privacy: .public)"
                )
                transportThrew = true
                nonterminalIndexes = Set(entries.indices)
            }

            let classified = entries.indices.map { index in
                HealthSyncEntryOutcome(
                    index: index,
                    stableIdentity: entries[index].externalId,
                    classification: nonterminalIndexes.contains(index) ? .nonterminal : .terminalAccepted
                )
            }
            guard !nonterminalIndexes.isEmpty else {
                return HealthSyncPageOutcome(
                    postedCount: entries.count,
                    entries: classified,
                    transportThrew: false,
                    durableRetryPersisted: false,
                    durableRetryFailed: false,
                    leaseIsCurrent: lease.isCurrent,
                    wasCancelled: false
                )
            }
            let held = nonterminalIndexes.sorted().map { entries[$0] }
            let persisted = await persistRetry(held, requiring: lease)
            return HealthSyncPageOutcome(
                postedCount: entries.count,
                entries: classified,
                transportThrew: transportThrew,
                durableRetryPersisted: persisted,
                durableRetryFailed: !persisted,
                leaseIsCurrent: lease.isCurrent,
                wasCancelled: Task.isCancelled
            )
        }

        /// Writes the rows the server did not accept under a **derived**
        /// idempotency key — the page's own sorted sample UUIDs — so a process
        /// that dies before the cursor write rebuilds the same key on relaunch
        /// instead of minting a second server row.
        private func persistRetry(
            _ entries: [HealthKitBatchEntryDTO],
            requiring lease: HealthSyncAuthenticatedLease
        ) async -> Bool {
            guard let retry else { return false }
            guard let envelope = HealthSyncRetryEnvelope(
                ownerID: lease.ownerID,
                source: lease.source,
                stableIdentity: HealthSampleConsumption.stableIdentity(of: entries)
            ) else {
                return false
            }
            do {
                // The actor-isolated form of the `admitting(_:)` fence.
                try lease.requireCurrent()
                try await retry.enqueueHealthKitRetry(
                    entries,
                    idempotencyKey: envelope.idempotencyKey,
                    requiringCurrentOwner: lease.ownerID
                )
                try lease.requireCurrent()
                return true
            } catch {
                // No value, no identifier, no owner — only the fact that the
                // durable write did not happen, which is what holds the cursor.
                HLLog.healthKit.error("hk-event durable retry write failed — cursor holds")
                return false
            }
        }

        private static var emptyPage: HealthSyncPageOutcome {
            HealthSyncPageOutcome(
                postedCount: 0,
                entries: [],
                transportThrew: false,
                durableRetryPersisted: false,
                durableRetryFailed: false,
                leaseIsCurrent: true,
                wasCancelled: false
            )
        }

        private static func refusedPage(
            _ refusal: HealthSyncLeaseRefusal,
            postedCount: Int
        ) -> HealthSyncPageOutcome {
            HealthSyncPageOutcome(
                postedCount: postedCount,
                entries: [],
                transportThrew: false,
                durableRetryPersisted: false,
                durableRetryFailed: false,
                leaseIsCurrent: refusal == .cancelled,
                wasCancelled: refusal == .cancelled
            )
        }

        // MARK: - Anchor persistence (UserDefaults, per PROJECT_GUIDE.md battery rationale)

        private func anchorKey(for type: HKCategoryType) -> String {
            anchorKeyPrefix + type.identifier
        }

        /// The partition this admission may write for one event type. Owner-bound
        /// by construction: there is no path here that yields another account's
        /// key.
        private static func cursorKey(
            for lease: HealthSyncAuthenticatedLease,
            type: HKCategoryType
        ) -> HealthSyncCursorKey? {
            let owner: HealthSyncOwnerLease = lease.owner
            return owner.cursorKey(typeIdentifier: type.identifier)
        }

        /// Adopts the pre-Phase-07 per-user, per-type anchor into the owner
        /// partition, once. `.provenOwner` is honest here for the same reason it
        /// is on the mood path: the legacy key is per-user by construction and
        /// the sweep has already refused unless the admitted owner hashes to
        /// exactly this importer's token.
        private func establishCursorPartitionIfNeeded(
            _ type: HKCategoryType,
            requiring lease: HealthSyncAuthenticatedLease
        ) async {
            guard let cursors,
                  let key = Self.cursorKey(for: lease, type: type),
                  !migratedPartitions.contains(key.storageKey) else { return }
            _ = try? await cursors.migrate(
                key,
                legacyKey: anchorKey(for: type),
                ownership: .provenOwner(lease.ownerID),
                requiring: lease
            )
            migratedPartitions.insert(key.storageKey)
        }

        /// The anchor this account's partition committed for one type, or the
        /// legacy per-user value when no durable store is wired.
        private func committedAnchor(
            for type: HKCategoryType,
            requiring lease: HealthSyncAuthenticatedLease
        ) async -> HKQueryAnchor? {
            if let cursors, let key = Self.cursorKey(for: lease, type: type) {
                return await cursors.queryAnchor(for: key)
            }
            // W-HK-RELIABILITY H-2 — surface decode failures + controlled reset.
            return HealthKitAnchorArchive.loadAnchor(
                forKey: anchorKey(for: type),
                from: defaults,
                label: "hkevent:\(type.identifier)"
            )
        }

        /// Commits this type's new anchor if — and only if — the shared rule
        /// permits it. The un-wired fallback consults
        /// ``HealthSyncCursorPolicy/installed`` directly, so a context without a
        /// cursor store is never *more* permissive than production.
        private func commitAnchor(
            _ anchor: HKQueryAnchor?,
            for type: HKCategoryType,
            page: HealthSyncPageOutcome,
            requiring lease: HealthSyncAuthenticatedLease
        ) async -> HealthSyncDisposition {
            guard let anchor else {
                return page.durableRetryPersisted ? .retryPersisted : .succeeded
            }
            let decision: HealthSyncCommitDecision
            if let cursors, let key = Self.cursorKey(for: lease, type: type),
               let blob = HealthKitAnchorArchive.encodeAnchor(anchor, label: "hkevent:\(type.identifier)")
            {
                decision = await cursors.commit(page: page, anchor: blob, for: key, requiring: lease)
            } else {
                decision = HealthSyncCursorPolicy.installed.decide(page)
                if decision == .commit {
                    HealthKitAnchorArchive.saveAnchor(
                        anchor,
                        forKey: anchorKey(for: type),
                        to: defaults,
                        label: "hkevent:\(type.identifier)"
                    )
                }
            }
            guard case let .hold(reason) = decision else {
                return page.durableRetryPersisted ? .retryPersisted : .succeeded
            }
            // A fixed enum case naming why the anchor did not move — operator-grade
            // by construction, and it carries no sample, value, or account.
            // swiftlint:disable:next hllog_public_privacy_interpolation
            HLLog.healthKit.info("hk-event anchor holds — \(reason.rawValue, privacy: .public)")
            switch reason {
            case .cancelled: return .deferred
            case .leaseLost: return .expired
            case .nonterminalEntry, .incompleteIndexCoverage, .retryPersistenceFailed: return .failed
            }
        }
    }

#endif
