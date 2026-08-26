import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// b177 W-SYNCPROGRESS — locks the honest sync-progress aggregation on
/// `SyncStateStore`:
///
/// - `pendingOutboxCount` mirrors the live outbox backlog (sinks on dequeue),
/// - `activeRevalidationCount` mirrors the SWR single-flight registry,
/// - `pendingSyncCount` is the plain sum (no invented percentages, spec §4.5),
/// - a `>0 → 0` outbox drain arms the short "Daten übermittelt ✓" beat,
///   any new backlog (or logout) disarms it.
@MainActor
@Suite("SyncStateStore — sync progress aggregation", .serialized)
struct SyncStateStoreProgressTests {
    private func makeStore(hold: Duration = .seconds(2.5)) -> SyncStateStore {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.14.8",
            buildNumber: "1"
        )
        let api = APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
        return SyncStateStore(repo: SyncStateRepository(api: api), drainConfirmationHold: hold)
    }

    /// Polls `condition` on the main actor until it holds or `timeout` passes.
    private func waitUntil(
        timeout: Duration = .seconds(3),
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func makeOperation() -> OutboxQueue.Operation {
        OutboxQueue.Operation(kind: .createMeasurement, payload: Data("{}".utf8))
    }

    // MARK: - Pure aggregation

    @Test("pendingSyncCount is the sum of outbox backlog + active revalidations")
    func aggregateIsPlainSum() {
        let store = makeStore()
        store.noteOutboxPending(3)
        store.noteActiveRevalidations(4)
        #expect(store.pendingOutboxCount == 3)
        #expect(store.activeRevalidationCount == 4)
        #expect(store.pendingSyncCount == 7)
    }

    @Test("outbox drain (>0 → 0) arms the transmitted confirmation")
    func drainArmsConfirmation() {
        let store = makeStore()
        store.noteOutboxPending(2)
        #expect(!store.showsDrainConfirmation)
        store.noteOutboxPending(0)
        #expect(store.showsDrainConfirmation)
    }

    @Test("a 0 → 0 settle never arms the confirmation (cold start)")
    func zeroSettleStaysQuiet() {
        let store = makeStore()
        store.noteOutboxPending(0)
        #expect(!store.showsDrainConfirmation)
    }

    @Test("confirmation expires after the hold")
    func confirmationExpires() async {
        let store = makeStore(hold: .milliseconds(40))
        store.noteOutboxPending(2)
        store.noteOutboxPending(0)
        #expect(store.showsDrainConfirmation)
        let settled = await waitUntil { !store.showsDrainConfirmation }
        #expect(settled, "confirmation must drop after the hold")
    }

    @Test("new backlog disarms a showing confirmation immediately")
    func newBacklogDisarms() {
        let store = makeStore()
        store.noteOutboxPending(2)
        store.noteOutboxPending(0)
        #expect(store.showsDrainConfirmation)
        store.noteOutboxPending(1)
        #expect(!store.showsDrainConfirmation)
        #expect(store.pendingOutboxCount == 1)
    }

    @Test("clearOnLogout drops the confirmation")
    func logoutDropsConfirmation() {
        let store = makeStore()
        store.noteOutboxPending(2)
        store.noteOutboxPending(0)
        #expect(store.showsDrainConfirmation)
        store.clearOnLogout()
        #expect(!store.showsDrainConfirmation)
    }

    // MARK: - Live outbox binding (counts sink on dequeue)

    @Test("bindOutbox mirrors the live backlog and sinks on dequeue")
    func boundCountSinksOnDequeue() async throws {
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { "usr_test" })
        let store = makeStore()
        store.bindOutbox(outbox)

        let first = makeOperation()
        let second = makeOperation()
        try await outbox.enqueue(first)
        try await outbox.enqueue(second)
        #expect(await waitUntil { store.pendingOutboxCount == 2 }, "backlog must reach 2 after two enqueues")

        try await outbox.remove(id: first.id)
        #expect(await waitUntil { store.pendingOutboxCount == 1 }, "backlog must sink to 1 after dequeue")

        try await outbox.remove(id: second.id)
        #expect(await waitUntil { store.pendingOutboxCount == 0 }, "backlog must sink to 0 after final dequeue")
        #expect(store.showsDrainConfirmation, "full drain must arm the transmitted beat")
    }

    // MARK: - Live SWR binding

    @Test("bindRevalidations mirrors the in-flight single-flight count")
    func boundRevalidationCountFollowsFetch() async throws {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        let coordinator = SWRCoordinator(cache: cache, reachability: AlwaysOnlineReach())
        let store = makeStore()
        store.bindRevalidations(coordinator)
        #expect(await waitUntil { store.activeRevalidationCount == 0 }, "initial yield must land")

        let gate = FetchGate()
        let fetchTask = Task {
            try await coordinator.fetchCachingFirst(
                .dashboardSummary(day: "2026-06-11"),
                decoding: String.self,
                forceRevalidate: true
            ) {
                await gate.wait()
                return "fresh"
            }
        }
        #expect(await waitUntil { store.activeRevalidationCount == 1 }, "in-flight fetch must count as 1")

        await gate.open()
        let value = try await fetchTask.value
        #expect(value == "fresh")
        #expect(await waitUntil { store.activeRevalidationCount == 0 }, "count must sink back to 0 after the fetch lands")
    }
}

/// Reachability stub — always online so `fetchCachingFirst` takes the
/// network/single-flight path.
private final class AlwaysOnlineReach: ReachabilityProviding, @unchecked Sendable {
    var isOnlineStream: AsyncStream<Bool> {
        get async {
            AsyncStream { c in
                c.yield(true)
                c.finish()
            }
        }
    }

