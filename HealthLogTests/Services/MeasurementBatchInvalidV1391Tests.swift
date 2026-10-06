import Foundation
#if canImport(HealthKit)
    import HealthKit
#endif
@testable import HealthLog
import os
import Testing

// swiftlint:disable force_unwrapping

#if canImport(HealthKit)

    /// E1 — `measurement.batch.invalid` (server v1.39.1) is final for the batch
    /// as sent, and names the offending entries under `details.issues`.
    ///
    /// Fixtures are the v1.39.1 route's own envelope: `apiValidationError(…,
    /// sanitiseZodIssues(issues), 422, { errorCode: "measurement.batch.invalid" })`
    /// in `src/app/api/measurements/batch/route.ts`, whose issue `path` is the
    /// Zod path joined with dots (`src/lib/api-response.ts`). Before E1 the app
    /// read that 422 as "not stored": the heart-event importer held its anchor
    /// for five sweeps and the replay parked the page, re-sending the same batch
    /// on every pass. v1.39.0's code-less 422 still behaves that way.
    @Suite("measurement.batch.invalid — register the named entries, send the rest", .serialized, .mockURLSession)
    struct MeasurementBatchInvalidV1391Tests {
        static let owner = "account-e1"
        static let batchPath = "/api/measurements/batch"

        private static let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "1.1.0",
            buildNumber: "1"
        )

        /// v1.39.1: entry 1 carries a value Zod refuses.
        static let invalidEntry1 =
            #"{"data":null,"error":"Invalid input: expected number, received string","details":{"issues":["#
                + #"{"path":"entries.1.value","code":"invalid_type","message":"Invalid input: expected number, received string"}"#
                + #"]},"meta":{"errorCode":"measurement.batch.invalid"}}"#

        /// v1.39.1: the envelope itself is refused (`syncTrigger` outside its enum).
        static let invalidEnvelope =
            #"{"data":null,"error":"Invalid option","details":{"issues":[{"path":"syncTrigger","code":"invalid_value","message":"Invalid option"}]},"meta":{"errorCode":"measurement.batch.invalid"}}"#

        static func accepted(_ count: Int) -> String {
            let entries = (0 ..< count).map { #"{"index":\#($0),"status":"inserted"}"# }.joined(separator: ",")
            return #"{"data":{"processed":\#(count),"inserted":\#(count),"duplicates":0,"skipped":[],"entries":[\#(entries)]},"error":null}"#
        }

        static func events(_ identities: [String]) -> [HealthKitBatchEntryDTO] {
            identities.enumerated().map { index, identity in
                HealthKitBatchEntryDTO(
                    hkIdentifier: HKCategoryTypeIdentifier.irregularHeartRhythmEvent.rawValue,
                    value: 1,
                    unit: "event",
                    startDate: Date(timeIntervalSince1970: TimeInterval(1_790_100_000 + index)),
                    endDate: Date(timeIntervalSince1970: TimeInterval(1_790_100_000 + index)),
                    categoryValue: 1,
                    externalId: identity
                )
            }
        }

        /// Every batch POST, in order: the external ids it carried and its key.
        final class Wire: Sendable {
            private let posts = OSAllocatedUnfairLock<[(ids: [String], key: String)]>(initialState: [])

            func note(_ request: URLRequest) {
                let body = request.httpBody ?? request.httpBodyStream.map(Self.drain) ?? Data()
                let payload = try? JSONDecoder.hlDefault.decode(HealthKitBatchPayload.self, from: body)
                let key = request.value(forHTTPHeaderField: "Idempotency-Key") ?? ""
                posts.withLock { $0.append((payload?.entries.map(\.externalId) ?? [], key)) }
            }

            var ids: [[String]] {
                posts.withLock { $0.map(\.ids) }
            }

            var keys: [String] {
                posts.withLock { $0.map(\.key) }
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

        /// Answers the n-th batch POST with `answers[n]` (the last one repeats).
        static func install(_ answers: [(Int, String)], wire: Wire) {
            let served = OSAllocatedUnfairLock(initialState: 0)
            MockURLProtocol.install { req in
                wire.note(req)
                let index = served.withLock { count in
                    defer { count += 1 }
                    return min(count, answers.count - 1)
                }
                let (status, json) = answers[index]
                let response = HTTPURLResponse(
                    url: req.url!,
                    statusCode: status,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, Data(json.utf8))
            }
        }

        static func makeAPI() -> APIClient {
            let keychain = InMemoryKeychain()
            try? keychain.setString("bearer-e1", forKey: KeychainKey.authToken)
            try? keychain.setString(owner, forKey: KeychainKey.userID)
            return APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock())
        }

        static func makeUploader() -> MeasurementBatchUploader {
            MeasurementBatchUploader(
                api: makeAPI(),
                throttle: BatchSyncThrottle(maxPerWindow: 60, window: 60.0, jitter: 0 ... 0),
                syncTrigger: SyncTriggerContext(),
                authenticationSnapshot: {
                    MeasurementUploadAuthenticationSnapshot(ownerUserID: owner, bearerToken: "bearer-e1")
                }
            )
        }

        // MARK: - The transport reads the v1.39.1 envelope

        @Test("the entry paths of details.issues are read; an envelope issue names no entry")
        func issuePathsNameEntries() {
            #expect(MeasurementBatchInvalid.entryIndexes(of: ["entries.1.value", "entries.4", "entries.1.unit"]) == [1, 4])
            #expect(MeasurementBatchInvalid.entryIndexes(of: ["entries.1.value", "syncTrigger"]) == nil)
            #expect(MeasurementBatchInvalid.entryIndexes(of: ["entries"]) == nil)
            #expect(MeasurementBatchInvalid.entryIndexes(of: []) == nil)
            let fromWire = MeasurementBatchInvalid.from(
                path: Self.batchPath,
                status: 422,
                code: MeasurementBatchInvalid.code,
                body: Data(Self.invalidEntry1.utf8)
            )
            #expect(fromWire == MeasurementBatchInvalid(status: 422, entryIndexes: [1]))
            // Another route with the same code shape stays `HLError.server`.
            #expect(MeasurementBatchInvalid.from(
                path: "/api/nutrients/batch",
                status: 422,
                code: MeasurementBatchInvalid.code,
                body: Data(Self.invalidEntry1.utf8)
            ) == nil)
        }

        // MARK: - Live upload

        @Test("the uploader registers the named entry and sends the rest once, under a fresh key")
        func uploaderSplitsTheBatch() async throws {
            let wire = Wire()
            Self.install([(422, Self.invalidEntry1), (200, Self.accepted(2))], wire: wire)
            let register = HealthKitSkippedRowRegister(storage: SkipRegisterBacking().storage)

            let outcomes = try await HealthKitSkippedRowRegister.$bound.withValue(register) {
                try await Self.makeUploader().upload(Self.events(["evt-1", "evt-2", "evt-3"]))
            }

            #expect(wire.ids == [["evt-1", "evt-2", "evt-3"], ["evt-1", "evt-3"]])
            #expect(Set(wire.keys).count == 2, "the rest is a different body, so it gets its own key")
            let rows = await register.rows(ownerID: Self.owner)
            #expect(rows.map(\.id) == ["evt-2"])
            #expect(rows.first?.reason == "422:measurement.batch.invalid")
            let outcome = try #require(outcomes.first)
            #expect(outcome.consumedIndexes.sorted() == [0, 1, 2])
            #expect(outcome.skipped.map(\.index) == [1])
            #expect(outcome.successfulExternalIds.sorted() == ["evt-1", "evt-2", "evt-3"])
        }

        @Test("heart events: the named entry is registered, the rest stored, and the anchor moves at once")
        func heartEventPageCommitsAfterTheSplit() async throws {
            let wire = Wire()
            Self.install([(422, Self.invalidEntry1), (200, Self.accepted(1))], wire: wire)
            let harness = try HeartHarness()
            let register = HealthKitSkippedRowRegister(storage: SkipRegisterBacking().storage)

            let page = await HealthKitSkippedRowRegister.$bound.withValue(register) {
                await harness.importer.transmit(Self.events(["evt-h1", "evt-h2"]), requiring: harness.lease)
            }

            #expect(HealthSyncCursorPolicy.installed.decide(page) == .commit)
            #expect(await register.rows(ownerID: Self.owner).map(\.id) == ["evt-h2"])
            #expect(wire.ids == [["evt-h1", "evt-h2"], ["evt-h1"]])
            #expect(await harness.retry.enqueueCount() == 0)
        }

        @Test("heart events: an envelope issue refuses the batch whole — registered at once, no five-sweep hold")
        func heartEventEnvelopeRefusalIsFinal() async throws {
            let wire = Wire()
            Self.install([(422, Self.invalidEnvelope)], wire: wire)
            let harness = try HeartHarness()
            let register = HealthKitSkippedRowRegister(storage: SkipRegisterBacking().storage)

            let page = await HealthKitSkippedRowRegister.$bound.withValue(register) {
                await harness.importer.transmit(Self.events(["evt-e1", "evt-e2"]), requiring: harness.lease)
            }

            #expect(HealthSyncCursorPolicy.installed.decide(page) == .commit)
            #expect(wire.ids.count == 1, "halving would meet the same envelope issue again")
            let rows = await register.rows(ownerID: Self.owner)
            #expect(rows.map(\.id).sorted() == ["evt-e1", "evt-e2"])
            #expect(rows.allSatisfy { $0.reason == "422:measurement.batch.invalid" })
        }

        @Test("a register that cannot keep the named entry sends nothing more and holds the page")
        func splitWithoutRegisterHolds() async throws {
            let wire = Wire()
            Self.install([(422, Self.invalidEntry1), (200, Self.accepted(1))], wire: wire)
            let harness = try HeartHarness()
            let register = HealthKitSkippedRowRegister(storage: SkipRegisterBacking(lossy: true).storage)

            let page = await HealthKitSkippedRowRegister.$bound.withValue(register) {
                await harness.importer.transmit(Self.events(["evt-l1", "evt-l2"]), requiring: harness.lease)
            }

            #expect(wire.ids.count == 1)
            #expect(HealthSyncCursorPolicy.installed.decide(page) == .hold(reason: .nonterminalEntry))
        }

        // MARK: - Replay

        @Test("a queued page is split on replay: named entry registered, rest delivered, row gone")
        func replaySplitsTheQueuedPage() async throws {
            let wire = Wire()
            Self.install([(422, Self.invalidEntry1), (200, Self.accepted(1))], wire: wire)
            let register = HealthKitSkippedRowRegister(storage: SkipRegisterBacking().storage)
            let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { Self.owner })
            try await outbox.enqueueHealthKitBatch(
                Self.events(["evt-q1", "evt-q2"]),
                encoder: .hlBatch,
                idempotencyKey: "e1-\(UUID().uuidString)",
                requiringCurrentOwner: Self.owner
            )

            await HealthKitSkippedRowRegister.$bound.withValue(register) {
                await Self.makeReplay(outbox: outbox).runOnce()
            }

            #expect(await outbox.snapshot.isEmpty)
            #expect(await outbox.deadLetterCount == 0)
            #expect(await register.rows(ownerID: Self.owner).map(\.id) == ["evt-q2"])
            #expect(wire.ids == [["evt-q1", "evt-q2"], ["evt-q1"]])
        }

        static func makeReplay(outbox: OutboxQueue) -> OutboxReplayService {
            let api = makeAPI()
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

        /// An admitted heart-event importer over the real uploader.
        struct HeartHarness {
            /// Retained on purpose — the lease holds the registry weakly.
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease: HealthSyncAuthenticatedLease
            let retry = RecordingStatsRetryQueue()
            let importer: HeartHealthEventImporter

            init() throws {
                registry.activate(ownerID: MeasurementBatchInvalidV1391Tests.owner)
                lease = try HealthSyncAuthenticatedLease.admit(
                    from: registry,
                    ownerID: MeasurementBatchInvalidV1391Tests.owner,
                    source: .heartEvent,
                    bearerProvider: { "bearer-e1" }
                )
                let admitted = lease
                importer = HeartHealthEventImporter(
                    store: HKHealthStore(),
                    uploader: MeasurementBatchInvalidV1391Tests.makeUploader(),
                    userID: MeasurementBatchInvalidV1391Tests.owner,
                    defaults: UserDefaults(suiteName: "e1-heart-\(UUID().uuidString)")!,
                    admission: { admitted },
                    cursors: nil,
                    retry: retry
                )
            }
        }
    }

#endif

// swiftlint:enable force_unwrapping
