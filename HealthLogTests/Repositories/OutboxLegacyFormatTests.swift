import Foundation
@testable import HealthLog
import SwiftData
import Testing

// swiftlint:disable force_unwrapping

/// A queue as a 1.5.0 installation leaves it behind. Nothing here is produced
/// by today's encoder or today's cipher: the payloads are the JSON 1.5.0 wrote,
/// the blobs were sealed once under the fixed key below in the layout 1.5.0
/// used (`0x02`, 12-byte nonce, ciphertext, 16-byte tag), and the notes in
/// `lastError` are spelled the way the 1.5.0 replay spelled them. If a later
/// change stops reading any of it, these rows stop being delivered and the
/// suite fails.
enum Outbox150Fixture {
    static let keyAccount = "outbox-150-fixture"

    /// The 256-bit key the blobs are sealed under: the bytes 1 to 32.
    static let key = Data((1 ... 32).map { UInt8($0) })

    static func sealed(_ parts: String...) -> Data {
        Data(base64Encoded: parts.joined())!
    }

    static let takePlain = #"{"intakeId":"intake-1","status":"TAKEN","takenAt":"2026-06-13T06:05:00Z"}"#
    static let freePlain =
        #"{"medicationId":"med-1","body":{"takenAt":"2026-06-13T06:05:00Z","skipped":false,"idempotencyKey":"k150-free"}}"#
    static let allergyPlain = #"{"body":{"substance":"Penicillin","category":"MEDICATION"}}"#
    static let moodPlain = #"{"id":"mood-1"}"#
    static let stalePlain = #"{"body":{"substance":"Latex"}}"#
    static let deadPlain = #"{"body":{"substance":"Nickel"}}"#

    static let takeSealed = sealed(
        "AgEBAQEBAQEBAQEBAVybty/iVdV1R7tTcJvtdRSULd4auUF+pfhvK7iQMv30MWx137l8LJTSYvmkFR1CMcW7UiIXV3P+0F5R",
        "uNcBqUR9xkqHXezRR/HBUuMhbzz5GfUNU0+mhW9u"
    )

    static let freeSealed = sealed(
        "AgICAgICAgICAgICAuoFZutrtV4LMJ6AlykGW6o+/EgIOEhUIYjWBzegmgdmkalE1fyBZCWulK6Z1FQVtwBY8JDDUX/X8AsO",
        "WZFB9wnzfRfOawGh2kaz8UqkFVfXzhYOJzwe1geQgYSSx9dJg7q85rbCK03RV2ztH2eO4dYk4XgFlymxEatbV2PLAmM="
    )

    static let allergySealed = sealed(
        "AgMDAwMDAwMDAwMDA5S2e75R2cZIIjCx1chcbxIgySlhRsK9ROSsoTNgZViiS4c/3fKdQu2RSlcHzv6mJCAHYSW85O+//4kQ",
        "441JS71Q+Nkn6cSUJNJv1A=="
    )

    static let moodSealed = sealed(
        "AgQEBAQEBAQEBAQEBDZHTM1vGRFjTsIhboHgLQdEJm+1/FHc2tFpzQnZd+M="
    )

    static let staleSealed = sealed(
        "AgUFBQUFBQUFBQUFBbE7Yehl6pInBVRm34ty9+so3OJ9RGm6WNzJ0y1HyCuBPgU6LcqOC6ji3FY4eb8="
    )

    static let deadSealed = sealed(
        "AgYGBgYGBgYGBgYGBtO0CZjUPAqHAXeEwW+XTgsfi5HjdGTeNcQmDf1vXhdhwX0+YuKkfNFwE7eL3lJP"
    )

    struct Row: Sendable {
        let id = UUID()
        let kindRaw: String
        let sealed: Data
        let plain: String
        let key: String
        /// Minutes before `now` the write was queued; also fixes the send order.
        let minutesOld: Double
        var attempts = 0
        var lastError: String?
        var deadLettered = false
    }

