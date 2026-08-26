import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// Stateless JSON builders used by the stub handler. A plain `enum` so the
/// `@Sendable` `MockURLProtocol.handler` closure can call them from outside the
/// `@MainActor` test type.
private enum LabsTestJSON {
    static func row(id: String, panel: String?, analyte: String, status: String = "in-range") -> String {
        let panelJSON = panel.map { "\"\($0)\"" } ?? "null"
        return """
        {"id":"\(id)","biomarkerId":null,"panel":\(panelJSON),"analyte":"\(analyte)",
         "value":1,"unit":"x","referenceLow":null,"referenceHigh":null,
         "takenAt":"2026-06-10T08:00:00.000Z","source":"MANUAL","hasNote":false,
         "rangeStatus":"\(status)","createdAt":"2026-06-10T08:00:00.000Z",
         "updatedAt":"2026-06-10T08:00:00.000Z"}
        """
    }

    static func labsList(_ rows: [String]) -> Data {
        Data("""
        {"data":{"results":[\(rows.joined(separator: ","))],
          "meta":{"total":\(rows.count),"limit":100,"offset":0}},"error":null}
        """.utf8)
    }

    static func biomarker(id: String, name: String) -> String {
        """
        {"id":"\(id)","name":"\(name)","unit":"x","lowerBound":null,
         "upperBound":null,"panel":null,"hasContext":false,"context":null,
         "createdAt":"2026-06-10T08:00:00.000Z","updatedAt":"2026-06-10T08:00:00.000Z"}
        """
    }

    static func biomarkers(_ rows: [String]) -> Data {
        Data("""
        {"data":{"biomarkers":[\(rows.joined(separator: ","))]},"error":null}
        """.utf8)
    }

