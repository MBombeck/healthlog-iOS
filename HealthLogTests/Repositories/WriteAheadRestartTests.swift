import Foundation
@testable import HealthLog
import SwiftData
import Synchronization
import Testing

/// A write is on disk before its request leaves. These tests take the process
/// away at the worst moment, with the request on the wire and no answer yet,
/// and check what the next launch does with what it finds: it delivers the
/// write once, under the key the first request carried, and it does not send
/// what the server had already answered.
///
/// "Restart" is a second queue over the same store: the rows are there,
/// nothing that lived in memory is.
@Suite("Write-ahead across a restart", .serialized, .isolatedSkipRegister, .mockURLSession)
struct WriteAheadRestartTests {
    private static let window: TimeInterval = 24 * 3600

    private func allergy() -> AllergyCreate {
        AllergyCreate(substance: "Penicillin", category: .medication)
    }

    // MARK: - Medication intake

    @Test("a dose whose request is out when the process dies is delivered once, under the key it left with")
    func intakeInFlightAtRestart() async throws {
        let container = try OutboxStore.makeInMemory()
        let before = WAFixture.queue(on: container)
        let stalled = WAStalledAPI()
        let live = Task {
            try await MedicationsRepository(api: stalled, outbox: before)
                .record(intake: "intake-1", status: .taken, takenAt: WAFixture.takenAt)
        }
        await stalled.requestLeft()
        let left = try #require(stalled.log.all.first)

        let after = WAFixture.queue(on: container)
        let row = try #require(await after.snapshot.first, "the dose is on disk while its request is still out")
        #expect(row.kind == .takeMedication)
        #expect(row.idempotencyKey == left.key)
        #expect(row.lastError == nil, "the server folds a dose by itself, so the row is held to no window")

        let wire = WAWireLog()
        MockURLProtocol.install { req in
            wire.record(req)
            return WAFixture.reply(req, 201, WAFixture.intakeLogged)
        }
        let replay = WAFixture.replay(outbox: after)
        await replay.runOnce()
        await replay.runOnce()

        #expect(wire.all == [WAWireCall(method: "POST", path: "/api/medications/intake", key: left.key)])
        #expect(await after.snapshot.isEmpty)
        #expect(await after.deadLetterCount == 0)

        live.cancel()
        _ = await live.result
    }

    @Test("a free dose out at restart keeps its key in the header and in the body the server stores")
    func freeIntakeInFlightAtRestart() async throws {
        let container = try OutboxStore.makeInMemory()
        let before = WAFixture.queue(on: container)
        let stalled = WAStalledAPI()
        let live = Task {
            try await MedicationsRepository(api: stalled, outbox: before).logIntake(
                medicationId: "med-1",
                scheduledFor: nil,
                takenAt: WAFixture.takenAt,
                skipped: false
            )
        }
        await stalled.requestLeft()
        let left = try #require(stalled.log.all.first)

        let after = WAFixture.queue(on: container)
        let bodies = Mutex<[String]>([])
        let wire = WAWireLog()
        MockURLProtocol.install { req in
            wire.record(req)
            bodies.withLock { $0.append(String(bytes: req.waBody, encoding: .utf8) ?? "") }
            return WAFixture.reply(req, 201, WAFixture.intakeLogged)
        }
        let replay = WAFixture.replay(outbox: after)
        await replay.runOnce()
        await replay.runOnce()

        #expect(wire.all == [WAWireCall(method: "POST", path: "/api/medications/med-1/intake", key: left.key)])
        let body = try #require(bodies.withLock { $0 }.first)
        #expect(body.contains(left.key), "the stored key is what makes a second delivery the same dose")
        #expect(await after.snapshot.isEmpty)

        live.cancel()
        _ = await live.result
    }

    @Test("a dose the server answered leaves nothing for a restart to send again")
    func landedIntakeLeavesNoRow() async throws {
        let container = try OutboxStore.makeInMemory()
        let before = WAFixture.queue(on: container)
        let wire = WAWireLog()
        MockURLProtocol.install { req in
            wire.record(req)
            return WAFixture.reply(req, 201, WAFixture.intakeLogged)
        }
        _ = try await MedicationsRepository(api: WAFixture.api(), outbox: before)
            .record(intake: "intake-1", status: .taken, takenAt: WAFixture.takenAt)

        let after = WAFixture.queue(on: container)
        #expect(await after.snapshot.isEmpty)
        await WAFixture.replay(outbox: after).runOnce()
        #expect(wire.all.count == 1, "one tap, one request")
    }

    // MARK: - A record the server only knows by its key

