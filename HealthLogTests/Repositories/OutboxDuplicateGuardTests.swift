import Foundation
@testable import HealthLog
import Synchronization
import Testing

// swiftlint:disable force_unwrapping

/// 1.4 (S2, S3, S5) — a write that may already be on the server never goes
/// out as a second record, and a superseded pass never retargets one.
///
/// * S2: "Erneut senden" keeps the `unconfirmed:since=` marker, so the 23-hour
///   window still counts from the first unconfirmed answer.
/// * S3: a timeout after the request went out is "sent, unconfirmed" like an
///   unreadable 2xx; no connection at all stays a plain retry.
/// * S5: the server id of a replayed create belongs to the pass that sent it.
///   A pass the watchdog superseded used to leave its id in a shared slot,
///   and the pass that replaced it remapped another entity onto it, so a
///   queued delete removed the wrong record.
///
/// Real `APIClient` over `MockURLProtocol`, allergy envelopes from server
/// v1.39.0 (`src/app/api/allergies/route.ts`), as in
/// `OutboxReplayInterruptionTests`.
@Suite(
    "S2, S3, S5 — unconfirmed writes keep their window, a superseded pass never remaps",
    .serialized,
    .isolatedSkipRegister,
    .mockURLSession
)
struct OutboxDuplicateGuardTests {
    static let owner = "account-a1"

