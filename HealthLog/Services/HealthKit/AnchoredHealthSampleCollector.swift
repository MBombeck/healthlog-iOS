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

    /// One bounded HealthKit page of one type; `newAnchor` is persisted only through the commit seam.
    struct AnchoredHealthSamplePage: Sendable, Equatable {
        let samples: [HKSample]
        let deletedObjectCount: Int
        let newAnchor: HKQueryAnchor?
        /// `true` when the page filled its limit, so more is waiting behind it.
        let mayHaveMore: Bool
        /// Deleted since the anchor: UUIDs for the server (A5), server ids of HealthLog copies (A6).
        var deletedSampleIDs: [String] = []
        var deletedCopyServerIDs: [String] = []

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

        /// 1.3 (#127) — the same bounded read, narrowed to `window` on every
        /// call (not only the first). `nil` reads everything after `anchor`.
        func page(
            typeIdentifier: String,
            resumingFrom anchor: HKQueryAnchor?,
            within window: HealthSampleDateWindow?,
            limit: Int
        ) async throws -> AnchoredHealthSamplePage
    }

    extension AnchoredHealthSampleQuerying {
        /// A source that only knows the cutoff form (test doubles) sees the
        /// window's start as its cutoff.
        func page(
            typeIdentifier: String,
            resumingFrom anchor: HKQueryAnchor?,
            within window: HealthSampleDateWindow?,
            limit: Int
        ) async throws -> AnchoredHealthSamplePage {
            try await page(
                typeIdentifier: typeIdentifier,
                resumingFrom: anchor,
                notBefore: window?.start ?? .distantPast,
                limit: limit
            )
        }
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

        /// A2 (1.4, R-A7, #138) — one page of the history walk: the same
        /// consumption, posted as `syncTrigger: "backfill"` where the server
        /// takes it, so history never moves the server's live arrival stamps.
        func consumeHistory(
            _ samples: [HKSample],
            ofType typeIdentifier: String,
            requiring lease: HealthSyncAuthenticatedLease
        ) async -> HealthSyncPageOutcome
    }

    /// The change-signal seam. One subscription per type, delivering the type
    /// identifier that changed and nothing else.
    protocol HealthSampleChangeObserving: Sendable {
        /// V1 (1.2) — `onChange` is awaited: the observer hands back HealthKit's
        /// completion handler only once the delivery it reports was collected
        /// (or its deadline passed), so iOS keeps the process running for it.
        func startObserving(
            _ typeIdentifiers: [String],
            onChange: @escaping @Sendable (String) async -> Void
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
            /// 1.3 (#127) — what the history leg did for this type in this
            /// pass, `nil` when the pass ran no history.
            var history: HistoryResult?
        }

        /// Objects per anchored page. Large enough that a normal wake finishes in
        /// one round trip, small enough that a year of backlog cannot build one
        /// unbounded in-memory batch. Matches `MeasurementBatchUploader`'s own
        /// per-POST ceiling so a page is at most one batch.
        static let defaultPageLimit = MeasurementBatchUploader.maxEntriesPerBatch

        // Internal rather than private so the history leg
        // (`AnchoredHealthSampleCollector+History.swift`) can share them.
        let cursors: DurableHealthCursorStore
        let query: any AnchoredHealthSampleQuerying
        let history: (any HealthSampleHistoryQuerying)?
        let consumer: any HealthSamplePageConsuming
        private let observer: (any HealthSampleChangeObserving)?
        let pageLimit: Int
        let clock: HealthSampleSplitClock
        /// The history run in flight, so two passes never walk the same date
        /// cursor at once. Uptime at start; a run older than
        /// `HealthSampleSplitPolicy.staleHistoryRun` no longer blocks.
        var historyRun: (token: UUID, startedAt: TimeInterval)?
        /// A2 (1.4, R-A8) — types whose history another path owns (the summed
        /// types, which the statistics path sends as day and hour totals).
        /// Their raw history is never walked.
        let historyOwnedElsewhere: @Sendable (String) -> Bool
        /// V1 — what a delivery waits for after its drain: the statistics and
        /// pulse-bucket sweeps its pages requested.
        private let deliveryFollowUp: (@Sendable () async -> Void)?

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
            history: (any HealthSampleHistoryQuerying)? = nil,
            pageLimit: Int = AnchoredHealthSampleCollector.defaultPageLimit,
            clock: HealthSampleSplitClock = .live,
            historyOwnedElsewhere: @escaping @Sendable (String) -> Bool = { _ in false },
            deliveryFollowUp: (@Sendable () async -> Void)? = nil
        ) {
            self.cursors = cursors
            self.query = query
            self.consumer = consumer
            self.observer = observer
            self.history = history
            self.pageLimit = max(1, pageLimit)
            self.clock = clock
            self.historyOwnedElsewhere = historyOwnedElsewhere
            self.deliveryFollowUp = deliveryFollowUp
        }

        // MARK: - Bounded collection

        /// Runs one bounded pass over `typeIdentifiers` under `lease`.
        ///
        /// `cutoff` is the window the authenticated user chose during onboarding.
        /// It is a parameter rather than a lookup on purpose: a collector that
        /// resolved it itself could query before the choice was loaded, which is
        /// exactly the cold-activation defect Wave 0 pinned.
        ///
        /// **1.3 (#127)** — every type's live stream first, then history in
        /// what is left: `historyOrder` (default: `typeIdentifiers`) is the
        /// order the history leg visits, `historyBudget` replaces the
        /// trigger's own history allowance ("Sync everything now"), and
        /// `beforeHistory` runs between the two (the #128 floor lookup).
        @discardableResult
        func collect(
            typeIdentifiers: [String],
            trigger: HealthSyncTrigger,
            notBefore cutoff: Date,
            requiring lease: HealthSyncAuthenticatedLease,
            historyOrder: [String]? = nil,
            historyBudget: HealthSampleHistoryBudget? = nil,
            beforeHistory: (@Sendable () async -> Void)? = nil
        ) async -> [TypeResult] {
            let budget = HealthSyncBudget.required(for: trigger)
            guard budget.maxPagesPerType > 0 else { return [] }

            var results: [TypeResult] = []
            for typeIdentifier in typeIdentifiers {
                await results.append(
                    collectLive(typeIdentifier, budget: budget, cutoff: cutoff, lease: lease)
                )
                if Task.isCancelled { return results }
            }

            let allowance = historyBudget ?? .required(for: budget)
            guard budget.allowsFirstHistoryImport, allowance.pagesPerType > 0, history != nil else {
                return results
            }
            // A2 (1.4, R3 S6) — a live page found the server out of reach: no
            // history this pass, it would only read pages it cannot send.
            if results.contains(where: { $0.holdReason == .serverUnreachable }) {
                return results.map { Self.withUnreachableHistory($0) }
            }
            await beforeHistory?()
            let order = (historyOrder ?? typeIdentifiers).filter { typeIdentifiers.contains($0) }
            let walked = await collectHistory(order: order, cutoff: cutoff, lease: lease, allowance: allowance)
            return results.map { result in
                var merged = result
                merged.history = walked[result.typeIdentifier]
                return merged
            }
        }

        /// Whether a type's live leg may read, and from which split.
        private enum LiveOpening {
            case open(HealthSyncCursorKey, HealthSampleSplitState)
            case refused(TypeResult)
        }

        private func openLive(
            _ typeIdentifier: String,
            cutoff: Date,
            lease: HealthSyncAuthenticatedLease
        ) async -> LiveOpening {
            // A blank owner cannot produce a key, and a partition nobody owns is a
            // partition nobody may write. Fail closed rather than fall back.
            guard let key = lease.cursorKey(typeIdentifier: typeIdentifier) else {
                return .refused(result(typeIdentifier, 0, 0, .failed, .leaseLost))
            }
            // The same gate the store applies to a write, applied before the read:
            // an unproven or failed migration collects nothing at all.
            guard await cursors.permitsCollection(for: key) else {
                return .refused(result(typeIdentifier, 0, 0, .deferred, nil))
            }
            // 1.3 — establishes the split once: a 1.2.0 forward cursor moves to
            // the legacy leg and the live stream starts at `liveStart`. A live
            // read is bounded to that window, so even a short wake may start it.
            do {
                return try await .open(key, cursors.establishSplit(for: key, cutoff: cutoff, requiring: lease))
            } catch {
                let reason = lease.refusal?.holdReason ?? .retryPersistenceFailed
                logHold(key, reason: reason)
                return .refused(result(typeIdentifier, 0, 0, .failed, reason))
            }
        }

        // The live leg of one type: the partition's main cursor, narrowed to
        // `liveStart` until it has reached the present.
        // swiftlint:disable:next cyclomatic_complexity
        private func collectLive(
            _ typeIdentifier: String,
            budget: HealthSyncBudget,
            cutoff: Date,
            lease: HealthSyncAuthenticatedLease
        ) async -> TypeResult {
            let key: HealthSyncCursorKey
            let split: HealthSampleSplitState
            switch await openLive(typeIdentifier, cutoff: cutoff, lease: lease) {
            case let .refused(refusal): return refusal
            case let .open(openedKey, openedSplit): (key, split) = (openedKey, openedSplit)
            }

            var anchor = await cursors.queryAnchor(for: key)
            var caughtUp = split.liveCaughtUp
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
                        within: caughtUp ? nil : HealthSampleDateWindow(start: split.liveStart),
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
                let outcome = await consumeLive(
                    page,
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

                let decision = await cursors.commit(page: outcome, anchor: blob, for: key, requiring: lease)
                pages += 1

                if case let .hold(reason) = decision {
                    logHold(key, reason: reason)
                    return result(typeIdentifier, pages, samplesRead, retryPersisted ? .retryPersisted : .failed, reason)
                }

                anchor = newAnchor
                if !page.mayHaveMore {
                    // The stream has reached the present. From here on it reads
                    // without a date narrowing, so a sample HealthKit inserts
                    // later with an older date still arrives through it.
                    if !caughtUp {
                        caughtUp = await cursors.updateSplit(for: key, requiring: lease) { $0.liveCaughtUp = true }
                    }
                    break
                }
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
                await self?.deliver(typeIdentifier: typeIdentifier)
            }
        }

        /// V1 (1.2) — one HealthKit delivery, start to finish: the type joins the
        /// drain, the drain runs, and the sweeps its pages requested finish. The
        /// observer calls HealthKit's completion handler after this returns.
        func deliver(typeIdentifier: String) async {
            handleObservedChange(typeIdentifier: typeIdentifier)
            if let drain = observedDrain { await drain.value }
            await deliveryFollowUp?()
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

        func result(
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

        func logHold(_ key: HealthSyncCursorKey, reason: HealthSyncHoldReason) {
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
            ) ?? HealthKitServer144Types.otherSampleType(for: identifier) // HK-NEW: State of Mind
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
            onChange: @escaping @Sendable (String) async -> Void
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
                    // It is called exactly once on every path, including the
                    // error path, so a transient failure does not stop future
                    // deliveries. V1 (1.2): after the delivery was collected and
                    // its sweeps ran, not before: until 1.1.1 it was called at
                    // once and iOS could suspend the process with the work
                    // still in flight. The deadline keeps a slow network from
                    // holding it past HealthKit's patience.
                    let receipt = HealthKitDeliveryReceipt(completionHandler)
                    guard error == nil else {
                        receipt.fire()
                        return
                    }
                    receipt.arm(deadline: HealthKitDeliveryReceipt.deadline)
                    Task {
                        await onChange(identifier)
                        receipt.fire()
                    }
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
