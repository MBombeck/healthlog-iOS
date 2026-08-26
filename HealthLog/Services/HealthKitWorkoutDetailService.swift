import Foundation
#if canImport(HealthKit)
    import HealthKit
    import Synchronization
#endif

// v0.5.4-SP5 — Per-workout HR-time-series fetcher (HK-direct).
//
// The server's `GET /api/workouts/{id}` ships avg/max/min HR + the
// optional GPS route geometry, but **not** the second-by-second HR
// curve — that's too heavy to round-trip through the JSON envelope and
// it's already on-device for any Apple-Health-sourced workout. We
// query HK locally between the workout's `startedAt` and `endedAt` and
// hand the consumer a small `[HRSample]` array for the chart.
//
// **Why a new actor, not a method on `HealthKitService`:** the existing
// service is the long-running anchored-query owner — adding ad-hoc
// sample-fetch surface to it would muddy that contract. This service
// is stateless, single-shot, and only used by the workout-detail
// screen, so it lives in its own file. Per the v0.5.4 marathon
// ownership rules ("touch DIFFERENT methods if HK"), this file owns
// the HR-strip query path; the core service stays untouched.
//
// **Concurrency:** `actor` to keep `HKHealthStore` access serialised
// per instance. `HKHealthStore` itself is documented as thread-safe
// for query-execution, but wrapping it in an actor matches the rest of
// the HK-touching service surface in this codebase.
#if canImport(HealthKit)

    enum HealthKitHeartRateQueryResult: Sendable {
        case samples([WorkoutHRSample])
        case failed
    }

    /// Narrow query seam: the service owns async continuation lifecycle while
    /// the driver owns exactly one live `HKSampleQuery` and the matching
    /// `HKHealthStore.stop` call. Tests can deterministically order callback
    /// and cancellation without relying on simulator HealthKit authorization.
    protocol HealthKitHeartRateQueryDriving: Sendable {
        func start(
            id: UUID,
            from start: Date,
            to end: Date,
            limit: Int,
            completion: @escaping @Sendable (HealthKitHeartRateQueryResult) -> Void
        )
        func stop(id: UUID)
    }

    private final class LiveHealthKitHeartRateQueryDriver: HealthKitHeartRateQueryDriving, Sendable {
        private struct PendingQuery {
            let query: HKSampleQuery
            let completion: @Sendable (HealthKitHeartRateQueryResult) -> Void
        }

        private let store: HKHealthStore
        private let pending = Mutex<[UUID: PendingQuery]>([:])

        init(store: HKHealthStore) {
            self.store = store
        }

        func start(
            id: UUID,
            from start: Date,
            to end: Date,
            limit: Int,
            completion: @escaping @Sendable (HealthKitHeartRateQueryResult) -> Void
        ) {
            let type = HKQuantityType(.heartRate)
            let predicate = HKQuery.predicateForSamples(
                withStart: start,
                end: end,
                options: [.strictStartDate, .strictEndDate]
            )
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
            let unit = HKUnit.count().unitDivided(by: .minute())
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: limit,
                sortDescriptors: [sort]
            ) { [weak self] _, samples, error in
                let result: HealthKitHeartRateQueryResult
                if error != nil {
                    HLLog.healthKit.warning("HK workout HR query failed")
                    result = .failed
                } else {
                    let mapped = (samples ?? []).compactMap { sample -> WorkoutHRSample? in
                        guard let quantitySample = sample as? HKQuantitySample else { return nil }
                        return WorkoutHRSample(
                            timestamp: quantitySample.startDate,
                            bpm: quantitySample.quantity.doubleValue(for: unit)
                        )
                    }
                    result = .samples(mapped)
                }
                self?.finish(id: id, result: result)
            }
            pending.withLock { $0[id] = PendingQuery(query: query, completion: completion) }
            store.execute(query)
        }

        func stop(id: UUID) {
            let query = pending.withLock { $0.removeValue(forKey: id)?.query }
            guard let query else { return }
            store.stop(query)
        }

        private func finish(id: UUID, result: HealthKitHeartRateQueryResult) {
            let completion = pending.withLock { $0.removeValue(forKey: id)?.completion }
            completion?(result)
        }
    }

    /// Single HR observation as decoded from `HKQuantitySample`. `bpm` is
    /// the count-per-minute scalar; `timestamp` is the sample's start
    /// time. Sendable so the chart view can hold a snapshot on
    /// `@MainActor` without recopying.
    public struct WorkoutHRSample: Sendable, Equatable, Identifiable {
        public let timestamp: Date
        public let bpm: Double

        public var id: TimeInterval {
            timestamp.timeIntervalSinceReferenceDate
        }

        public init(timestamp: Date, bpm: Double) {
            self.timestamp = timestamp
            self.bpm = bpm
        }
    }

    enum WorkoutHeartRateSeriesFailure: String, Sendable, Equatable {
        case unavailable
        case invalidWindow
        case query
    }

    enum WorkoutHeartRateSeriesOutcome: Sendable, Equatable {
        /// An empty array means the query completed but HealthKit exposed no
        /// rows. Read denial and genuine no-data remain indistinguishable.
        case samples([WorkoutHRSample])
        case failed(WorkoutHeartRateSeriesFailure)
        case cancelled
    }

    protocol WorkoutHeartRateSeriesSyncServicing: Sendable {
        func heartRateSeriesOutcome(
            from start: Date,
            to end: Date
        ) async -> WorkoutHeartRateSeriesOutcome
    }

    /// Pure contract — the iOS detail screen depends on the protocol so
    /// tests can swap in a deterministic fake without spinning up
    /// HealthKit (which simulators auth-deny by default).
    public protocol HealthKitWorkoutDetailServicing: Sendable {
        /// Returns HR samples inside `[start, end]` sorted ascending by
        /// timestamp. Returns `[]` when HK is unavailable, when the user
        /// has not authorised HR reads, or when no samples fall into the
        /// window. **Never** throws — the chart is best-effort and
        /// hides itself on empty data.
        func heartRateSeries(from start: Date, to end: Date) async -> [WorkoutHRSample]
    }

    public actor HealthKitWorkoutDetailService:
        HealthKitWorkoutDetailServicing,
        WorkoutHeartRateSeriesSyncServicing
    {
        private struct PendingSeries {
            let continuation: CheckedContinuation<WorkoutHeartRateSeriesOutcome, Never>
        }

        private let queryDriver: any HealthKitHeartRateQueryDriving
        private let healthDataIsAvailable: @Sendable () -> Bool
        private var pendingSeries: [UUID: PendingSeries] = [:]

        public init(store: HKHealthStore = HKHealthStore()) {
            queryDriver = LiveHealthKitHeartRateQueryDriver(store: store)
            healthDataIsAvailable = { HKHealthStore.isHealthDataAvailable() }
        }

        init(
            queryDriver: any HealthKitHeartRateQueryDriving,
            healthDataIsAvailable: @escaping @Sendable () -> Bool = { true }
        ) {
            self.queryDriver = queryDriver
            self.healthDataIsAvailable = healthDataIsAvailable
        }

        public func heartRateSeries(from start: Date, to end: Date) async -> [WorkoutHRSample] {
            switch await heartRateSeriesOutcome(from: start, to: end) {
            case let .samples(samples):
                samples
            case .failed, .cancelled:
                []
            }
        }

        func heartRateSeriesOutcome(
            from start: Date,
            to end: Date
        ) async -> WorkoutHeartRateSeriesOutcome {
            guard !Task.isCancelled else { return .cancelled }
            guard healthDataIsAvailable() else { return .failed(.unavailable) }
            // Guard against an upside-down window so we never block on an
            // HK query that can't return anything.
            guard end > start else { return .failed(.invalidWindow) }
            // Caller-passes HKAuthorizationStatus is undocumented for read
            // — Apple returns `.notDetermined` even when the user denied,
            // so we can't pre-filter on the status enum. The query just
            // returns `[]` in that case, which is what we want.

            // Bounded sample limit: a typical 60-minute Apple-Watch
            // workout emits ~360 HR samples (one per ~10s). 5_000 is well
            // beyond pathological cases (3-hour ultra-marathon at 1-Hz
            // streaming) and protects the chart pipeline from a runaway
            // import.
            let limit = 5000

            let queryID = UUID()
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    guard !Task.isCancelled else {
                        continuation.resume(returning: .cancelled)
                        return
                    }
                    pendingSeries[queryID] = PendingSeries(continuation: continuation)
                    queryDriver.start(
                        id: queryID,
                        from: start,
                        to: end,
                        limit: limit
                    ) { [weak self] result in
                        Task { await self?.completeSeries(id: queryID, result: result) }
                    }
                }
            } onCancel: {
                Task { await self.cancelSeries(id: queryID) }
            }
        }

        private func cancelSeries(id: UUID) {
            guard let pending = pendingSeries.removeValue(forKey: id) else { return }
            queryDriver.stop(id: id)
            pending.continuation.resume(returning: .cancelled)
        }

        private func completeSeries(id: UUID, result: HealthKitHeartRateQueryResult) {
            guard let pending = pendingSeries.removeValue(forKey: id) else { return }
            switch result {
            case let .samples(samples):
                pending.continuation.resume(returning: .samples(samples))
            case .failed:
                pending.continuation.resume(returning: .failed(.query))
            }
        }
    }

#else
    /// SPM-build / non-iOS shim. The view layer guards on `canImport`, but
    /// the protocol stays visible so test targets that link against the
    /// library can stub it.
    public struct WorkoutHRSample: Sendable, Equatable, Identifiable {
        public let timestamp: Date
        public let bpm: Double

        public var id: TimeInterval {
            timestamp.timeIntervalSinceReferenceDate
        }

        public init(timestamp: Date, bpm: Double) {
            self.timestamp = timestamp
            self.bpm = bpm
        }
    }

    public protocol HealthKitWorkoutDetailServicing: Sendable {
        func heartRateSeries(from start: Date, to end: Date) async -> [WorkoutHRSample]
    }
#endif
