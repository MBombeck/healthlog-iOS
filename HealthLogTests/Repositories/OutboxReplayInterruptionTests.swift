import Foundation
@testable import HealthLog
import Synchronization
import Testing

// swiftlint:disable force_unwrapping

/// C4 — the outbox replay never loses a write to an answer that is not a
/// refusal.
///
/// Before C4 every error that was neither `shouldPersistToOutbox` nor a
/// decoding error of our own payload reached `onNonRetriable`, which deleted
/// the row. That included a cancelled request (`URLError.cancelled` →
/// `HLError.canceled`, or a raw `CancellationError` out of `APIClient`'s
/// back-off sleep) — exactly what a background window closing or an app
/// suspend produces while a row is on the wire — and a 2xx whose body could
/// not be read, where the write may well have landed.
///
/// The contract now, per failure class:
///
/// * cancellation: row untouched (no attempt, no stamp), the pass ends;
/// * timeout / 5xx: row kept, one attempt counted (unchanged);
/// * a refusal the server names (4xx): never deleted when the data would be
///   gone — the row is dead-lettered (retained, visible, not re-sent); a
///   delete, which carries nothing to lose, still drains;
/// * an unreadable 2xx: "sent, unconfirmed" — kept and re-sent under the same
///   idempotency key only inside the server's 24 h replay window, then
///   dead-lettered, never sent blind.
///
/// Real `APIClient` over `MockURLProtocol` (`.mockURLSession`). Envelopes from
/// server v1.39.0: `src/app/api/allergies/route.ts` (`returnAllZodIssues`,
/// `errorCode: "allergy.invalid"`), `src/lib/idempotency.ts` (24 h TTL).
@Suite(
    "Outbox replay — cancellation and unconfirmed writes are never a discard (C4)",
    .serialized,
    .isolatedSkipRegister,
    .mockURLSession
)
struct OutboxReplayInterruptionTests {
    static let owner = "account-c4"

    // MARK: - Fixtures (server v1.39.0)

