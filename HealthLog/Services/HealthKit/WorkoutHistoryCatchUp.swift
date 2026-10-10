import Foundation

#if canImport(HealthKit)
    import HealthKit

    /// **#17 — newest workouts first, history catch-up within a budget.**
    ///
    /// The direct importer used to take exactly one anchored page per pass.
    /// A fresh anchor starts at the oldest workout, so with a long Apple Watch
    /// history today's walk waited behind years of history while every pass
    /// truthfully reported "delivered". These numbers bound the two fixes.
    enum WorkoutCatchUpPolicy {
        /// Wall-clock budget for one foreground / manual / BGProcessing pass.
        ///
        /// Twenty seconds: a series-free page of 100 workouts is one HealthKit
        /// query plus one POST, typically one to two seconds, so a pass drains
        /// roughly 1 000–2 000 workouts. That covers the reported history
        /// (≈730) in one app open while staying inside the ~30 s iOS grants an
        /// app that is backgrounded mid-pass. The budget is checked only
        /// between pages: a page in flight always finishes or is cancelled as a
        /// whole, and the anchor still advances only after an accepted page.
        static let processingBudget: TimeInterval = 20

        /// Hard page ceiling per pass, independent of the clock. 25 pages of
        /// 100 stay well under the server's 60 batches/min/user limit for
        /// `POST /api/workouts/batch`, which the HR backfill shares.
        static let maxPagesPerPass = 25

        /// The recent window: workouts that started in the last 14 days, at
        /// most one series-bearing batch (10) per pass. Fourteen days covers
        /// what the dashboard and the workout list show first; ten keeps the
        /// window a single `maxWorkoutsPerSeriesBatch` upload so its HR series
        /// can ride along without risking the 5 MB route ceiling.
        static let recentWindowDays = 14
        static let recentWindowLimit = WorkoutIngestDTO.maxWorkoutsPerSeriesBatch

        /// Upper bound on UUIDs remembered as "delivered ahead of the anchor".
        /// Entries leave the set as the anchor passes them; the cap only
        /// matters for an account that stays behind for a long time. An
        /// evicted entry is re-posted once by the backlog and lands on the
        /// server's `(userId, source, externalId)` upsert as `duplicate`.
        static let deliveredAheadCap = 200

        static func recentWindowStart(now: Date) -> Date {
            now.addingTimeInterval(-Double(recentWindowDays) * 86400)
        }
    }

    /// Per-user persisted backlog bookkeeping, stored beside the anchor and
    /// cleared with it.
    ///
    /// - `isBehind`: `nil` until a page has proven either way (an install that
    ///   predates this state), `true` after a full anchored page, `false` once
    ///   a page came back short — the anchor has passed every workout.
    /// - `deliveredAhead`: HKWorkout UUIDs (= the server `externalId`) the
    ///   recent window delivered and the server accepted before the anchor
    ///   reached them. The anchored backlog skips them, so nothing is sent
    ///   twice; they leave the set once the anchor has passed them.
    /// - `remainingEstimate`: workouts still behind the anchor, minus those
    ///   already delivered ahead. `nil` while unknown.
    struct WorkoutImportBacklogState: Codable, Sendable, Equatable {
        var isBehind: Bool?
        var deliveredAhead: [String] = []
        var remainingEstimate: Int?

        init(isBehind: Bool? = nil, deliveredAhead: [String] = [], remainingEstimate: Int? = nil) {
            self.isBehind = isBehind
            self.deliveredAhead = deliveredAhead
            self.remainingEstimate = remainingEstimate
        }

        /// Records UUIDs the server accepted ahead of the anchor, newest
        /// entries kept when the cap is reached.
        mutating func noteDeliveredAhead(_ identifiers: [String]) {
            let known = Set(deliveredAhead)
            deliveredAhead.append(contentsOf: identifiers.filter { !known.contains($0) })
            if deliveredAhead.count > WorkoutCatchUpPolicy.deliveredAheadCap {
                deliveredAhead.removeFirst(deliveredAhead.count - WorkoutCatchUpPolicy.deliveredAheadCap)
            }
        }

        /// Applies one fully accepted anchored page.
        mutating func noteAcceptedPage(fetchedCount: Int, passedIdentifiers: Set<String>, wasFull: Bool) {
            if wasFull {
                isBehind = true
                deliveredAhead.removeAll { passedIdentifiers.contains($0) }
                if let remaining = remainingEstimate {
                    let newlyImported = max(0, fetchedCount - passedIdentifiers.count)
                    // Still behind with nothing counted left means workouts
                    // arrived meanwhile: unknown again, recounted next pass.
                    let left = remaining - newlyImported
                    remainingEstimate = left > 0 ? left : nil
                }
            } else {
                // A short page means the anchor has passed every workout that
                // exists: whatever is left in the set was passed earlier.
                isBehind = false
                deliveredAhead.removeAll()
                remainingEstimate = 0
            }
        }

        var publicStatus: HKSyncDiagnostics.WorkoutHistoryImportStatus? {
            guard let isBehind else { return nil }
            return HKSyncDiagnostics.WorkoutHistoryImportStatus(
                isImporting: isBehind,
                remainingEstimate: isBehind ? remainingEstimate : 0
            )
        }
    }

    /// Newest-first query for the recent window. Separate from the anchored
    /// query on purpose: it never touches the anchor.
    protocol WorkoutRecentWindowFetching: Sendable {
        func fetchRecent(since: Date, limit: Int) async throws -> WorkoutAnchoredQueryPage
    }

    /// Live recent window over `HKSampleQuery`, newest start date first.
    /// Cancellation stops the concrete query exactly once; a late callback
    /// after cancellation is ignored.
    actor LiveWorkoutRecentWindowSource: WorkoutRecentWindowFetching {
        private let driver: WorkoutHistoryQueryDriver
        private var pending: [UUID: (query: HKSampleQuery, continuation: CheckedContinuation<[HKWorkout], any Error>)] = [:]

        init(store: HKHealthStore) {
            driver = WorkoutHistoryQueryDriver(store: store)
        }

        init(driver: WorkoutHistoryQueryDriver) {
            self.driver = driver
        }

        func fetchRecent(since: Date, limit: Int) async throws -> WorkoutAnchoredQueryPage {
            let predicate = HKQuery.predicateForSamples(
                withStart: since,
                end: nil,
                options: [.strictStartDate]
            )
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
            let id = UUID()
            let workouts = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    begin(id: id, predicate: predicate, limit: max(1, limit), sort: sort, continuation: continuation)
                }
            } onCancel: {
                Task { await self.cancel(id: id) }
            }
            return WorkoutAnchoredQueryPage(workouts: workouts, newAnchor: nil)
        }

        private func begin(
            id: UUID,
            predicate: NSPredicate,
            limit: Int,
            sort: NSSortDescriptor,
            continuation: CheckedContinuation<[HKWorkout], any Error>
        ) {
            let query = driver.makeQuery(predicate, limit, sort) { [weak self] samples, error in
                let workouts = (samples as? [HKWorkout]) ?? []
                Task { await self?.complete(id: id, workouts: workouts, error: error) }
            }
            pending[id] = (query, continuation)
            driver.execute(query)
        }

        private func cancel(id: UUID) {
            guard let entry = pending.removeValue(forKey: id) else { return }
            driver.stop(entry.query)
            entry.continuation.resume(throwing: CancellationError())
        }

        private func complete(id: UUID, workouts: [HKWorkout], error: (any Error)?) {
            guard let entry = pending.removeValue(forKey: id) else { return }
            if let error {
                entry.continuation.resume(throwing: error)
            } else {
                entry.continuation.resume(returning: workouts)
            }
        }
    }

#endif

#if canImport(HealthKit)

    /// Injectable time for the catch-up budget (monotonic) and the recent
    /// window (calendar).
    struct WorkoutCatchUpClock: Sendable {
        let now: @Sendable () -> Date
        let uptime: @Sendable () -> TimeInterval

        static let live = Self(
            now: { Date() },
            uptime: { ProcessInfo.processInfo.systemUptime }
        )
    }

#endif
