import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// T-3 store-level CRUD orchestration. The store delegates to
/// `MedicationsRepository` (T-0) but owns the optimistic in-memory list,
/// the archive-rollback semantics, and the active/archived split that
/// `MedicationsScreen` consumes.
@MainActor
@Suite("MedicationsStore — T-3 CRUD orchestration")
struct MedicationsStoreCRUDTests {
    // MARK: - create

    @Test("create() happy path prepends the server row into medications")
    func createSuccessPrepends() async throws {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)

        await api.setHandler { _ in medT3Wire(id: "srv-1", name: "Ozempic", dose: "1.0 mg") }
        let outcome = await store.create(.init(name: "Ozempic", dose: "1.0 mg"))

        #expect(outcome == .success)
        #expect(store.medications.count == 1)
        #expect(store.medications.first?.id == "srv-1")
        #expect(store.error == nil)
        let snap = await outbox.snapshot
        #expect(snap.isEmpty, "Success path must not enqueue an outbox row")
    }

    @Test("create() retriable failure surfaces .queued + leaves list untouched")
    func createRetriableQueues() async throws {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)

        await api.setHandler { _ in throw HLError.offline }
        let outcome = await store.create(.init(name: "Ozempic", dose: "1.0 mg"))

        #expect(outcome == .queued)
        #expect(store.medications.isEmpty, "List must stay empty — server has not echoed an id yet")
        #expect(store.error == .offline)
        let snap = await outbox.snapshot
        #expect(snap.count == 1, "Retriable failure must enqueue the create on the outbox")
        #expect(snap.first?.kind == .createMedication)
    }

    @Test("create() non-retriable 422 surfaces .failed + sets error")
    func createNonRetriableFails() async throws {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)

        await api.setHandler { _ in throw HLError.server(status: 422, code: "INVALID", message: "bad") }
        let outcome = await store.create(.init(name: "", dose: ""))

        if case let .failed(err) = outcome {
            if case let .server(status, _, _) = err {
                #expect(status == 422)
            } else {
                Issue.record("expected HLError.server, was \(err)")
            }
        } else {
            Issue.record("expected .failed, was \(outcome)")
        }
        #expect(store.medications.isEmpty)
    }

    // MARK: - update

    @Test("update() happy path replaces the matching row in-place")
    func updateSuccessReplaces() async throws {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)

        // Seed via direct mutation — emulates a post-load list.
        store._test_seed([medT3Domain(id: "srv-1", name: "Old", dose: "1 mg")])

        await api.setHandler { _ in medT3Wire(id: "srv-1", name: "New", dose: "2 mg") }
        let outcome = await store.update(id: "srv-1", patch: .init(name: "New", dose: "2 mg"))

        #expect(outcome == .success)
        #expect(store.medications.count == 1)
        #expect(store.medications.first?.name == "New")
        #expect(store.medications.first?.dose == "2 mg")
    }

    @Test("update() retriable failure surfaces .queued + outbox holds the patch")
    func updateRetriableQueues() async throws {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)

        store._test_seed([medT3Domain(id: "srv-1", name: "Old", dose: "1 mg")])
        await api.setHandler { _ in throw HLError.network(.timeout) }

        let outcome = await store.update(id: "srv-1", patch: .init(name: "New"))
        #expect(outcome == .queued)
        let snap = await outbox.snapshot
        #expect(snap.count == 1)
        #expect(snap.first?.kind == .updateMedication)
    }

    // MARK: - archive

    @Test("archive() happy path flips active=false + stamps archivedAt locally")
    func archiveSuccess() async throws {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)

        store._test_seed([medT3Domain(id: "srv-1", name: "Ozempic", dose: "1 mg")])
        // DELETE returns 204 — handler echoes a sentinel; APIClient<EmptyResponse> accepts any payload.
        await api.setHandler { _ in EmptyResponse() }

        let frozen = Date(timeIntervalSince1970: 1_714_550_400)
        let outcome = await store.archive(id: "srv-1", now: frozen)

        #expect(outcome == .success)
        #expect(store.medications.count == 1, "Archive keeps the row — it just flips active")
        let row = store.medications.first
        #expect(row?.active == false)
        #expect(row?.archivedAt == frozen)
        #expect(store.activeMedications.isEmpty)
        #expect(store.archivedMedications.count == 1)
    }

    @Test("archive() retriable failure keeps optimistic patch + enqueues delete")
    func archiveRetriableKeepsOptimistic() async throws {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)

        store._test_seed([medT3Domain(id: "srv-1", name: "Ozempic", dose: "1 mg")])
        await api.setHandler { _ in throw HLError.offline }

        let outcome = await store.archive(id: "srv-1")

        #expect(outcome == .queued)
        // The optimistic patch stays — user-perceived archive succeeded.
        #expect(store.medications.first?.active == false)
        #expect(store.medications.first?.archivedAt != nil)
        let snap = await outbox.snapshot
        #expect(snap.count == 1)
        #expect(snap.first?.kind == .deleteMedication)
    }

    @Test("archive() non-retriable rolls back the optimistic patch")
    func archiveNonRetriableRollsBack() async throws {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)

        let original = medT3Domain(id: "srv-1", name: "Ozempic", dose: "1 mg")
        store._test_seed([original])
        await api.setHandler { _ in throw HLError.server(status: 403, code: "FORBIDDEN", message: "no") }

        let outcome = await store.archive(id: "srv-1")

        if case .failed = outcome { /* ok */ } else { Issue.record("expected .failed") }
        // Rolled back: row is back to active.
        #expect(store.medications.first?.active == true)
        #expect(store.medications.first?.archivedAt == nil)
    }

    @Test("archive() unknown id returns .failed without mutating list")
    func archiveUnknownId() async throws {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)

        let outcome = await store.archive(id: "missing")
        if case .failed = outcome { /* ok */ } else { Issue.record("expected .failed for unknown id") }
        #expect(store.medications.isEmpty)
    }

    // MARK: - unarchive

    @Test("unarchive() routes via update(active:true) and flips the row back")
    func unarchiveRestoresActive() async throws {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)

        // Seed an archived row.
        store._test_seed([medT3Domain(id: "srv-1", name: "Ozempic", dose: "1 mg", active: false, archivedAt: .now)])
        await api.setHandler { _ in medT3Wire(id: "srv-1", name: "Ozempic", dose: "1 mg", active: true) }

        let outcome = await store.unarchive(id: "srv-1")

        #expect(outcome == .success)
        #expect(store.medications.first?.active == true)
        #expect(store.activeMedications.count == 1)
        #expect(store.archivedMedications.isEmpty)
    }

    // MARK: - derived collections

    @Test("Re-load preserves archivedAt locally when server omits it")
    func loadPreservesLocalArchivedAt() async throws {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)

        // Step 1: archive a row → local archivedAt stamped.
        store._test_seed([medT3Domain(id: "srv-1", name: "Ozempic", dose: "1 mg")])
        await api.setHandler { _ in EmptyResponse() }
        let frozen = Date(timeIntervalSince1970: 1_714_550_400)
        _ = await store.archive(id: "srv-1", now: frozen)
        #expect(store.medications.first?.archivedAt == frozen)

        // Step 2: a follow-up load() pulls a fresh server list that has
        // active=false (server-side state) but NO archivedAt (server
        // schema doesn't carry the column). The store must NOT lose the
        // local timestamp.
        await api.setHandler { request in
            switch request {
            case is APIRequest<[MedicationWireDTO]>:
                return [MedicationWireDTO(id: "srv-1", name: "Ozempic", dose: "1 mg", active: false)]
            case is APIRequest<[MedicationIntake]>:
                return [MedicationIntake]()
            case is APIRequest<[ComplianceDay]>:
                return [ComplianceDay]()
            default:
                throw HLError.unknown("unexpected request")
            }
        }
        await store.load()
        #expect(store.medications.first?.active == false)
        #expect(store.medications.first?.archivedAt == frozen, "Local archivedAt must survive a server-list refresh")
    }

    @Test("Re-load drops archivedAt when the server has reactivated the row")
    func loadDropsArchivedAtOnReactivation() async throws {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)

        store._test_seed([medT3Domain(id: "srv-1", name: "Ozempic", dose: "1 mg", active: false, archivedAt: .now)])
        // Server returns active=true → user must have un-archived elsewhere
        // (web client). The local stale timestamp gets dropped.
        await api.setHandler { request in
            switch request {
            case is APIRequest<[MedicationWireDTO]>:
                return [MedicationWireDTO(id: "srv-1", name: "Ozempic", dose: "1 mg", active: true)]
            case is APIRequest<[MedicationIntake]>:
                return [MedicationIntake]()
            case is APIRequest<[ComplianceDay]>:
                return [ComplianceDay]()
            default:
                throw HLError.unknown("unexpected request")
            }
        }
        await store.load()
        #expect(store.medications.first?.active == true)
        #expect(store.medications.first?.archivedAt == nil)
    }

    @Test("activeMedications + archivedMedications partition correctly")
    func partitionedAccessors() throws {
        let api = StubAPIClient()
        let outbox = try? OutboxQueue(inMemory: true)
        let repo = try MedicationsRepository(api: api, outbox: #require(outbox))
        let store = MedicationsStore(repo: repo)

        let now = Date(timeIntervalSince1970: 1_714_550_400)
        let earlier = now.addingTimeInterval(-3600)
        store._test_seed([
            medT3Domain(id: "a-1", name: "Active1", dose: "1 mg"),
            medT3Domain(id: "ar-1", name: "Old1", dose: "1 mg", active: false, archivedAt: earlier),
            medT3Domain(id: "a-2", name: "Active2", dose: "1 mg"),
            medT3Domain(id: "ar-2", name: "Old2", dose: "1 mg", active: false, archivedAt: now)
        ])

        #expect(store.activeMedications.map(\.id) == ["a-1", "a-2"])
        // Archived sort by archivedAt desc — newest first.
        #expect(store.archivedMedications.map(\.id) == ["ar-2", "ar-1"])
    }

    // MARK: - Helpers — referenced via free functions so the

    // @Sendable handler closure (running on StubAPIClient actor) can
    // call them without crossing the @MainActor boundary of the suite.
}

func medT3Wire(id: String, name: String, dose: String, active: Bool = true) -> MedicationWireDTO {
    MedicationWireDTO(id: id, name: name, dose: dose, active: active)
}

func medT3Domain(
    id: String,
    name: String,
    dose: String,
    active: Bool = true,
    archivedAt: Date? = nil
) -> Medication {
    Medication(
        id: id,
        name: name,
        dose: dose,
        schedule: MedicationSchedule(times: [], weekdays: nil),
        active: active,
        archivedAt: archivedAt
    )
}

/// Test-only seam: forces the in-memory medications array without
/// going through `load()` (which would hit the network). Mirrors the
/// `_testInject` pattern used by `MedicationDetailStore`. Calls into
/// the DEBUG-only `_testForceSet` declared in MedicationsStore.
private extension MedicationsStore {
    // swiftlint:disable:next identifier_name
    func _test_seed(_ medications: [Medication]) {
        _testForceSet(medications: medications)
    }
}

// swiftlint:enable force_unwrapping