    static let emptyBiomarkers = Data(#"{"data":{"biomarkers":[]},"error":null}"#.utf8)
    static let deleted = Data(#"{"data":{"deleted":true},"error":null}"#.utf8)
    static let restored = Data(#"{"data":{"restored":1},"error":null}"#.utf8)
}

/// Locks the ``LabsStore`` behaviour: panel grouping, optimistic delete +
/// undo-restore round-trip, and the `403 module.disabled` → `isDisabled` branch.
/// Real `APIClient` + stub `URLProtocol` (no mock server).
@MainActor
@Suite("LabsStore (v1.18.1 W-LABS)", .serialized)
struct LabsStoreTests {
    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.14.9",
            buildNumber: "1"
        )
        let kc = InMemoryKeychain()
        try? kc.setString("token", forKey: KeychainKey.authToken)
        return APIClient(environment: env, keychain: kc, sessionConfiguration: .mock())
    }

    private func makeStore(undo: UndoCoordinator? = nil) throws -> LabsStore {
        let repo = try LabsRepository(api: makeAPI(), outbox: OutboxQueue(inMemory: true))
        return LabsStore(repository: repo, undo: undo)
    }

    @Test("load groups labs by panel, named panels first + no-panel bucket last")
    func grouping() async throws {
        let rows = [
            LabsTestJSON.row(id: "a", panel: "Metabolic", analyte: "Glucose"),
            LabsTestJSON.row(id: "b", panel: nil, analyte: "Custom"),
            LabsTestJSON.row(id: "c", panel: "CBC", analyte: "Hemoglobin")
        ]
        MockURLProtocol.handler = { req in
            let body: Data = req.url?.path == "/api/biomarkers"
                ? LabsTestJSON.emptyBiomarkers
                : LabsTestJSON.labsList(rows)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let store = try makeStore()
        await store.load()
        #expect(store.labs.count == 3)
        let groups = store.groupedByPanel
        // CBC, Metabolic (alphabetical), then the nil bucket.
        #expect(groups.count == 3)
        #expect(groups[0].panel == "CBC")
        #expect(groups[1].panel == "Metabolic")
        #expect(groups[2].panel == nil)
        #expect(groups[2].rows.first?.analyte == "Custom")
    }

    @Test("optimistic delete removes the row + enqueues an undo action")
    func optimisticDelete() async throws {
        let rows = [LabsTestJSON.row(id: "a", panel: "Metabolic", analyte: "Glucose")]
        MockURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            let body: Data = if path == "/api/biomarkers" {
                LabsTestJSON.emptyBiomarkers
            } else if req.httpMethod == "DELETE" {
                LabsTestJSON.deleted
            } else {
                LabsTestJSON.labsList(rows)
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let undo = UndoCoordinator()
        let store = try makeStore(undo: undo)
        await store.load()
        #expect(store.labs.count == 1)

        await store.deleteLab(id: "a", undoMessage: "removed")
        // Row is optimistically gone + an undo action is live.
        #expect(store.labs.isEmpty)
        #expect(store.pendingRestoreIDs == ["a"])
        #expect(undo.current != nil)
        #expect(undo.current?.message == "removed")
    }

    @Test("retriable delete failure (enqueued to Outbox) KEEPS the optimistic removal + undo")
    func retriableDeleteKeepsOptimisticRemoval() async throws {
        // v0150 C-M3 — a 500 on DELETE is retriable, so the repository enqueues
        // the delete to the Outbox (it will replay + succeed). The store must NOT
        // roll the row back in — that would make it flicker back then vanish on
        // the next load. Mirror MeasurementsStore/MedicationsStore: keep the
        // optimistic removal + keep the undo affordance live.
        let rows = [LabsTestJSON.row(id: "a", panel: "Metabolic", analyte: "Glucose")]
        MockURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            if path == "/api/biomarkers" {
                return (
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    LabsTestJSON.emptyBiomarkers
                )
            }
            if req.httpMethod == "DELETE" {
                // Retriable 5xx → repo enqueues to Outbox + re-throws.
                return (
                    HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"data":null,"error":"boom"}"#.utf8)
                )
            }
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                LabsTestJSON.labsList(rows)
            )
        }
        let undo = UndoCoordinator()
        let store = try makeStore(undo: undo)
        await store.load()
        #expect(store.labs.count == 1)

        await store.deleteLab(id: "a", undoMessage: "removed")
        // Optimistic removal STAYS (the outbox owns the durable replay).
        #expect(store.labs.isEmpty)
        #expect(store.pendingRestoreIDs == ["a"])
        // Undo affordance stays live — the user can still recover.
        #expect(undo.current != nil)
    }