    @Test("a new record out at restart goes again under its key while the server still knows the key")
    func createInFlightInsideTheWindow() async throws {
        let container = try OutboxStore.makeInMemory()
        let before = WAFixture.queue(on: container)
        let stalled = WAStalledAPI()
        let body = allergy()
        let live = Task { try await AllergiesRepository(api: stalled, outbox: before).create(body) }
        await stalled.requestLeft()
        let left = try #require(stalled.log.all.first)

        let after = WAFixture.queue(on: container)
        let wire = WAWireLog()
        MockURLProtocol.install { req in
            wire.record(req)
            return WAFixture.reply(req, 201, WAFixture.allergyCreated)
        }
        let clock = C4Clock()
        let replay = WAFixture.replay(outbox: after, clock: clock)
        clock.advance(by: 3600)
        await replay.runOnce()
        await replay.runOnce()

        #expect(wire.all == [WAWireCall(method: "POST", path: "/api/allergies", key: left.key)])
        #expect(await after.snapshot.isEmpty)
        #expect(await after.deadLetterCount == 0)

        live.cancel()
        _ = await live.result
    }

    @Test("a new record out at restart is kept and shown, not sent blind, once the server has forgotten the key")
    func createInFlightPastTheWindow() async throws {
        let container = try OutboxStore.makeInMemory()
        let before = WAFixture.queue(on: container)
        let stalled = WAStalledAPI()
        let body = allergy()
        let live = Task { try await AllergiesRepository(api: stalled, outbox: before).create(body) }
        await stalled.requestLeft()

        let after = WAFixture.queue(on: container)
        let wire = WAWireLog()
        MockURLProtocol.install { req in
            wire.record(req)
            return WAFixture.reply(req, 201, WAFixture.allergyCreated)
        }
        let clock = C4Clock()
        let discards = C4Discards()
        let replay = WAFixture.replay(outbox: after, clock: clock, discards: discards)
        clock.advance(by: Self.window)
        await replay.runOnce()

        #expect(wire.all.isEmpty, "a second request now could be a second record")
        #expect(await after.deadLetterCount == 1, "retained for the user to decide")
        #expect(discards.all == [.init(kind: "createAllergy", reason: .responseUnreadable)])

        live.cancel()
        _ = await live.result
    }

    // MARK: - A send that failed while the process lived

