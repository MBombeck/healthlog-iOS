import Foundation

#if canImport(HealthKit)

    struct WorkoutHistoryQueryDriver: Sendable {
        typealias Completion = @Sendable ([HKSample]?, (any Error)?) -> Void

        let makeQuery: @Sendable (
            NSPredicate,
            Int,
            NSSortDescriptor,
            @escaping Completion
        ) -> HKSampleQuery
        let execute: @Sendable (HKQuery) -> Void
        let stop: @Sendable (HKQuery) -> Void

        init(
            makeQuery: @escaping @Sendable (
                NSPredicate,
                Int,
                NSSortDescriptor,
                @escaping Completion
            ) -> HKSampleQuery,
            execute: @escaping @Sendable (HKQuery) -> Void,
            stop: @escaping @Sendable (HKQuery) -> Void
        ) {
            self.makeQuery = makeQuery
            self.execute = execute
            self.stop = stop
        }

        init(store: HKHealthStore) {
            self.init(
                makeQuery: { predicate, limit, sort, completion in
                    HKSampleQuery(
                        sampleType: HKObjectType.workoutType(),
                        predicate: predicate,
                        limit: limit,
                        sortDescriptors: [sort]
                    ) { _, samples, error in
                        completion(samples, error)
                    }
                },
                execute: { store.execute($0) },
                stop: { store.stop($0) }
            )
        }
    }

    import HealthKit
#endif

