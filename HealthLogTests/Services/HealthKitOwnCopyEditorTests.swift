import Foundation
@testable import HealthLog
import Testing

/// Editing or deleting a reading in HealthLog changes exactly the copy
/// HealthLog wrote to Apple Health. Objects of other sources stay, even when
/// they carry the same external UUID; a failed removal leaves everything as
/// it was and is retried; the direction rules decide whether a copy goes.
@Suite("HealthKit own-copy editor")
struct HealthKitOwnCopyEditorTests {
    private let weight = "HKQuantityTypeIdentifierBodyMass"
    private let ownX = UUID()
    private let foreignX = UUID()
    private let ownY = UUID()

    private func seededStore(authorized: Bool = true) -> FakeCopyStore {
        FakeCopyStore(
            records: [
                HealthKitCopyRecord(objectID: ownX, typeIdentifier: weight, externalUUID: "srv-x", isFromThisApp: true),
                HealthKitCopyRecord(objectID: foreignX, typeIdentifier: weight, externalUUID: "srv-x", isFromThisApp: false),
                HealthKitCopyRecord(objectID: ownY, typeIdentifier: weight, externalUUID: "srv-y", isFromThisApp: true)
            ],
            authorized: authorized
        )
    }

    private func removal(_ ids: [String]) -> HealthKitPendingCopyEdit {
        HealthKitPendingCopyEdit(kind: .remove, serverIDs: ids, typeIdentifiers: [weight])
    }

    private func change(_ ids: [String], contentChanged: Bool) -> HealthKitPendingCopyEdit {
        HealthKitPendingCopyEdit(
            kind: .replace,
            serverIDs: ids,
            typeIdentifiers: [weight],
            metricKind: MetricKind.weight.rawValue,
            contentChanged: contentChanged,
            mirrorEligible: true
        )
    }

    // MARK: - Selection

    @Test("selection: own source and one of the server ids, nothing else")
    func pureSelection() {
        let records = [
            HealthKitCopyRecord(objectID: ownX, typeIdentifier: weight, externalUUID: "srv-x", isFromThisApp: true),
            HealthKitCopyRecord(objectID: foreignX, typeIdentifier: weight, externalUUID: "srv-x", isFromThisApp: false),
            HealthKitCopyRecord(objectID: ownY, typeIdentifier: weight, externalUUID: "srv-y", isFromThisApp: true),
            HealthKitCopyRecord(objectID: UUID(), typeIdentifier: weight, externalUUID: nil, isFromThisApp: true)
        ]
        #expect(HealthKitOwnCopyEditor.ownCopies(in: records, serverIDs: ["srv-x"]).map(\.objectID) == [ownX])
    }

    @Test("a foreign object handed to the store is never asked to be deleted")
    func foreignNeverReachesDelete() async {
        let store = seededStore()
        let editor = HealthKitOwnCopyEditor(store: store, ledger: HealthKitOwnCopyLedger(url: nil))
        await editor.remove(removal(["srv-x"]))
        #expect(await store.deleteRequests == [[ownX]])
    }

    // MARK: - Delete and change

    @Test("delete removes exactly the own copy; the foreign sample and other readings stay")
    func deleteRemovesOwnOnly() async {
        let store = seededStore()
        let ledger = HealthKitOwnCopyLedger(url: nil)
        let done = await HealthKitOwnCopyEditor(store: store, ledger: ledger).remove(removal(["srv-x"]))
        #expect(done)
        #expect(await store.objectIDs == [foreignX, ownY])
        #expect(ledger.pending().isEmpty)
    }

    @Test("change with write access replaces exactly the own copy")
    func replaceSwapsOwnOnly() async {
        let store = seededStore()
        let editor = HealthKitOwnCopyEditor(store: store, ledger: HealthKitOwnCopyLedger(url: nil))
        let newCopy = UUID()
        let action = await editor.replace(change(["srv-x"], contentChanged: false), writeAllowed: true) { [weight] in
            await store.add(HealthKitCopyRecord(objectID: newCopy, typeIdentifier: weight, externalUUID: "srv-x", isFromThisApp: true))
        }
        #expect(action == .removeAndRewrite)
        #expect(await store.objectIDs == [foreignX, ownY, newCopy])
    }

    @Test("direction unknown: nothing removed, the whole change waits in the ledger")
    func unknownDirectionDefers() async {
        let store = seededStore()
        let ledger = HealthKitOwnCopyLedger(url: nil)
        let edit = change(["srv-x"], contentChanged: true)
        let action = await HealthKitOwnCopyEditor(store: store, ledger: ledger).replace(edit, writeAllowed: nil, write: nil)
        #expect(action == .deferred)
        #expect(await store.objectIDs == [ownX, foreignX, ownY])
        #expect(ledger.pending() == [edit])
    }