    @Test("non-retriable delete failure (NOT enqueued) rolls the row back in")
    func nonRetriableDeleteRollsBack() async throws {
        // A 400 is non-retriable → the repo does NOT enqueue + re-throws. The
        // store rolls the optimistic removal back so the user sees an honest
        // "couldn't delete" state rather than a silently vanished row that never
        // syncs.
        let rows = [LabsTestJSON.row(id: "a", panel: "Metabolic", analyte: "Glucose")]
        MockURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            if path == "/api/biomarkers" {
                return (
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    LabsTestJSON.emptyBiomarkers
                )
            }
            if req.httpMethod == "DELETE" {
                return (
                    HTTPURLResponse(url: req.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"data":null,"error":"bad request"}"#.utf8)
                )
            }
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                LabsTestJSON.labsList(rows)
            )
        }
        let undo = UndoCoordinator()
        let store = try makeStore(undo: undo)
        await store.load()
        #expect(store.labs.count == 1)

        await store.deleteLab(id: "a", undoMessage: "removed")
        // Row rolled back in; undo affordance dismissed; error surfaced.
        #expect(store.labs.count == 1)
        #expect(store.pendingRestoreIDs.isEmpty)
        #expect(undo.current == nil)
        #expect(store.lastError != nil)
    }

    @Test("undo restore calls /api/labs/restore + reloads")
    func undoRestore() async throws {
        let rows = [LabsTestJSON.row(id: "a", panel: "Metabolic", analyte: "Glucose")]
        nonisolated(unsafe) var restoreCalled = false
        MockURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            let body: Data
            if path == "/api/biomarkers" {
                body = LabsTestJSON.emptyBiomarkers
            } else if path == "/api/labs/restore" {
                restoreCalled = true
                body = LabsTestJSON.restored
            } else if req.httpMethod == "DELETE" {
                body = LabsTestJSON.deleted
            } else {
                body = LabsTestJSON.labsList(rows)
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let undo = UndoCoordinator()
        let store = try makeStore(undo: undo)
        await store.load()
        await store.deleteLab(id: "a", undoMessage: "removed")
        #expect(store.labs.isEmpty)

        // Fire the undo closure (what the toast's Rückgängig does).
        await undo.performUndo()
        #expect(restoreCalled)
        #expect(store.pendingRestoreIDs.isEmpty)
        #expect(store.labs.count == 1)
    }

    // MARK: - Biomarker catalog render inputs (BiomarkerCatalogScreen)

    @Test("biomarker catalog: empty list + not loading drives the empty state")
    func biomarkerCatalogEmptyState() async throws {
        MockURLProtocol.handler = { req in
            let body: Data = req.url?.path == "/api/biomarkers"
                ? LabsTestJSON.emptyBiomarkers
                : LabsTestJSON.labsList([])
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let store = try makeStore()
        await store.reloadBiomarkers()
        // The screen renders its empty state exactly when both hold.
        #expect(store.biomarkers.isEmpty)
        #expect(!store.isLoading)
    }

    @Test("biomarker catalog: populated list renders name-sorted rows")
    func biomarkerCatalogPopulatedAndSorted() async throws {
        let markers = [
            LabsTestJSON.biomarker(id: "1", name: "Zinc"),
            LabsTestJSON.biomarker(id: "2", name: "ferritin"),
            LabsTestJSON.biomarker(id: "3", name: "Albumin")
        ]
        MockURLProtocol.handler = { req in
            let body: Data = req.url?.path == "/api/biomarkers"
                ? LabsTestJSON.biomarkers(markers)
                : LabsTestJSON.labsList([])
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let store = try makeStore()
        await store.reloadBiomarkers()
        #expect(store.biomarkers.count == 3)
        // The screen sorts by name, case-insensitive ascending.
        let sorted = store.biomarkers
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map(\.name)
        #expect(sorted == ["Albumin", "ferritin", "Zinc"])
    }

    @Test("403 module.disabled flips isDisabled + clears data")
    func moduleDisabled() async throws {
        MockURLProtocol.handler = { req in
            let body = Data(#"""
            {"data":null,"error":"Module disabled","meta":{"errorCode":"module.disabled","module":"labs"}}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!, body)
        }
        let store = try makeStore()
        await store.load()
        #expect(store.isDisabled)
        #expect(store.labs.isEmpty)
        #expect(store.lastError == nil)
    }
}

// swiftlint:enable force_unwrapping

// MARK: - LabsStoreOfflineTests (audit H-2)

// swiftlint:disable force_unwrapping

/// H-2 — an offline (durably-enqueued) lab-result / biomarker create must surface
/// as SUCCESS, not failure. `LabsRepository.createLab`/`createBiomarker` mint an
/// idempotency key, enqueue the write to the encrypted outbox on a retriable
/// failure, and re-throw `HLError.shouldPersistToOutbox`. If the store reported
/// that durably-queued write as a failure, the user would see a "save failed"
/// state and re-tap Save → the repo mints a FRESH key → a SECOND enqueue → both
/// replay under different keys → TWO identical lab rows. These lock the
/// success-branch that stops the duplicate-clinical-record vector. Real
/// `APIClient` + stub `URLProtocol` (per the no-mock-server doctrine); a
/// retriable 503 routes the write into the outbox and the store reports success.
@MainActor
@Suite("LabsStore offline create (audit H-2)", .serialized)
struct LabsStoreOfflineTests {
    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.14.1",
            buildNumber: "1"
        )
        let kc = InMemoryKeychain()
        try? kc.setString("token", forKey: KeychainKey.authToken)
        return APIClient(environment: env, keychain: kc, sessionConfiguration: .mock())
    }

    /// 503 on every request → retriable → the repo enqueues + re-throws.
    private func install503() {
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
        }
    }

    @Test("offline lab create → SUCCESS (optimistic row), enqueued exactly once, no failure")
    func labOfflineCreateIsSuccess() async throws {
        install503()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = LabsRepository(api: makeAPI(), outbox: outbox)
        let store = LabsStore(repository: repo)

        let ok = await store.createLab(
            LabResultCreate(analyte: "Glucose", value: 5.4, unit: "mmol/L", takenAt: "2026-07-04T08:00:00.000Z")
        )

        // Surfaced as success — the editor dismisses, the user does NOT retry
        // (a retry would mint a SECOND key → a duplicate clinical record).
        #expect(ok)
        #expect(store.lastError == nil)
        #expect(store.labs.contains { $0.analyte == "Glucose" })
        // Durably enqueued under ONE idempotency key (no duplicate vector).
        let ops = await outbox.snapshot
        #expect(ops.filter { $0.kind == .createLab }.count == 1)
    }

    @Test("offline biomarker create → SUCCESS (optimistic row), enqueued exactly once, no failure")
    func biomarkerOfflineCreateIsSuccess() async throws {
        install503()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = LabsRepository(api: makeAPI(), outbox: outbox)
        let store = LabsStore(repository: repo)

        let ok = await store.createBiomarker(BiomarkerCreate(name: "Ferritin", unit: "ng/mL"))

        #expect(ok)
        #expect(store.lastError == nil)
        #expect(store.biomarkers.contains { $0.name == "Ferritin" })
        let ops = await outbox.snapshot
        #expect(ops.filter { $0.kind == .createBiomarker }.count == 1)
    }
}

