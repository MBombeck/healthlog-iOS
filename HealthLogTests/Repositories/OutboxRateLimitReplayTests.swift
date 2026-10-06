import Foundation
@testable import HealthLog
import Synchronization
import Testing

// swiftlint:disable force_unwrapping

/// #110 — the outbox replay against the v1.39.0 rate limits.
///
/// The per-record creates share one per-account bucket (300 per 60 s) and are
/// refused as 429 with `meta.errorCode == "record_write.rate_limited"`; the batch
/// routes answer their own 429 without a code. Both carry `Retry-After`. A 429
/// is "not yet", never "no": the row keeps its attempt budget, its place and
/// its payload, the pass sits the named wait out (or holds the queue until the
/// named instant) and then carries on with the same row.
///
/// Real `APIClient` over `MockURLProtocol`, response shapes from
/// `src/app/api/allergies/route.ts` and `src/app/api/measurements/batch/route.ts`
/// at v1.39.0 (headers from `rateLimitResponseHeaders`).
@Suite("Outbox replay — 429 is transient (#110)", .serialized, .isolatedSkipRegister, .mockURLSession)
struct OutboxRateLimitReplayTests {
    static let owner = "account-c3"

    // MARK: - Fixtures (server v1.39.0)

    /// `apiError("Too many writes, try again later", 429, { errorCode: "record_write.rate_limited" })`.
    static let recordWriteRefusal = Data(#"""
    {"data":null,"error":"Too many writes, try again later","meta":{"errorCode":"record_write.rate_limited"}}
    """#.utf8)

    /// `apiError("Too many batch submissions, try again later", 429)` — no code.
    static let batchRefusal = Data(#"""
    {"data":null,"error":"Too many batch submissions, try again later"}
    """#.utf8)

    static let allergyCreated = Data(#"""
    {"data":{"id":"srv-a-1","substance":"Penicillin","category":"MEDICATION","type":"ALLERGY",
    "severity":"SEVERE","status":"ACTIVE","onsetAt":null,"reaction":null,"note":null,
    "createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}}
    """#.utf8)

    /// The four headers `rateLimitResponseHeaders` emits for a refused bucket.
    static func limiterHeaders(retryAfter: Int, now: Date = Date()) -> [String: String] {
        [
            "Content-Type": "application/json",
            "Retry-After": String(retryAfter),
            "X-RateLimit-Limit": "300",
            "X-RateLimit-Remaining": "0",
            "X-RateLimit-Reset": ISO8601DateFormatter().string(from: now.addingTimeInterval(TimeInterval(retryAfter)))
        ]
    }

    static func reply(_ req: URLRequest, _ status: Int, _ body: Data, headers: [String: String]? = nil)
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
        try? keychain.setString("bearer-c3", forKey: KeychainKey.authToken)
        try? keychain.setString(Self.owner, forKey: KeychainKey.userID)
        return APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock())
    }

    private func makeReplay(
        outbox: OutboxQueue,
        clock: ReplayClock = ReplayClock(),
        maxAttempts: Int = 8,
        deadLetterMinAge: TimeInterval = 7 * 86400,
        discards: DiscardRecorder = DiscardRecorder()
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

    private func enqueueAllergy(_ outbox: OutboxQueue, _ substance: String) async throws {
        try await outbox.enqueue(.init(
            kind: .createAllergy,
            payload: JSONEncoder.hlDefault.encode(
                OutboxQueue.Payloads.CreateAllergy(body: AllergyCreate(substance: substance, category: .medication))
            ),
            idempotencyKey: "c3-\(substance)",
            clientEntityId: "optimistic-\(substance)"
        ))
    }

    // MARK: - A wait inside the pass is sat out, then the same row goes again

    @Test("record_write 429 with Retry-After pauses the pass, re-sends the same row, and drains the queue uncounted")
    func shortWaitPausesAndResumes() async throws {
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { Self.owner })
        try await enqueueAllergy(outbox, "Penicillin")
        try await enqueueAllergy(outbox, "Latex")
        let requests = Mutex<[String]>([])
        // The first request and APIClient's three in-request retries all meet
        // the ceiling; the fifth — the replay's own re-send after its pause —
        // lands.
        MockURLProtocol.install { req in
            let count = requests.withLock { list in
                list.append(req.value(forHTTPHeaderField: "Idempotency-Key") ?? "")
                return list.count
            }
            if count <= 4 {
                return Self.reply(req, 429, Self.recordWriteRefusal, headers: Self.limiterHeaders(retryAfter: 1))
            }
            return Self.reply(req, 201, Self.allergyCreated)
        }
        let pauses = PauseRecorder()
        let discards = DiscardRecorder()

        await OutboxReplayPause.$sleep.withValue(pauses.sleeper()) {
            await makeReplay(outbox: outbox, discards: discards).runOnce()
        }

        #expect(pauses.recorded == [1], "paused for exactly the server's Retry-After")
        #expect(await outbox.snapshot.isEmpty, "both rows delivered in the same pass")
        #expect(await outbox.deadLetterCount == 0)
        #expect(discards.all.isEmpty, "a 429 is never a discard")
        let keys = requests.withLock { $0 }
        #expect(keys.prefix(5).allSatisfy { $0 == "c3-Penicillin" }, "the rate-limited row goes again before any other")
        #expect(keys.last == "c3-Latex")
    }

    // MARK: - A wait beyond the pass holds the queue, nothing counted

    @Test("a wait the pass cannot absorb holds the whole queue until the named instant, attempts untouched")
    func longWaitHoldsTheQueue() async throws {
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { Self.owner })
        try await enqueueAllergy(outbox, "Penicillin")
        try await enqueueAllergy(outbox, "Latex")
        let requests = Mutex(0)
        let serverOpen = Mutex(false)
        MockURLProtocol.install { req in
            requests.withLock { $0 += 1 }
            if serverOpen.withLock({ $0 }) { return Self.reply(req, 201, Self.allergyCreated) }
            return Self.reply(req, 429, Self.recordWriteRefusal, headers: Self.limiterHeaders(retryAfter: 120))
        }
        let clock = ReplayClock()
        let pauses = PauseRecorder()
        let replay = makeReplay(outbox: outbox, clock: clock)

        await OutboxReplayPause.$sleep.withValue(pauses.sleeper()) {
            await replay.runOnce()
        }
        #expect(requests.withLock { $0 } == 1, "one request, no in-request retry, no second row sent into the same wall")
        #expect(pauses.recorded.isEmpty, "120 s is beyond the pass's budget — no pause")
        let rows = await outbox.snapshot
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.attempts == 0 }, "the attempt budget is untouched")
        #expect(rows.allSatisfy { $0.lastAttemptAt == nil }, "not even stamped — the row keeps its place")
        #expect(await outbox.deadLetterCount == 0)

        clock.advance(by: 60)
        await replay.runOnce()
        #expect(requests.withLock { $0 } == 1, "inside the named wait nothing is sent")

        clock.advance(by: 61)
        serverOpen.withLock { $0 = true }
        await replay.runOnce()
        #expect(await outbox.snapshot.isEmpty, "after the wait the replay resumes with the same rows")
    }

    // MARK: - A HealthKit page never ages into the register on a 429

    @Test("a HealthKit page refused 429 without a code never reaches the skip register or the dead-letter lane")
    func healthKitPageStaysQueued() async throws {
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { Self.owner })
        try await outbox.enqueueHealthKitBatch(
            [HealthKitBatchEntryDTO(
                hkIdentifier: "HKQuantityTypeIdentifierStepCount",
                value: 4200,
                unit: "count",
                startDate: Date(timeIntervalSince1970: 1_790_000_000),
                endDate: Date(timeIntervalSince1970: 1_790_003_600),
                externalId: "steps-c3"
            )],
            encoder: .hlBatch,
            idempotencyKey: "c3-hk-page",
            requiringCurrentOwner: Self.owner
        )
        MockURLProtocol.install { req in
            Self.reply(req, 429, Self.batchRefusal, headers: Self.limiterHeaders(retryAfter: 120))
        }

        // A budget of one attempt and no minimum age: a single COUNTED failure
        // would move the page into the register at the end of this very pass.
        await makeReplay(outbox: outbox, maxAttempts: 1, deadLetterMinAge: 0).runOnce()

        let row = try #require(await outbox.snapshot.first)
        #expect(row.kind == .syncHealthKitSample)
        #expect(row.attempts == 0)
        #expect(await HealthKitSkippedRowRegister.current.count(ownerID: Self.owner) == 0)
        #expect(await outbox.deadLetterCount == 0)
    }

    // MARK: - A pause cut short is still a wait

    @Test("a pause that is cancelled keeps the row — it never falls through to the non-retriable delete")
    func cancelledPauseKeepsTheRow() async throws {
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { Self.owner })
        try await enqueueAllergy(outbox, "Penicillin")
        MockURLProtocol.install { req in
            Self.reply(req, 429, Self.recordWriteRefusal, headers: Self.limiterHeaders(retryAfter: 1))
        }
        let discards = DiscardRecorder()

        let cancelled: @Sendable (TimeInterval) async throws -> Void = { _ in throw CancellationError() }
        await OutboxReplayPause.$sleep.withValue(cancelled) {
            await makeReplay(outbox: outbox, discards: discards).runOnce()
        }

        let row = try #require(await outbox.snapshot.first)
        #expect(row.attempts == 0)
        #expect(discards.all.isEmpty)
    }
}

// MARK: - Test doubles

/// A pinned, advanceable clock for the replay.
private final class ReplayClock: Sendable {
    private let value = Mutex(Date())
    var now: Date {
        value.withLock { $0 }
    }

    func advance(by seconds: TimeInterval) {
        value.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}

/// Records every pause the replay asks for and returns at once.
private final class PauseRecorder: Sendable {
    private let list = Mutex<[TimeInterval]>([])
    var recorded: [TimeInterval] {
        list.withLock { $0 }
    }

    func sleeper() -> @Sendable (TimeInterval) async throws -> Void {
        { [self] seconds in list.withLock { $0.append(seconds) } }
    }
}

/// Collects the discard notices a pass publishes.
private final class DiscardRecorder: Sendable {
    private let list = Mutex<[OutboxDiscardNotice]>([])
    var all: [OutboxDiscardNotice] {
        list.withLock { $0 }
    }

    func add(_ notices: [OutboxDiscardNotice]) {
        list.withLock { $0.append(contentsOf: notices) }
    }
}

// swiftlint:enable force_unwrapping
