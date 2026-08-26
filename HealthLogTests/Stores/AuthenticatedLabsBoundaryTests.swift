import Foundation
@testable import HealthLog
import Testing

@MainActor
@Suite("Authenticated labs boundary")
struct AuthenticatedLabsBoundaryTests {
    private final class SessionOwnerBox: @unchecked Sendable {
        private let lock = NSLock()
        private var ownerID: String

        init(_ ownerID: String) {
            self.ownerID = ownerID
        }

        func read() -> String {
            lock.withLock { ownerID }
        }

        func set(_ ownerID: String) {
            lock.withLock { self.ownerID = ownerID }
        }
    }

    private actor FanoutGate {
        private var entered = 0
        private var entryWaiters: [CheckedContinuation<Void, Never>] = []
        private var released = false
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func suspend() async {
            entered += 1
            let waiters = entryWaiters
            entryWaiters.removeAll()
            waiters.forEach { $0.resume() }
            guard !released else { return }
            await withCheckedContinuation { releaseWaiters.append($0) }
        }

        func waitForRequests(_ count: Int) async {
            while entered < count {
                await withCheckedContinuation { entryWaiters.append($0) }
            }
        }

        func release() {
            released = true
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    @Test("lateAccountAFanoutCannotPublishIntoB")
    func lateAccountAFanoutCannotPublishIntoB() async throws {
        let api = StubAPIClient()
        let gate = FanoutGate()
        await api.setHandler { request in
            await gate.suspend()
            if request is APIRequest<ListLabResultsResponse> {
                return ListLabResultsResponse(
                    results: [Self.lab(id: "account-a-lab")],
                    meta: LabResultsListMeta(total: 1, limit: 500, offset: 0)
                )
            }
            if request is APIRequest<ListBiomarkersResponse> {
                return ListBiomarkersResponse(biomarkers: [Self.biomarker(id: "account-a-marker")])
            }
            throw HLError.unknown("unexpected labs boundary request")
        }

        let repository = try LabsRepository(api: api, outbox: OutboxQueue(inMemory: true))
        let sessionRegistry = AuthenticatedSessionLeaseRegistry()
        let sessionOwner = SessionOwnerBox("account-a")
        sessionRegistry.activate(ownerID: sessionOwner.read())
        let store = LabsStore(repository: repository)
        store.bindAuthenticatedSessionRegistry(sessionRegistry, ownerIDProvider: sessionOwner.read)
        let accountALoad = Task { @MainActor in await store.load() }
        await gate.waitForRequests(2)

        sessionRegistry.invalidate()
        store.clearOnLogout()
        sessionOwner.set("account-b")
        sessionRegistry.activate(ownerID: sessionOwner.read())
        let accountBLab = Self.lab(id: "account-b-lab")
        let accountBMarker = Self.biomarker(id: "account-b-marker")
        store.seedForTesting(labs: [accountBLab], biomarkers: [accountBMarker])
        await gate.release()
        await accountALoad.value

        let accountBRemainsCurrent = store.labs == [accountBLab]
            && store.biomarkers == [accountBMarker]
            && store.total == 1
            && !store.isLoading
            && store.lastError == nil
        #expect(
            accountBRemainsCurrent,
            "EXPECTED_RED: late A lab fanout published into B"
        )
    }

    /// **20-02 / D-14-06-A — the labs half of the same instruction.**
    ///
    /// `lateAccountAFanoutCannotPublishIntoB` directly above proves the DATA
    /// fence: a superseded fan-out publishes no rows, no markers, no error. It
    /// cannot see the flag, because it settles the boundary with
    /// `clearOnLogout()` before the late load returns, and after that
    /// `isLoading == false` is true for either behaviour.
    ///
    /// The flag is the open half. 13-03 gave `LabsStore.load()` an
    /// **unconditional** defer, deliberately, because the exit it was closing
    /// was cancellation and because a stranded `isReloading` turns every later
    /// `load()` into a permanent no-op. That reasoning is still right — and it
    /// is also why this store's boundary exposure was recorded as a deferred
    /// item rather than "fixed" in passing: `isLoading` is an observable, so a
    /// superseded generation lowering it publishes over the skeleton the account
    /// that IS here is legitimately showing.
    ///
    /// So this test carries both halves. The retired generation must publish
    /// nothing, flag included; and the boundary step production always runs
    /// (`clearOnLogout()`) must still leave the store usable — no stranded
    /// `isReloading`, and a later `load()` that reaches the transport and lands.
    /// Without that second half the guard would trade one permanent skeleton for
    /// a permanently deaf store, which is the worse of the two.
    @Test("lateAccountATerminalStateCannotRepaintLabsB")
    @MainActor
    func lateAccountATerminalStateCannotRepaintLabsB() async throws {
        let api = StubAPIClient()
        let gateA = FanoutGate()
        let gateB = FanoutGate()
        let calls = CallCounter()
        await api.setHandler { request in
            // Two requests per load (labs + biomarkers); the first pair belongs
            // to account A, the second to account B.
            let ordinal = calls.next()
            if ordinal <= 2 {
                await gateA.suspend()
            } else {
                await gateB.suspend()
            }
            let suffix = ordinal <= 2 ? "account-a" : "account-b"
            if request is APIRequest<ListLabResultsResponse> {
                return ListLabResultsResponse(
                    results: [Self.lab(id: "\(suffix)-lab")],
                    meta: LabResultsListMeta(total: 1, limit: 500, offset: 0)
                )
            }
            if request is APIRequest<ListBiomarkersResponse> {
                return ListBiomarkersResponse(biomarkers: [Self.biomarker(id: "\(suffix)-marker")])
            }
            throw HLError.unknown("unexpected labs boundary request")
        }

        let repository = try LabsRepository(api: api, outbox: OutboxQueue(inMemory: true))
        let registry = AuthenticatedSessionLeaseRegistry()
        let owner = SessionOwnerBox("account-a")
        registry.activate(ownerID: owner.read())
        let store = LabsStore(repository: repository)
        store.bindAuthenticatedSessionRegistry(registry, ownerIDProvider: owner.read)

        let accountALoad = Task { @MainActor in await store.load() }
        await gateA.waitForRequests(2)

        registry.invalidate()
        store.clearOnLogout()
        owner.set("account-b")
        registry.activate(ownerID: owner.read())

        let accountBLoad = Task { @MainActor in await store.load() }
        await gateB.waitForRequests(2)
        #expect(store.isLoading, "precondition: account B's load is legitimately showing a skeleton")

        await gateA.release()
        await accountALoad.value

        #expect(
            store.isLoading,
            "EXPECTED_RED: a superseded labs load's unconditional defer cleared account B's skeleton"
        )
        #expect(store.labs.isEmpty, "and it published no rows either")

        await gateB.release()
        await accountBLoad.value
        #expect(store.labs.map(\.id) == ["account-b-lab"], "account B's own load still lands")
        #expect(store.isLoading == false, "and it settles its own flags")

        // The recovery half, proven by consequence rather than by reading the
        // private re-entry guard: a later load must still reach the transport.
        let before = calls.value
        await store.load()
        #expect(calls.value > before, "the re-entry guard is not stranded — a deaf store is not a fix")
    }

    private final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            count += 1
            return count
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    private nonisolated static func lab(id: String) -> LabResultDTO {
        LabResultDTO(
            id: id,
            biomarkerId: nil,
            panel: "Panel",
            analyte: "Analyte",
            value: 1,
            unit: "unit",
            referenceLow: nil,
            referenceHigh: nil,
            takenAt: "2026-08-14T08:00:00.000Z",
            source: "MANUAL",
            hasNote: false,
            rangeStatus: .inRange,
            createdAt: "2026-08-14T08:00:00.000Z",
            updatedAt: "2026-08-14T08:00:00.000Z"
        )
    }

    private nonisolated static func biomarker(id: String) -> BiomarkerDTO {
        BiomarkerDTO(
            id: id,
            name: id,
            unit: "unit",
            lowerBound: nil,
            upperBound: nil,
            panel: "Panel",
            hasContext: false,
            context: nil,
            createdAt: "2026-08-14T08:00:00.000Z",
            updatedAt: "2026-08-14T08:00:00.000Z"
        )
    }
}