// swiftlint:enable force_unwrapping

// MARK: - LabsSortModeTests (v0.15.3 LR1)

/// Locks the two sort axes the `LabsScreen` toggle switches between:
/// ``LabsStore/groupedByAnalyte`` (the "by type" mode) and
/// ``LabsStore/sortedByDate`` (the "chronological" mode). Pure derivations over a
/// seeded in-memory snapshot — no network round-trip needed.
@MainActor
@Suite("LabsStore sort modes (LR1)", .serialized)
struct LabsSortModeTests {
    private func makeStore() throws -> LabsStore {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local"),
            bundleID: "dev.healthlog.app",
            appVersion: "0.15.3",
            buildNumber: "1"
        )
        let kc = InMemoryKeychain()
        try? kc.setString("token", forKey: KeychainKey.authToken)
        let api = APIClient(environment: env, keychain: kc, sessionConfiguration: .mock())
        let repo = try LabsRepository(api: api, outbox: OutboxQueue(inMemory: true))
        return LabsStore(repository: repo)
    }

    private func row(id: String, analyte: String, takenAt: String, panel: String? = nil) -> LabResultDTO {
        LabResultDTO(
            id: id,
            biomarkerId: nil,
            panel: panel,
            analyte: analyte,
            value: 1,
            unit: "x",
            referenceLow: nil,
            referenceHigh: nil,
            takenAt: takenAt,
            source: "MANUAL",
            hasNote: false,
            rangeStatus: .inRange,
            createdAt: takenAt,
            updatedAt: takenAt
        )
    }

    @Test("groupedByAnalyte buckets by analyte, named first (alphabetical) + blank bucket last")
    func groupedByAnalyte() throws {
        let store = try makeStore()
        store.seedForTesting(labs: [
            row(id: "a", analyte: "Glucose", takenAt: "2026-06-10T08:00:00.000Z"),
            row(id: "b", analyte: "", takenAt: "2026-06-09T08:00:00.000Z"),
            row(id: "c", analyte: "Albumin", takenAt: "2026-06-08T08:00:00.000Z")
        ])
        let groups = store.groupedByAnalyte
        // Albumin, Glucose (alphabetical), then the blank bucket.
        #expect(groups.count == 3)
        #expect(groups[0].analyte == "Albumin")
        #expect(groups[1].analyte == "Glucose")
        #expect(groups[2].analyte == nil)
        #expect(groups[2].rows.first?.id == "b")
    }

    @Test("groupedByAnalyte orders bucket NAMES case-insensitively (mirrors groupedByPanel)")
    func groupedByAnalyteCaseInsensitiveOrder() throws {
        let store = try makeStore()
        // Like `groupedByPanel`, bucket KEYS are the exact analyte string (so
        // "Glucose"/"glucose" are distinct buckets — the server controls the
        // canonical casing), but the section ORDER is case-insensitive. Here
        // "albumin" sorts before "Glucose" despite the lowercase first letter.
        store.seedForTesting(labs: [
            row(id: "a", analyte: "Glucose", takenAt: "2026-06-10T08:00:00.000Z"),
            row(id: "c", analyte: "albumin", takenAt: "2026-06-08T08:00:00.000Z")
        ])
        let groups = store.groupedByAnalyte
        #expect(groups.map(\.analyte) == ["albumin", "Glucose"])
    }

    @Test("groupedByAnalyte keeps server (newest-first) order within an analyte bucket")
    func groupedByAnalyteWithinBucketOrder() throws {
        let store = try makeStore()
        // Two Glucose rows arrive newest-first (server order); grouping must NOT
        // re-sort within the bucket.
        store.seedForTesting(labs: [
            row(id: "new", analyte: "Glucose", takenAt: "2026-06-10T08:00:00.000Z"),
            row(id: "old", analyte: "Glucose", takenAt: "2026-06-01T08:00:00.000Z")
        ])
        let groups = store.groupedByAnalyte
        #expect(groups.count == 1)
        #expect(groups[0].rows.map(\.id) == ["new", "old"])
    }

    @Test("groupedByAnalyte with no blank rows omits the nil bucket")
    func groupedByAnalyteNoBlankBucket() throws {
        let store = try makeStore()
        store.seedForTesting(labs: [
            row(id: "a", analyte: "Glucose", takenAt: "2026-06-10T08:00:00.000Z"),
            row(id: "b", analyte: "Albumin", takenAt: "2026-06-09T08:00:00.000Z")
        ])
        let groups = store.groupedByAnalyte
        #expect(groups.count == 2)
        #expect(groups.allSatisfy { $0.analyte != nil })
    }

    @Test("sortedByDate returns a flat list newest-first regardless of input order")
    func sortedByDateNewestFirst() throws {
        let store = try makeStore()
        store.seedForTesting(labs: [
            row(id: "mid", analyte: "Glucose", takenAt: "2026-06-05T08:00:00.000Z"),
            row(id: "newest", analyte: "Albumin", takenAt: "2026-06-10T08:00:00.000Z"),
            row(id: "oldest", analyte: "Sodium", takenAt: "2026-01-01T08:00:00.000Z")
        ])
        let sorted = store.sortedByDate
        #expect(sorted.map(\.id) == ["newest", "mid", "oldest"])
    }

    @Test("sortedByDate is a single flat list (no grouping)")
    func sortedByDateFlat() throws {
        let store = try makeStore()
        store.seedForTesting(labs: [
            row(id: "a", analyte: "Glucose", takenAt: "2026-06-10T08:00:00.000Z", panel: "Metabolic"),
            row(id: "b", analyte: "Hemoglobin", takenAt: "2026-06-09T08:00:00.000Z", panel: "CBC")
        ])
        // Different panels/analytes still collapse into one flat date-sorted list.
        #expect(store.sortedByDate.count == 2)
        #expect(store.sortedByDate.map(\.id) == ["a", "b"])
    }
}
