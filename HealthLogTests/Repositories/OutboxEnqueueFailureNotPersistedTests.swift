import Foundation
@testable import HealthLog
import Testing

/// Audit B-1 (2026-09-10) — six repositories used to swallow a failed outbox
/// enqueue: the private `enqueue(...)` logged the failure and returned, the
/// caller re-threw the ORIGINAL retriable network error, and every store read
/// that as "offline, will be replayed". The user saw the entry; nothing was
/// queued and nothing was on the server.
///
/// Since build 274 the trigger is real, not theoretical:
/// `OutboxQueue.WriteRefusal.noBackgroundExecutionTime` — iOS grants no
/// background execution time, the outbox refuses the write rather than gamble
/// with the SQLite lock, and `enqueue` throws.
///
/// Each test below drives one repository over an API that fails retriably AND
/// an outbox whose lease refuses, and pins the honest outcome the measurements
/// path has had since G-2 (`MeasurementsRepository+Writes.swift`):
/// `HLError.notPersisted` reaches the caller and the outbox holds no row.
@Suite("Audit B-1 — a refused outbox enqueue surfaces as notPersisted")
struct OutboxEnqueueFailureNotPersistedTests {
    // MARK: - Fixtures

    /// A lease that never grants background execution time — the shape build
    /// 274 introduced (`OutboxQueueBackgroundLeaseTests.RecordingLease(grants:
    /// false)`), reduced to what these tests need.
    private struct RefusingLease: BackgroundExecutionLeasing {
        func withLease<T: Sendable>(
            named _: String,
            _: @escaping @Sendable () async throws -> T
        ) async throws -> T? {
            nil
        }
    }

    /// Every request fails with a retriable transport error, so each repository
    /// takes its `shouldPersistToOutbox` arm and tries to enqueue.
    private struct FailingAPI: APIClientProtocol {
        func send<T: Decodable & Sendable>(_: APIRequest<T>) async throws -> T {
            throw HLError.network(.connectionLost)
        }

        func sendVoid(_: APIRequest<EmptyPayload>) async throws {
            throw HLError.network(.connectionLost)
        }

        func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
            throw HLError.network(.connectionLost)
        }
    }

    private func refusingOutbox() throws -> OutboxQueue {
        try OutboxQueue(inMemory: true, backgroundLease: RefusingLease())
    }

    /// Asserts the write reached the caller as `HLError.notPersisted` — NOT as
    /// the original retriable error, which the stores read as "queued".
    private func expectNotPersisted(
        _ label: String,
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            Issue.record("\(label): expected HLError.notPersisted, but the call returned")
        } catch let error as HLError {
            guard case .notPersisted = error else {
                Issue.record("\(label): expected HLError.notPersisted, got \(error)")
                return
            }
        } catch {
            Issue.record("\(label): expected HLError.notPersisted, got \(error)")
        }
    }

    // MARK: - The six repositories

    @Test("AllergiesRepository.create reports notPersisted when the enqueue is refused")
    func allergiesCreate() async throws {
        let outbox = try refusingOutbox()
        let repo = AllergiesRepository(api: FailingAPI(), outbox: outbox)
        await expectNotPersisted("allergies.create") {
            _ = try await repo.create(AllergyCreate(substance: "Pollen"))
        }
        #expect(await outbox.snapshot.isEmpty)
    }

    @Test("IllnessRepository.createEpisode reports notPersisted when the enqueue is refused")
    func illnessCreateEpisode() async throws {
        let outbox = try refusingOutbox()
        let repo = IllnessRepository(api: FailingAPI(), outbox: outbox)
        await expectNotPersisted("illness.createEpisode") {
            _ = try await repo.createEpisode(IllnessEpisodeCreate(label: "Flu", type: .infection))
        }
        #expect(await outbox.snapshot.isEmpty)
    }

    @Test("LabsRepository.createLab reports notPersisted when the enqueue is refused")
    func labsCreateLab() async throws {
        let outbox = try refusingOutbox()
        let repo = LabsRepository(api: FailingAPI(), outbox: outbox)
        await expectNotPersisted("labs.createLab") {
            _ = try await repo.createLab(LabResultCreate(value: 5.4, takenAt: "2026-01-01T08:30:00Z"))
        }
        #expect(await outbox.snapshot.isEmpty)
    }

    @Test("NutrientReadRepository.quickAddWater reports notPersisted when the enqueue is refused")
    func nutrientQuickAddWater() async throws {
        let outbox = try refusingOutbox()
        let repo = NutrientReadRepository(api: FailingAPI(), outbox: outbox)
        await expectNotPersisted("nutrients.quickAddWater") {
            _ = try await repo.quickAddWater(amountMl: 250, mode: .add)
        }
        #expect(await outbox.snapshot.isEmpty)
    }

    @Test("CustomMetricsRepository.createMetric reports notPersisted when the enqueue is refused")
    func customMetricsCreateMetric() async throws {
        let outbox = try refusingOutbox()
        let repo = CustomMetricsRepository(api: FailingAPI(), outbox: outbox)
        await expectNotPersisted("customMetrics.createMetric") {
            _ = try await repo.createMetric(CustomMetricCreate(name: "Grip strength", unit: "kg"))
        }
        #expect(await outbox.snapshot.isEmpty)
    }

    @Test("MedicationTherapyLogRepository.createSideEffect reports notPersisted when the enqueue is refused")
    func therapyLogCreateSideEffect() async throws {
        let outbox = try refusingOutbox()
        let repo = MedicationTherapyLogRepository(api: FailingAPI(), outbox: outbox)
        await expectNotPersisted("therapyLog.createSideEffect") {
            _ = try await repo.createSideEffect(
                medicationID: "med-1",
                body: MedicationSideEffectCreate(entry: "NAUSEA", severity: 2, occurredAt: nil, notes: nil)
            )
        }
        #expect(await outbox.snapshot.isEmpty)
    }

    // MARK: - Store-level outcome

    /// The store half of B-1: `AllergiesStore.create` treats a
    /// `shouldPersistToOutbox` error as SUCCESS and inserts an optimistic row.
    /// `.notPersisted` is deliberately NOT `shouldPersistToOutbox`, so the same
    /// store must fall through to its honest failure arm — no optimistic row,
    /// an error the editor sheet surfaces, and `nil` back to the caller.
    @Test("AllergiesStore.create keeps no optimistic row when the write was not persisted")
    @MainActor
    func allergiesStoreRollsBackOnNotPersisted() async throws {
        let outbox = try refusingOutbox()
        let store = AllergiesStore(repository: AllergiesRepository(api: FailingAPI(), outbox: outbox))
        let created = await store.create(AllergyCreate(substance: "Pollen"))
        #expect(created == nil)
        #expect(store.records.isEmpty)
        #expect(store.lastError != nil)
        #expect(await outbox.snapshot.isEmpty)
    }
}