    @Test("not allowed to write: a note-only change keeps the copy, a value change removes it")
    func notWritingRules() async {
        let keepStore = seededStore()
        let keep = await HealthKitOwnCopyEditor(store: keepStore, ledger: HealthKitOwnCopyLedger(url: nil))
            .replace(change(["srv-x"], contentChanged: false), writeAllowed: false, write: nil)
        #expect(keep == .keep)
        #expect(await keepStore.objectIDs == [ownX, foreignX, ownY])

        let removeStore = seededStore()
        let remove = await HealthKitOwnCopyEditor(store: removeStore, ledger: HealthKitOwnCopyLedger(url: nil))
            .replace(change(["srv-x"], contentChanged: true), writeAllowed: false, write: nil)
        #expect(remove == .remove)
        #expect(await removeStore.objectIDs == [foreignX, ownY])
    }

    @Test("the deferred change runs once the direction is known")
    func deferredChangeRetries() async {
        let store = seededStore()
        let ledger = HealthKitOwnCopyLedger(url: nil)
        let editor = HealthKitOwnCopyEditor(store: store, ledger: ledger)
        await editor.replace(change(["srv-x"], contentChanged: true), writeAllowed: nil, write: nil)

        let left = await editor.retryPending { _ in false }

        #expect(left == 0)
        #expect(await store.objectIDs == [foreignX, ownY])
    }

    @Test("a refused delete changes nothing, writes nothing, and stays pending until a retry lands")
    func failedDeleteIsRetried() async {
        let store = seededStore()
        await store.failDeletes(true)
        let ledger = HealthKitOwnCopyLedger(url: nil)
        let editor = HealthKitOwnCopyEditor(store: store, ledger: ledger)
        let wrote = WriteFlag()

        _ = await editor.replace(change(["srv-x"], contentChanged: true), writeAllowed: true) { await wrote.set() }

        #expect(await !wrote.didWrite)
        #expect(await store.objectIDs == [ownX, foreignX, ownY])
        #expect(ledger.pending().count == 1)
        // The failed delete takes back its self-deletion entries.
        #expect(ledger.withoutSelfDeleted(["srv-x"], typeIdentifier: weight) == ["srv-x"])

        await store.failDeletes(false)
        let left = await editor.retryPending { _ in true }

        #expect(left == 0)
        #expect(await store.objectIDs == [foreignX, ownY])
    }

    @Test("without write access to the type nothing starts and nothing lands in the ledger")
    func unauthorizedStartsNothing() async {
        let store = seededStore(authorized: false)
        let ledger = HealthKitOwnCopyLedger(url: nil)
        let editor = HealthKitOwnCopyEditor(store: store, ledger: ledger)

        await editor.remove(removal(["srv-x"]))
        await editor.replace(change(["srv-x"], contentChanged: true), writeAllowed: nil, write: nil)

        #expect(await store.deleteRequests.isEmpty)
        #expect(ledger.pending().isEmpty)
    }

    // MARK: - Self-deletions

    @Test("each deleted object is one self-deletion of its type, used up by one deleted object of a page")
    func selfDeletionPerObject() async {
        let ledger = HealthKitOwnCopyLedger(url: nil)
        await HealthKitOwnCopyEditor(store: seededStore(), ledger: ledger).remove(removal(["srv-x"]))

        #expect(ledger.withoutSelfDeleted(["srv-x"], typeIdentifier: "HKQuantityTypeIdentifierHeartRate") == ["srv-x"])
        #expect(ledger.withoutSelfDeleted(["srv-x"], typeIdentifier: weight).isEmpty)
        // A later deletion by the person is a tombstone again.
        #expect(ledger.withoutSelfDeleted(["srv-x"], typeIdentifier: weight) == ["srv-x"])
    }

    @Test("blood pressure: systolic and diastolic deletion pages both stay without a tombstone")
    func bloodPressureTwoPages() {
        let ledger = HealthKitOwnCopyLedger(url: nil)
        let systolic = "HKQuantityTypeIdentifierBloodPressureSystolic"
        let diastolic = "HKQuantityTypeIdentifierBloodPressureDiastolic"
        ledger.noteSelfDeleted([
            (serverID: "bp-1", typeIdentifier: "HKCorrelationTypeIdentifierBloodPressure"),
            (serverID: "bp-1", typeIdentifier: systolic),
            (serverID: "bp-1", typeIdentifier: diastolic)
        ])

        #expect(ledger.withoutSelfDeleted(["bp-1"], typeIdentifier: systolic).isEmpty)
        #expect(ledger.withoutSelfDeleted(["bp-1"], typeIdentifier: diastolic).isEmpty)
        #expect(ledger.withoutSelfDeleted(["bp-1"], typeIdentifier: systolic) == ["bp-1"])
    }

