import Foundation

// Lifecycle and bounded-page transaction intentionally remain co-located.
// swiftlint:disable file_length
#if canImport(HealthKit)
    import HealthKit
#endif

#if canImport(HealthKit)

    struct WorkoutBoundedSyncOutcome: Sendable, Equatable {
        let didRun: Bool
        let completelyAcceptedSeriesOmittedCount: Int

        static let notRun = Self(didRun: false, completelyAcceptedSeriesOmittedCount: 0)
    }

    /// Importer-local result coordinator. The service-level coordinator keeps
    /// its public Bool contract, while direct-page callers share the richer
    /// omission evidence needed for the pre-anchor durability barrier.
    private actor WorkoutBoundedSyncCoordinator {
        private struct Slot: Sendable {
            let id: UUID
            let task: Task<WorkoutBoundedSyncOutcome, Never>
        }

        private var slots: [String: [WorkoutSyncPassMode: Slot]] = [:]
        private var laneTail: Task<Void, Never>?

        func run(
            partition: String,
            mode: WorkoutSyncPassMode,
            operation: @escaping @Sendable (WorkoutSyncPassMode) async -> WorkoutBoundedSyncOutcome
        ) async -> WorkoutBoundedSyncOutcome {
            if let slot = compatibleSlot(partition: partition, mode: mode) {
                let outcome = await slot.task.value
                return Task.isCancelled ? .notRun : outcome
            }
            let id = UUID()
            let predecessor = laneTail
            let task = Task<WorkoutBoundedSyncOutcome, Never> { [weak self] in
                await predecessor?.value
                guard !Task.isCancelled else {
                    await self?.complete(partition: partition, mode: mode, id: id)
                    return WorkoutBoundedSyncOutcome.notRun
                }
                let outcome = await operation(mode)
                await self?.complete(partition: partition, mode: mode, id: id)
                return Task.isCancelled ? WorkoutBoundedSyncOutcome.notRun : outcome
            }
            slots[partition, default: [:]][mode] = Slot(id: id, task: task)
            laneTail = Task { _ = await task.value }
            return await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                Task { await self.cancel(partition: partition, mode: mode, id: id) }
            }
        }

        private func compatibleSlot(partition: String, mode: WorkoutSyncPassMode) -> Slot? {
            switch mode {
            case .incrementalOnly:
                slots[partition]?[.incrementalOnly] ?? slots[partition]?[.processing]
            case .processing:
                slots[partition]?[.processing]
            }
        }

        private func complete(partition: String, mode: WorkoutSyncPassMode, id: UUID) {
            guard var partitionSlots = slots[partition], partitionSlots[mode]?.id == id else { return }
            partitionSlots[mode] = nil
            slots[partition] = partitionSlots.isEmpty ? nil : partitionSlots
        }

        private func cancel(partition: String, mode: WorkoutSyncPassMode, id: UUID) {
            guard let slot = slots[partition]?[mode], slot.id == id else { return }
            slot.task.cancel()
        }

        func cancelAll() {
            for partitionSlots in slots.values {
                partitionSlots.values.forEach { $0.task.cancel() }
            }
            slots.removeAll()
            laneTail?.cancel()
            laneTail = nil
        }
    }

    // swiftlint:disable type_body_length
    /// **v1.15 W-WORKOUT — collect `HKWorkout` from HealthKit and upload it to
    /// the server so the existing Workouts UI populates.**
    ///
    /// `HKWorkout` is NOT expressible in the SpeziHealthKit `CollectSamples`
    /// DSL (it collects `HKQuantitySample` / `HKCategorySample` types only), so
    /// — exactly like ``MoodStateOfMindImporter`` and ``CycleHealthKitImporter``
    /// — workouts ride a dedicated direct-`HKHealthStore` path: one long-running
    /// `HKObserverQuery` over `HKObjectType.workoutType()` plus an
    /// `HKAnchoredObjectQuery` batch, persisting its anchor in UserDefaults
    /// (battery rationale, per-user partition — PROJECT_GUIDE.md).
    ///
    /// **Why this existed as orphaned UI before:** the app shipped the Workouts
    /// screen + `WorkoutsRepository` (read-only `GET /api/workouts`) + the
    /// server's `POST /api/workouts/batch` ingest, but nothing ever *collected*
    /// HKWorkout — so a logged workout never reached the server and the screen
    /// stayed empty. This importer closes that loop.
    ///
    /// **Anti-duplicate (PROJECT_GUIDE.md mandate).** Workouts carrying our own
    /// `HKMetadataKeyExternalUUID` are HealthLog-written echoes — skipped. The
    /// `externalId` we send is the `HKWorkout` `uuid.uuidString`; the server's
    /// `@@unique([userId, source, externalId])` index upserts a re-posted
    /// workout to `duplicate` rather than inserting a twin, so a re-delivered
    /// observer wakeup is idempotent. Failures keep the anchor (no `saveAnchor`)
    /// → next sweep re-fetches; the externalId upsert makes the replay safe.
    ///
    /// **Backfill window.** A fresh anchor starts at the oldest available
    /// workout, but every query remains finite: processing/foreground pages are
    /// capped at the server's 100-workout batch limit and short wakes at the
    /// 10-workout series-safe limit. Since #17 a processing pass keeps paging
    /// while pages come back full, within ``WorkoutCatchUpPolicy``, and a
    /// history that is behind gets its newest workouts first through a
    /// separate recent window that never moves the anchor.
    ///
    /// **Always-on (not toggle-gated).** Workouts are a core surface, so the
    /// owner (`HealthKitService`) starts this whenever HealthKit is authorised —
    /// alongside the standard background-delivery activation — rather than
    /// behind a dedicated Settings switch.
    actor WorkoutHealthKitImporter {
        private let lifecycleStore: any WorkoutHealthKitStore
        private let anchoredQuerySource: any WorkoutAnchoredQueryFetching
        /// #17 — newest-first window; `nil` disables it (synthetic tests).
        private let recentWindowSource: (any WorkoutRecentWindowFetching)?
        private let clock: WorkoutCatchUpClock
        private let repo: any WorkoutBatchUploading
        /// Captured canonical owner + monotonic auth generation. Lifecycle
        /// generation alone cannot detect a keychain account change that occurs
        /// while a query, HR-series mapping, or upload is suspended.
        private let lease: WorkoutImportLease
        /// GH #86 — per-session HR series source. Costs one extra
        /// `HKSampleQuery` per workout, spent only on the incremental path
        /// (see ``shouldAttachSeries(workoutCount:)``).
        let series: any WorkoutHeartRateSeriesSyncServicing
        private let anchorKey: String
        private let backlogKey: String
        private let defaultsBox: WorkoutDefaultsBox

        private enum LifecycleState: Equatable {
            case stopped
            case activating
            case active
            case stopping
        }

        private var lifecycleState = LifecycleState.stopped
        /// Incremented whenever a lifecycle begins or is invalidated. Every
        /// suspended start and sweep captures its generation and must prove it
        /// is still current after each suspension point.
        private var lifecycleGeneration: UInt64 = 0
        /// A stop remains in `.stopping` while an older `start()` is suspended.
        /// This prevents a replacement start from racing with the stale
        /// activation's compensating disable and losing its new observer.
        private var pendingActivationGeneration: UInt64?
        private var stopCleanupInProgress = false
        /// Observer updates create unstructured tasks at Apple's callback
        /// boundary. Keep their real handles so stop/reset can cancel them.
        private var sweepTasks: [UUID: Task<Void, Never>] = [:]
        /// Serializes pages within this lifecycle generation while preserving a
        /// stronger processing request as one bounded follow-up to a short pass.
        private let pageCoordinator = WorkoutBoundedSyncCoordinator()
        /// Focused lifecycle tests replace only the sweep side effect. The
        /// production path remains the existing anchored HealthKit query.
        private let sweepOverride: (@Sendable () async -> Void)?
        private let directDTOProvider: (@Sendable () async -> [WorkoutIngestDTO])?
        private let beforeSeriesFreeAnchorAdvance: @Sendable (Int) async -> Bool

        /// Fired after a sweep ingests ≥1 workout so the `@MainActor`
        /// `WorkoutsStore` can revalidate and surface the new rows. Injected by
        /// the owner; `@Sendable` so it can hop to the main actor.
        private var onIngest: (@Sendable () async -> Void)?

        /// **Logout-race invariant (audit M4).** `anchorKey` is captured HERE,
        /// at construction, from the user-id the importer was built for.
        /// `resetAnchor()` operates ONLY on this cached key — it must never
        /// re-resolve `KeychainKey.userID`. The 401 bridge wipes the keychain
        /// user-id inside `AuthStore.handleUnauthorized()` and dispatches the HK
        /// cleanup on an unstructured task, so a reset that re-read the keychain
        /// could observe a half-wiped (`_anonymous`) id and clear the WRONG
        /// partition. The cached key closes that race;
        /// `HKImporterResetIsolationTests` pins it.
        init(
            store: HKHealthStore,
            repo: any WorkoutBatchUploading,
            userID: String?,
            defaults: sending UserDefaults = .standard,
            defaultsBox: WorkoutDefaultsBox? = nil,
            series: (any WorkoutHeartRateSeriesSyncServicing)? = nil,
            lifecycleStore: (any WorkoutHealthKitStore)? = nil,
            anchoredQuerySource: (any WorkoutAnchoredQueryFetching)? = nil,
            recentWindowSource: (any WorkoutRecentWindowFetching)? = nil,
            lease: WorkoutImportLease? = nil,
            sweepOverride: (@Sendable () async -> Void)? = nil,
            directDTOProvider: (@Sendable () async -> [WorkoutIngestDTO])? = nil,
            beforeSeriesFreeAnchorAdvance: @escaping @Sendable (Int) async -> Bool = { _ in true },
            clock: WorkoutCatchUpClock = .live
        ) {
            let canonicalOwner = userID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self.lifecycleStore = lifecycleStore ?? LiveWorkoutHealthKitStore(store: store)
            self.anchoredQuerySource = anchoredQuerySource ?? LiveWorkoutAnchoredQuerySource(store: store)
            self.recentWindowSource = recentWindowSource
            self.clock = clock
            self.repo = repo
            if let defaultsBox {
                self.defaultsBox = defaultsBox
            } else {
                self.defaultsBox = WorkoutDefaultsBox(defaults)
            }
            self.series = series ?? HealthKitWorkoutDetailService(store: store)
            self.sweepOverride = sweepOverride
            self.directDTOProvider = directDTOProvider
            self.beforeSeriesFreeAnchorAdvance = beforeSeriesFreeAnchorAdvance
            self.lease = lease ?? .unchecked(ownerUserID: canonicalOwner)
            anchorKey = "hl.workout.hk.anchor." + HealthKitService.partitionToken(for: userID)
            backlogKey = "hl.workout.hk.backlog." + HealthKitService.partitionToken(for: userID)
        }

        /// Set the post-ingest revalidation hook (composition-root injection).
        func setOnIngest(_ hook: (@Sendable () async -> Void)?) {
            onIngest = hook
        }

        func hasCurrentLease() -> Bool {
            lease.isCurrent
        }

        // MARK: - Lifecycle

        /// Start the long-running observer + run an initial anchored sweep
        /// (which backfills the full history on a fresh anchor). Idempotent —
        /// a second call is a no-op while one observer is live.
        func start() async {
            guard lifecycleState == .stopped, pendingActivationGeneration == nil else { return }
            _ = await runBoundedPage(mode: .processing)
        }

        /// Runs one finite page without disturbing a live observer. If stopped,
        /// observer activation and this page form the normal start transaction.
        func runBoundedPage(mode: WorkoutSyncPassMode) async -> WorkoutBoundedSyncOutcome {
            guard lease.isCurrent else { return .notRun }
            if lifecycleState == .active {
                let generation = lifecycleGeneration
                return await scheduleSweep(
                    generation: generation,
                    source: WorkoutSyncDiagnosticContext.source ?? .manual,
                    mode: mode,
                    waitForCompletion: true
                )
            }
            guard lifecycleState == .stopped,
                  pendingActivationGeneration == nil,
                  lease.isCurrent else { return .notRun }
            await MainActor.run {
                HKSyncDiagnostics.shared.recordWorkoutRegistration(.attempted)
            }
            guard lease.isCurrent else { return .notRun }
            lifecycleGeneration &+= 1
            let generation = lifecycleGeneration
            lifecycleState = .activating
            pendingActivationGeneration = generation
            guard activationIsCurrent(generation) else { return .notRun }
            await lifecycleStore.executeWorkoutObserver { [weak self] in
                // The lifecycle adapter acknowledges HealthKit before this hook,
                // so the network sweep never holds the observer callback open.
                Task { [weak self] in await self?.observerDidUpdate() }
            }

            guard activationIsCurrent(generation) else {
                // stop/reset may have completed while observer execution was
                // suspended. The late execution must not resurrect the query.
                await lifecycleStore.stopWorkoutObserver()
                finishStaleActivation(generation)
                return .notRun
            }

            do {
                guard lease.isCurrent else { throw CancellationError() }
                try await lifecycleStore.enableWorkoutBackgroundDelivery()
            } catch {
                // Registration and delivery activation form one transaction:
                // never leave a live observer that iOS cannot wake, and keep
                // start retryable for the next foreground/auth transition.
                await lifecycleStore.stopWorkoutObserver()
                finishFailedActivation(generation)
                HLLog.healthKit.error(
                    "workout HK background delivery activation failed: \(LogSanitizer.redact(String(describing: error)), privacy: .public)"
                )
                await MainActor.run {
                    HKSyncDiagnostics.shared.recordWorkoutRegistration(.failed)
                }
                return .notRun
            }

            guard activationIsCurrent(generation) else {
                // A concurrent stop can disable before the suspended enable
                // completes. If that stale enable then succeeds, compensate in
                // this order so background delivery cannot be resurrected.
                await lifecycleStore.stopWorkoutObserver()
                await disableWorkoutDeliveryWithRetry()
                finishStaleActivation(generation)
                return .notRun
            }

            pendingActivationGeneration = nil
            lifecycleState = .active
            guard sweepMayProceed(generation) else { return .notRun }
            await MainActor.run {
                HKSyncDiagnostics.shared.recordWorkoutRegistration(.succeeded)
            }
            guard sweepMayProceed(generation) else { return .notRun }
            let source = WorkoutSyncDiagnosticContext.source ?? .foreground
            guard sweepMayProceed(generation) else { return .notRun }
            return await scheduleSweep(
                generation: generation,
                source: source,
                mode: mode,
                waitForCompletion: true
            )
        }

        /// Stop the observer and disable only its workout delivery registration
        /// (logout / account transition). Spezi-owned sample types are untouched.
        func stop() async {
            await stop(resetAnchor: false)
        }

        func stopAndWaitUntilSettled() async {
            await stop()
            while lifecycleState != .stopped || pendingActivationGeneration != nil {
                await Task.yield()
            }
        }

        private func stop(resetAnchor: Bool) async {
            if resetAnchor {
                defaultsBox.removeObject(forKey: anchorKey)
                // The backlog bookkeeping describes this anchor; it goes with it.
                defaultsBox.removeObject(forKey: backlogKey)
            }

            lifecycleGeneration &+= 1
            cancelTrackedSweeps()
            await pageCoordinator.cancelAll()

            guard lifecycleState != .stopped else {
                await drainCancelledSweepTasks()
                return
            }
            guard lifecycleState != .stopping else {
                await drainCancelledSweepTasks()
                return
            }

            lifecycleState = .stopping
            stopCleanupInProgress = true
            await lifecycleStore.stopWorkoutObserver()
            await disableWorkoutDeliveryWithRetry()
            stopCleanupInProgress = false
            finishStoppingIfPossible()
            await drainCancelledSweepTasks()
        }

        /// Reset the per-user import anchor, then stop. On logout / user-change
        /// the next user must start from a clean anchor so the importer never
        /// silently sweeps one user's workout history into whoever is logged in.
        ///
        /// **Invariant (audit M4):** clears the `anchorKey` captured at `init`.
        /// Does NOT re-read `KeychainKey.userID` — the keychain may already be
        /// wiped by the concurrent logout cascade.
        func resetAnchor() async {
            await stop(resetAnchor: true)
        }

        func resetAnchorAndWaitUntilSettled() async {
            await stop(resetAnchor: true)
            while lifecycleState != .stopped || pendingActivationGeneration != nil {
                await Task.yield()
            }
        }

        private func activationIsCurrent(_ generation: UInt64) -> Bool {
            lifecycleState == .activating
                && lifecycleGeneration == generation
                && pendingActivationGeneration == generation
                && lease.isCurrent
        }

        private func finishFailedActivation(_ generation: UInt64) {
            if activationIsCurrent(generation) {
                lifecycleGeneration &+= 1
                pendingActivationGeneration = nil
                lifecycleState = .stopped
            } else {
                finishStaleActivation(generation)
            }
        }

        private func finishStaleActivation(_ generation: UInt64) {
            if pendingActivationGeneration == generation {
                pendingActivationGeneration = nil
            }
            finishStoppingIfPossible()
        }

        private func finishStoppingIfPossible() {
            guard lifecycleState == .stopping,
                  pendingActivationGeneration == nil,
                  !stopCleanupInProgress else { return }
            lifecycleState = .stopped
        }

        private func disableWorkoutDeliveryWithRetry() async {
            let maximumAttempts = 3
            for attempt in 1 ... maximumAttempts {
                do {
                    try await lifecycleStore.disableWorkoutBackgroundDelivery()
                    return
                } catch where attempt < maximumAttempts {
                    await Task.yield()
                } catch {
                    HLLog.healthKit.error(
                        "workout HK background delivery disable failed after three attempts: \(LogSanitizer.redact(String(describing: error)), privacy: .private)"
                    )
                }
            }
        }

        // MARK: - Sweep

        /// One anchored batch, serialized through the sweep gate (N5.3).
        private func observerDidUpdate() async {
            guard lifecycleState == .active else { return }
            await MainActor.run {
                HKSyncDiagnostics.shared.recordWorkoutObserverCallback()
            }
            _ = await scheduleSweep(
                generation: lifecycleGeneration,
                source: .observer,
                mode: .incrementalOnly,
                waitForCompletion: false
            )
        }

        private func scheduleSweep(
            generation: UInt64,
            source: WorkoutSyncSource,
            mode: WorkoutSyncPassMode,
            waitForCompletion: Bool
        ) async -> WorkoutBoundedSyncOutcome {
            guard sweepMayProceed(generation) else { return .notRun }
            let id = UUID()
            let task = Task { [weak self] in
                guard let self else { return }
                await WorkoutSyncDiagnosticContext.$source.withValue(source) {
                    let outcome = await runAnchoredSweep(generation: generation, mode: mode)
                    await sweepDidFinish(id, outcome: waitForCompletion ? outcome : nil)
                }
            }
            sweepTasks[id] = task
            if waitForCompletion {
                await withTaskCancellationHandler {
                    await task.value
                } onCancel: {
                    task.cancel()
                }
                let outcome = completedSweepOutcomes.removeValue(forKey: id) ?? .notRun
                return Task.isCancelled ? .notRun : outcome
            }
            return .notRun
        }

        private var completedSweepOutcomes: [UUID: WorkoutBoundedSyncOutcome] = [:]

        private func sweepDidFinish(_ id: UUID, outcome: WorkoutBoundedSyncOutcome?) {
            sweepTasks[id] = nil
            if let outcome {
                completedSweepOutcomes[id] = outcome
            }
        }

        private func cancelTrackedSweeps() {
            sweepTasks.values.forEach { $0.cancel() }
        }

        /// Cancellation-aware work drains immediately. HealthKit or repository
        /// APIs that do not promptly observe cancellation are left tracked and
        /// harmless: generation checks after every await prevent upload/save.
        private func drainCancelledSweepTasks() async {
            for _ in 0 ..< 16 where !sweepTasks.isEmpty {
                await Task.yield()
            }
        }

        private func sweepMayProceed(_ generation: UInt64) -> Bool {
            lifecycleState == .active
                && lifecycleGeneration == generation
                && lease.isCurrent
        }

        private func requireCurrentSweep(_ generation: UInt64) throws {
            guard sweepMayProceed(generation) else { throw CancellationError() }
        }

        private func runAnchoredSweep(
            generation: UInt64,
            mode: WorkoutSyncPassMode
        ) async -> WorkoutBoundedSyncOutcome {
            guard sweepMayProceed(generation) else { return .notRun }
            if let sweepOverride {
                await sweepOverride()
                return WorkoutBoundedSyncOutcome(
                    didRun: sweepMayProceed(generation),
                    completelyAcceptedSeriesOmittedCount: 0
                )
            }
            // A cancelled HealthKit query can finish after a replacement
            // lifecycle starts. Keying by generation prevents that stale pass
            // from joining (and thereby swallowing) the new initial sweep.
            return await pageCoordinator.run(partition: String(generation), mode: mode) { [weak self] requestedMode in
                guard let self else { return .notRun }
                return await performPass(generation: generation, mode: requestedMode)
            }
        }

        private enum PageResult {
            case notRun
            case failed
            case accepted(fetchedCount: Int, omitted: Int, ingested: Bool)

            /// A failed page ends the pass but still reports it as run.
            var isFailure: Bool {
                if case .failed = self { return true }
                return false
            }
        }

        private struct PassProgress {
            var recentAttempted = false
            var recentDelivered = 0
            var omitted = 0
            var ingested = false
        }

        /// #17 — one pass: the recent window first when the history is behind,
        /// then anchored pages. Short wakes (`.incrementalOnly`) keep one page
        /// of 10 — or the recent window instead of it, never both. Processing
        /// passes keep paging while pages come back full, within
        /// ``WorkoutCatchUpPolicy/processingBudget`` and
        /// ``WorkoutCatchUpPolicy/maxPagesPerPass``. Every page is its own
        /// transaction: fetch, upload, durably rearm, then advance the anchor.
        private func performPass(
            generation: UInt64,
            mode: WorkoutSyncPassMode
        ) async -> WorkoutBoundedSyncOutcome {
            guard sweepMayProceed(generation) else { return .notRun }
            let source = WorkoutSyncDiagnosticContext.source ?? .manual
            await MainActor.run {
                HKSyncDiagnostics.shared.recordWorkoutAttempt(source: source)
            }
            guard sweepMayProceed(generation) else { return .notRun }
            let deadline = clock.uptime() + (mode == .processing ? WorkoutCatchUpPolicy.processingBudget : 0)
            var progress = PassProgress()
            if Self.pullsRecentFirst(backlog: loadBacklog(), hasAnchor: loadAnchor() != nil) {
                guard await runRecentWindow(generation: generation, progress: &progress) else { return .notRun }
                if mode == .incrementalOnly, progress.recentDelivered > 0 {
                    return await finishPass(generation: generation, progress: progress)
                }
            }
            guard await runAnchoredPages(
                generation: generation,
                mode: mode,
                deadline: deadline,
                progress: &progress
            ) else { return .notRun }
            return await finishPass(generation: generation, progress: progress)
        }

        /// Anchored pages until one comes back short, the budget or page
        /// ceiling is spent, or the pass is no longer current. Returns `false`
        /// when the pass must report `.notRun` (cancelled / superseded).
        private func runAnchoredPages(
            generation: UInt64,
            mode: WorkoutSyncPassMode,
            deadline: TimeInterval,
            progress: inout PassProgress
        ) async -> Bool {
            let limit = Self.pageLimit(for: mode)
            for page in 1 ... WorkoutCatchUpPolicy.maxPagesPerPass {
                let result = await performAnchoredPage(generation: generation, limit: limit)
                guard case let .accepted(fetched, omitted, ingested) = result else {
                    return result.isFailure
                }
                progress.omitted += omitted
                progress.ingested = progress.ingested || ingested
                guard mode == .processing, fetched >= limit else { return true }
                if !progress.recentAttempted {
                    guard await runRecentWindow(generation: generation, progress: &progress) else { return false }
                }
                if loadBacklog().remainingEstimate == nil {
                    await refreshRemainingEstimate(generation: generation)
                }
                guard page < WorkoutCatchUpPolicy.maxPagesPerPass,
                      clock.uptime() < deadline,
                      sweepMayProceed(generation) else { return true }
            }
            return true
        }

        /// A fresh anchor, or a history known to be behind, delivers the
        /// recent window before the backlog. An install from before #17 with
        /// an anchor learns its state from its first page instead, so a
        /// caught-up account never re-posts its newest workouts.
        static func pullsRecentFirst(backlog: WorkoutImportBacklogState, hasAnchor: Bool) -> Bool {
            !hasAnchor || backlog.isBehind == true
        }

        private func finishPass(
            generation: UInt64,
            progress: PassProgress
        ) async -> WorkoutBoundedSyncOutcome {
            // Surface the freshly-ingested rows in the UI.
            if progress.ingested, let onIngest, sweepMayProceed(generation) {
                await onIngest()
            }
            return WorkoutBoundedSyncOutcome(
                didRun: sweepMayProceed(generation),
                completelyAcceptedSeriesOmittedCount: progress.omitted
            )
        }

        /// The recent window: newest workouts of the last 14 days that the
        /// anchor has not reached and that were not delivered ahead before.
        /// Never touches the anchor. Returns `false` only when the pass must
        /// stop (cancelled or no longer current); a failure falls through to
        /// the backlog, which delivers the same workouts in time.
        private func runRecentWindow(
            generation: UInt64,
            progress: inout PassProgress
        ) async -> Bool {
            progress.recentAttempted = true
            guard let recentWindowSource else { return true }
            let known = Set(loadBacklog().deliveredAhead)
            do {
                let page = try await recentWindowSource.fetchRecent(
                    since: WorkoutCatchUpPolicy.recentWindowStart(now: clock.now()),
                    limit: WorkoutCatchUpPolicy.recentWindowLimit + known.count
                )
                try requireCurrentSweep(generation)
                let fresh = Array(
                    page.workouts
                        .filter { !known.contains($0.uuid.uuidString) }
                        .prefix(WorkoutCatchUpPolicy.recentWindowLimit)
                )
                guard !fresh.isEmpty else { return true }
                let upload = try await uploadWorkouts(
                    fresh,
                    countedAs: fresh.count,
                    generation: generation
                )
                try requireCurrentSweep(generation)
                var backlog = loadBacklog()
                backlog.noteDeliveredAhead(fresh.map(\.uuid.uuidString))
                saveBacklog(backlog)
                progress.recentDelivered = fresh.count
                progress.omitted += upload.omitted
                // Today's workout shows up before the history behind it; the
                // end of the pass revalidates again only for history pages.
                if upload.ingested, let onIngest { await onIngest() }
                return sweepMayProceed(generation)
            } catch is CancellationError {
                return false
            } catch {
                HLLog.healthKit.error(
                    "workout HK recent window failed: \(LogSanitizer.redact(String(describing: error)), privacy: .public)"
                )
                return sweepMayProceed(generation)
            }
        }

        /// One anchored page: fetch, skip what the recent window already
        /// delivered, upload, durably rearm, then advance the anchor.
        private func performAnchoredPage(generation: UInt64, limit: Int) async -> PageResult {
            guard sweepMayProceed(generation) else { return .notRun }
            let anchor = loadAnchor()
            do {
                try requireCurrentSweep(generation)
                let result = try await anchoredQuerySource.fetch(anchor: anchor, limit: limit)
                try requireCurrentSweep(generation)
                let ahead = Set(loadBacklog().deliveredAhead)
                let passedAhead = Set(result.workouts.map(\.uuid.uuidString)).intersection(ahead)
                let pending = result.workouts.filter { !passedAhead.contains($0.uuid.uuidString) }
                let upload = try await uploadWorkouts(
                    pending,
                    countedAs: result.fetchedCount - passedAhead.count,
                    generation: generation
                )
                guard sweepMayProceed(generation) else { return .notRun }
                // HealthKit returns an empty page without an error when workout
                // read access is denied. Retain the prior anchor for every empty
                // page so a later regrant can replay from the last proven point.
                if !Self.shouldSkipAnchorSave(hadPersistedAnchor: anchor != nil, fetchedCount: result.fetchedCount) {
                    saveAnchor(result.newAnchor)
                } else {
                    HLLog.healthKit.debug(
                        "workout HK sweep empty — anchor retained (read grant cannot be distinguished)"
                    )
                }
                var backlog = loadBacklog()
                backlog.noteAcceptedPage(
                    fetchedCount: result.fetchedCount,
                    passedIdentifiers: passedAhead,
                    wasFull: result.fetchedCount >= limit
                )
                saveBacklog(backlog)
                await publishHistoryImport(backlog)
                return .accepted(fetchedCount: result.fetchedCount, omitted: upload.omitted, ingested: upload.ingested)
            } catch is CancellationError {
                await MainActor.run {
                    HKSyncDiagnostics.shared.recordWorkoutFailure(.cancelled)
                }
                return .notRun
            } catch {
                // Transient failure → keep the anchor (no `saveAnchor`) so the
                // next sweep re-fetches; the externalId upsert makes the
                // re-delivery idempotent. Log redacted — never workout values.
                HLLog.healthKit.error(
                    "workout HK sweep failed: \(LogSanitizer.redact(String(describing: error)), privacy: .public)"
                )
                let failure = workoutDiagnosticFailureClass(for: error)
                await MainActor.run {
                    HKSyncDiagnostics.shared.recordWorkoutFailure(failure)
                }
                return .failed
            }
        }

        /// Map, upload and pass the pre-anchor durability barrier for one set
        /// of workouts. `countedAs` is how many HealthKit workouts this set
        /// stands for (the synthetic-page seam can differ from
        /// `workouts.count`); it is the "read" diagnostics count and decides
        /// whether HR series ride along (≤ 10) or the accepted rows are handed
        /// to the HR backfill. Workouts delivered ahead are never counted twice.
        private func uploadWorkouts(
            _ workouts: [HKWorkout],
            countedAs: Int,
            generation: UInt64
        ) async throws -> (omitted: Int, ingested: Bool) {
            let mappingOutcome = if let directDTOProvider {
                await WorkoutDirectPageMappingOutcome.page(
                    dtos: directDTOProvider(),
                    successfulEmptySeriesCount: 0
                )
            } else {
                await buildDTOs(
                    from: workouts,
                    leaseIsCurrent: { [lease] in lease.isCurrent }
                )
            }
            let dtos: [WorkoutIngestDTO]
            let successfulEmptySeriesCount: Int
            switch mappingOutcome {
            case let .page(mapped, emptyCount):
                dtos = mapped
                successfulEmptySeriesCount = emptyCount
            case .failed:
                throw WorkoutDirectSeriesMappingError.failed
            case .cancelled:
                throw CancellationError()
            }
            try requireCurrentSweep(generation)
            await MainActor.run {
                HKSyncDiagnostics.shared.recordWorkoutFetch(fetched: countedAs, mapped: dtos.count)
            }
            try requireCurrentSweep(generation)
            guard !dtos.isEmpty else { return (0, false) }
            try await drain(dtos, generation: generation)
            try requireCurrentSweep(generation)
            let omittedCount = Self.shouldAttachSeries(workoutCount: countedAs)
                ? successfulEmptySeriesCount
                : dtos.count
            if omittedCount > 0 {
                guard await beforeSeriesFreeAnchorAdvance(omittedCount),
                      sweepMayProceed(generation) else { throw CancellationError() }
            }
            return (omittedCount, true)
        }

        /// Counts what is still behind the anchor once per behind pass. Costs
        /// one unlimited anchored read, which only happens while a long
        /// history is still being imported; later pages decrement the count.
        private func refreshRemainingEstimate(generation: UInt64) async {
            guard let anchor = loadAnchor(), sweepMayProceed(generation) else { return }
            guard let rest = try? await anchoredQuerySource.fetch(anchor: anchor, limit: HKObjectQueryNoLimit),
                  sweepMayProceed(generation) else { return }
            var backlog = loadBacklog()
            guard backlog.isBehind == true else { return }
            let ahead = Set(backlog.deliveredAhead)
            let aheadInRest = rest.workouts.count(where: { ahead.contains($0.uuid.uuidString) })
            backlog.remainingEstimate = max(0, rest.fetchedCount - aheadInRest)
            saveBacklog(backlog)
            await publishHistoryImport(backlog)
        }

        private func publishHistoryImport(_ backlog: WorkoutImportBacklogState) async {
            guard let status = backlog.publicStatus else { return }
            await MainActor.run {
                HKSyncDiagnostics.shared.recordWorkoutHistoryImport(status)
            }
        }

        /// Test and diagnostics read of the persisted backlog bookkeeping.
        func historyBacklog() -> WorkoutImportBacklogState {
            loadBacklog()
        }

        /// Drain a batch through `POST /api/workouts/batch`, chunked at the
        /// server's 100-workout cap. The Idempotency-Key (per chunk) + the
        /// externalId upsert make a re-delivered chunk a no-op.
        private func drain(_ dtos: [WorkoutIngestDTO], generation: UInt64) async throws {
            // GH #86 — a batch carrying HR series chunks far smaller: 100
            // series-bearing workouts would push the body past the route's
            // 5 MB ceiling (413). Series-free batches keep the 100-cap.
            let cap = dtos.contains { $0.samples != nil }
                ? WorkoutIngestDTO.maxWorkoutsPerSeriesBatch
                : WorkoutIngestDTO.maxWorkoutsPerBatch
            for start in stride(from: 0, to: dtos.count, by: cap) {
                guard sweepMayProceed(generation) else { throw CancellationError() }
                let slice = Array(dtos[start ..< min(start + cap, dtos.count)])
                guard sweepMayProceed(generation) else { throw CancellationError() }
                await MainActor.run {
                    HKSyncDiagnostics.shared.recordWorkoutSend(count: slice.count)
                }
                guard sweepMayProceed(generation) else { throw CancellationError() }
                let response = try await repo.uploadBatch(slice, ownerUserID: lease.ownerUserID)
                guard sweepMayProceed(generation) else { throw CancellationError() }
                let accepted = response.entries.filter { entry in
                    entry.status == .inserted || entry.status == .duplicate || entry.status == .enriched
                }.count
                let skipped = max(0, response.entries.count - accepted)
                // A 2xx envelope is not enough: the route can reject one row
                // as `skipped` while accepting its siblings. Require one
                // accepted terminal result for every posted index before the
                // anchored sweep is allowed to persist its new anchor.
                do {
                    try WorkoutBatchAcceptance.validate(postedCount: slice.count, response: response)
                    await MainActor.run {
                        HKSyncDiagnostics.shared.recordWorkoutResponse(
                            accepted: accepted,
                            skipped: skipped,
                            completeAcceptance: true
                        )
                    }
                } catch {
                    await MainActor.run {
                        HKSyncDiagnostics.shared.recordWorkoutResponse(
                            accepted: accepted,
                            skipped: skipped,
                            completeAcceptance: false
                        )
                    }
                    guard sweepMayProceed(generation) else { throw CancellationError() }
                    throw error
                }
                try requireCurrentSweep(generation)
                // Pure row counts — operator-grade, no PII.
                let inserted = response.inserted
                let dupes = response.duplicates
                let sent = slice.count
                // swiftlint:disable:next hllog_public_privacy_interpolation
                HLLog.healthKit.debug(
                    "workout HK ingest: \(inserted, privacy: .public) ins / \(dupes, privacy: .public) dup / \(sent, privacy: .public) sent"
                )
            }
        }

        // MARK: - Anchor persistence (UserDefaults, per PROJECT_GUIDE.md battery rationale)

        private func loadAnchor() -> HKQueryAnchor? {
            // W-HK-RELIABILITY H-2 — surface decode failures + controlled reset.
            defaultsBox.loadAnchor(forKey: anchorKey, label: "workout")
        }

        private func saveAnchor(_ anchor: HKQueryAnchor?) {
            defaultsBox.saveAnchor(anchor, forKey: anchorKey, label: "workout")
        }

        private func loadBacklog() -> WorkoutImportBacklogState {
            defaultsBox.loadBacklog(forKey: backlogKey)
        }

        private func saveBacklog(_ state: WorkoutImportBacklogState) {
            defaultsBox.saveBacklog(state, forKey: backlogKey)
        }
    }
    // swiftlint:enable type_body_length

#endif
