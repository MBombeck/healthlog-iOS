import Foundation
@testable import HealthLog
import Testing

/// **v0.6.1.4 Y4.2 — server-canonical compliance fetch tests.**
///
/// Verifies that `MedicationsStore.refreshCardComplianceSnapshot(for:)`
/// hits `/api/medications/[id]/compliance`, decodes the server's
/// `compliance7` + `compliance30` rate ints, patches them into
/// `complianceCardSnapshots`, and that `cardComplianceSnapshot(for:windowIntakes:)`
/// prefers the cached value over the local-algorithm fallback. Also
/// verifies the failure path: a thrown HLError leaves the dict
/// untouched so the previous-good value (or the local fallback) keeps
/// rendering.
@Suite("MedicationsStore — server-canonical card compliance")
@MainActor
struct MedicationsStoreServerComplianceTests {
    @Test("refreshCardComplianceSnapshot caches the server rates")
    func refreshCachesServerRates() async throws {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)

        await api.setHandler { request in
            guard let req = request as? any APIRequestType else {
                throw HLError.unknown("unexpected request type")
            }
            #expect(req.urlPath.contains("/api/medications/srv-1/compliance"))
            return Self.payload(rate7: 86, rate30: 92)
        }

        await store.refreshCardComplianceSnapshot(for: "srv-1")