#if canImport(HealthKit)

    /// **GH #86** — HealthKit producer for ``WorkoutHRBackfillSweep``: hands out
    /// the workout history newest-first, page by page, each entry already mapped
    /// to ``WorkoutIngestDTO`` WITH its HR series attached.
    ///
    /// Deliberately a plain `HKSampleQuery` walk rather than an anchored query:
    /// the backfill is not "what changed since last time" but "walk everything
    /// once, backwards, and stop at the end of history". The anchored path
    /// belongs to ``WorkoutHealthKitImporter`` and stays untouched — this source
    /// never advances that anchor and never writes to HealthKit.
    ///
    /// **Entries without a series are dropped here, not at the server.** A
    /// manually logged workout, or one from a device with no HR sensor, has
    /// nothing to enrich; posting it would be a pure no-op round-trip. Dropping
    /// it locally is also what keeps ``WorkoutIngestDTO/samples`` honest: what we
    /// post always carries a real series.
    actor HealthKitWorkoutHistorySource: WorkoutHRBackfillSourcing {
        private let driver: WorkoutHistoryQueryDriver
        private let series: any WorkoutHeartRateSeriesSyncServicing
        private let leaseIsCurrent: @Sendable () -> Bool

        private struct PendingFetch {
            let query: HKSampleQuery
            let continuation: CheckedContinuation<FetchOutcome, Never>
        }

        private var pendingFetches: [UUID: PendingFetch] = [:]

        init(
            store: HKHealthStore,
            series: (any WorkoutHeartRateSeriesSyncServicing)? = nil,
            leaseIsCurrent: @escaping @Sendable () -> Bool = { true },
            driver: WorkoutHistoryQueryDriver? = nil
        ) {
            self.driver = driver ?? WorkoutHistoryQueryDriver(store: store)
            self.series = series ?? HealthKitWorkoutDetailService(store: store)
            self.leaseIsCurrent = leaseIsCurrent
        }

        func page(
            before cursor: WorkoutHRBackfillCursor,
            limit: Int
        ) async -> WorkoutHRBackfillPageOutcome {
            guard hasCurrentLease else { return .cancelled }
            guard HKHealthStore.isHealthDataAvailable() else {
                return .authorizationPending
            }
            let fetchOutcome = await fetch(before: cursor, limit: limit)
            guard hasCurrentLease else { return .cancelled }
            let workouts: [HKWorkout]
            switch fetchOutcome {
            case let .page(value):
                workouts = value
            case .exhausted:
                return .exhausted
            case .authorizationPending:
                return .authorizationPending
            case .failed:
                return .failed(.query)
            case .cancelled:
                return .cancelled
            }
            return await map(workouts)
        }

        private func map(_ workouts: [HKWorkout]) async -> WorkoutHRBackfillPageOutcome {
            var dtos: [WorkoutIngestDTO] = []
            var containsAuthorizationAmbiguousEmpty = false
            dtos.reserveCapacity(workouts.count)
            for workout in workouts {
                guard hasCurrentLease else { return .cancelled }
                if WorkoutHealthKitMapping.isOwnEcho(workout) {
                    continue
                }
                let disposition = await WorkoutHealthKitMapping.ingestDisposition(
                    from: workout,
                    series: series
                )
                guard hasCurrentLease else { return .cancelled }
                switch disposition {
                case let .attached(dto):
                    dtos.append(dto)
                case .empty:
                    containsAuthorizationAmbiguousEmpty = true
                case .failed:
                    return .failed(.series)
                case .cancelled:
                    return .cancelled
                case .notRequested:
                    return .failed(.series)
                case .skipped:
                    continue
                }
            }
            guard hasCurrentLease else { return .cancelled }
            guard !containsAuthorizationAmbiguousEmpty else { return .seriesEmpty }
            let oldestStart = workouts.map(\.startDate).min()
            let oldestIdentifiers = Set(workouts.compactMap { workout in
                workout.startDate == oldestStart ? workout.uuid.uuidString : nil
            })
            return .page(WorkoutHRBackfillPage(
                workouts: dtos,
                oldestStart: oldestStart,
                oldestStartIdentifiers: oldestIdentifiers,
                fetchedCount: workouts.count
            ))
        }

        /// Newest-first page of workouts that STARTED before `before`.
        /// `.strictStartDate` pins the predicate to the start date (an overlap
        /// match would keep re-serving a long session that spans the bound).
        private enum FetchOutcome: Sendable {
            case page([HKWorkout])
            case exhausted
            case authorizationPending
            case failed
            case cancelled
        }

        /// Keeps successful exhaustion separate from authorization and query
        /// failure. The sweep may retry `.failed`, but only `.exhausted` after
        /// prior progress is allowed to mark the walk complete.
        private func fetch(
            before cursor: WorkoutHRBackfillCursor,
            limit: Int
        ) async -> FetchOutcome {
            let predicate = HKQuery.predicateForSamples(
                withStart: Date.distantPast,
                // `.strictStartDate` evaluates the upper bound as `< end`.
                // Advancing by one representable instant keeps the composite
                // cursor's timestamp in the query so its UUID ties can be
                // filtered explicitly below instead of disappearing forever.
                end: Self.inclusiveQueryEnd(for: cursor.startDate),
                options: [.strictStartDate]
            )
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
            let finiteLimit = Self.finiteQueryLimit(
                pageLimit: limit,
                excludedCount: cursor.excludedIdentifiersAtStart.count
            )
            let queryID = UUID()
            let outcome = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    beginFetch(
                        id: queryID,
                        predicate: predicate,
                        limit: finiteLimit,
                        sort: sort,
                        continuation: continuation
                    )
                }
            } onCancel: {
                Task { await self.cancelFetch(id: queryID) }
            }
            guard case let .page(workouts) = outcome else { return outcome }
            let bounded = Self.selectPage(
                from: workouts,
                cursor: cursor,
                limit: limit,
                startDate: \HKWorkout.startDate,
                identifier: { $0.uuid.uuidString }
            )
            return bounded.isEmpty ? .exhausted : .page(bounded)
        }

        /// Exclusive HealthKit query end that still includes samples exactly
        /// at the composite cursor timestamp.
        static func inclusiveQueryEnd(for cursorStart: Date) -> Date {
            Date(timeIntervalSinceReferenceDate: cursorStart.timeIntervalSinceReferenceDate.nextUp)
        }

        /// Every request remains finite while widening by the number of UUIDs
        /// already drained at the timestamp boundary. That widening is what
        /// makes arbitrarily large ties progress instead of re-serving the
        /// same first page forever.
        static func finiteQueryLimit(pageLimit: Int, excludedCount: Int) -> Int {
            let positivePageLimit = max(1, pageLimit)
            let sum = positivePageLimit.addingReportingOverflow(max(0, excludedCount))
            return sum.overflow ? Int.max : sum.partialValue
        }

        /// Exact post-query selection shared by production and the semantic
        /// boundary test. HealthKit provides only the date predicate; UUID tie
        /// exclusion and the public page bound remain our responsibility.
        static func selectPage<Element>(
            from elements: [Element],
            cursor: WorkoutHRBackfillCursor,
            limit: Int,
            startDate: (Element) -> Date,
            identifier: (Element) -> String
        ) -> [Element] {
            let filtered = elements.filter { element in
                !(startDate(element) == cursor.startDate
                    && cursor.excludedIdentifiersAtStart.contains(identifier(element)))
            }
            return Array(filtered.prefix(max(1, limit)))
        }

        private func beginFetch(
            id: UUID,
            predicate: NSPredicate,
            limit: Int,
            sort: NSSortDescriptor,
            continuation: CheckedContinuation<FetchOutcome, Never>
        ) {
            let query = driver.makeQuery(predicate, limit, sort) { [weak self] samples, error in
                let workouts = (samples as? [HKWorkout]) ?? []
                Task { await self?.completeFetch(id: id, workouts: workouts, error: error) }
            }
            pendingFetches[id] = PendingFetch(query: query, continuation: continuation)
            driver.execute(query)
        }

        private func cancelFetch(id: UUID) {
            guard let pending = pendingFetches.removeValue(forKey: id) else {
                // `beginFetch` registers synchronously on this actor before
                // `fetch` first suspends. Missing means callback/cancellation
                // already won; retaining a never-reused UUID would leak.
                return
            }
            driver.stop(pending.query)
            pending.continuation.resume(returning: .cancelled)
        }

        private func completeFetch(id: UUID, workouts: [HKWorkout], error: (any Error)?) {
            guard let pending = pendingFetches.removeValue(forKey: id) else { return }
            if let error {
                let nsError = error as NSError
                HLLog.healthKit.warning(
                    "workout HR backfill page failed: \(LogSanitizer.redact(String(describing: error)), privacy: .public)"
                )
                if nsError.domain == HKErrorDomain,
                   nsError.code == HKError.Code.errorAuthorizationDenied.rawValue
                {
                    pending.continuation.resume(returning: .authorizationPending)
                } else {
                    pending.continuation.resume(returning: .failed)
                }
                return
            }
            pending.continuation.resume(returning: workouts.isEmpty ? .exhausted : .page(workouts))
        }

        private var hasCurrentLease: Bool {
            !Task.isCancelled && leaseIsCurrent()
        }
    }

#endif
