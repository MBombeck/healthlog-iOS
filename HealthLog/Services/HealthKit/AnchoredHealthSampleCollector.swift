#if canImport(HealthKit)
    import Foundation
    import HealthKit

    // Phase 07 Wave 2 — the app owns the query, so the app can own the cursor.
    //
    // SpeziHealthKit 1.4.2 (`a86db5c`) reads the stored anchor, runs the query,
    // awaits the app handler, and then persists the query's new anchor
    // unconditionally. There is no veto and no useful rewind: the page the query
    // already consumed cannot be recovered by writing an older value back, because
    // the library overwrites that write on return
    // (`HealthKitDurableCursorTests/callbackRewindIsOverwritten` models the exact
    // order). Every durability rule Phase 07 owes therefore has to live on the side
    // of the boundary that *issues* the query.
    //
    // This collector is that side. For one `{owner, source, type}` partition it
    // performs the whole transaction in one place:
    //
    //   read the committed anchor → issue a bounded anchored query → hand the page
    //   to the shared mapping/consumption operation → classify → commit through
    //   `DurableHealthCursorStore.commit(page:anchor:for:requiring:)`
    //
    // and it commits only when that seam says so. A hold leaves the partition
    // exactly where it was, so the next wake re-reads the same window and the
    // server folds the repeat on `externalId`.
    //
    // Three bounds are structural rather than advisory:
    //
    //   * Pages per type come from `HealthSyncBudget.required(for:)`, so a short
    //     wake cannot start an unbounded history walk and a first history import is
    //     refused outright when the trigger does not allow one.
    //   * The query carries an explicit `limit`, so a single page is finite even
    //     when a year of history is waiting behind it.
    //   * Observer signals are coalesced onto one owned, cancellable drain task, so
    //     a burst of HealthKit callbacks produces one pass rather than one pass per
    //     callback.
    //
    // Nothing here logs a value, a health label, an owner id, or a token: the
    // results this type returns are named counts and dispositions.

    /// One bounded page read out of HealthKit for a single sample type.
    ///
    /// `newAnchor` is the resume token the *query* produced. It is never persisted
    /// by this type directly — only through the verified commit seam.
    struct AnchoredHealthSamplePage: Sendable, Equatable {
        let samples: [HKSample]
        let deletedObjectCount: Int
        let newAnchor: HKQueryAnchor?
        /// `true` when the page filled its limit, so more is waiting behind it.
        let mayHaveMore: Bool

        static func == (lhs: AnchoredHealthSamplePage, rhs: AnchoredHealthSamplePage) -> Bool {
            lhs.samples.count == rhs.samples.count
                && lhs.deletedObjectCount == rhs.deletedObjectCount
                && lhs.newAnchor == rhs.newAnchor
                && lhs.mayHaveMore == rhs.mayHaveMore
        }
    }

    /// Why a bounded read could not be performed at all.
    enum AnchoredHealthCollectionError: String, Error, Sendable, Equatable {
        /// The identifier is not a sample type this build can resolve.
        case unknownSampleType
    }

    /// The bounded read seam. Production issues a real `HKAnchoredObjectQuery`;
    /// a test drives the exact page sequence a fault matrix needs.
    protocol AnchoredHealthSampleQuerying: Sendable {
        func page(
            typeIdentifier: String,
            resumingFrom anchor: HKQueryAnchor?,
            notBefore cutoff: Date,
            limit: Int
        ) async throws -> AnchoredHealthSamplePage
    }

    /// The mapping/transmission seam. The collector owns *when* a page is read and
    /// whether its cursor moves; it owns none of the wire mapping, which stays with
    /// `HealthLogStandard`'s extracted consumption operation.
    protocol HealthSamplePageConsuming: Sendable {
        func consume(
            _ samples: [HKSample],
            ofType typeIdentifier: String,
            requiring lease: HealthSyncAuthenticatedLease
        ) async -> HealthSyncPageOutcome
    }

    /// The change-signal seam. One subscription per type, delivering the type
    /// identifier that changed and nothing else.
    protocol HealthSampleChangeObserving: Sendable {
        func startObserving(
            _ typeIdentifiers: [String],
            onChange: @escaping @Sendable (String) -> Void
        ) async
        func stopObserving() async
    }

    /// Bounded, account-scoped, app-owned HealthKit sample collection.
    actor AnchoredHealthSampleCollector {
        /// What one type did in one pass. Named counts and a named disposition —
        /// never a value, a health label, or an owner.
        struct TypeResult: Sendable, Equatable {
            let typeIdentifier: String
            let pagesCollected: Int
            let samplesRead: Int
            let disposition: HealthSyncDisposition
            /// Present exactly when the cursor did not advance for this page.
            let holdReason: HealthSyncHoldReason?
        }

        /// Objects per anchored page. Large enough that a normal wake finishes in
        /// one round trip, small enough that a year of backlog cannot build one
        /// unbounded in-memory batch. Matches `MeasurementBatchUploader`'s own
        /// per-POST ceiling so a page is at most one batch.
        static let defaultPageLimit = MeasurementBatchUploader.maxEntriesPerBatch

        private let cursors: DurableHealthCursorStore
        private let query: any AnchoredHealthSampleQuerying
        private let consumer: any HealthSamplePageConsuming
        private let observer: (any HealthSampleChangeObserving)?
        private let pageLimit: Int

        /// Types signalled since the drain last looked. A set, so a burst of
        /// callbacks for one type is one unit of work.
        private var pendingObservedTypes: Set<String> = []
        /// The single owned drain. Its lifetime is this actor's, so cancellation is
        /// a method call rather than a hope.
        private var observedDrain: Task<Void, Never>?
        private var observedCutoff: Date?
        private var observedAdmission: (@Sendable () throws -> HealthSyncAuthenticatedLease)?
        private var isObserving = false

        init(
            cursors: DurableHealthCursorStore,
            query: any AnchoredHealthSampleQuerying,
            consumer: any HealthSamplePageConsuming,
            observer: (any HealthSampleChangeObserving)? = nil,
            pageLimit: Int = AnchoredHealthSampleCollector.defaultPageLimit
        ) {
            self.cursors = cursors
            self.query = query
            self.consumer = consumer
            self.observer = observer
            self.pageLimit = max(1, pageLimit)
        }

        // MARK: - Bounded collection

        /// Runs one bounded pass over `typeIdentifiers` under `lease`.
        ///
        /// `cutoff` is the window the authenticated user chose during onboarding.
        /// It is a parameter rather than a lookup on purpose: a collector that
        /// resolved it itself could query before the choice was loaded, which is
        /// exactly the cold-activation defect Wave 0 pinned.
        @discardableResult
        func collect(
            typeIdentifiers: [String],
            trigger: HealthSyncTrigger,
            notBefore cutoff: Date,
            requiring lease: HealthSyncAuthenticatedLease
        ) async -> [TypeResult] {
            let budget = HealthSyncBudget.required(for: trigger)
            guard budget.maxPagesPerType > 0 else { return [] }

            var results: [TypeResult] = []
            for typeIdentifier in typeIdentifiers {
                await results.append(
                    collectOne(typeIdentifier, budget: budget, cutoff: cutoff, lease: lease)
                )
                if Task.isCancelled { break }
            }
            return results
        }

        // swiftlint:disable:next cyclomatic_complexity
        private func collectOne(
            _ typeIdentifier: String,
            budget: HealthSyncBudget,
            cutoff: Date,
            lease: HealthSyncAuthenticatedLease
        ) async -> TypeResult {
            // A blank owner cannot produce a key, and a partition nobody owns is a
            // partition nobody may write. Fail closed rather than fall back.
            guard let key = lease.cursorKey(typeIdentifier: typeIdentifier) else {
                return result(typeIdentifier, 0, 0, .failed, .leaseLost)
            }
            // The same gate the store applies to a write, applied before the read:
            // an unproven or failed migration collects nothing at all.
            guard await cursors.permitsCollection(for: key) else {
                return result(typeIdentifier, 0, 0, .deferred, nil)
            }

            var anchor = await cursors.queryAnchor(for: key)
            // A partition with no committed cursor has never walked its history.
            // A short wake may not start that walk — it would be cancelled long
            // before it finished and would burn the grant every time.
            if anchor == nil, !budget.allowsFirstHistoryImport {
                return result(typeIdentifier, 0, 0, .deferred, nil)
            }

            var pages = 0
            var samplesRead = 0
            var retryPersisted = false

            while pages < budget.maxPagesPerType {
                if Task.isCancelled {
                    return result(typeIdentifier, pages, samplesRead, .expired, .cancelled)
                }
                if let refusal = lease.refusal {
                    return result(typeIdentifier, pages, samplesRead, .failed, refusal.holdReason)
                }

                let page: AnchoredHealthSamplePage
                do {
                    page = try await query.page(
                        typeIdentifier: typeIdentifier,
                        resumingFrom: anchor,
                        notBefore: cutoff,
                        limit: pageLimit
                    )
                } catch is CancellationError {
                    return result(typeIdentifier, pages, samplesRead, .expired, .cancelled)
                } catch {
                    // The read itself failed, so nothing in this window is
                    // terminally accounted for. The cursor holds under the same
                    // reason a non-terminal page holds it.
                    logHold(key, reason: .nonterminalEntry)
                    return result(typeIdentifier, pages, samplesRead, .failed, .nonterminalEntry)
                }

                samplesRead += page.samples.count
                let outcome = await consumer.consume(
                    page.samples,
                    ofType: typeIdentifier,
                    requiring: lease
                )
                retryPersisted = retryPersisted || outcome.durableRetryPersisted

                guard let newAnchor = page.newAnchor,
                      let blob = HealthKitAnchorArchive.encodeAnchor(newAnchor, label: key.source.rawValue) else
                {
                    // No resume token, or one this build cannot archive. There is
                    // nothing safe to commit; the partition holds.
                    logHold(key, reason: .retryPersistenceFailed)
                    return result(typeIdentifier, pages, samplesRead, .failed, .retryPersistenceFailed)
                }

                let decision = await cursors.commit(
                    page: outcome,
                    anchor: blob,
                    for: key,
                    requiring: lease
                )
                pages += 1

                if case let .hold(reason) = decision {
                    logHold(key, reason: reason)
                    return result(
                        typeIdentifier,
                        pages,
                        samplesRead,
                        retryPersisted ? .retryPersisted : .failed,
                        reason
                    )
                }

                anchor = newAnchor
                if !page.mayHaveMore { break }
            }

            return result(
                typeIdentifier,
                pages,
                samplesRead,
                retryPersisted ? .retryPersisted : .succeeded,
                nil
            )
        }

        // MARK: - Observers

        /// Arms one change subscription per type. Idempotent: a second call while
        /// already observing is a no-op rather than a second set of queries.
        ///
        /// `admitting` is called fresh for every observed wake. An observer wake may
        /// arrive hours after activation, and the admission pinned at activation
        /// would by then describe a session that no longer exists.
        func startObserving(
            _ typeIdentifiers: [String],
            notBefore cutoff: Date,
            admitting admission: @escaping @Sendable () throws -> HealthSyncAuthenticatedLease
        ) async {
            guard let observer, !isObserving else { return }
            isObserving = true
            observedCutoff = cutoff
            observedAdmission = admission
            await observer.startObserving(typeIdentifiers) { [weak self] typeIdentifier in
                guard let self else { return }
                Task { await self.handleObservedChange(typeIdentifier: typeIdentifier) }
            }
        }

        /// The observer entry point. Exactly-once per signalled type per drain: the
        /// type is recorded and the *existing* drain picks it up, so a burst never
        /// starts a second pass over the same partition.
        func handleObservedChange(typeIdentifier: String) {
            pendingObservedTypes.insert(typeIdentifier)
            guard observedDrain == nil else { return }
            observedDrain = Task { [weak self] in
                await self?.drainObservedTypes()
            }
        }

        /// Stops observing and cancels the owned drain. Cancellation holds every
        /// cursor mid-flight, because `collect` refuses to commit a cancelled page.
        func stopObserving() async {
            observedDrain?.cancel()
            observedDrain = nil
            pendingObservedTypes.removeAll()
            observedAdmission = nil
            observedCutoff = nil
            isObserving = false
            await observer?.stopObserving()
        }

        private func drainObservedTypes() async {
            defer { observedDrain = nil }
            while !pendingObservedTypes.isEmpty, !Task.isCancelled {
                let batch = pendingObservedTypes.sorted()
                pendingObservedTypes.removeAll()
                guard let cutoff = observedCutoff,
                      let admission = observedAdmission,
                      let lease = try? admission() else { return }
                await collect(
                    typeIdentifiers: batch,
                    trigger: .observer,
                    notBefore: cutoff,
                    requiring: lease
                )
            }
        }

        // MARK: - Private

        private func result(
            _ typeIdentifier: String,
            _ pages: Int,
            _ samplesRead: Int,
            _ disposition: HealthSyncDisposition,
            _ holdReason: HealthSyncHoldReason?
        ) -> TypeResult {
            TypeResult(
                typeIdentifier: typeIdentifier,
                pagesCollected: pages,
                samplesRead: samplesRead,
                disposition: disposition,
                holdReason: holdReason
            )
        }

        private func logHold(_ key: HealthSyncCursorKey, reason: HealthSyncHoldReason) {
            // Source and hold reason are fixed enum cases chosen in this file; the
            // owner is hashed out of the key and never appears here, and an anchor
            // is an opaque resume token that carries no health data.
            // swiftlint:disable:next hllog_public_privacy_interpolation
            HLLog.healthKit.info(
                "health cursor held [\(key.source.rawValue, privacy: .public)] — \(reason.rawValue, privacy: .public)"
            )
        }
    }

    // MARK: - Production HealthKit conformances

    /// Resolves a registry identifier onto the concrete `HKSampleType` it names.
    /// Returns `nil` for anything this build cannot name, which the collector
    /// treats as "do not query" rather than "query everything".
    enum HealthKitSampleTypeResolver {
        static func sampleType(for identifier: String) -> HKSampleType? {
            if let quantity = HKObjectType.quantityType(
                forIdentifier: HKQuantityTypeIdentifier(rawValue: identifier)
            ) {
                return quantity
            }
            return HKObjectType.categoryType(
                forIdentifier: HKCategoryTypeIdentifier(rawValue: identifier)
            )
        }
    }

    /// One bounded `HKAnchoredObjectQuery` per call. No update handler is
    /// installed, so the query is genuinely one-shot and the collector — not
    /// HealthKit — decides whether to ask again.
    struct HealthKitAnchoredPageSource: AnchoredHealthSampleQuerying {
        let store: HKHealthStore

        func page(
            typeIdentifier: String,
            resumingFrom anchor: HKQueryAnchor?,
            notBefore cutoff: Date,
            limit: Int
        ) async throws -> AnchoredHealthSamplePage {
            guard let sampleType = HealthKitSampleTypeResolver.sampleType(for: typeIdentifier) else {
                throw AnchoredHealthCollectionError.unknownSampleType
            }
            // The chosen window bounds the *first* walk only. Once an anchor
            // exists HealthKit resolves the window from the anchor itself, and a
            // start predicate would then silently re-narrow an established stream.
            let predicate: NSPredicate? = anchor == nil
                ? HKQuery.predicateForSamples(withStart: cutoff, end: nil, options: .strictStartDate)
                : nil

            return try await withCheckedThrowingContinuation { continuation in
                let query = HKAnchoredObjectQuery(
                    type: sampleType,
                    predicate: predicate,
                    anchor: anchor,
                    limit: limit
                ) { _, samples, deleted, newAnchor, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    let collected = samples ?? []
                    let deletedCount = deleted?.count ?? 0
                    continuation.resume(
                        returning: AnchoredHealthSamplePage(
                            samples: collected,
                            deletedObjectCount: deletedCount,
                            newAnchor: newAnchor,
                            mayHaveMore: collected.count + deletedCount >= limit
                        )
                    )
                }
                store.execute(query)
            }
        }
    }

    /// Source-targeted `HKObserverQuery` subscriptions, one per type, plus the
    /// background-delivery arming the app already declared per type.
    actor HealthKitSampleChangeObserver: HealthSampleChangeObserving {
        private let store: HKHealthStore
        private var queries: [HKObserverQuery] = []
        private var backgroundArmed: [HKSampleType] = []

        init(store: HKHealthStore) {
            self.store = store
        }

        func startObserving(
            _ typeIdentifiers: [String],
            onChange: @escaping @Sendable (String) -> Void
        ) async {
            for identifier in typeIdentifiers {
                guard let sampleType = HealthKitSampleTypeResolver.sampleType(for: identifier) else {
                    continue
                }
                let query = HKObserverQuery(
                    sampleType: sampleType,
                    predicate: nil
                ) { _, completionHandler, error in
                    // The completion handler is HealthKit's own delivery receipt.
                    // It is called on every path, including the error path, so a
                    // transient failure does not stop future deliveries.
                    if error == nil {
                        onChange(identifier)
                    }
                    completionHandler()
                }
                store.execute(query)
                queries.append(query)

                guard HealthKitBackgroundDeliveryPolicy.continuesInBackground(for: identifier) else {
                    continue
                }
                do {
                    try await store.enableBackgroundDelivery(for: sampleType, frequency: .immediate)
                    backgroundArmed.append(sampleType)
                } catch {
                    // A refused arming is a reachability fact about this device,
                    // not a data fault: the type still collects on every pull
                    // trigger. The identifier is a fixed HealthKit constant, never
                    // a value and never an account.
                    // swiftlint:disable:next hllog_public_privacy_interpolation
                    HLLog.healthKit.info(
                        "background delivery unavailable [\(identifier, privacy: .public)] — pull triggers still collect"
                    )
                }
            }
        }

        func stopObserving() async {
            for query in queries {
                store.stop(query)
            }
            queries.removeAll()
            for sampleType in backgroundArmed {
                try? await store.disableBackgroundDelivery(for: sampleType)
            }
            backgroundArmed.removeAll()
        }
    }
#endif