    /// Six rows: two doses, a record that may have landed an hour ago, a
    /// delete, a record whose key the server has long forgotten, and one the
    /// user already finds under "not sent".
    static func rows(now: Date) -> [Row] {
        let epoch = Int(now.timeIntervalSince1970)
        return [
            Row(kindRaw: "takeMedication", sealed: takeSealed, plain: takePlain, key: "k150-take", minutesOld: 60),
            Row(
                kindRaw: "logMedicationIntake",
                sealed: freeSealed,
                plain: freePlain,
                key: "k150-free",
                minutesOld: 50,
                attempts: 1,
                lastError: "The request timed out."
            ),
            Row(
                kindRaw: "createAllergy",
                sealed: allergySealed,
                plain: allergyPlain,
                key: "k150-allergy",
                minutesOld: 40,
                attempts: 1,
                lastError: "unconfirmed:since=\(epoch - 3600)"
            ),
            Row(kindRaw: "deleteMood", sealed: moodSealed, plain: moodPlain, key: "k150-mood", minutesOld: 30),
            Row(
                kindRaw: "createAllergy",
                sealed: staleSealed,
                plain: stalePlain,
                key: "k150-stale",
                minutesOld: 20,
                attempts: 1,
                lastError: "unconfirmed:since=\(epoch - 30 * 3600)"
            ),
            Row(
                kindRaw: "createAllergy",
                sealed: deadSealed,
                plain: deadPlain,
                key: "k150-dead",
                minutesOld: 10,
                attempts: 5,
                lastError: "HTTP 500",
                deadLettered: true
            )
        ]
    }

    /// Writes the rows straight into the store, past the queue, as an older
    /// build would have left them on disk.
    @MainActor
    static func seed(_ rows: [Row], now: Date, in container: ModelContainer) throws {
        let context = ModelContext(container)
        for row in rows {
            let queuedAt = now.addingTimeInterval(-row.minutesOld * 60)
            context.insert(OutboxOperation(
                id: row.id,
                kindRaw: row.kindRaw,
                payload: row.sealed,
                idempotencyKey: row.key,
                createdAt: queuedAt,
                attempts: row.attempts,
                lastAttemptAt: row.attempts > 0 ? queuedAt.addingTimeInterval(60) : nil,
                lastError: row.lastError,
                ownerUserID: WAFixture.owner,
                deadLettered: row.deadLettered,
                deadLetteredAt: row.deadLettered ? queuedAt.addingTimeInterval(120) : nil
            ))
        }
        try context.save()
    }

    /// The updated app's queue over the old store, with the old key in its keychain.
    static func queueAfterUpdate(on container: ModelContainer, keychain: InMemoryKeychain) async throws -> OutboxQueue {
        try keychain.setData(key, forKey: keyAccount)
        let queue = WAFixture.queue(on: container)
        await queue.useCipher(OutboxPayloadCipher(keychain: keychain, keyAccount: keyAccount))
        return queue
    }
}

/// The update path: whatever 1.5.0 had queued is still there after the update,
/// reads as it was written, and is delivered under the keys it was queued with.
@Suite("An outbox written by 1.5.0 is read and drained after the update", .serialized, .isolatedSkipRegister, .mockURLSession)
struct OutboxLegacyFormatTests {
    @Test("every row reads back with the payload, key, attempt count and note it was written with")
    func rowsAreReadAsWritten() async throws {
        let now = Date()
        let rows = Outbox150Fixture.rows(now: now)
        let container = try OutboxStore.makeInMemory()
        try await Outbox150Fixture.seed(rows, now: now, in: container)
        let keychain = InMemoryKeychain()
        let queue = try await Outbox150Fixture.queueAfterUpdate(on: container, keychain: keychain)

        let live = await queue.snapshot
        let expected = rows.filter { !$0.deadLettered }
        #expect(live.map(\.id) == expected.map(\.id), "oldest first, the dead-lettered row left out")
        for (read, written) in zip(live, expected) {
            #expect(read.kind.rawValue == written.kindRaw)
            #expect(String(bytes: read.payload, encoding: .utf8) == written.plain)
            #expect(read.idempotencyKey == written.key)
            #expect(read.attempts == written.attempts)
            #expect(read.lastError == written.lastError)
        }
        #expect(await queue.deadLetterCount == 1)
        #expect(await queue.waitingCount(in: live) == live.count, "all of them count as waiting for the signed-in account")
        #expect(keychain.getData(forKey: Outbox150Fixture.keyAccount) == Outbox150Fixture.key, "reading replaces no key")
    }

