import Foundation
#if canImport(HealthKit)
    import CoreLocation
    import HealthKit
#endif

#if canImport(HealthKit)

    /// **1.5 ROUTES (#149) — reading the GPS track of a new workout.**
    ///
    /// Reached only through ``WorkoutRouteAttachment``, which asks
    /// ``WorkoutRouteOptIn`` first: without the opt-in no route query runs at
    /// all. A workout without a route (indoors, no watch GPS) is an empty
    /// list, a refused permission is an empty list or an error, and neither
    /// ever stops the workout itself from going out.
    protocol WorkoutRouteReading: Sendable {
        func locations(for workout: HKWorkout) async throws -> [WorkoutRouteLocation]
    }

    /// Live reader: the `HKWorkoutRoute` samples attached to the workout, then
    /// each route's locations through `HKWorkoutRouteQuery`. Every query is
    /// stopped when the caller is cancelled.
    struct LiveWorkoutRouteReader: WorkoutRouteReading {
        let store: HKHealthStore

        func locations(for workout: HKWorkout) async throws -> [WorkoutRouteLocation] {
            var fixes: [WorkoutRouteLocation] = []
            for route in try await routeSamples(of: workout) {
                try Task.checkCancellation()
                fixes += try await locations(in: route)
            }
            return fixes
        }

        private func routeSamples(of workout: HKWorkout) async throws -> [HKWorkoutRoute] {
            let box = WorkoutRouteQueryBox<[HKWorkoutRoute]>()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let query = HKSampleQuery(
                        sampleType: HKSeriesType.workoutRoute(),
                        predicate: HKQuery.predicateForObjects(from: workout),
                        limit: HKObjectQueryNoLimit,
                        sortDescriptors: nil
                    ) { _, samples, error in
                        if let error {
                            box.finish(.failure(error))
                        } else {
                            box.finish(.success((samples ?? []).compactMap { $0 as? HKWorkoutRoute }))
                        }
                    }
                    if box.start(query, continuation) { store.execute(query) }
                }
            } onCancel: {
                box.cancel { store.stop($0) }
            }
        }

        private func locations(in route: HKWorkoutRoute) async throws -> [WorkoutRouteLocation] {
            let box = WorkoutRouteQueryBox<[WorkoutRouteLocation]>()
            let collected = WorkoutRouteFixes()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let query = HKWorkoutRouteQuery(route: route) { _, locations, done, error in
                        if let error {
                            box.finish(.failure(error))
                            return
                        }
                        collected.append((locations ?? []).compactMap(WorkoutRouteLocation.init(location:)))
                        if done { box.finish(.success(collected.all)) }
                    }
                    if box.start(query, continuation) { store.execute(query) }
                }
            } onCancel: {
                box.cancel { store.stop($0) }
            }
        }
    }

    extension WorkoutRouteLocation {
        /// A fix with a negative horizontal accuracy is invalid (CoreLocation's
        /// own rule) and dropped; altitude and speed only when valid.
        init?(location: CLLocation) {
            guard location.horizontalAccuracy >= 0 else { return nil }
            self.init(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                altitude: location.verticalAccuracy >= 0 ? location.altitude : nil,
                timestamp: location.timestamp,
                speed: location.speed >= 0 ? location.speed : nil
            )
        }
    }

    /// Resumes its continuation exactly once, whichever of answer and
    /// cancellation comes first, and stops the query on cancellation.
    private final class WorkoutRouteQueryBox<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value, any Error>?
        private var query: HKQuery?
        private var cancelled = false

        /// `false` when the caller was cancelled before the query started.
        func start(_ query: HKQuery, _ continuation: CheckedContinuation<Value, any Error>) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !cancelled else {
                continuation.resume(throwing: CancellationError())
                return false
            }
            self.query = query
            self.continuation = continuation
            return true
        }

        func finish(_ result: Result<Value, any Error>) {
            lock.lock()
            let pending = continuation
            continuation = nil
            query = nil
            lock.unlock()
            pending?.resume(with: result)
        }

        func cancel(stop: (HKQuery) -> Void) {
            lock.lock()
            cancelled = true
            let pending = continuation
            let running = query
            continuation = nil
            query = nil
            lock.unlock()
            if let running { stop(running) }
            pending?.resume(throwing: CancellationError())
        }
    }

    /// The fixes of one route query, which HealthKit delivers in batches.
    private final class WorkoutRouteFixes: @unchecked Sendable {
        private let lock = NSLock()
        private var fixes: [WorkoutRouteLocation] = []

        func append(_ batch: [WorkoutRouteLocation]) {
            lock.lock()
            fixes += batch
            lock.unlock()
        }

        var all: [WorkoutRouteLocation] {
            lock.lock()
            defer { lock.unlock() }
            return fixes
        }
    }

    /// **The route step of one workout page.** Owned by the importer; decides
    /// per workout whether a route is read and attached.
    ///
    /// A route is read only when all of this holds: the opt-in gate is open
    /// (asked again after the read, so a switch turned off meanwhile still
    /// wins), the page is a small one that also carries heart-rate series (new
    /// workouts, never the 100-workout history pages of a background
    /// processing pass), and the workout started inside the recent window
    /// (``WorkoutCatchUpPolicy/recentWindowDays``). Older workouts are already
    /// on the server, and the server attaches a route only to a workout it
    /// inserts (`batch-ingest/write.ts`, v1.47.0), so reading theirs would
    /// move location data for nothing.
    struct WorkoutRouteAttachment: Sendable {
        let reader: any WorkoutRouteReading
        let isAllowed: @Sendable () -> Bool
        let now: @Sendable () -> Date
        /// Bound for one workout's route read; a hung query costs the route,
        /// never the page.
        var readLimit: Duration = .seconds(15)

        enum Outcome: Equatable {
            case notRequested
            case none
            case attached(points: Int, thinnedFrom: Int?)
            case failed
        }

        static func live(store: HKHealthStore, ownerUserID: String) -> WorkoutRouteAttachment {
            WorkoutRouteAttachment(
                reader: LiveWorkoutRouteReader(store: store),
                isAllowed: { WorkoutRouteOptIn.allowsUpload(ownerUserID: ownerUserID) },
                now: Date.init
            )
        }

        func pageMayCarryRoutes(workoutCount: Int) -> Bool {
            WorkoutHealthKitImporter.shouldAttachSeries(workoutCount: workoutCount) && isAllowed()
        }

        /// The DTO with its route when one may and can be attached, and what
        /// happened. Cancellation is the only error that escapes. `notBefore`
        /// widens the window for the explicit pass for older workouts
        /// (``WorkoutRouteBackfill``, POLISH-B B10); the importer keeps the
        /// recent window.
        func attach(
            to dto: WorkoutIngestDTO,
            of workout: HKWorkout,
            notBefore: Date? = nil
        ) async throws -> (dto: WorkoutIngestDTO, outcome: Outcome) {
            let windowStart = notBefore ?? WorkoutCatchUpPolicy.recentWindowStart(now: now())
            guard workout.startDate >= windowStart, isAllowed() else {
                return (dto, .notRequested)
            }
            let reader = reader
            let read = Task { try await reader.locations(for: workout) }
            let fixes: [WorkoutRouteLocation]
            do {
                fixes = try await withTaskCancellationHandler {
                    try await Self.bounded(read, limit: readLimit)
                } onCancel: {
                    read.cancel()
                }
            } catch is CancellationError {
                try Task.checkCancellation()
                return (dto, .failed)
            } catch {
                HLLog.healthKit.error(
                    "workout route read failed: \(LogSanitizer.redact(String(describing: error)), privacy: .public)"
                )
                return (dto, .failed)
            }
            guard isAllowed() else { return (dto, .notRequested) }
            let wire = WorkoutRouteWire.route(from: fixes)
            guard let route = wire.route else { return (dto, .none) }
            return (
                dto.withRoute(route),
                .attached(points: route.pointCount, thinnedFrom: wire.wasThinned ? wire.usableCount : nil)
            )
        }

        private static func bounded(
            _ read: Task<[WorkoutRouteLocation], any Error>,
            limit: Duration
        ) async throws -> [WorkoutRouteLocation] {
            try await withThrowingTaskGroup(of: [WorkoutRouteLocation].self) { group in
                group.addTask { try await read.value }
                group.addTask {
                    try await Task.sleep(for: limit)
                    read.cancel()
                    throw WorkoutRouteReadTimeout()
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else { throw WorkoutRouteReadTimeout() }
                return first
            }
        }
    }

    struct WorkoutRouteReadTimeout: Error {}

#endif