    static func allergy(id: String) -> Data {
        Data(#"""
        {"data":{"id":"\#(id)","substance":"Penicillin","category":"MEDICATION","type":"ALLERGY",
        "severity":"SEVERE","status":"ACTIVE","onsetAt":null,"reaction":null,"note":null,
        "createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}}
        """#.utf8)
    }

    /// What a captive portal answers with a 200.
    static let captivePortal = Data("<html><body>Please sign in to the Wi-Fi</body></html>".utf8)

    /// `apiError("Too many writes, try again later", 429, { errorCode: "record_write.rate_limited" })`.
    static let recordWriteRefusal = Data(#"""
    {"data":null,"error":"Too many writes, try again later","meta":{"errorCode":"record_write.rate_limited"}}
    """#.utf8)

    static func reply(_ req: URLRequest, _ status: Int, _ body: Data?, contentType: String = "application/json")
        -> (HTTPURLResponse, Data?)
    {
        (
            HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": contentType])!,
            body
        )
    }

    private func makeReplay(outbox: OutboxQueue, clock: C4Clock, discards: C4Discards = C4Discards()) -> OutboxReplayService {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "1.4.0",
            buildNumber: "1"
        )
        let keychain = InMemoryKeychain()
        try? keychain.setString("bearer-a1", forKey: KeychainKey.authToken)
        try? keychain.setString(Self.owner, forKey: KeychainKey.userID)
        let api = APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock())
        return OutboxReplayService(
            outbox: outbox,
            measurementsRepo: MeasurementsRepository(api: api, outbox: outbox),
            moodRepo: MoodRepository(api: api, outbox: outbox),
            medicationsRepo: MedicationsRepository(api: api, outbox: outbox),
            allergiesRepo: AllergiesRepository(api: api, outbox: outbox),
            currentUserProvider: { Self.owner },
            attemptBackoff: 0,
            clock: { clock.now },
            onDiscarded: { notices in discards.add(notices) },
            runWatchdogTimeout: 600
        )
    }

    @discardableResult
    private func enqueue(
        _ outbox: OutboxQueue,
        _ kind: OutboxQueue.Operation.Kind,
        payload: some Encodable,
        key: String,
        entity: String,
        attempts: Int = 0,
        order: Int = 0
    ) async throws -> UUID {
        let op = try OutboxQueue.Operation(
            kind: kind,
            payload: JSONEncoder.hlDefault.encode(payload),
            idempotencyKey: key,
            createdAt: Date(timeIntervalSince1970: 1_790_000_000 + Double(order)),
            attempts: attempts,
            clientEntityId: entity
        )
        try await outbox.enqueue(op)
        return op.id
    }

    private func createAllergy(_ substance: String) -> OutboxQueue.Payloads.CreateAllergy {
        OutboxQueue.Payloads.CreateAllergy(body: AllergyCreate(substance: substance, category: .medication))
    }

    private static func marker(_ date: Date) -> String {
        "unconfirmed:since=\(Int(date.timeIntervalSince1970))"
    }

    // MARK: - S2: "Erneut senden" keeps the window

    @Test("Erneut senden gives an unconfirmed row its budget back and keeps its marker")
    func rearmKeepsTheUnconfirmedMarker() async throws {
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { Self.owner })
        let since = Self.marker(Date(timeIntervalSince1970: 1_790_000_000))
        let id = try await enqueue(
            outbox,
            .createAllergy,
            payload: createAllergy("Latex"),
            key: "s2-latex",
            entity: "optimistic-latex",
            attempts: 8
        )
        try await outbox.touchAttempt(id: id, lastError: since)
        let other = try await enqueue(
            outbox,
            .createAllergy,
            payload: createAllergy("Nuts"),
            key: "s2-nuts",
            entity: "optimistic-nuts",
            attempts: 8
        )
        try await outbox.touchAttempt(id: other, lastError: "Serverfehler")

        #expect(try await outbox.rearmHeld() == 2)

        let rows = await outbox.snapshot
        let unconfirmed = try #require(rows.first { $0.id == id })
        #expect(unconfirmed.attempts == 0)
        #expect(unconfirmed.lastAttemptAt == nil)
        #expect(unconfirmed.lastError == since, "the first unconfirmed answer still dates the window")
        #expect(rows.first { $0.id == other }?.lastError == nil, "any other note is cleared as before")
    }

    @Test("a re-armed unconfirmed row goes out inside the window and never after it")
    func rearmedRowRespectsTheFirstWindow() async throws {
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { Self.owner })
        let clock = C4Clock()
        let discards = C4Discards()
        let id = try await enqueue(
            outbox,
            .createAllergy,
            payload: createAllergy("Latex"),
            key: "s2-latex",
            entity: "optimistic-latex",
            attempts: 8
        )
        try await outbox.touchAttempt(id: id, lastError: Self.marker(clock.now))
        let requests = Mutex<[String]>([])
        MockURLProtocol.install { req in
            requests.withLock { $0.append(req.value(forHTTPHeaderField: "Idempotency-Key") ?? "") }
            return Self.reply(req, 200, Self.captivePortal, contentType: "text/html")
        }
        let replay = makeReplay(outbox: outbox, clock: clock, discards: discards)

        // The person taps "Erneut senden" an hour later; the answer is
        // unreadable again.
        #expect(try await outbox.rearmHeld() == 1)
        clock.advance(by: 3600)
        await replay.runOnce()
        let sent = requests.withLock { $0 }
        #expect(!sent.isEmpty)
        #expect(Set(sent) == ["s2-latex"], "the same idempotency key")

        // 23.5 hours after the FIRST unconfirmed answer the server's cache is
        // about to forget the key: the row is retained, not sent.
        clock.advance(by: 22.5 * 3600)
        await replay.runOnce()
        #expect(requests.withLock { $0 } == sent, "no send past the first window")
        #expect(await outbox.deadLetterCount == 1)
        #expect(discards.all == [.init(kind: "createAllergy", reason: .responseUnreadable)])
    }

    // MARK: - S3: a timeout after sending is unconfirmed

    @Test("a timeout on a sent write is unconfirmed: re-sent under its key inside the window, never after")
    func timeoutIsUnconfirmed() async throws {
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { Self.owner })
        let clock = C4Clock()
        let discards = C4Discards()
        let first = clock.now
        try await enqueue(outbox, .createAllergy, payload: createAllergy("Penicillin"), key: "s3-timeout", entity: "optimistic-p")
        let requests = Mutex(0)
        MockURLProtocol.install { _ in
            requests.withLock { $0 += 1 }
            throw URLError(.timedOut)
        }
        let replay = makeReplay(outbox: outbox, clock: clock, discards: discards)

        await replay.runOnce()
        let row = try #require(await outbox.snapshot.first)
        #expect(row.lastError == Self.marker(first), "dated by the first timeout")
        #expect(row.attempts == 0, "still the network's fault, not counted (W1)")

        // Inside the window it goes out again, and the window keeps its start.
        clock.advance(by: 2 * 3600)
        let beforeSecond = requests.withLock { $0 }
        await replay.runOnce()
        #expect(requests.withLock { $0 } > beforeSecond)
        #expect(await outbox.snapshot.first?.lastError == Self.marker(first))

        // Past it the row is retained, never sent blind.
        clock.advance(by: 21.5 * 3600)
        let beforeThird = requests.withLock { $0 }
        await replay.runOnce()
        #expect(requests.withLock { $0 } == beforeThird)
        #expect(await outbox.deadLetterCount == 1)
        #expect(discards.all == [.init(kind: "createAllergy", reason: .responseUnreadable)])
    }

    /// B5 (1.4, from A1) — `URLError.networkConnectionLost` was mapped to
    /// `.offline` together with "no network", so a write cut off on the wire
    /// after it went out never reached the window above.
    @Test("a connection lost on the wire after sending is unconfirmed, like a timeout")
    func connectionLostIsUnconfirmed() async throws {
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { Self.owner })
        let clock = C4Clock()
        let first = clock.now
        try await enqueue(outbox, .createAllergy, payload: createAllergy("Penicillin"), key: "b5-lost", entity: "optimistic-p")
        MockURLProtocol.install { _ in throw URLError(.networkConnectionLost) }
        let replay = makeReplay(outbox: outbox, clock: clock)

        await replay.runOnce()
        let row = try #require(await outbox.snapshot.first)
        #expect(row.lastError == Self.marker(first), "dated by the first lost connection")
        #expect(row.attempts == 0, "still the network's fault, not counted (W1)")
    }

    @Test("no connection at all sent nothing: a plain retry without a window")
    func offlineKeepsThePlainRetry() async throws {
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { Self.owner })
        let clock = C4Clock()
        try await enqueue(outbox, .createAllergy, payload: createAllergy("Penicillin"), key: "s3-offline", entity: "optimistic-p")
        let requests = Mutex(0)
        MockURLProtocol.install { _ in
            requests.withLock { $0 += 1 }
            throw URLError(.notConnectedToInternet)
        }
        let replay = makeReplay(outbox: outbox, clock: clock)

        await replay.runOnce()
        let row = try #require(await outbox.snapshot.first)
        #expect(OutboxReplayService.unconfirmedSince(row.lastError) == nil)

        clock.advance(by: 30 * 3600)
        let before = requests.withLock { $0 }
        await replay.runOnce()
        #expect(requests.withLock { $0 } > before, "still sent a day later")
        #expect(await outbox.deadLetterCount == 0)
    }

    // MARK: - S5: a superseded pass never remaps

    /// The first call of each pause waits until the test releases it.
    actor PauseGate {
        private var waiting: [Int: CheckedContinuation<Void, Never>] = [:]
        private(set) var count = 0

        func pause() async {
            count += 1
            let index = count
            await withCheckedContinuation { waiting[index] = $0 }
        }

        func release(_ index: Int) {
            waiting.removeValue(forKey: index)?.resume()
        }
    }

    private func waitForPauses(_ gate: PauseGate, _ expected: Int) async throws {
        for _ in 0 ..< 2000 {
            if await gate.count >= expected { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("the replay never reached pause \(expected)")
    }

    @Test("a create that lands in a superseded pass cannot retarget another entity's delete")
    func supersededPassNeverRemaps() async throws {
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { Self.owner })
        let clock = C4Clock()
        // Two allergies created offline; the second was then edited and
        // deleted, still offline.
        try await enqueue(outbox, .createAllergy, payload: createAllergy("A"), key: "s5-create-a", entity: "optimistic-a", order: 1)
        try await enqueue(outbox, .createAllergy, payload: createAllergy("Y"), key: "s5-create-y", entity: "optimistic-y", order: 2)
        try await enqueue(
            outbox,
            .updateAllergy,
            payload: OutboxQueue.Payloads.UpdateAllergy(id: "optimistic-y", patch: AllergyPatch(note: .clear)),
            key: "s5-update-y",
            entity: "optimistic-y",
            order: 3
        )
        try await enqueue(
            outbox,
            .deleteAllergy,
            payload: OutboxQueue.Payloads.DeleteAllergy(id: "optimistic-y"),
            key: "s5-delete-y",
            entity: "optimistic-y",
            order: 4
        )

        // Phase 0: the first pass's create of A meets a 429 and pauses.
        // Phase 1: the pass that replaces it creates A and Y, then pauses on
        // Y's edit. Phase 2: everything is answered.
        let phase = Mutex(0)
        let deletes = Mutex<[String]>([])
        MockURLProtocol.install { req in
            let current = phase.withLock { $0 }
            let path = req.url?.path ?? ""
            switch (req.httpMethod ?? "", req.value(forHTTPHeaderField: "Idempotency-Key") ?? "") {
            case ("POST", "s5-create-a"):
                return current == 0 ? Self.reply(req, 429, Self.recordWriteRefusal) : Self.reply(req, 201, Self.allergy(id: "srv-a"))
            case ("POST", "s5-create-y"):
                return Self.reply(req, 201, Self.allergy(id: "srv-y"))
            case ("PATCH", _):
                return current == 1 ? Self.reply(req, 429, Self.recordWriteRefusal) : Self.reply(req, 200, Self.allergy(id: "srv-y"))
            case ("DELETE", _):
                deletes.withLock { $0.append(path) }
                return Self.reply(req, 200, Data(#"{"data":{"deleted":true}}"#.utf8))
            default:
                return Self.reply(req, 500, nil)
            }
        }
        let replay = makeReplay(outbox: outbox, clock: clock)
        let gate = PauseGate()
        let pause: @Sendable (TimeInterval) async throws -> Void = { _ in await gate.pause() }

        try await OutboxReplayPause.$sleep.withValue(pause) {
            let stale = Task { await replay.runOnce() }
            try await waitForPauses(gate, 1)

            // Past the watchdog timeout a trigger starts the pass that
            // replaces the paused one.
            phase.withLock { $0 = 1 }
            clock.advance(by: 601)
            let current = Task { await replay.runOnce() }
            try await waitForPauses(gate, 2)

            // The stale pass's create of A lands while the current pass waits
            // on Y's edit.
            phase.withLock { $0 = 2 }
            await gate.release(1)
            await stale.value
            await gate.release(2)
            await current.value
        }

        #expect(deletes.withLock { $0 } == ["/api/allergies/srv-y"], "Y's delete reaches Y, never A")
        #expect(await outbox.snapshot.isEmpty)
        #expect(await outbox.deadLetterCount == 0)
    }
}

// swiftlint:enable force_unwrapping