        let snapshot = store.complianceCardSnapshots["srv-1"]
        #expect(snapshot?.rate7 == 86)
        #expect(snapshot?.rate30 == 92)
    }

    @Test("refreshCardComplianceSnapshot leaves dict untouched on failure")
    func refreshSwallowsServerError() async throws {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)

        // Pre-seed a value so we can assert it survives the failed fetch.
        store._testForceSet(cardSnapshot: .init(rate7: 50, rate30: 50), for: "srv-1")

        await api.setHandler { _ in
            throw HLError.server(status: 500, code: "INTERNAL", message: "boom")
        }

        await store.refreshCardComplianceSnapshot(for: "srv-1")

        let snapshot = store.complianceCardSnapshots["srv-1"]
        #expect(snapshot?.rate7 == 50, "previous-good value must survive failed refresh")
        #expect(snapshot?.rate30 == 50)
        // The error path must NOT bubble into `store.error` — the card
        // surface keeps its previous-good rate and silently retries on
        // the next foreground tick / mark.
        #expect(store.error == nil, "compliance fetch failure must not surface as a store error banner")
    }

    @Test("cardComplianceSnapshot prefers server cache over local fallback")
    func cardSnapshotPrefersServerCache() throws {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let med = Self.makeWeeklyMedication(id: "trulicity")

        // No today-intakes seeded — local-algorithm fallback would
        // divide 0 taken / 7 effective days → 0%. The server cache
        // carries 100%; the accessor must return the server value.
        store._testForceSet(cardSnapshot: .init(rate7: 100, rate30: 100), for: med.id)

        let snapshot = store.cardComplianceSnapshot(
            for: med,
            windowIntakes: []
        )

        _ = now
        #expect(snapshot?.rate7 == 100)
        #expect(snapshot?.rate30 == 100)
    }

    // MARK: - W-COMPLIANCE-INV — pending → nil (skeleton), failed → fallback

    @Test("W-COMPLIANCE-INV: cardComplianceSnapshot is nil while the server fetch is pending")
    func cardSnapshotPendingReturnsNil() throws {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)

        let med = Self.makeDailyMedication(id: "lisinopril")
        // No cache, no recorded fetch failure → the accessor must NOT run
        // the local algorithm (that interim value would jump on server
        // arrival — the operator's 100→60→50 flicker). The card paints a
        // skeleton from `nil`.
        let snapshot = store.cardComplianceSnapshot(
            for: med,
            windowIntakes: []
        )
        #expect(snapshot == nil, "pending fetch must paint a skeleton, never the local interim value")
    }

    @Test("W-COMPLIANCE-INV: failed fetch unlocks the clearly-marked local offline fallback")
    func cardSnapshotFailedFetchFallsBackToLocal() async throws {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)

        let med = Self.makeDailyMedication(id: "lisinopril")
        await api.setHandler { _ in
            throw HLError.server(status: 500, code: "INTERNAL", message: "boom")
        }
        await store.refreshCardComplianceSnapshot(for: med.id)

        // Fetch settled with a failure + no cached value → the local
        // algorithm runs as the offline fallback (rates non-nil for a
        // scheduled med).
        let snapshot = store.cardComplianceSnapshot(
            for: med,
            windowIntakes: []
        )
        #expect(snapshot != nil)
        #expect(snapshot?.rate7 != nil)
        #expect(snapshot?.rate30 != nil)
    }

    @Test("W-COMPLIANCE-INV: a later successful fetch clears the failure marker")
    func successClearsFailureMarker() async throws {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)

        await api.setHandler { _ in
            throw HLError.server(status: 500, code: "INTERNAL", message: "boom")
        }
        await store.refreshCardComplianceSnapshot(for: "srv-1")
        #expect(store.failedComplianceFetchIDs.contains("srv-1"))

        await api.setHandler { _ in Self.payload(rate7: 86, rate30: 92) }
        await store.refreshCardComplianceSnapshot(for: "srv-1")
        #expect(!store.failedComplianceFetchIDs.contains("srv-1"))
        #expect(store.complianceCardSnapshots["srv-1"]?.rate30 == 92)
    }

    @Test("PRN medication (no schedule) keeps nil rates via the offline fallback")
    func cardSnapshotPrnFallback() async throws {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)

        let med = Self.makePrnMedication(id: "naproxen-prn")
        // Unlock the fallback by settling the fetch with a failure.
        await api.setHandler { _ in
            throw HLError.server(status: 500, code: "INTERNAL", message: "boom")
        }
        await store.refreshCardComplianceSnapshot(for: med.id)

        let snapshot = store.cardComplianceSnapshot(
            for: med,
            windowIntakes: []
        )
        #expect(snapshot != nil)
        #expect(snapshot?.rate7 == nil)
        #expect(snapshot?.rate30 == nil)
    }

    @Test("clearOnLogout empties the snapshot dict")
    func logoutClearsSnapshots() throws {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)

        store._testForceSet(cardSnapshot: .init(rate7: 80, rate30: 75), for: "srv-1")
        store._testForceSet(cardSnapshot: .init(rate7: 40, rate30: 60), for: "srv-2")
        #expect(store.complianceCardSnapshots.count == 2)

        store.clearOnLogout()
        #expect(store.complianceCardSnapshots.isEmpty)
    }

    // MARK: - Fixtures

    private nonisolated static func payload(rate7: Int, rate30: Int) -> MedicationCompliancePayload {
        MedicationCompliancePayload(
            compliance7: ComplianceWindowResult(
                totalExpected: 7,
                taken: max(0, rate7 / 14),
                skipped: 0,
                missed: 0,
                rate: rate7,
                streak: 0
            ),
            compliance30: ComplianceWindowResult(
                totalExpected: 30,
                taken: max(0, rate30 / 3),
                skipped: 0,
                missed: 0,
                rate: rate30,
                streak: 0
            ),
            dailyCompliance: [:]
        )
    }

    private nonisolated static func makeDailyMedication(id: String) -> Medication {
        Medication(
            id: id,
            name: "Lisinopril",
            dose: "5 mg",
            schedule: MedicationSchedule(
                times: [TimeOfDay(hour: 8, minute: 0)],
                weekdays: nil,
                intervalWeeks: 1
            )
        )
    }

    private nonisolated static func makeWeeklyMedication(id: String) -> Medication {
        Medication(
            id: id,
            name: "Trulicity",
            dose: "5 mg",
            schedule: MedicationSchedule(
                times: [TimeOfDay(hour: 8, minute: 0)],
                weekdays: [.wed],
                intervalWeeks: 1
            )
        )
    }

    private nonisolated static func makePrnMedication(id: String) -> Medication {
        Medication(
            id: id,
            name: "Naproxen",
            dose: "400 mg",
            schedule: MedicationSchedule(
                times: [],
                weekdays: nil,
                intervalWeeks: 1
            )
        )
    }
}

// Test seam `_testForceSet(cardSnapshot:for:)` lives on
// `MedicationsStore` itself behind `#if DEBUG`. The bottom-of-file
// extension that older Y4 tests carried (writing to a private(set)
// dict via internal-access escape) doesn't work for Y4.2 because
// the dict is intentionally `private(set)` — the store owns every
// write path.
