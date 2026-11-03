import Foundation
@testable import HealthLog
import os
import Testing

// swiftlint:disable force_unwrapping

/// A2 (1.4) — a queued HealthKit page on replay.
///
/// * Production, 1.3.0: 6 to 10 full 500-row pages a day reached the server
///   without a `syncTrigger`. They were outbox replays: the row kept the
///   entries, not the word they had been posted under, so the server's
///   diagnosis read "unknown" and a parked history page counted as a live
///   arrival.
/// * R3 S7: a whole-batch 422 that names no row (a server before v1.39.1
///   answers every schema failure that way) parked the page for good, 499
///   good rows held hostage by one bad one. The page is now halved until the
///   bad row stands alone; only it goes into the skip register.
@Suite("Outbox HealthKit replay: trigger and halving (A2)", .serialized, .mockURLSession)
struct OutboxHealthKitTriggerAndBisectionTests {
    static let owner = "account-a2"

    private static let env = AppEnvironment(
        baseURL: URL(string: "https://test.healthlog.local")!,
        bundleID: "dev.healthlog.app",
        appVersion: "1.4.0",
        buildNumber: "1"
    )

    /// A code-less 422, the way a server before v1.39.1 refused a schema
    /// failure (`apiValidationError` without `errorCode`).
    static let zodFailure = #"{"data":null,"error":"Validation failed"}"#

    static func accepted(_ count: Int) -> String {
        let entries = (0 ..< count).map { #"{"index":\#($0),"status":"inserted"}"# }.joined(separator: ",")
        return #"{"data":{"processed":\#(count),"inserted":\#(count),"duplicates":0,"skipped":[],"entries":[\#(entries)]},"error":null}"#
    }

    static func rows(_ count: Int, prefix: String = "row") -> [HealthKitBatchEntryDTO] {
        (0 ..< count).map { (index: Int) -> HealthKitBatchEntryDTO in
            let instant = Date(timeIntervalSince1970: 1_790_000_000 + Double(index) * 60)
            let value = 60 + Double(index % 40)
            return HealthKitBatchEntryDTO(
                hkIdentifier: "HKQuantityTypeIdentifierHeartRate",
                value: value,
                unit: "count/min",
                startDate: instant,
                endDate: instant,
                externalId: "\(prefix)-\(index)"
            )
        }
    }

    /// Every batch POST: its external ids, its key and its trigger.
    final class Wire: Sendable {
        struct Post: Sendable {
            let ids: [String]
            let key: String
            let syncTrigger: SyncTrigger?
            let hasTriggerKey: Bool
        }

        private let posts = OSAllocatedUnfairLock<[Post]>(initialState: [])

        func note(_ request: URLRequest) {
            let body = request.httpBody ?? request.httpBodyStream.map(Self.drain) ?? Data()
            let payload = try? JSONDecoder.hlDefault.decode(HealthKitBatchPayload.self, from: body)
            let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            let post = Post(
                ids: payload?.entries.map(\.externalId) ?? [],
                key: request.value(forHTTPHeaderField: "Idempotency-Key") ?? "",
                syncTrigger: payload?.syncTrigger,
                hasTriggerKey: object?["syncTrigger"] != nil
            )
            posts.withLock { $0.append(post) }
        }

        var all: [Post] {
            posts.withLock { $0 }
        }

        private static func drain(_ stream: InputStream) -> Data {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            return data
        }
    }

    /// A server that refuses, with a code-less 422, every batch that carries
    /// one of `bad`, and stores every other batch.
    static func install(refusing bad: Set<String>, wire: Wire) {
        MockURLProtocol.install { request in
            wire.note(request)
            let ids = wire.all.last?.ids ?? []
            let refused = ids.contains(where: bad.contains)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: refused ? 422 : 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data((refused ? zodFailure : accepted(ids.count)).utf8))
        }
    }