    @Test("a record that never left the device is an ordinary queued row and still goes out a day later")
    func offlineCreateIsNotHeldToTheWindow() async throws {
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { WAFixture.owner })
        let offline = WAFailingAPI(error: .offline)
        await #expect(throws: HLError.offline) {
            _ = try await AllergiesRepository(api: offline, outbox: outbox).create(allergy())
        }
        let key = try #require(offline.log.all.first?.key)
        #expect(await outbox.snapshot.count == 1)

        let wire = WAWireLog()
        MockURLProtocol.install { req in
            wire.record(req)
            return WAFixture.reply(req, 201, WAFixture.allergyCreated)
        }
        let clock = C4Clock()
        let replay = WAFixture.replay(outbox: outbox, clock: clock)
        clock.advance(by: Self.window)
        await replay.runOnce()

        #expect(wire.all == [WAWireCall(method: "POST", path: "/api/allergies", key: key)])
        #expect(await outbox.snapshot.isEmpty)
    }

    @Test("a record whose request timed out may have landed, so it is not sent again past the window")
    func timedOutCreateIsHeldToTheWindow() async throws {
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { WAFixture.owner })
        let timeout = WAFailingAPI(error: .network(.timeout))
        await #expect(throws: HLError.network(.timeout)) {
            _ = try await AllergiesRepository(api: timeout, outbox: outbox).create(allergy())
        }
        #expect(await outbox.snapshot.count == 1)

        let wire = WAWireLog()
        MockURLProtocol.install { req in
            wire.record(req)
            return WAFixture.reply(req, 201, WAFixture.allergyCreated)
        }
        let clock = C4Clock()
        let discards = C4Discards()
        let replay = WAFixture.replay(outbox: outbox, clock: clock, discards: discards)
        clock.advance(by: Self.window)
        await replay.runOnce()

        #expect(wire.all.isEmpty)
        #expect(await outbox.deadLetterCount == 1)
        #expect(discards.all == [.init(kind: "createAllergy", reason: .responseUnreadable)])
    }

    @Test("a record whose request was cut off on the wire had left the device: it keeps its note and goes again under its key")
    func cutOffCreateInsideTheWindow() async throws {
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { WAFixture.owner })
        let cutOff = WAFailingAPI(error: .network(.writeCancelled))
        await #expect(throws: HLError.network(.writeCancelled)) {
            _ = try await AllergiesRepository(api: cutOff, outbox: outbox).create(allergy())
        }
        let key = try #require(cutOff.log.all.first?.key)
        let row = try #require(await outbox.snapshot.first)
        #expect(OutboxReplayService.unconfirmedSince(row.lastError) != nil, "the server may hold the record already")

        let wire = WAWireLog()
        MockURLProtocol.install { req in
            wire.record(req)
            return WAFixture.reply(req, 201, WAFixture.allergyCreated)
        }
        let clock = C4Clock()
        let replay = WAFixture.replay(outbox: outbox, clock: clock)
        clock.advance(by: 3600)
        await replay.runOnce()

        #expect(wire.all == [WAWireCall(method: "POST", path: "/api/allergies", key: key)])
        #expect(await outbox.snapshot.isEmpty)
        #expect(await outbox.deadLetterCount == 0)
    }

    @Test("a record whose request was cut off is kept and shown, not sent again, once the server has forgotten the key")
    func cutOffCreatePastTheWindow() async throws {
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { WAFixture.owner })
        let cutOff = WAFailingAPI(error: .network(.writeCancelled))
        await #expect(throws: HLError.network(.writeCancelled)) {
            _ = try await AllergiesRepository(api: cutOff, outbox: outbox).create(allergy())
        }
        #expect(await outbox.snapshot.count == 1)

        let wire = WAWireLog()
        MockURLProtocol.install { req in
            wire.record(req)
            return WAFixture.reply(req, 201, WAFixture.allergyCreated)
        }
        let clock = C4Clock()
        let discards = C4Discards()
        let replay = WAFixture.replay(outbox: outbox, clock: clock, discards: discards)
        clock.advance(by: OutboxReplayService.unconfirmedResendWindow)
        await replay.runOnce()

        #expect(wire.all.isEmpty, "a second request now could be a second record")
        #expect(await outbox.deadLetterCount == 1)
        #expect(discards.all == [.init(kind: "createAllergy", reason: .responseUnreadable)])
    }

    @Test("a dose whose request was cut off carries no note and still goes out, under its key, weeks later")
    func cutOffDoseGoesOutAtAnyAge() async throws {
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { WAFixture.owner })
        let cutOff = WAFailingAPI(error: .network(.writeCancelled))
        await #expect(throws: HLError.network(.writeCancelled)) {
            _ = try await MedicationsRepository(api: cutOff, outbox: outbox)
                .record(intake: "intake-1", status: .taken, takenAt: WAFixture.takenAt)
        }
        let key = try #require(cutOff.log.all.first?.key)
        let row = try #require(await outbox.snapshot.first)
        #expect(row.lastError == nil, "the server folds a dose by itself")

        let wire = WAWireLog()
        MockURLProtocol.install { req in
            wire.record(req)
            return WAFixture.reply(req, 201, WAFixture.intakeLogged)
        }
        let clock = C4Clock()
        let replay = WAFixture.replay(outbox: outbox, clock: clock)
        clock.advance(by: 21 * Self.window)
        await replay.runOnce()

        #expect(wire.all == [WAWireCall(method: "POST", path: "/api/medications/intake", key: key)])
        #expect(await outbox.snapshot.isEmpty)
        #expect(await outbox.deadLetterCount == 0)
    }

    // MARK: - While the first send is still running

    @Test("a row whose first send is running is not sent by a pass, not counted as waiting, and gone when the send is cancelled")
    func liveRowBelongsToItsSend() async throws {
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { WAFixture.owner })
        let stalled = WAStalledAPI()
        let live = Task {
            try await MedicationsRepository(api: stalled, outbox: outbox)
                .record(intake: "intake-1", status: .taken, takenAt: WAFixture.takenAt)
        }
        await stalled.requestLeft()

        let wire = WAWireLog()
        MockURLProtocol.install { req in
            wire.record(req)
            return WAFixture.reply(req, 201, WAFixture.intakeLogged)
        }
        await WAFixture.replay(outbox: outbox).runOnce()
        #expect(wire.all.isEmpty, "the pass would deliver the dose a second time")

        let rows = await outbox.snapshot
        #expect(rows.count == 1)
        #expect(await outbox.waitingCount(in: rows) == 0)

        live.cancel()
        let outcome = await live.result
        #expect(throws: (any Error).self) { try outcome.get() }
        #expect(await outbox.snapshot.isEmpty, "a cancelled send was never reported as queued")
    }
}