    @Test("the queue is delivered once, under the old keys, and the rows 1.5.0 would not have sent stay unsent")
    func queueIsDrained() async throws {
        let clock = C4Clock()
        let rows = Outbox150Fixture.rows(now: clock.now)
        let container = try OutboxStore.makeInMemory()
        try await Outbox150Fixture.seed(rows, now: clock.now, in: container)
        let queue = try await Outbox150Fixture.queueAfterUpdate(on: container, keychain: InMemoryKeychain())

        let wire = WAWireLog()
        let bodies = WABodyLog()
        MockURLProtocol.install { req in
            wire.record(req)
            bodies.add(req)
            switch (req.httpMethod ?? "", req.url?.path ?? "") {
            case ("POST", "/api/allergies"):
                return WAFixture.reply(req, 201, WAFixture.allergyCreated)
            case ("DELETE", _):
                return WAFixture.reply(req, 204)
            default:
                return WAFixture.reply(req, 201, WAFixture.intakeLogged)
            }
        }
        let discards = C4Discards()
        let replay = WAFixture.replay(outbox: queue, clock: clock, discards: discards)
        await replay.runOnce()
        await replay.runOnce()

        #expect(wire.all == [
            WAWireCall(method: "POST", path: "/api/medications/intake", key: "k150-take"),
            WAWireCall(method: "POST", path: "/api/medications/med-1/intake", key: "k150-free"),
            WAWireCall(method: "POST", path: "/api/allergies", key: "k150-allergy"),
            // A delete names its row in the path and carries no key header.
            WAWireCall(method: "DELETE", path: "/api/mood-entries/mood-1", key: "")
        ])
        let freeDose = try #require(bodies.all.first { $0.contains("k150-free") })
        #expect(freeDose.contains("2026-06-13T06:05:00"), "the dose goes out with the time it was taken, not the time of the update")

        #expect(await queue.snapshot.isEmpty)
        #expect(await queue.deadLetterCount == 2, "the row that was already there, and the record past its window")
        #expect(discards.all == [.init(kind: "createAllergy", reason: .responseUnreadable)])
    }

    @Test("a write made after the update shares the queue with the old rows and neither disturbs the other")
    func newWriteJoinsTheOldQueue() async throws {
        let clock = C4Clock()
        let rows = Array(Outbox150Fixture.rows(now: clock.now).prefix(1))
        let container = try OutboxStore.makeInMemory()
        try await Outbox150Fixture.seed(rows, now: clock.now, in: container)
        let queue = try await Outbox150Fixture.queueAfterUpdate(on: container, keychain: InMemoryKeychain())

        let offline = WAFailingAPI(error: .offline)
        await #expect(throws: HLError.offline) {
            _ = try await MoodRepository(api: offline, outbox: queue).delete(id: "mood-2")
        }
        #expect(offline.log.all.count == 1, "the new write was tried once before it was left to the queue")
        #expect(await queue.snapshot.count == 2)

        let wire = WAWireLog()
        MockURLProtocol.install { req in
            wire.record(req)
            return req.httpMethod == "DELETE" ? WAFixture.reply(req, 204) : WAFixture.reply(req, 201, WAFixture.intakeLogged)
        }
        await WAFixture.replay(outbox: queue, clock: clock).runOnce()

        #expect(wire.all == [
            WAWireCall(method: "POST", path: "/api/medications/intake", key: "k150-take"),
            WAWireCall(method: "DELETE", path: "/api/mood-entries/mood-2", key: "")
        ])
        #expect(await queue.snapshot.isEmpty)
    }
}

// swiftlint:enable force_unwrapping
