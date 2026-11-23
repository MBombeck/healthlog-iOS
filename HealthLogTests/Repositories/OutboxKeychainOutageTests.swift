import Foundation
@testable import HealthLog
import Security
import SwiftData
import Synchronization
import Testing

/// A keychain that can stop answering, the way the real one does before the
/// first unlock after a reboot or when a background wake may not interact
/// with it. While it is out, `getData` returns nothing (as it always did) and
/// `readData` says why.
final class OutageKeychain: KeychainStoring, Sendable {
    private struct State {
        var items: [String: Data] = [:]
        var outage: OSStatus?
        var writes = 0
    }

    private let state = Mutex(State())

    /// How often anything was written or removed: a read path must never do either.
    var writes: Int {
        state.withLock { $0.writes }
    }

    func goDown(_ status: OSStatus) {
        state.withLock { $0.outage = status }
    }

    func comeBack() {
        state.withLock { $0.outage = nil }
    }

    func setString(_ value: String, forKey key: String) throws {
        try setData(Data(value.utf8), forKey: key)
    }

    func getString(forKey key: String) -> String? {
        getData(forKey: key).flatMap { String(bytes: $0, encoding: .utf8) }
    }

    func setData(_ data: Data, forKey key: String) throws {
        state.withLock { state in
            state.writes += 1
            state.items[key] = data
        }
    }

    func getData(forKey key: String) -> Data? {
        guard case let .found(data) = readData(forKey: key) else { return nil }
        return data
    }

    func readData(forKey key: String) -> KeychainRead {
        state.withLock { state in
            if let status = state.outage { return .unavailable(status) }
            return state.items[key].map(KeychainRead.found) ?? .missing
        }
    }

    func remove(forKey key: String) throws {
        state.withLock { state in
            state.writes += 1
            state.items[key] = nil
        }
    }

    func removeAll() throws {
        state.withLock { state in
            state.writes += 1
            state.items.removeAll()
        }
    }
}

/// The outbox key lives in the keychain. When the keychain cannot answer, the
/// app knows nothing about the key, and must neither make a new one nor throw
/// rows away that it merely cannot open at this moment.
@Suite("A keychain that cannot answer costs the outbox nothing", .serialized, .isolatedSkipRegister, .mockURLSession)
struct OutboxKeychainOutageTests {
    private static let account = "outbox-outage-test"

    private struct Rig {
        let queue: OutboxQueue
        let keychain: OutageKeychain
        let container: ModelContainer
    }

    private func rig() async throws -> Rig {
        let container = try OutboxStore.makeInMemory()
        let keychain = OutageKeychain()
        let queue = WAFixture.queue(on: container)
        await queue.useCipher(OutboxPayloadCipher(keychain: keychain, keyAccount: Self.account))
        return Rig(queue: queue, keychain: keychain, container: container)
    }

    @MainActor
    private func rowsOnDisk(_ container: ModelContainer) throws -> Int {
        try ModelContext(container).fetchCount(FetchDescriptor<OutboxOperation>())
    }

    @Test("rows and key survive an outage, and the queue is delivered once the keychain is back")
    func outageLeavesRowsAndKey() async throws {
        let setup = try await rig()
        let (queue, keychain, container) = (setup.queue, setup.keychain, setup.container)
        try await WAFixture.enqueueIntake(queue)
        let keyBefore = try #require(keychain.getData(forKey: Self.account))
        let writesBefore = keychain.writes

        keychain.goDown(errSecInteractionNotAllowed)
        #expect(await queue.snapshot.isEmpty, "nothing can be read right now")
        await WAFixture.replay(outbox: queue).runOnce()
        #expect(try await rowsOnDisk(container) == 1, "the row is still on disk")
        #expect(keychain.writes == writesBefore, "no key was written over the one that opens the row")

        keychain.comeBack()
        #expect(keychain.getData(forKey: Self.account) == keyBefore)
        let wire = WAWireLog()
        MockURLProtocol.install { req in
            wire.record(req)
            return WAFixture.reply(req, 201, WAFixture.intakeLogged)
        }
        await WAFixture.replay(outbox: queue).runOnce()

        #expect(wire.all == [WAWireCall(method: "POST", path: "/api/medications/intake", key: "wa-intake")])
        #expect(await queue.snapshot.isEmpty)
        #expect(try await rowsOnDisk(container) == 0)
    }

    @Test("the store reports the outage instead of an empty queue")
    func storeReportsTheOutage() async throws {
        let container = try OutboxStore.makeInMemory()
        let keychain = OutageKeychain()
        let store = OutboxStore(modelContainer: container)
        await store.useCipher(OutboxPayloadCipher(keychain: keychain, keyAccount: Self.account))
        try await store.enqueue(
            id: UUID(),
            kindRaw: OutboxQueue.Operation.Kind.deleteMood.rawValue,
            payload: Data(#"{"id":"mood-1"}"#.utf8),
            idempotencyKey: "wa-outage",
            createdAt: .now
        )

        keychain.goDown(errSecInteractionNotAllowed)
        await #expect(throws: OutboxPayloadCipher.CipherError.keyUnavailable(errSecInteractionNotAllowed)) {
            _ = try await store.snapshot()
        }
        #expect(try await rowsOnDisk(container) == 1)

        keychain.comeBack()
        #expect(try await store.snapshot().count == 1)
    }