    static let allergyInvalid = Data(#"""
    {"data":null,"error":"Validation failed","details":{"issues":[{"path":["substance"],"message":"Required","code":"invalid_type"}]},"meta":{"errorCode":"allergy.invalid"}}
    """#.utf8)

    static let allergyCreated = Data(#"""
    {"data":{"id":"srv-a-1","substance":"Penicillin","category":"MEDICATION","type":"ALLERGY",
    "severity":"SEVERE","status":"ACTIVE","onsetAt":null,"reaction":null,"note":null,
    "createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}}
    """#.utf8)

    /// What a captive portal (or a proxy error page) answers with a 200.
    static let captivePortal = Data("<html><body>Please sign in to the Wi-Fi</body></html>".utf8)

    static func reply(_ req: URLRequest, _ status: Int, _ body: Data?, headers: [String: String]? = nil)
        -> (HTTPURLResponse, Data?)
    {
        let fields = headers ?? ["Content-Type": "application/json"]
        return (HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: fields)!, body)
    }

    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "1.1.0",
            buildNumber: "281"
        )
        let keychain = InMemoryKeychain()
        try? keychain.setString("bearer-c4", forKey: KeychainKey.authToken)
        try? keychain.setString(Self.owner, forKey: KeychainKey.userID)
        return APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock())
    }

    private func makeReplay(
        outbox: OutboxQueue,
        clock: C4Clock = C4Clock(),
        maxAttempts: Int = 8,
        deadLetterMinAge: TimeInterval = 7 * 86400,
        discards: C4Discards = C4Discards()
    ) -> OutboxReplayService {
        let api = makeAPI()
        return OutboxReplayService(
            outbox: outbox,
            measurementsRepo: MeasurementsRepository(api: api, outbox: outbox),
            moodRepo: MoodRepository(api: api, outbox: outbox),
            medicationsRepo: MedicationsRepository(api: api, outbox: outbox),
            allergiesRepo: AllergiesRepository(api: api, outbox: outbox),
            currentUserProvider: { Self.owner },
            maxAttempts: maxAttempts,
            deadLetterMinAge: deadLetterMinAge,
            attemptBackoff: 0,
            clock: { clock.now },
            onDiscarded: { notices in discards.add(notices) }
        )
    }

    private func enqueueAllergy(_ outbox: OutboxQueue, _ substance: String, attempts: Int = 0) async throws {
        try await outbox.enqueue(.init(
            kind: .createAllergy,
            payload: JSONEncoder.hlDefault.encode(
                OutboxQueue.Payloads.CreateAllergy(body: AllergyCreate(substance: substance, category: .medication))
            ),
            idempotencyKey: "c4-\(substance)",
            attempts: attempts,
            clientEntityId: "optimistic-\(substance)"
        ))
    }

    private func enqueueIntake(_ outbox: OutboxQueue) async throws {
        let body = MedicationsRepository.IntakeUpdate(
            intakeId: "intake-c4",
            status: "TAKEN",
            takenAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
        try await outbox.enqueue(.init(
            kind: .takeMedication,
            payload: JSONEncoder.hlDefault.encode(body),
            idempotencyKey: "c4-intake"
        ))
    }

    private func enqueueHealthKitPage(_ outbox: OutboxQueue) async throws {
        try await outbox.enqueueHealthKitBatch(
            [HealthKitBatchEntryDTO(
                hkIdentifier: "HKQuantityTypeIdentifierHeartRate",
                value: 62,
                unit: "count/min",
                startDate: Date(timeIntervalSince1970: 1_790_000_000),
                endDate: Date(timeIntervalSince1970: 1_790_000_000),
                externalId: "hr-c4"
            )],
            encoder: .hlBatch,
            idempotencyKey: "c4-hk-page",
            requiringCurrentOwner: Self.owner
        )
    }

    // MARK: - Cancellation

    @Test("a medication intake whose request is cancelled stays queued, uncounted, and the pass ends")
    func cancelledIntakeStaysQueued() async throws {
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { Self.owner })
        try await enqueueIntake(outbox)
        try await enqueueAllergy(outbox, "Latex")
        let requests = Mutex(0)
        MockURLProtocol.install { _ in
            requests.withLock { $0 += 1 }
            throw URLError(.cancelled)
        }
        let discards = C4Discards()

        await makeReplay(outbox: outbox, discards: discards).runOnce()

        let rows = await outbox.snapshot
        #expect(rows.map(\.kind) == [.takeMedication, .createAllergy], "no row lost, order kept")
        #expect(rows.allSatisfy { $0.attempts == 0 }, "a cancellation is not an attempt")
        #expect(rows.allSatisfy { $0.lastAttemptAt == nil }, "not even stamped")
        #expect(requests.withLock { $0 } == 1, "the pass ends at the cancellation — nothing else goes out")
        #expect(discards.all.isEmpty, "a cancellation is never a discard")
        #expect(await outbox.deadLetterCount == 0)
    }

    @Test("cancelling the replay task mid-request (a background window closing) keeps the row")
    func cancelledTaskKeepsTheRow() async throws {
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { Self.owner })
        try await enqueueAllergy(outbox, "Penicillin")
        let reached = Mutex(false)
        // A 503 sends `APIClient` into its back-off sleep; the task is cancelled
        // there, so the error that surfaces is a raw `CancellationError` (or,
        // if the cancel lands on the wire, `URLError.cancelled`).
        MockURLProtocol.install { req in
            reached.withLock { $0 = true }
            return Self.reply(req, 503, Data(#"{"data":null,"error":"unavailable"}"#.utf8))
        }
        let discards = C4Discards()
        let replay = makeReplay(outbox: outbox, discards: discards)

        let pass = Task { await replay.runOnce() }
        while !reached.withLock({ $0 }) {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        pass.cancel()
        await pass.value

        let row = try #require(await outbox.snapshot.first)
        #expect(row.kind == .createAllergy)
        #expect(row.attempts == 0)
        #expect(row.lastAttemptAt == nil)
        #expect(discards.all.isEmpty)
        #expect(await outbox.deadLetterCount == 0)
    }

    @Test("a HealthKit page whose replay is cancelled stays in the outbox, not in the register")
    func cancelledHealthKitPageStaysQueued() async throws {
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { Self.owner })
        try await enqueueHealthKitPage(outbox)
        MockURLProtocol.install { _ in throw URLError(.cancelled) }

        // One attempt of budget and no minimum age: a single COUNTED failure
        // would move the page into the register at the end of this pass.
        await makeReplay(outbox: outbox, maxAttempts: 1, deadLetterMinAge: 0).runOnce()

        let row = try #require(await outbox.snapshot.first)
        #expect(row.kind == .syncHealthKitSample)
        #expect(row.attempts == 0)
        #expect(await HealthKitSkippedRowRegister.current.count(ownerID: Self.owner) == 0)
        #expect(await outbox.deadLetterCount == 0)
    }

    // MARK: - Transient failures stay what they were

    @Test("a timeout or a 5xx keeps the row and counts one attempt", arguments: ["timeout", "503"])
    func transientFailureKeepsTheRowCounted(_ failure: String) async throws {
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { Self.owner })
        try await enqueueAllergy(outbox, "Penicillin")
        MockURLProtocol.install { req in
            if failure == "timeout" { throw URLError(.timedOut) }
            return Self.reply(req, 503, Data(#"{"data":null,"error":"unavailable"}"#.utf8))
        }
        let discards = C4Discards()

        await makeReplay(outbox: outbox, discards: discards).runOnce()

        let row = try #require(await outbox.snapshot.first)
        #expect(row.attempts == 1)
        #expect(discards.all.isEmpty)
        #expect(await outbox.deadLetterCount == 0)
    }

    // MARK: - A refusal the server names

    @Test("a named 422 on a create is retained as a visible dead-letter, not deleted, and not re-sent")
    func namedRefusalIsRetained() async throws {
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { Self.owner })
        try await enqueueAllergy(outbox, "Penicillin")
        let requests = Mutex(0)
        MockURLProtocol.install { req in
            requests.withLock { $0 += 1 }
            return Self.reply(req, 422, Self.allergyInvalid)
        }
        let discards = C4Discards()
        let replay = makeReplay(outbox: outbox, discards: discards)

        await replay.runOnce()

        #expect(await outbox.snapshot.isEmpty, "out of the live queue")
        #expect(await outbox.deadLetterCount == 1, "but the write is retained")
        #expect(discards.all == [.init(kind: "createAllergy", reason: .serverRejected)])
        await replay.runOnce()
        #expect(requests.withLock { $0 } == 1, "never re-sent")
    }

    @Test("a refused delete carries nothing to lose and still drains")
    func refusedDeleteDrains() async throws {
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { Self.owner })
        try await outbox.enqueue(.init(
            kind: .deleteAllergy,
            payload: JSONEncoder.hlDefault.encode(OutboxQueue.Payloads.DeleteAllergy(id: "srv-gone")),
            idempotencyKey: "c4-delete"
        ))
        MockURLProtocol.install { req in
            Self.reply(req, 404, Data(#"{"data":null,"error":"Not found"}"#.utf8))
        }
        let discards = C4Discards()

        await makeReplay(outbox: outbox, discards: discards).runOnce()

        #expect(await outbox.snapshot.isEmpty)
        #expect(await outbox.deadLetterCount == 0)
        #expect(discards.all.first?.reason == .serverRejected)
    }

    // MARK: - Sent, unconfirmed

    @Test("an unreadable 2xx keeps the row and re-sends it under the same key, which the server answers once")
    func unreadableResponseIsResentUnderTheSameKey() async throws {
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { Self.owner })
        try await enqueueAllergy(outbox, "Penicillin")
        let keys = Mutex<[String]>([])
        MockURLProtocol.install { req in
            let count = keys.withLock { list in
                list.append(req.value(forHTTPHeaderField: "Idempotency-Key") ?? "")
                return list.count
            }
            if count == 1 { return Self.reply(req, 200, Self.captivePortal, headers: ["Content-Type": "text/html"]) }
            // `src/lib/idempotency.ts` — the same key inside 24 h answers the
            // first request's response, no second side effect.
            return Self.reply(req, 201, Self.allergyCreated, headers: [
                "Content-Type": "application/json", "X-Idempotent-Replay": "true"
            ])
        }
        let clock = C4Clock()
        let discards = C4Discards()
        let replay = makeReplay(outbox: outbox, clock: clock, discards: discards)

        await replay.runOnce()
        let row = try #require(await outbox.snapshot.first, "the write may have landed — it is not deleted")
        #expect(row.attempts == 1)
        #expect(discards.all.isEmpty)

        clock.advance(by: 3600)
        await replay.runOnce()
        #expect(await outbox.snapshot.isEmpty)
        #expect(await outbox.deadLetterCount == 0)
        #expect(keys.withLock { $0 } == ["c4-Penicillin", "c4-Penicillin"], "exactly one re-send, same key")
        #expect(discards.all.isEmpty)
    }

    @Test("an unconfirmed write is never re-sent once the server's idempotency window has run out")
    func unconfirmedWriteStopsAtTheWindow() async throws {
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { Self.owner })
        try await enqueueAllergy(outbox, "Penicillin")
        let requests = Mutex(0)
        MockURLProtocol.install { req in
            requests.withLock { $0 += 1 }
            return Self.reply(req, 200, Self.captivePortal, headers: ["Content-Type": "text/html"])
        }
        let clock = C4Clock()
        let discards = C4Discards()
        let replay = makeReplay(outbox: outbox, clock: clock, discards: discards)

        await replay.runOnce()
        #expect(requests.withLock { $0 } == 1)

        clock.advance(by: 23.5 * 3600)
        await replay.runOnce()
        #expect(requests.withLock { $0 } == 1, "a re-send now could be a second record")
        #expect(await outbox.snapshot.isEmpty)
        #expect(await outbox.deadLetterCount == 1, "retained, recoverable")
        #expect(discards.all == [.init(kind: "createAllergy", reason: .responseUnreadable)])

        clock.advance(by: 3600)
        await replay.runOnce()
        #expect(requests.withLock { $0 } == 1)
        #expect(discards.all.count == 1, "reported once")
    }

    @Test("a timeout in between does not restart the window of an unconfirmed write")
    func windowSurvivesALaterTransientFailure() async throws {
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { Self.owner })
        try await enqueueAllergy(outbox, "Penicillin")
        let requests = Mutex(0)
        let timesOut = Mutex(false)
        MockURLProtocol.install { req in
            requests.withLock { $0 += 1 }
            if timesOut.withLock({ $0 }) { throw URLError(.timedOut) }
            return Self.reply(req, 200, Self.captivePortal, headers: ["Content-Type": "text/html"])
        }
        let clock = C4Clock()
        let discards = C4Discards()
        let replay = makeReplay(outbox: outbox, clock: clock, discards: discards)

        await replay.runOnce() // unconfirmed at t0
        clock.advance(by: 2 * 3600)
        timesOut.withLock { $0 = true }
        await replay.runOnce() // a counted timeout at t0 + 2 h
        let sent = requests.withLock { $0 }
        #expect(await outbox.snapshot.first?.attempts == 2)

        clock.advance(by: 21.5 * 3600) // t0 + 23.5 h: past the window of the FIRST answer
        await replay.runOnce()
        #expect(requests.withLock { $0 } == sent, "measured from the first unconfirmed answer, not the timeout")
        #expect(await outbox.deadLetterCount == 1)
        #expect(discards.all == [.init(kind: "createAllergy", reason: .responseUnreadable)])
    }

    // MARK: - Update path (rows written by 280 / 281)

    @Test("a row a 1.1.0 build already counted keeps its attempts through a cancellation and then drains")
    func legacyRowDrainsAfterCancellation() async throws {
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { Self.owner })
        // Same on-disk shape 280/281 wrote; a prior transient failure left
        // attempts at 3 and a free-form `lastError`.
        try await enqueueAllergy(outbox, "Penicillin", attempts: 3)
        let row = try #require(await outbox.snapshot.first)
        try await outbox.touchAttempt(id: row.id, lastError: "Netzwerk-Fehler: timeout")
        let cancelled = Mutex(true)
        MockURLProtocol.install { req in
            if cancelled.withLock({ $0 }) { throw URLError(.cancelled) }
            return Self.reply(req, 201, Self.allergyCreated)
        }
        let clock = C4Clock()
        let replay = makeReplay(outbox: outbox, clock: clock)

        await replay.runOnce()
        #expect(await outbox.snapshot.first?.attempts == 3)

        cancelled.withLock { $0 = false }
        await replay.runOnce()
        #expect(await outbox.snapshot.isEmpty)
    }
}

/// C3 / C4 — the medication banner after a queued intake. `WriteOutcome.queued`
/// does not say why it was queued (offline, 429, 5xx, a sign-in refresh), so
/// the sentence must be true for every reason: no "when back online".
@Suite("Medication queued banner copy (C4)")
struct MedicationQueuedBannerCopyTests {
    @Test("the queued banner says saved and syncing by itself, in en and de, without claiming offline")
    func queuedBannerIsReasonNeutral() throws {
        for (language, saved) in [("en", "Saved"), ("de", "Gespeichert")] {
            let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
            let bundle = try #require(Bundle(path: path))
            let text = bundle.localizedString(forKey: "medication.quick_mark.queued", value: "MISSING", table: nil)
            #expect(text != "MISSING", "\(language): key missing")
            #expect(text.hasPrefix(saved))
            #expect(!text.localizedCaseInsensitiveContains("online"))
        }
    }
}

// MARK: - Test doubles

final class C4Clock: Sendable {
    private let value = Mutex(Date())
    var now: Date {
        value.withLock { $0 }
    }

    func advance(by seconds: TimeInterval) {
        value.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}

final class C4Discards: Sendable {
    private let list = Mutex<[OutboxDiscardNotice]>([])
    var all: [OutboxDiscardNotice] {
        list.withLock { $0 }
    }

    func add(_ notices: [OutboxDiscardNotice]) {
        list.withLock { $0.append(contentsOf: notices) }
    }
}

// swiftlint:enable force_unwrapping