    func isCurrentlyOnline() async -> Bool {
        true
    }
}

/// Minimal async gate — holds the fetch open until the test releases it, so
/// Phase 07 / plan 07-07 — the named HealthKit sync truth the same store now
/// carries, and the three claims it is forbidden from making.
@MainActor
@Suite("SyncStateStore — named HealthKit sync truth", .serialized)
struct SyncStateStoreHealthSyncTests {
    // swiftlint:disable:next force_unwrapping
    private static let baseURL = URL(string: "https://test.healthlog.local")!

    private func makeStore() -> SyncStateStore {
        let env = AppEnvironment(
            baseURL: Self.baseURL,
            bundleID: "dev.healthlog.app",
            appVersion: "0.14.8",
            buildNumber: "1"
        )
        let api = APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
        return SyncStateStore(repo: SyncStateRepository(api: api))
    }

    private func snapshot(
        trigger: HealthSyncTrigger,
        results: [HealthSyncCapabilityResult],
        planned: Set<HealthSyncCapability>? = nil
    ) -> HealthSyncPassSnapshot {
        HealthSyncPassResult(
            trigger: trigger,
            planned: planned ?? Set(results.map(\.capability)),
            results: results,
            startedAt: Date(),
            durationMilliseconds: 12,
            wasCancelled: false,
            wasExpired: false
        ).publicSnapshot
    }

    @Test("a complete pass is named complete and owes nothing")
    func completePassIsNamed() {
        let store = makeStore()
        store.noteHealthSyncPass(
            snapshot(
                trigger: .manual,
                results: HealthSyncCapability.allCases.map { .succeeded($0) }
            )
        )
        #expect(store.healthSyncLastPassWasComplete)
        #expect(store.healthSyncHeldItemCount == 0)
        #expect(store.healthSyncAdmissionRefusalCount == 0)
        #expect(store.lastHealthSyncPass?.trigger == "manual")
    }

    @Test("a durably queued retry is progress, never completion")
    func retryPersistedIsNotComplete() {
        let store = makeStore()
        store.noteHealthSyncPass(
            snapshot(
                trigger: .processing,
                results: [
                    .succeeded(.outboxDrain),
                    HealthSyncCapabilityResult(
                        capability: .heartHealthEvents,
                        disposition: .retryPersisted,
                        itemsHeld: 4,
                        holdReason: .nonterminalEntry
                    )
                ]
            )
        )
        #expect(!store.healthSyncLastPassWasComplete)
        #expect(store.healthSyncHeldItemCount == 4)
        #expect(store.lastHealthSyncPass?.capabilitiesOwingWork == ["heartHealthEvents"])
    }

    @Test("an admission refusal is counted separately and by name")
    func admissionRefusalsAreCounted() {
        let store = makeStore()
        store.noteHealthSyncPass(
            snapshot(
                trigger: .foreground,
                results: [
                    .refused(.cycleImport, .notAdmitted),
                    .refused(.moodStateOfMindImport, .notAdmitted),
                    .succeeded(.ecgUpload)
                ]
            )
        )
        #expect(store.healthSyncAdmissionRefusalCount == 2)
        #expect(
            store.lastHealthSyncPass?.capabilitiesRefusedForMissingAdmission
                == ["cycleImport", "moodStateOfMindImport"]
        )
        #expect(!store.healthSyncLastPassWasComplete)
    }

    @Test("an omitted capability keeps the pass from reading as complete")
    func omissionIsVisible() {
        let store = makeStore()
        store.noteHealthSyncPass(
            snapshot(
                trigger: .manual,
                results: [.succeeded(.outboxDrain)],
                planned: [.outboxDrain, .cycleImport]
            )
        )
        #expect(store.lastHealthSyncPass?.omittedCapabilities == ["cycleImport"])
        #expect(!store.healthSyncLastPassWasComplete)
    }

    @Test("a HealthKit pass never touches the server-handshake phase or the drain beat")
    func passDoesNotFakeTheHandshake() {
        let store = makeStore()
        store.noteOutboxPending(3)
        store.noteHealthSyncPass(
            snapshot(trigger: .silentPush, results: [.succeeded(.outboxDrain)])
        )
        #expect(store.phase == .idle)
        #expect(!store.showsDrainConfirmation)
        #expect(store.pendingOutboxCount == 3)
    }

    @Test("the scheduling claim promises no cadence and no device guarantee")
    func schedulingClaimIsHonest() {
        let claim = makeStore().healthSyncSchedulingClaim.lowercased()
        #expect(!HealthSyncSchedulingTruth.guaranteesFixedPeriod)
        for forbidden in ["every ", "minute", "hour", "alle ", "stünd", "guarant"] {
            #expect(!claim.contains(forbidden), "the scheduling claim promises \(forbidden)")
        }
    }

    @Test("logout drops the previous account's pass and its refusal counter")
    func logoutClearsHealthSyncTruth() {
        let store = makeStore()
        store.noteHealthSyncPass(
            snapshot(trigger: .manual, results: [.refused(.cycleImport, .notAdmitted)])
        )
        #expect(store.healthSyncAdmissionRefusalCount == 1)
        store.clearOnLogout()
        #expect(store.lastHealthSyncPass == nil)
        #expect(store.healthSyncAdmissionRefusalCount == 0)
    }
}

/// the in-flight count is observable deterministically.
private actor FetchGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for w in waiters {
            w.resume()
        }
        waiters.removeAll()
    }
}

// swiftlint:enable force_unwrapping