    @Test("a write during the outage is not stored under a fresh key, and the caller hears that it was not saved")
    func writeDuringOutageIsRefused() async throws {
        let setup = try await rig()
        let (queue, keychain, container) = (setup.queue, setup.keychain, setup.container)
        try await WAFixture.enqueueIntake(queue)
        let writesBefore = keychain.writes

        keychain.goDown(errSecInteractionNotAllowed)
        let lostConnection = WAFailingAPI(error: .network(.connectionLost))
        do {
            try await MoodRepository(api: lostConnection, outbox: queue).delete(id: "mood-1")
            Issue.record("the delete returned as if it were safe")
        } catch HLError.notPersisted {
            // Neither sent nor stored, and said so.
        } catch {
            Issue.record("expected notPersisted, got \(error)")
        }
        #expect(keychain.writes == writesBefore)
        #expect(try await rowsOnDisk(container) == 1, "only the row from before the outage")

        keychain.comeBack()
        #expect(await queue.snapshot.count == 1, "and it opens again with the key it was sealed under")
    }

    @Test("an empty keychain still gets its key on the first write")
    func firstWriteCreatesTheKey() async throws {
        let setup = try await rig()
        let (queue, keychain) = (setup.queue, setup.keychain)
        #expect(keychain.getData(forKey: Self.account) == nil)

        try await WAFixture.enqueueIntake(queue)

        #expect(keychain.getData(forKey: Self.account)?.count == 32)
        #expect(await queue.snapshot.count == 1)
    }

    @Test("reading a row never creates a key, even when the keychain says there is none")
    func readingCreatesNoKey() async throws {
        let setup = try await rig()
        let (queue, keychain) = (setup.queue, setup.keychain)
        try await WAFixture.enqueueIntake(queue)
        try keychain.remove(forKey: Self.account)
        let writesBefore = keychain.writes

        _ = await queue.snapshot

        #expect(keychain.writes == writesBefore)
        #expect(keychain.getData(forKey: Self.account) == nil)
    }

    // MARK: - A key that is gone for good

    @Test("rows whose key is gone are reported to their owner, each one once, and nothing is sent")
    func missingKeyReportsEveryLostRow() async throws {
        let setup = try await rig()
        let (queue, keychain, container) = (setup.queue, setup.keychain, setup.container)
        for key in ["wa-1", "wa-2", "wa-3"] {
            try await WAFixture.enqueueIntake(queue, key: key)
        }
        // What a move to a new iPhone leaves: the outbox file, not its key.
        try keychain.remove(forKey: Self.account)

        let wire = WAWireLog()
        MockURLProtocol.install { req in
            wire.record(req)
            return WAFixture.reply(req, 201, WAFixture.intakeLogged)
        }
        let discards = C4Discards()
        let replay = WAFixture.replay(outbox: queue, discards: discards)
        await replay.runOnce()
        await replay.runOnce()

        let lost = OutboxDiscardNotice(kind: "takeMedication", reason: .payloadUnreadable)
        #expect(discards.all == [lost, lost, lost])
        #expect(wire.all.isEmpty)
        #expect(try await rowsOnDisk(container) == 0)
    }

    @Test("a missing key over an empty queue reports nothing")
    func missingKeyOverAnEmptyQueue() async throws {
        let setup = try await rig()
        try await WAFixture.enqueueIntake(setup.queue)
        let row = try #require(await setup.queue.snapshot.first)
        try await setup.queue.remove(id: row.id)
        try setup.keychain.remove(forKey: Self.account)

        let discards = C4Discards()
        await WAFixture.replay(outbox: setup.queue, discards: discards).runOnce()

        #expect(discards.all.isEmpty)
    }

    @Test("a keychain that cannot answer reports no loss, because nothing was lost")
    func outageReportsNothing() async throws {
        let setup = try await rig()
        let (queue, keychain, container) = (setup.queue, setup.keychain, setup.container)
        try await WAFixture.enqueueIntake(queue, key: "wa-1")
        try await WAFixture.enqueueIntake(queue, key: "wa-2")

        keychain.goDown(errSecInteractionNotAllowed)
        let discards = C4Discards()
        await WAFixture.replay(outbox: queue, discards: discards).runOnce()

        #expect(discards.all.isEmpty)
        #expect(try await rowsOnDisk(container) == 2)
    }

    @Test("lost rows of another account are not this account's news and wait for their owner")
    func lostRowsWaitForTheirOwner() async throws {
        let container = try OutboxStore.makeInMemory()
        let keychain = OutageKeychain()
        let queue = WAFixture.queue(on: container, owner: "account-other")
        await queue.useCipher(OutboxPayloadCipher(keychain: keychain, keyAccount: Self.account))
        try await WAFixture.enqueueIntake(queue)
        try keychain.remove(forKey: Self.account)

        let mine = C4Discards()
        await WAFixture.replay(outbox: queue, discards: mine).runOnce()
        #expect(mine.all.isEmpty)

        let theirs = C4Discards()
        await WAFixture.replay(outbox: queue, owner: "account-other", discards: theirs).runOnce()
        #expect(theirs.all == [.init(kind: "takeMedication", reason: .payloadUnreadable)])
    }
}
