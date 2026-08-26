import Foundation
import Synchronization

#if canImport(HealthKit)

    enum WorkoutDirectPageMappingOutcome: Sendable, Equatable {
        case page(dtos: [WorkoutIngestDTO], successfulEmptySeriesCount: Int)
        case failed(WorkoutHeartRateSeriesFailure)
        case cancelled
    }

    enum WorkoutDirectSeriesMappingError: Error {
        case failed
    }

    func workoutDiagnosticFailureClass(
        for error: any Error
    ) -> HKSyncDiagnostics.WorkoutFailureClass {
        if error is WorkoutBatchAcceptanceError {
            return .serverRejected
        }
        guard let error = error as? HLError else { return .healthKitQuery }
        switch error {
        case .notPersisted:
            return .persistence
        case .canceled:
            return .cancelled
        case let .server(status, _, _) where status < 500:
            return .serverRejected
        case .refusedWithReason, .assistantDisabled, .moduleDisabled, .serverNotConfigured:
            return .serverRejected
        default:
            return .transport
        }
    }

    import HealthKit
#endif

#if canImport(HealthKit)

    /// Serialize workout transactions and never expose the non-Sendable
    /// UserDefaults reference across executors.
    final class WorkoutDefaultsBox: Sendable {
        private let defaults: Mutex<UserDefaults>

        init(_ value: sending UserDefaults) {
            defaults = Mutex(value)
        }

        init(suiteName: String?) {
            let value = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
            defaults = Mutex(value)
        }

        func removeObject(forKey key: String) {
            defaults.withLock { $0.removeObject(forKey: key) }
        }

        func loadAnchor(forKey key: String, label: String) -> HKQueryAnchor? {
            defaults.withLock {
                HealthKitAnchorArchive.loadAnchor(forKey: key, from: $0, label: label)
            }
        }

        func saveAnchor(_ anchor: HKQueryAnchor?, forKey key: String, label: String) {
            defaults.withLock {
                HealthKitAnchorArchive.saveAnchor(anchor, forKey: key, to: $0, label: label)
            }
        }

        func hasObject(forKey key: String) -> Bool {
            defaults.withLock { $0.object(forKey: key) != nil }
        }

        func loadBackfill(for userID: String?) -> WorkoutHRBackfillState {
            defaults.withLock { WorkoutHRBackfillStore.load(for: userID, defaults: $0) }
        }

        func saveBackfill(_ state: WorkoutHRBackfillState, for userID: String?) {
            defaults.withLock { WorkoutHRBackfillStore.save(state, for: userID, defaults: $0) }
        }

        func rearmBackfill(
            for userID: String?,
            trigger: WorkoutHRBackfillRearmTrigger,
            leaseIsCurrent: @Sendable () -> Bool
        ) -> Bool {
            defaults.withLock {
                WorkoutHRBackfillStore.rearm(
                    for: userID,
                    trigger: trigger,
                    defaults: $0,
                    leaseIsCurrent: leaseIsCurrent
                )
            }
        }

        func clearWorkoutReadRearmPending(for userID: String?) {
            defaults.withLock {
                HKReadinessStore.clearWorkoutReadRearmPending(for: userID, defaults: $0)
            }
        }
    }

    /// Immutable page returned by the dedicated direct-workout anchored query.
    /// HealthKit objects are immutable after callback delivery but do not carry
    /// consistent Sendable annotations across supported SDKs.
    struct WorkoutAnchoredQueryPage: @unchecked Sendable {
        let workouts: [HKWorkout]
        let newAnchor: HKQueryAnchor?
        let fetchedCount: Int

        init(workouts: [HKWorkout], newAnchor: HKQueryAnchor?, fetchedCount: Int? = nil) {
            self.workouts = workouts
            self.newAnchor = newAnchor
            self.fetchedCount = fetchedCount ?? workouts.count
        }
    }

    /// Internal composition seam used by service-level integration tests.
    /// Every nil dependency selects the live HealthKit implementation.
    struct WorkoutSyncDependencies: Sendable {
        let lifecycleStore: (any WorkoutHealthKitStore)?
        let anchoredQuerySource: (any WorkoutAnchoredQueryFetching)?
        let directDTOProvider: (@Sendable () async -> [WorkoutIngestDTO])?
        let historySource: (any WorkoutHRBackfillSourcing)?

        init(
            lifecycleStore: (any WorkoutHealthKitStore)? = nil,
            anchoredQuerySource: (any WorkoutAnchoredQueryFetching)? = nil,
            directDTOProvider: (@Sendable () async -> [WorkoutIngestDTO])? = nil,
            historySource: (any WorkoutHRBackfillSourcing)? = nil
        ) {
            self.lifecycleStore = lifecycleStore
            self.anchoredQuerySource = anchoredQuerySource
            self.directDTOProvider = directDTOProvider
            self.historySource = historySource
        }
    }

    protocol WorkoutAnchoredQueryFetching: Sendable {
        func fetch(anchor: HKQueryAnchor?, limit: Int) async throws -> WorkoutAnchoredQueryPage
    }

    /// Captured authentication ownership for one direct-workout importer.
    /// The monotonic generation prevents a stopped user-A importer from
    /// becoming valid again after an A -> B -> A sequence in the same process.
    struct WorkoutImportLease: Sendable {
        let ownerUserID: String
        let authGeneration: UInt64
        private let current: @Sendable () -> Bool

        init(
            ownerUserID: String,
            authGeneration: UInt64,
            current: @escaping @Sendable () -> Bool
        ) {
            self.ownerUserID = ownerUserID
            self.authGeneration = authGeneration
            self.current = current
        }

        var isCurrent: Bool {
            !Task.isCancelled && !ownerUserID.isEmpty && current()
        }

        static func unchecked(ownerUserID: String) -> Self {
            Self(ownerUserID: ownerUserID, authGeneration: 0, current: { true })
        }
    }

    /// Synchronous because query callbacks and cancellation handlers cannot hop
    /// through the HealthKitService actor to validate ownership.
    final class WorkoutImportLeaseRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var generation: UInt64 = 0
        private var activeOwnerUserID: String?

        func activate(
            ownerUserID: String,
            authIsCurrent: @escaping @Sendable () -> Bool
        ) -> WorkoutImportLease {
            let capturedGeneration = lock.withLock { () -> UInt64 in
                generation &+= 1
                activeOwnerUserID = ownerUserID
                return generation
            }
            return WorkoutImportLease(
                ownerUserID: ownerUserID,
                authGeneration: capturedGeneration,
                current: { [weak self] in
                    guard authIsCurrent(), let self else { return false }
                    return lock.withLock {
                        self.generation == capturedGeneration && self.activeOwnerUserID == ownerUserID
                    }
                }
            )
        }

        func invalidate() {
            lock.withLock {
                generation &+= 1
                activeOwnerUserID = nil
            }
        }
    }

    /// Narrow execution seam around the one `HKAnchoredObjectQuery` owned by
    /// the direct workout importer. Tests can deterministically exercise the
    /// cancellation races without subclassing `HKHealthStore`.
    struct WorkoutAnchoredQueryDriver: @unchecked Sendable {
        typealias Completion = @Sendable (Result<WorkoutAnchoredQueryPage, any Error>) -> Void

        let makeQuery: @Sendable (HKQueryAnchor?, Int, @escaping Completion) -> HKAnchoredObjectQuery
        let execute: @Sendable (HKQuery) -> Void
        let stop: @Sendable (HKQuery) -> Void

        init(
            makeQuery: @escaping @Sendable (HKQueryAnchor?, Int, @escaping Completion) -> HKAnchoredObjectQuery,
            execute: @escaping @Sendable (HKQuery) -> Void,
            stop: @escaping @Sendable (HKQuery) -> Void
        ) {
            self.makeQuery = makeQuery
            self.execute = execute
            self.stop = stop
        }

        init(store: HKHealthStore) {
            self.init(
                makeQuery: { anchor, limit, completion in
                    HKAnchoredObjectQuery(
                        type: HKObjectType.workoutType(),
                        predicate: nil,
                        anchor: anchor,
                        limit: limit
                    ) { _, samples, _, newAnchor, error in
                        if let error {
                            completion(.failure(error))
                        } else {
                            completion(.success(.init(
                                workouts: (samples as? [HKWorkout]) ?? [],
                                newAnchor: newAnchor
                            )))
                        }
                    }
                },
                execute: { store.execute($0) },
                stop: { store.stop($0) }
            )
        }
    }

    /// Cancellation-safe async bridge. Cancellation always stops the concrete
    /// query exactly once. A cancellation that wins before query registration
    /// is remembered and compensated as soon as the query object exists; a
    /// late HealthKit callback is ignored by the single-terminal state.
    struct LiveWorkoutAnchoredQuerySource: WorkoutAnchoredQueryFetching {
        private let driver: WorkoutAnchoredQueryDriver
        private let beforeRegister: (@Sendable () async -> Void)?

        init(store: HKHealthStore) {
            driver = WorkoutAnchoredQueryDriver(store: store)
            beforeRegister = nil
        }

        init(
            driver: WorkoutAnchoredQueryDriver,
            beforeRegister: (@Sendable () async -> Void)? = nil
        ) {
            self.driver = driver
            self.beforeRegister = beforeRegister
        }

        func fetch(anchor: HKQueryAnchor?, limit: Int) async throws -> WorkoutAnchoredQueryPage {
            let state = WorkoutAnchoredQueryContinuationState()
            let query = driver.makeQuery(anchor, limit) { result in
                state.complete(result)
            }
            state.prepare(query: query)
            return try await withTaskCancellationHandler {
                if let beforeRegister {
                    await beforeRegister()
                }
                return try await withCheckedThrowingContinuation { continuation in
                    state.registerAndExecute(
                        continuation: continuation,
                        driver: driver
                    )
                }
            } onCancel: {
                state.cancel(driver: driver)
            }
        }
    }

    private final class WorkoutAnchoredQueryContinuationState: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<WorkoutAnchoredQueryPage, any Error>?
        private var query: HKAnchoredObjectQuery?
        private var cancellationRequested = false
        private var terminal = false
        private var didStop = false

        func prepare(query: HKAnchoredObjectQuery) {
            lock.withLock {
                self.query = query
            }
        }

        func registerAndExecute(
            continuation: CheckedContinuation<WorkoutAnchoredQueryPage, any Error>,
            driver: WorkoutAnchoredQueryDriver
        ) {
            var resumeCancellation = false
            lock.lock()
            self.continuation = continuation
            if terminal || cancellationRequested {
                terminal = true
                resumeCancellation = true
            } else if let query {
                // HKHealthStore.execute returns promptly and anchored-query
                // callbacks are asynchronous. Holding the lock closes the
                // register/execute cancellation gap.
                driver.execute(query)
            }
            lock.unlock()

            if resumeCancellation {
                continuation.resume(throwing: CancellationError())
            }
        }

        func cancel(driver: WorkoutAnchoredQueryDriver) {
            var queryToStop: HKAnchoredObjectQuery?
            var continuationToResume: CheckedContinuation<WorkoutAnchoredQueryPage, any Error>?
            lock.lock()
            cancellationRequested = true
            if !terminal, let query {
                terminal = true
                if !didStop {
                    didStop = true
                    queryToStop = query
                }
                continuationToResume = continuation
            }
            lock.unlock()

            if let queryToStop {
                driver.stop(queryToStop)
            }
            continuationToResume?.resume(throwing: CancellationError())
        }

        func complete(_ result: Result<WorkoutAnchoredQueryPage, any Error>) {
            var continuationToResume: CheckedContinuation<WorkoutAnchoredQueryPage, any Error>?
            lock.lock()
            if !terminal {
                terminal = true
                continuationToResume = continuation
            }
            lock.unlock()
            continuationToResume?.resume(with: result)
        }
    }

    /// Narrow owner for the direct workout observer lifecycle.
    ///
    /// Spezi owns background delivery for its sample collectors, but it does
    /// not collect `HKWorkout`. Keeping this seam workout-specific prevents the
    /// dedicated importer from accidentally enabling or disabling Spezi-owned
    /// types and makes the observer lifecycle deterministic in tests.
    protocol WorkoutHealthKitStore: Sendable {
        func executeWorkoutObserver(onUpdate: @escaping @Sendable () -> Void) async
        func stopWorkoutObserver() async
        func enableWorkoutBackgroundDelivery() async throws
        func disableWorkoutBackgroundDelivery() async throws
    }

    /// Production adapter around the app's shared `HKHealthStore`.
    /// Anchored and detail queries remain on the importer's existing store path.
    actor LiveWorkoutHealthKitStore: WorkoutHealthKitStore {
        private let store: HKHealthStore
        private var observerQuery: HKObserverQuery?

        init(store: HKHealthStore) {
            self.store = store
        }

        func executeWorkoutObserver(onUpdate: @escaping @Sendable () -> Void) {
            guard observerQuery == nil else { return }
            let query = HKObserverQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: nil
            ) { _, completion, error in
                // HealthKit requires prompt completion. Network work is always
                // scheduled after this acknowledgement and never blocks it.
                completion()
                if let error {
                    HLLog.healthKit.error(
                        "workout HK observer error: \(LogSanitizer.redact(String(describing: error)), privacy: .public)"
                    )
                    return
                }
                onUpdate()
            }
            observerQuery = query
            store.execute(query)
        }

        func stopWorkoutObserver() {
            if let observerQuery {
                store.stop(observerQuery)
            }
            observerQuery = nil
        }

        func enableWorkoutBackgroundDelivery() async throws {
            try await store.enableBackgroundDelivery(
                for: HKObjectType.workoutType(),
                frequency: .immediate
            )
        }

        func disableWorkoutBackgroundDelivery() async throws {
            try await store.disableBackgroundDelivery(for: HKObjectType.workoutType())
        }
    }

    extension WorkoutHealthKitImporter {
        /// HealthKit cannot distinguish genuine emptiness from read denial.
        static func shouldSkipAnchorSave(hadPersistedAnchor: Bool, fetchedCount: Int) -> Bool {
            _ = hadPersistedAnchor
            return fetchedCount == 0
        }

        static func pageLimit(for mode: WorkoutSyncPassMode) -> Int {
            switch mode {
            case .incrementalOnly:
                WorkoutIngestDTO.maxWorkoutsPerSeriesBatch
            case .processing:
                WorkoutIngestDTO.maxWorkoutsPerBatch
            }
        }

        func buildDTOs(
            from workouts: [HKWorkout],
            leaseIsCurrent: @escaping @Sendable () -> Bool = { true }
        ) async -> WorkoutDirectPageMappingOutcome {
            let attach: (any WorkoutHeartRateSeriesSyncServicing)? =
                Self.shouldAttachSeries(workoutCount: workouts.count) ? series : nil
            var dtos: [WorkoutIngestDTO] = []
            var successfulEmptySeriesCount = 0
            dtos.reserveCapacity(workouts.count)
            for workout in workouts where !WorkoutHealthKitMapping.isOwnEcho(workout) {
                guard leaseIsCurrent() else { return .cancelled }
                let disposition = await WorkoutHealthKitMapping.ingestDisposition(
                    from: workout,
                    series: attach
                )
                guard leaseIsCurrent() else { return .cancelled }
                switch disposition {
                case let .notRequested(dto), let .attached(dto):
                    dtos.append(dto)
                case let .empty(dto):
                    dtos.append(dto)
                    successfulEmptySeriesCount += 1
                case let .failed(failure):
                    return .failed(failure)
                case .cancelled:
                    return .cancelled
                case .skipped:
                    continue
                }
            }
            return .page(
                dtos: dtos,
                successfulEmptySeriesCount: successfulEmptySeriesCount
            )
        }

        static func shouldAttachSeries(workoutCount: Int) -> Bool {
            workoutCount <= WorkoutIngestDTO.maxWorkoutsPerSeriesBatch
        }
    }

#endif