    @Test("edited twice in a row: two deletions of the same id in one page, both answered")
    func doubleEdit() {
        let ledger = HealthKitOwnCopyLedger(url: nil)
        ledger.noteSelfDeleted([(serverID: "w-1", typeIdentifier: weight)])
        ledger.noteSelfDeleted([(serverID: "w-1", typeIdentifier: weight)])

        #expect(ledger.withoutSelfDeleted(["w-1", "w-1"], typeIdentifier: weight).isEmpty)
        #expect(ledger.withoutSelfDeleted(["w-1"], typeIdentifier: weight) == ["w-1"])
    }

    @Test("a self-deletion older than its memory no longer hides a deletion")
    func selfDeletionExpires() {
        let ledger = HealthKitOwnCopyLedger(url: nil)
        let then = Date(timeIntervalSince1970: 1_800_000_000)
        ledger.noteSelfDeleted([(serverID: "w-2", typeIdentifier: weight)], now: then)
        let later = then.addingTimeInterval(HealthKitOwnCopyLedger.selfDeletionMemory + 60)
        #expect(ledger.withoutSelfDeleted(["w-2"], typeIdentifier: weight, now: later) == ["w-2"])
    }

    // MARK: - Ledger

    @Test("the ledger survives a restart, is bounded and clears on logout")
    func ledgerPersistsBoundedClears() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("own-copy-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let ledger = HealthKitOwnCopyLedger(url: url)
        ledger.addPending(removal(["srv-x"]))
        #expect(HealthKitOwnCopyLedger(url: url).pending() == [removal(["srv-x"])])

        for index in 0 ..< HealthKitOwnCopyLedger.maxPending + 5 {
            ledger.addPending(removal(["srv-\(index)"]))
        }
        #expect(ledger.pending().count == HealthKitOwnCopyLedger.maxPending)

        ledger.clear()
        #expect(HealthKitOwnCopyLedger(url: url).pending().isEmpty)
    }

    // MARK: - Ordering

    @Test("copy edits run in the order they were handed in")
    func queueKeepsOrder() async {
        let queue = HealthKitCopyEditQueue()
        let order = OrderRecorder()
        queue.enqueue {
            try? await Task.sleep(for: .milliseconds(30))
            await order.note("replace")
        }
        queue.enqueue { await order.note("delete") }
        await queue.drain()
        #expect(await order.calls == ["replace", "delete"])
    }
}

/// Health store double holding own and foreign objects side by side. Unlike
/// HealthKit it would delete any object it is handed, so a wrong selection
/// shows up in the tests.
private actor FakeCopyStore: HealthKitCopyStore {
    private var records: [HealthKitCopyRecord]
    private var shouldFail = false
    private let authorized: Bool
    private(set) var deleteRequests: [[UUID]] = []

    init(records: [HealthKitCopyRecord], authorized: Bool) {
        self.records = records
        self.authorized = authorized
    }

    var objectIDs: [UUID] {
        records.map(\.objectID)
    }

    func failDeletes(_ fail: Bool) {
        shouldFail = fail
    }

    func add(_ record: HealthKitCopyRecord) {
        records.append(record)
    }

    nonisolated func authorizedTypes(_ typeIdentifiers: [String]) -> [String] {
        authorized ? typeIdentifiers : []
    }

    func copies(withExternalIDs ids: [String], typeIdentifiers _: [String]) async throws -> [HealthKitCopyRecord] {
        records.filter { record in record.externalUUID.map(ids.contains) ?? false }
    }

    func delete(_ requested: [HealthKitCopyRecord]) async -> HealthKitCopyDeletion {
        deleteRequests.append(requested.map(\.objectID))
        if shouldFail { return HealthKitCopyDeletion(gone: [], failed: true) }
        let ids = Set(requested.map(\.objectID))
        records.removeAll { ids.contains($0.objectID) }
        return HealthKitCopyDeletion(gone: Array(ids), failed: false)
    }
}

private actor WriteFlag {
    private(set) var didWrite = false

    func set() {
        didWrite = true
    }
}

private actor OrderRecorder {
    private(set) var calls: [String] = []

    func note(_ call: String) {
        calls.append(call)
    }
}
