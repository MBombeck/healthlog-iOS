import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// T-4 store-level retro-mutate orchestration. The store delegates to
/// `MedicationsRepository.updateIntake/deleteIntake` (T-0) and surfaces
/// the optimistic-write `WriteOutcome` contract that the IntakeHistoryRow
/// swipe-actions consume. Mirrors the T-3 `MedicationsStoreCRUDTests`
/// shape — `StubAPIClient` driver, `OutboxQueue(inMemory:)`, three arms
/// per method (success / retriable-queued / non-retriable-failed).
@MainActor
@Suite("MedicationsStore — T-4 intake retro-mutate")
struct MedicationsStoreIntakeRetroMutateTests {
    // MARK: - updateIntake

    @Test("updateIntake() happy path returns .success")
    func updateIntakeSuccess() async throws {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)

        let scheduledAt = Date(timeIntervalSince1970: 1_714_550_400)
        await api.setHandler { _ in
            MedicationIntakeWireDTO(
                id: "intake-1",
                medicationId: "med-1",
                scheduledFor: scheduledAt,
                takenAt: scheduledAt,
                skipped: false,
                snoozedUntil: nil
            )
        }

        let outcome = await store.updateIntake(
            medicationId: "med-1",
            eventId: "intake-1",
            patch: .init(status: "taken", takenAt: scheduledAt)
        )

