import Foundation
@testable import HealthLog
import Synchronization
import Testing
#if canImport(HealthKit)
    import HealthKit
#endif

#if canImport(HealthKit)

    /// #17 — newest workouts reach the server first, and a foreground pass
    /// catches the history up within its budget. Every case drives the real
    /// importer against a synthetic HealthKit with hundreds of workouts.
    @Suite("Workout history catch-up (#17)", .serialized, .timeLimit(.minutes(1)))
    struct WorkoutHistoryCatchUpTests {
        @Test("A new workout reaches the uploader in the first foreground pass, before the history")
        @available(iOS, deprecated: 18.0, message: "Synthetic HealthKit fixture")
        func newWorkoutGoesFirst() async throws {
            let harness = try await Harness(historyCount: 300, newestHistoryDaysAgo: 30, budgetPages: 1)
            let today = await harness.history.appendNew(hoursAgo: 2)

            let outcome = await harness.importer.runBoundedPage(mode: .processing)

            #expect(outcome.didRun)
            let batches = await harness.uploader.batches
            #expect(batches.first?.ids == [today], "the recent window is uploaded before any history page")
            #expect(batches.first?.withSeries == [true], "the recent workout carries its HR series")
            #expect(batches.count == 2, "budget of one page: recent window + one history page")
            #expect(await harness.uploader.allIDs.count(where: { $0 == today }) == 1)
            await harness.importer.stop()
        }

        @Test("A foreground pass catches up a 730-workout history within its budget, each workout once")
        @available(iOS, deprecated: 18.0, message: "Synthetic HealthKit fixture")
        func fullCatchUpWithinBudget() async throws {
            let harness = try await Harness(historyCount: 730, newestHistoryDaysAgo: 0)

            let outcome = await harness.importer.runBoundedPage(mode: .processing)

            #expect(outcome.didRun)
            let ids = await harness.uploader.allIDs
            #expect(ids.count == 730, "every workout uploaded")
            #expect(Set(ids).count == 730, "no workout uploaded twice across recent window and backlog")
            #expect(await harness.uploader.batches.first?.ids.count == WorkoutCatchUpPolicy.recentWindowLimit)
            // 7 full pages, one short page; nothing more.
            #expect(await harness.history.anchoredLimits.filter { $0 == 100 }.count == 8)
            let backlog = await harness.importer.historyBacklog()
            #expect(backlog.isBehind == false)
            #expect(backlog.deliveredAhead.isEmpty)
            #expect(backlog.publicStatus?.isImporting == false)
            #expect(try await harness.anchorPosition() == 730)
            await harness.importer.stop()
        }

        @Test("An exhausted budget stops between pages; the next pass resumes without duplicates")
        @available(iOS, deprecated: 18.0, message: "Synthetic HealthKit fixture")
        func budgetStopsAndNextPassResumes() async throws {
            let harness = try await Harness(historyCount: 730, newestHistoryDaysAgo: 0, budgetPages: 3)

            _ = await harness.importer.runBoundedPage(mode: .processing)

            #expect(await harness.uploader.allIDs.count == 310, "recent window (10) + three pages of 100")
            #expect(try await harness.anchorPosition() == 300)
            #expect(await harness.importer.historyBacklog().isBehind == true)

            let fresh = await harness.history.appendNew(hoursAgo: 1)
            for _ in 0 ..< 4 {
                _ = await harness.importer.runBoundedPage(mode: .processing)
            }

            let ids = await harness.uploader.allIDs
            #expect(Set(ids).count == 731)
            #expect(ids.count == 731, "nothing was sent twice")
            // The second pass opens with the rest of the 14-day window, newest
            // first: the new workout, then the four older recent ones.
            let secondPassFirstBatch = await harness.uploader.batches[4].ids
            #expect(secondPassFirstBatch.first == fresh, "the second pass also starts with the newest workout")
            #expect(secondPassFirstBatch.count == 5)
            #expect(await harness.importer.historyBacklog().isBehind == false)
            await harness.importer.stop()
        }

        @Test("A short background wake keeps its cap of 10, with or without the recent window")
        @available(iOS, deprecated: 18.0, message: "Synthetic HealthKit fixture")
        func backgroundWakeKeepsCap() async throws {
            let harness = try await Harness(historyCount: 300, newestHistoryDaysAgo: 30)
            try await harness.seedAnchor(at: 100, behind: true)

            // Nothing new in the recent window: exactly one anchored page of 10.
            _ = await harness.importer.runBoundedPage(mode: .incrementalOnly)
            #expect(await harness.history.anchoredLimits == [WorkoutIngestDTO.maxWorkoutsPerSeriesBatch])
            #expect(await harness.uploader.allIDs.count == 10)
            #expect(try await harness.anchorPosition() == 110)

            // A new workout: the wake delivers it instead of a history page.
            let today = await harness.history.appendNew(hoursAgo: 1)
            _ = await harness.importer.runBoundedPage(mode: .incrementalOnly)
            #expect(await harness.uploader.batches.last?.ids == [today])
            #expect(await harness.history.anchoredLimits.count == 1, "no anchored page beside the recent window")
            #expect(try await harness.anchorPosition() == 110)
            #expect(await harness.uploader.batches.allSatisfy { $0.ids.count <= 10 })
            await harness.importer.stop()
        }

        @Test("The anchor advances only past pages the server fully accepted")
        @available(iOS, deprecated: 18.0, message: "Synthetic HealthKit fixture")
        func anchorOnlyAdvancesOnAcceptedUploads() async throws {
            let harness = try await Harness(historyCount: 350, newestHistoryDaysAgo: 30)
            // Batch 1 = first history page, batch 2 = second page → one row skipped.
            await harness.uploader.rejectCall(2)

            _ = await harness.importer.runBoundedPage(mode: .processing)

            #expect(try await harness.anchorPosition() == 100, "the rejected page did not move the anchor")
            #expect(await harness.uploader.batches.count == 2, "a failed page ends the pass")

            _ = await harness.importer.runBoundedPage(mode: .processing)

            #expect(try await harness.anchorPosition() == 350)
            let ids = await harness.uploader.allIDs
            #expect(Set(ids).count == 350)
            #expect(ids.count == 450, "only the rejected page was posted again")
            await harness.importer.stop()
        }

        @Test("Cancelling mid-pass keeps the anchor at the last accepted page and the next pass resumes")
        @available(iOS, deprecated: 18.0, message: "Synthetic HealthKit fixture")
        func cancellationMidPassResumes() async throws {
            let harness = try await Harness(historyCount: 500, newestHistoryDaysAgo: 0)
            await harness.uploader.blockCall(3)

            let importer = harness.importer
            let pass = Task { await importer.runBoundedPage(mode: .processing) }
            let reachedBlockedUpload = await harness.uploader.waitForCalls(3)
            #expect(reachedBlockedUpload, "the pass reaches its third upload (recent window, page 1, page 2)")
            pass.cancel()

            #expect(await pass.value == .notRun)
            #expect(try await harness.anchorPosition() == 100, "recent window + one accepted page, the blocked one did not count")
            let resumed = try await harness.reopen()
            _ = await resumed.importer.runBoundedPage(mode: .processing)

            let ids = await harness.uploader.allIDs
            #expect(Set(ids).count == 500)
            let blocked = await harness.uploader.batches[2].ids
            #expect(ids.count == 500 + blocked.count, "only the cancelled page was posted again")
            #expect(try await harness.anchorPosition() == 500)
            await resumed.importer.stop()
        }

        @Test("The backlog counter reports what is left and reaches zero")
        @available(iOS, deprecated: 18.0, message: "Synthetic HealthKit fixture")
        func backlogCounter() async throws {
            let harness = try await Harness(historyCount: 730, newestHistoryDaysAgo: 0, budgetPages: 2)

            _ = await harness.importer.runBoundedPage(mode: .processing)

            let status = try #require(await harness.importer.historyBacklog().publicStatus)
            #expect(status.isImporting)
            // 730 − 200 imported by the anchor − 10 recent already delivered ahead.
            #expect(status.remainingEstimate == 520)

            harness.setBudgetPages(1000)
            _ = await harness.importer.runBoundedPage(mode: .processing)

            let done = try #require(await harness.importer.historyBacklog().publicStatus)
            #expect(!done.isImporting)
            #expect(done.remainingEstimate == 0)
            await harness.importer.stop()
        }

        @Test("An install from before #17 that is caught up re-posts nothing; one that is behind learns it")
        @available(iOS, deprecated: 18.0, message: "Synthetic HealthKit fixture")
        func legacyInstallsLearnTheirState() async throws {
            let caughtUp = try await Harness(historyCount: 120, newestHistoryDaysAgo: 0)
            try await caughtUp.seedAnchor(at: 120, behind: nil)
            _ = await caughtUp.importer.runBoundedPage(mode: .processing)
            #expect(await caughtUp.uploader.batches.isEmpty)
            #expect(await caughtUp.history.recentCalls == 0)
            #expect(await caughtUp.importer.historyBacklog().isBehind == false)
            await caughtUp.importer.stop()

            let behind = try await Harness(historyCount: 730, newestHistoryDaysAgo: 0, budgetPages: 2)
            try await behind.seedAnchor(at: 300, behind: nil)
            _ = await behind.importer.runBoundedPage(mode: .processing)
            let batches = await behind.uploader.batches
            #expect(batches.map(\.ids.count) == [100, 10, 100], "first page proves 'behind', then newest first")
            #expect(Set(batches.flatMap(\.ids)).count == 210)
            await behind.importer.stop()
        }

        @Test("Delivered-ahead bookkeeping is capped and clears once the anchor has passed everything")
        func backlogStateBookkeeping() {
            var state = WorkoutImportBacklogState()
            state.noteDeliveredAhead((0 ..< 250).map { "id-\($0)" })
            #expect(state.deliveredAhead.count == WorkoutCatchUpPolicy.deliveredAheadCap)
            #expect(state.deliveredAhead.first == "id-50", "the oldest entries are evicted first")

            state.remainingEstimate = 5
            state.noteAcceptedPage(fetchedCount: 100, passedIdentifiers: ["id-60"], wasFull: true)
            #expect(state.isBehind == true)
            #expect(!state.deliveredAhead.contains("id-60"))
            #expect(state.remainingEstimate == nil, "still behind with nothing counted left: recount")

            state.noteAcceptedPage(fetchedCount: 3, passedIdentifiers: [], wasFull: false)
            #expect(state.isBehind == false)
            #expect(state.deliveredAhead.isEmpty)
            #expect(state.publicStatus?.isImporting == false)
            #expect(state.publicStatus?.remainingEstimate == 0)
            #expect(WorkoutImportBacklogState().publicStatus == nil, "unknown state publishes nothing")
        }

        @Test("The history-import status persists across relaunch and is cleared on logout")
        @MainActor
        func diagnosticsStatusPersists() throws {
            let suite = "hl.hksync.workout.history.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = HKSyncDiagnostics.makeForTesting(defaults: defaults)
            let status = HKSyncDiagnostics.WorkoutHistoryImportStatus(
                isImporting: true,
                remainingEstimate: 42,
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )

            store.recordWorkoutHistoryImport(status)
            #expect(HKSyncDiagnostics.makeForTesting(defaults: defaults).workoutHistoryImport == status)

            store.reset()
            #expect(store.workoutHistoryImport == nil)
            #expect(HKSyncDiagnostics.makeForTesting(defaults: defaults).workoutHistoryImport == nil)
        }
    }

    // MARK: - Harness

    private struct Harness {
        let userID = "catch-up-user"
        let suite: String
        let history: SyntheticWorkoutHistory
        let uploader: RecordingWorkoutUploader
        let importer: WorkoutHealthKitImporter
        private let pageClock: PageBudgetClock

        @available(iOS, deprecated: 18.0, message: "Synthetic HealthKit fixture")
        init(historyCount: Int, newestHistoryDaysAgo: Int, budgetPages: Int = 1000) async throws {
            suite = "hl.test.catch-up.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defaults.removePersistentDomain(forName: suite)
            history = SyntheticWorkoutHistory(now: SyntheticWorkoutHistory.now)
            await history.seed(count: historyCount, newestDaysAgo: newestHistoryDaysAgo)
            uploader = RecordingWorkoutUploader()
            pageClock = PageBudgetClock(pages: budgetPages)
            importer = Self.makeImporter(
                suite: suite,
                userID: userID,
                history: history,
                uploader: uploader,
                clock: pageClock.clock
            )
        }

        private init(copying other: Harness) {
            suite = other.suite
            history = other.history
            uploader = other.uploader
            pageClock = other.pageClock
            importer = Self.makeImporter(
                suite: suite,
                userID: userID,
                history: history,
                uploader: uploader,
                clock: pageClock.clock
            )
        }

        /// A fresh importer over the same persisted state (relaunch).
        func reopen() async throws -> Harness {
            await importer.stop()
            return Harness(copying: self)
        }

        func setBudgetPages(_ pages: Int) {
            pageClock.setPages(pages)
        }

        private static func makeImporter(
            suite: String,
            userID: String,
            history: SyntheticWorkoutHistory,
            uploader: RecordingWorkoutUploader,
            clock: WorkoutCatchUpClock
        ) -> WorkoutHealthKitImporter {
            WorkoutHealthKitImporter(
                store: HKHealthStore(),
                repo: uploader,
                userID: userID,
                defaultsBox: WorkoutDefaultsBox(suiteName: suite),
                series: AlwaysSeriesService(),
                lifecycleStore: WorkoutSeriesLifecycleStore(),
                anchoredQuerySource: history,
                recentWindowSource: history,
                clock: clock
            )
        }

        private var anchorKey: String {
            "hl.workout.hk.anchor." + HealthKitService.partitionToken(for: userID)
        }

        func anchorPosition() async throws -> Int? {
            let box = WorkoutDefaultsBox(suiteName: suite)
            guard let anchor = box.loadAnchor(forKey: anchorKey, label: "test") else { return nil }
            return try await history.position(of: anchor)
        }

        func seedAnchor(at position: Int, behind: Bool?) async throws {
            let box = WorkoutDefaultsBox(suiteName: suite)
            let anchor = try await history.anchor(at: position)
            box.saveAnchor(anchor, forKey: anchorKey, label: "test")
            box.saveBacklog(
                WorkoutImportBacklogState(isBehind: behind),
                forKey: "hl.workout.hk.backlog." + HealthKitService.partitionToken(for: userID)
            )
        }
    }

    /// The budget is counted in pages: every `uptime` read advances the clock
    /// by a hair more than one budget slice, so exactly `pages` anchored pages
    /// fit before the deadline of a pass.
    private final class PageBudgetClock: Sendable {
        private let pages: Mutex<Int>
        private let ticks = Mutex(0)

        init(pages: Int) {
            self.pages = Mutex(pages)
        }

        func setPages(_ value: Int) {
            pages.withLock { $0 = value }
        }

        var clock: WorkoutCatchUpClock {
            WorkoutCatchUpClock(
                now: { SyntheticWorkoutHistory.now },
                uptime: { [self] in
                    let count = pages.withLock { max(1, $0) }
                    let tick = ticks.withLock { value -> Int in
                        defer { value += 1 }
                        return value
                    }
                    let slice = WorkoutCatchUpPolicy.processingBudget / Double(count) * 1.000_001
                    return Double(tick) * slice
                }
            )
        }
    }

    /// HealthKit stand-in: workouts in insertion order (oldest first, the way
    /// a long Apple Watch history reaches a fresh anchor), anchored pages over
    /// that order, and a newest-first recent window over start dates.
    private actor SyntheticWorkoutHistory: WorkoutAnchoredQueryFetching, WorkoutRecentWindowFetching {
        static let now = Date(timeIntervalSince1970: 1_790_000_000)

        private let reference: Date
        private var workouts: [HKWorkout] = []
        private var positions: [Data: Int] = [:]
        private(set) var anchoredLimits: [Int] = []
        private(set) var recentCalls = 0

        init(now: Date) {
            reference = now
        }

        @available(iOS, deprecated: 18.0, message: "Synthetic HealthKit fixture")
        func seed(count: Int, newestDaysAgo: Int) {
            for index in 0 ..< count {
                let daysAgo = newestDaysAgo + (count - 1 - index)
                let start = reference.addingTimeInterval(-Double(daysAgo) * 86400 - 7200)
                workouts.append(HKWorkout(activityType: .walking, start: start, end: start.addingTimeInterval(1800)))
            }
        }

        @available(iOS, deprecated: 18.0, message: "Synthetic HealthKit fixture")
        func appendNew(hoursAgo: Double) -> String {
            let start = reference.addingTimeInterval(-hoursAgo * 3600)
            let workout = HKWorkout(activityType: .walking, start: start, end: start.addingTimeInterval(1200))
            workouts.append(workout)
            return workout.uuid.uuidString
        }

        func anchor(at position: Int) throws -> HKQueryAnchor {
            let anchor = HKQueryAnchor(fromValue: position)
            try positions[Self.key(anchor)] = position
            return anchor
        }

        func position(of anchor: HKQueryAnchor) throws -> Int {
            guard let position = try positions[Self.key(anchor)] else {
                Issue.record("synthetic history does not know this anchor")
                return -1
            }
            return position
        }

        func fetch(anchor: HKQueryAnchor?, limit: Int) async throws -> WorkoutAnchoredQueryPage {
            anchoredLimits.append(limit)
            let start = try anchor.map { try position(of: $0) } ?? 0
            let end = limit == HKObjectQueryNoLimit ? workouts.count : min(workouts.count, start + limit)
            let page = Array(workouts[max(0, start) ..< max(max(0, start), end)])
            return try WorkoutAnchoredQueryPage(workouts: page, newAnchor: self.anchor(at: max(start, end)))
        }

        func fetchRecent(since: Date, limit: Int) async throws -> WorkoutAnchoredQueryPage {
            recentCalls += 1
            let recent = workouts
                .filter { $0.startDate >= since }
                .sorted { $0.startDate > $1.startDate }
            return WorkoutAnchoredQueryPage(workouts: Array(recent.prefix(limit)), newAnchor: nil)
        }

        private static func key(_ anchor: HKQueryAnchor) throws -> Data {
            try NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
        }
    }

    private struct UploadedBatch: Sendable {
        let ids: [String]
        let withSeries: [Bool]
    }

    /// Accepts everything unless told to reject or block one call.
    private actor RecordingWorkoutUploader: WorkoutBatchUploading {
        private(set) var batches: [UploadedBatch] = []
        private var rejectedCall: Int?
        private var blockedCall: Int?

        func rejectCall(_ call: Int) {
            rejectedCall = call
        }

        func blockCall(_ call: Int) {
            blockedCall = call
        }

        var allIDs: [String] {
            batches.flatMap(\.ids)
        }

        /// Bounded, so a regression fails the case instead of hanging the
        /// serialized gate every other unit is waiting on.
        func waitForCalls(_ count: Int, timeout: Duration = .seconds(10)) async -> Bool {
            let deadline = ContinuousClock.now + timeout
            while batches.count < count {
                guard ContinuousClock.now < deadline else { return false }
                await Task.yield()
            }
            return true
        }

        func uploadBatch(
            _ workouts: [WorkoutIngestDTO],
            ownerUserID _: String
        ) async throws -> WorkoutBatchResponseDTO {
            batches.append(UploadedBatch(
                ids: workouts.compactMap(\.externalId),
                withSeries: workouts.map { $0.samples != nil }
            ))
            let call = batches.count
            if call == blockedCall {
                try await Task.sleep(for: .seconds(30))
            }
            var entries = workouts.indices.map {
                WorkoutBatchResponseDTO.Entry(index: $0, status: .inserted)
            }
            if call == rejectedCall, let last = entries.indices.last {
                entries[last] = WorkoutBatchResponseDTO.Entry(index: last, status: .skipped, reason: "invalid")
            }
            return WorkoutBatchResponseDTO(
                processed: workouts.count,
                inserted: workouts.count,
                duplicates: 0,
                entries: entries
            )
        }
    }

    private struct AlwaysSeriesService: WorkoutHeartRateSeriesSyncServicing {
        func heartRateSeriesOutcome(from start: Date, to _: Date) async -> WorkoutHeartRateSeriesOutcome {
            .samples([WorkoutHRSample(timestamp: start, bpm: 118)])
        }
    }

#endif