    static func makeReplay(outbox: OutboxQueue) -> OutboxReplayService {
        let keychain = InMemoryKeychain()
        try? keychain.setString("bearer-a2", forKey: KeychainKey.authToken)
        try? keychain.setString(owner, forKey: KeychainKey.userID)
        let api = APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock())
        return OutboxReplayService(
            outbox: outbox,
            measurementsRepo: MeasurementsRepository(api: api, outbox: outbox),
            moodRepo: MoodRepository(api: api, outbox: outbox),
            medicationsRepo: MedicationsRepository(api: api, outbox: outbox),
            currentUserProvider: { owner },
            maxAttempts: 8,
            attemptBackoff: 0
        )
    }

    // MARK: - The trigger travels with the row

    @Test("a parked page keeps its syncTrigger, and the replay sends it under the persisted key")
    func parkedPageKeepsItsTrigger() async throws {
        let wire = Wire()
        Self.install(refusing: [], wire: wire)
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { Self.owner })
        let key = "a2-\(UUID().uuidString)"
        try await outbox.enqueueHealthKitBatch(
            Self.rows(3),
            encoder: .hlBatch,
            idempotencyKey: key,
            syncTrigger: .backfill,
            requiringCurrentOwner: Self.owner
        )
        let stored = try #require(await outbox.snapshot.first)
        #expect(try JSONDecoder.hlDefault.decode(HealthKitBatchPayload.self, from: stored.payload).syncTrigger == .backfill)

        await Self.makeReplay(outbox: outbox).runOnce()

        #expect(wire.all.map(\.syncTrigger) == [.backfill])
        #expect(wire.all.map(\.key) == [key])
        #expect(await outbox.snapshot.isEmpty)
    }

    @Test("update path: a row parked by 1.3.0 has no trigger and replays byte for byte as before")
    func legacyRowReplaysWithoutTrigger() async throws {
        let wire = Wire()
        Self.install(refusing: [], wire: wire)
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { Self.owner })
        let key = "a2-legacy-\(UUID().uuidString)"
        // Exactly what 1.3.0 wrote: the entries, no `syncTrigger` key.
        try await outbox.enqueueHealthKitBatch(
            Self.rows(2),
            encoder: .hlBatch,
            idempotencyKey: key,
            requiringCurrentOwner: Self.owner
        )
        let stored = try #require(await outbox.snapshot.first)
        let object = try #require(try JSONSerialization.jsonObject(with: stored.payload) as? [String: Any])
        #expect(object["syncTrigger"] == nil)

        await Self.makeReplay(outbox: outbox).runOnce()

        let post = try #require(wire.all.first)
        #expect(!post.hasTriggerKey)
        #expect(post.key == key)
        #expect(await outbox.snapshot.isEmpty)
    }

    // MARK: - Halving a 422 that names no row (S7)

    @Test("one bad row: the page is halved until it stands alone; only it is registered, the rest delivered")
    func halvingIsolatesTheBadRow() async throws {
        let wire = Wire()
        Self.install(refusing: ["row-5"], wire: wire)
        let register = HealthKitSkippedRowRegister(storage: SkipRegisterBacking().storage)
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { Self.owner })
        let key = "a2-halve-\(UUID().uuidString)"
        try await outbox.enqueueHealthKitBatch(
            Self.rows(8),
            encoder: .hlBatch,
            idempotencyKey: key,
            syncTrigger: .background,
            requiringCurrentOwner: Self.owner
        )

        await HealthKitSkippedRowRegister.$bound.withValue(register) {
            await Self.makeReplay(outbox: outbox).runOnce()
        }

        #expect(await outbox.snapshot.isEmpty, "the page is settled")
        #expect(await outbox.deadLetterCount == 0)
        let registered = await register.rows(ownerID: Self.owner)
        #expect(registered.map(\.id) == ["row-5"])
        #expect(registered.first?.reason == HealthKitBatchRejection.unclassifiedReason(status: 422))
        let delivered = Set(wire.all.filter { !$0.ids.contains("row-5") }.flatMap(\.ids))
        #expect(delivered == Set(Self.rows(8).map(\.externalId)).subtracting(["row-5"]))
        // The whole page, then 0-3, 4-7, 4-5, 4, 5, 6-7.
        #expect(wire.all.count == 7)
        #expect(wire.all.allSatisfy { $0.syncTrigger == .background }, "every half keeps the row's trigger")
        #expect(wire.all.dropFirst().allSatisfy { $0.key != key }, "a half is another body, so it gets its own key")
    }

    @Test("a 422 every row earns on its own is not a bad row: the page parks as before, and is not halved again")
    func refusalOfEveryRowParks() async throws {
        let wire = Wire()
        let rows = Self.rows(4)
        Self.install(refusing: Set(rows.map(\.externalId)), wire: wire)
        let register = HealthKitSkippedRowRegister(storage: SkipRegisterBacking().storage)
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { Self.owner })
        try await outbox.enqueueHealthKitBatch(
            rows,
            encoder: .hlBatch,
            idempotencyKey: "a2-every-\(UUID().uuidString)",
            requiringCurrentOwner: Self.owner
        )
        let replay = Self.makeReplay(outbox: outbox)

        await HealthKitSkippedRowRegister.$bound.withValue(register) {
            await replay.runOnce()
        }
        let postsAfterFirstPass = wire.all.count
        await HealthKitSkippedRowRegister.$bound.withValue(register) {
            await replay.runOnce()
        }

        let parked = try #require(await outbox.snapshot.first, "the row is the readings' only copy")
        #expect(parked.attempts == 0)
        #expect(parked.lastError?.hasPrefix("parked:not_stored status=422") == true)
        #expect(await register.rows(ownerID: Self.owner).isEmpty)
        #expect(postsAfterFirstPass == 7, "the page, two halves, four single rows")
        #expect(wire.all.count == postsAfterFirstPass + 1, "a page already halved goes out whole")
    }

    @Test("a 422 the halves cannot pin within their budget leaves the page parked")
    func halvingIsBounded() async throws {
        let wire = Wire()
        let rows = Self.rows(64)
        Self.install(refusing: Set(rows.map(\.externalId)), wire: wire)
        let register = HealthKitSkippedRowRegister(storage: SkipRegisterBacking().storage)
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { Self.owner })
        try await outbox.enqueueHealthKitBatch(
            rows,
            encoder: .hlBatch,
            idempotencyKey: "a2-bounded-\(UUID().uuidString)",
            requiringCurrentOwner: Self.owner
        )

        await HealthKitSkippedRowRegister.$bound.withValue(register) {
            await Self.makeReplay(outbox: outbox).runOnce()
        }

        #expect(wire.all.count == 1 + OutboxReplayService.maxBisectionPosts)
        #expect(await outbox.snapshot.count == 1)
        #expect(await register.rows(ownerID: Self.owner).isEmpty)
    }
}

// swiftlint:enable force_unwrapping