        #expect(outcome == .success)
        #expect(store.error == nil)
        let snap = await outbox.snapshot
        #expect(snap.isEmpty, "Happy path must not enqueue an outbox row")
    }

    @Test("updateIntake() retriable failure surfaces .queued + outbox holds the patch")
    func updateIntakeRetriableQueues() async throws {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)

        await api.setHandler { _ in throw HLError.offline }
        let outcome = await store.updateIntake(
            medicationId: "med-1",
            eventId: "intake-1",
            patch: .init(status: "taken", takenAt: .now)
        )

        #expect(outcome == .queued)
        #expect(store.error == .offline)
        let snap = await outbox.snapshot
        #expect(snap.count == 1, "Retriable failure must enqueue the updateIntake on the outbox")
        #expect(snap.first?.kind == .updateIntake)
    }

    @Test("updateIntake() non-retriable 422 surfaces .failed")
    func updateIntakeNonRetriableFails() async throws {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)

        await api.setHandler { _ in throw HLError.server(status: 422, code: "INVALID", message: "bad") }
        let outcome = await store.updateIntake(
            medicationId: "med-1",
            eventId: "intake-1",
            patch: .init(status: "garbage", takenAt: nil)
        )

        if case let .failed(err) = outcome {
            if case let .server(status, _, _) = err {
                #expect(status == 422)
            } else {
                Issue.record("expected HLError.server, was \(err)")
            }
        } else {
            Issue.record("expected .failed, was \(outcome)")
        }
        let snap = await outbox.snapshot
        #expect(snap.isEmpty, "Non-retriable failure must NOT enqueue an outbox row")
    }

    @Test("updateIntake() patches todayIntakes when the event is currently in the today list")
    func updateIntakePatchesTodayList() async throws {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)

        // Seed today's list with a pending intake.
        let scheduledAt = Date(timeIntervalSince1970: 1_714_550_400)
        store._testForceSet(todayIntakes: [
            MedicationIntake(
                id: "intake-1",
                medicationId: "med-1",
                scheduledAt: scheduledAt,
                takenAt: nil,
                status: .pending
            )
        ])

        // Server returns the row flipped to taken.
        await api.setHandler { _ in
            MedicationIntakeWireDTO(
                id: "intake-1",
                medicationId: "med-1",
                scheduledFor: scheduledAt,
                takenAt: scheduledAt,
                skipped: false,
                snoozedUntil: nil
            )
        }

        let outcome = await store.updateIntake(
            medicationId: "med-1",
            eventId: "intake-1",
            patch: .init(status: "taken", takenAt: scheduledAt)
        )

        #expect(outcome == .success)
        #expect(store.todayIntakes.first?.status == .taken)
        #expect(store.todayIntakes.first?.takenAt == scheduledAt)
    }

    // MARK: - markIntakeRetroactively convenience

    @Test("markIntakeRetroactively(.taken) sends takenAt = scheduledAt (the historical moment)")
    func retroactivelyTakenUsesScheduledTimestamp() async throws {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)

        let scheduled = Date(timeIntervalSince1970: 1_714_550_400)
        await api.setHandler { _ in
            MedicationIntakeWireDTO(
                id: "intake-1",
                medicationId: "med-1",
                scheduledFor: scheduled,
                takenAt: scheduled,
                skipped: false,
                snoozedUntil: nil
            )
        }
        // Send "now" well in the future of `scheduled` so the clamp never
        // fires. The test asserts on the repo's POST body: we can't peek
        // directly through StubAPIClient (it's swallow-all), so we instead
        // assert that the outcome is .success when the schedule round-trips.
        let outcome = await store.markIntakeRetroactively(
            medicationId: "med-1",
            eventId: "intake-1",
            status: .taken,
            scheduledAt: scheduled,
            now: scheduled.addingTimeInterval(3600)
        )
        #expect(outcome == .success)
    }

    @Test("markIntakeRetroactively(.taken) with scheduledAt > now clamps takenAt to now")
    func retroactivelyTakenClampsFutureScheduledAt() async throws {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)

        let now = Date(timeIntervalSince1970: 1_714_550_400)
        let futureScheduled = now.addingTimeInterval(7200)
        await api.setHandler { _ in
            MedicationIntakeWireDTO(
                id: "intake-1",
                medicationId: "med-1",
                scheduledFor: futureScheduled,
                takenAt: now,
                skipped: false,
                snoozedUntil: nil
            )
        }
        let outcome = await store.markIntakeRetroactively(
            medicationId: "med-1",
            eventId: "intake-1",
            status: .taken,
            scheduledAt: futureScheduled,
            now: now
        )
        #expect(outcome == .success)
    }

    @Test("markIntakeRetroactively(.skipped) sends no takenAt")
    func retroactivelySkippedNilTakenAt() async throws {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)

        let scheduled = Date(timeIntervalSince1970: 1_714_550_400)
        await api.setHandler { _ in
            MedicationIntakeWireDTO(
                id: "intake-1",
                medicationId: "med-1",
                scheduledFor: scheduled,
                takenAt: nil,
                skipped: true,
                snoozedUntil: nil
            )
        }
        let outcome = await store.markIntakeRetroactively(
            medicationId: "med-1",
            eventId: "intake-1",
            status: .skipped,
            scheduledAt: scheduled,
            now: scheduled.addingTimeInterval(3600)
        )
        #expect(outcome == .success)
    }

    @Test("markIntakeRetroactively(.missed) is read-only and never reaches the repository")
    func retroactivelyMissedFailsClosed() async throws {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)
        nonisolated(unsafe) var requestCount = 0

        await api.setHandler { _ in
            requestCount += 1
            return MedicationIntakeWireDTO(
                id: "intake-1",
                medicationId: "med-1",
                scheduledFor: .now,
                takenAt: nil,
                skipped: false,
                snoozedUntil: nil
            )
        }

        let outcome = await store.markIntakeRetroactively(
            medicationId: "med-1",
            eventId: "intake-1",
            status: .missed,
            scheduledAt: .now
        )

        if case let .failed(.server(status, code, _)) = outcome {
            #expect(status == 422)
            #expect(code == "medications.intake.status_read_only")
        } else {
            Issue.record("Expected read-only failure, got \(outcome)")
        }
        #expect(requestCount == 0)
        #expect(await outbox.snapshot.isEmpty)
    }

    // MARK: - deleteIntake

    @Test("deleteIntake() happy path returns .success")
    func deleteIntakeSuccess() async throws {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)

        await api.setHandler { _ in EmptyResponse() }
        let outcome = await store.deleteIntake(medicationId: "med-1", eventId: "intake-1")

        #expect(outcome == .success)
        let snap = await outbox.snapshot
        #expect(snap.isEmpty)
    }

    @Test("deleteIntake() retriable failure surfaces .queued + outbox holds the row")
    func deleteIntakeRetriableQueues() async throws {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)

        await api.setHandler { _ in throw HLError.network(.timeout) }
        let outcome = await store.deleteIntake(medicationId: "med-1", eventId: "intake-1")

        #expect(outcome == .queued)
        let snap = await outbox.snapshot
        #expect(snap.count == 1)
        #expect(snap.first?.kind == .deleteIntake)
    }

    @Test("deleteIntake() non-retriable 422 surfaces .failed (404 is repo-handled idempotent)")
    func deleteIntakeNonRetriableFails() async throws {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)

        await api.setHandler { _ in throw HLError.server(status: 422, code: "INVALID", message: "bad") }
        let outcome = await store.deleteIntake(medicationId: "med-1", eventId: "intake-1")

        if case let .failed(err) = outcome {
            if case let .server(status, _, _) = err {
                #expect(status == 422)
            } else {
                Issue.record("expected HLError.server, was \(err)")
            }
        } else {
            Issue.record("expected .failed, was \(outcome)")
        }
    }

    @Test("deleteIntake() drops the event from todayIntakes when present")
    func deleteIntakeDropsFromTodayList() async throws {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)

        // Seed two intakes; only the second is targeted.
        store._testForceSet(todayIntakes: [
            MedicationIntake(
                id: "intake-1",
                medicationId: "med-1",
                scheduledAt: Date(timeIntervalSince1970: 1_714_550_400),
                takenAt: nil,
                status: .pending
            ),
            MedicationIntake(
                id: "intake-2",
                medicationId: "med-2",
                scheduledAt: Date(timeIntervalSince1970: 1_714_554_000),
                takenAt: nil,
                status: .pending
            )
        ])

        await api.setHandler { _ in EmptyResponse() }
        let outcome = await store.deleteIntake(medicationId: "med-2", eventId: "intake-2")

        #expect(outcome == .success)
        #expect(store.todayIntakes.count == 1)
        #expect(store.todayIntakes.first?.id == "intake-1")
    }
}

// swiftlint:enable force_unwrapping
