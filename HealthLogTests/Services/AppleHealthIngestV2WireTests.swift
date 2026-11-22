import Foundation
#if canImport(HealthKit)
    import HealthKit
#endif
@testable import HealthLog
import os
import Testing

// swiftlint:disable force_unwrapping

#if canImport(HealthKit)

    /// The ingest-v2 wire half against the real `APIClient` over
    /// `MockURLProtocol`: what a symptom page proves, where its deletions go,
    /// what the outbox keeps and replays, and the workout tombstone answer.
    @Suite("Apple Health ingest v2: symptom pages, deletions, outbox", .serialized, .mockURLSession)
    struct AppleHealthIngestV2WireTests {
        static let owner = "account-a"
        /// A fixture credential, not a secret.
        static let fixtureBearer = ["bearer", "a"].joined(separator: "-")

        private static let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "1.7.0",
            buildNumber: "1"
        )

        private struct Admitted {
            let registry: AuthenticatedSessionLeaseRegistry
            let lease: HealthSyncAuthenticatedLease
        }

        /// What the mock server saw.
        final class Wire: Sendable {
            struct Seen: Sendable {
                let method: String
                let path: String
                let body: Data
            }

            private let requests = OSAllocatedUnfairLock<[Seen]>(initialState: [])
            var all: [Seen] {
                requests.withLock { $0 }
            }

            func record(_ request: URLRequest) {
                let body = request.httpBody ?? request.httpBodyStream.map(Self.drain) ?? Data()
                requests.withLock { $0.append(Seen(method: request.httpMethod ?? "", path: request.url?.path ?? "", body: body)) }
            }

            static func drain(_ stream: InputStream) -> Data {
                stream.open()
                defer { stream.close() }
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let read = stream.read(&buffer, maxLength: buffer.count)
                    guard read > 0 else { break }
                    data.append(buffer, count: read)
                }
                return data
            }
        }

        /// A queue that keeps what it is given.
        actor KeepingQueue: HealthSyncBatchRetryEnqueuing {
            var symptomPages: [[AppleHealthSymptomEntryDTO]] = []
            var deletions: [(AppleHealthDeleteDomain, [String])] = []

            func enqueueHealthKitRetry(
                _: [HealthKitBatchEntryDTO],
                idempotencyKey _: String,
                requiringCurrentOwner _: String
            ) async throws {}

            func enqueueAppleHealthSymptoms(
                _ entries: [AppleHealthSymptomEntryDTO],
                idempotencyKey _: String,
                requiringCurrentOwner _: String
            ) async throws {
                symptomPages.append(entries)
            }

            func enqueueAppleHealthDeletion(
                _ externalIDs: [String],
                domain: AppleHealthDeleteDomain,
                idempotencyKey _: String,
                requiringCurrentOwner _: String
            ) async throws {
                deletions.append((domain, externalIDs))
            }
        }

        private func admit() throws -> Admitted {
            let registry = AuthenticatedSessionLeaseRegistry()
            registry.activate(ownerID: Self.owner)
            let lease = try HealthSyncAuthenticatedLease.admit(
                from: registry,
                ownerID: Self.owner,
                source: .heartEvent,
                bearerProvider: { Self.fixtureBearer }
            )
            return Admitted(registry: registry, lease: lease)
        }

        private func api() -> APIClient {
            let keychain = InMemoryKeychain()
            try? keychain.setString(Self.fixtureBearer, forKey: KeychainKey.authToken)
            try? keychain.setString(Self.owner, forKey: KeychainKey.userID)
            return APIClient(environment: Self.env, keychain: keychain, sessionConfiguration: .mock())
        }

        private func importer(retry: (any HealthSyncBatchRetryEnqueuing)?) -> HeartHealthEventImporter {
            let uploader = MeasurementBatchUploader(
                api: api(),
                throttle: BatchSyncThrottle(maxPerWindow: 60, window: 60.0, jitter: 0 ... 0),
                syncTrigger: SyncTriggerContext(),
                authenticationSnapshot: {
                    MeasurementUploadAuthenticationSnapshot(ownerUserID: Self.owner, bearerToken: Self.fixtureBearer)
                }
            )
            return HeartHealthEventImporter(
                store: HKHealthStore(),
                uploader: uploader,
                userID: Self.owner,
                defaults: UserDefaults(suiteName: "ingest-v2-wire-\(UUID().uuidString)")!,
                admission: nil,
                cursors: nil,
                retry: retry
            )
        }

        private func serve(_ wire: Wire, status: Int = 200, offline: Bool = false, json: @escaping @Sendable (URLRequest) -> String) {
            MockURLProtocol.install { request in
                if offline { throw URLError(.notConnectedToInternet) }
                wire.record(request)
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: status,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, Data(json(request).utf8))
            }
        }

        private static func symptoms(_ ids: [String]) -> [AppleHealthSymptomEntryDTO] {
            ids.enumerated().map { index, id in
                AppleHealthSymptomEntryDTO(
                    code: index.isMultiple(of: 2) ? "FEVER" : "HEADACHE",
                    occurredAt: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + index)),
                    endAt: nil,
                    intensity: 6,
                    externalId: id
                )
            }
        }

        // MARK: - Symptom page

        @Test("an accepted symptom page goes to the symptom route and lets the cursor move")
        func acceptedSymptomPage() async throws {
            let wire = Wire()
            serve(wire) { _ in
                #"{"processed":2,"inserted":1,"duplicates":1,"skipped":[],"entries":[{"index":0,"status":"inserted"},{"index":1,"status":"duplicate"}]}"#
            }
            let admitted = try admit()
            let page = await importer(retry: nil).transmitSymptoms(Self.symptoms(["s-1", "s-2"]), requiring: admitted.lease)
            #expect(HealthSyncCursorPolicy.installed.decide(page) == .commit)
            #expect(wire.all.map(\.path) == ["/api/symptoms/events/batch"])
            let body = try #require(JSONSerialization.jsonObject(with: wire.all[0].body) as? [String: Any])
            let entries = try #require(body["entries"] as? [[String: Any]])
            #expect(entries.map { $0["code"] as? String } == ["FEVER", "HEADACHE"])
            #expect(entries.allSatisfy { $0["source"] as? String == "APPLE_HEALTH" })
        }

        @Test("a failed or missing index waits in the outbox; the rest is done")
        func failedIndexParks() async throws {
            let wire = Wire()
            serve(wire) { _ in
                #"{"processed":3,"inserted":1,"duplicates":0,"skipped":[{"index":2,"reason":"unknown_code"}],"entries":[{"index":0,"status":"inserted"},{"index":1,"status":"failed"}]}"#
            }
            let admitted = try admit()
            let queue = KeepingQueue()
            let page = await importer(retry: queue).transmitSymptoms(Self.symptoms(["s-1", "s-2", "s-3"]), requiring: admitted.lease)
            #expect(await queue.symptomPages.map { $0.map(\.externalId) } == [["s-2"]])
            #expect(page.durableRetryPersisted)
            #expect(HealthSyncCursorPolicy.installed.decide(page) == .commit)
        }

        @Test("offline holds the page and parks nothing")
        func offlineHolds() async throws {
            let wire = Wire()
            serve(wire, offline: true) { _ in "{}" }
            let admitted = try admit()
            let queue = KeepingQueue()
            let page = await importer(retry: queue).transmitSymptoms(Self.symptoms(["s-1"]), requiring: admitted.lease)
            #expect(await queue.symptomPages.isEmpty)
            #expect(HealthSyncCursorPolicy.installed.decide(page) != .commit)
        }

        // MARK: - Deletions

        @Test("deletions go to their domain's route, and offline into the outbox")
        func deletionSender() async throws {
            let wire = Wire()
            serve(wire) { _ in #"{"data":{"deletedCount":2}}"# }
            let admitted = try admit()
            let queue = KeepingQueue()
            let importer = importer(retry: queue)
            let uploader = await importer.uploader
            let sender = AppleHealthDeletionSender(
                send: { ids, domain in try await uploader.deleteAppleHealthRecords(ids, domain: domain) },
                queue: queue
            )
            #expect(await sender.forward(["d-1", "d-2", "d-1"], to: .symptoms, requiring: admitted.lease) == nil)
            #expect(wire.all.map(\.method) == ["DELETE"])
            #expect(wire.all.map(\.path) == ["/api/symptoms/events/by-external-ids"])
            let body = try #require(JSONSerialization.jsonObject(with: wire.all[0].body) as? [String: Any])
            #expect(body["externalIds"] as? [String] == ["d-1", "d-2"])

            serve(wire, offline: true) { _ in "{}" }
            #expect(await sender.forward(["d-3"], to: .workout, requiring: admitted.lease) == nil)
            let kept = await queue.deletions
            #expect(kept.map(\.0) == [.workout])
            #expect(kept.map(\.1) == [["d-3"]])
        }

        // MARK: - Outbox replay

        @Test("the outbox replays a symptom page and a deletion on their routes, then drains")
        func outboxReplay() async throws {
            let wire = Wire()
            serve(wire) { request in
                request.httpMethod == "DELETE"
                    ? #"{"data":{"deletedCount":1}}"#
                    : #"{"processed":1,"inserted":1,"duplicates":0,"skipped":[],"entries":[{"index":0,"status":"inserted"}]}"#
            }
            let client = api()
            // The queue and the replay read the same account as the client's
            // Keychain, as the app wires them. Left to the simulator's own
            // Keychain they stamp whoever another test signed in there, and the
            // replay rightly refuses to send that account's rows under
            // `account-a`'s bearer (`RequestOwnerBinding`).
            let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { Self.owner })
            try await outbox.enqueue(.init(
                kind: .uploadAppleHealthSymptoms,
                payload: JSONEncoder.hlDefault.encode(OutboxQueue.Payloads.UploadAppleHealthSymptoms(entries: Self.symptoms(["s-9"]))),
                idempotencyKey: "symptoms-key"
            ))
            try await outbox.enqueue(.init(
                kind: .deleteAppleHealthRecords,
                payload: JSONEncoder.hlDefault.encode(
                    OutboxQueue.Payloads.DeleteAppleHealthRecords(domain: .cycleDayLog, externalIds: ["c-1"])
                ),
                idempotencyKey: "delete-key"
            ))
            let replay = OutboxReplayService(
                outbox: outbox,
                measurementsRepo: MeasurementsRepository(api: client, outbox: outbox),
                moodRepo: MoodRepository(api: client, outbox: outbox),
                medicationsRepo: MedicationsRepository(api: client, outbox: outbox),
                currentUserProvider: { Self.owner }
            )
            await replay.runOnce()
            #expect(wire.all.map(\.path) == ["/api/symptoms/events/batch", "/api/cycle/day-logs/by-external-ids"])
            #expect(await outbox.snapshot.allSatisfy(\.delivered))
        }

        // MARK: - Server 1.48.2 clarifications

        @Test("Apple Health sync routes stay owner-only while another record is selected")
        func syncRoutesCarryNoRecordSelector() async throws {
            let headers = OSAllocatedUnfairLock<[String?]>(initialState: [])
            MockURLProtocol.install { request in
                headers.withLock { $0.append(request.value(forHTTPHeaderField: "X-HealthLog-Account")) }
                let body = request.httpMethod == "DELETE"
                    ? #"{"data":{"deletedCount":0}}"#
                    : #"{"processed":1,"inserted":1,"duplicates":0,"skipped":[],"entries":[{"index":0,"status":"inserted"}]}"#
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
            }
            let client = api()
            let json = #"[{"accountId":"other-record","username":"o","access":"read","level":"read","recordKind":"shared","sections":null,"canWrite":false}]"#
            let grant = try #require(try JSONDecoder.hlDefault.decode([AccountAccessEntry].self, from: Data(json.utf8)).first)
            await client.selectAccount(grant)
            let uploader = MeasurementBatchUploader(
                api: client,
                throttle: BatchSyncThrottle(maxPerWindow: 60, window: 60.0, jitter: 0 ... 0),
                syncTrigger: SyncTriggerContext()
            )
            _ = try await uploader.uploadSymptoms(Self.symptoms(["s-1"]))
            for domain in AppleHealthDeleteDomain.allCases {
                try await uploader.deleteAppleHealthRecords(["d-1"], domain: domain)
            }
            let seen = headers.withLock { $0 }
            #expect(seen.count == 1 + AppleHealthDeleteDomain.allCases.count)
            #expect(seen.allSatisfy { $0 == nil })
        }

        @Test("a symptom that ends before it starts loses its end; one in the future is not sent")
        func implausibleSymptomTimes() {
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            #expect(AppleHealthSymptomTimestamps.arePlausible(start: now.addingTimeInterval(-60), end: now, now: now))
            #expect(!AppleHealthSymptomTimestamps.arePlausible(
                start: now.addingTimeInterval(3600),
                end: now.addingTimeInterval(3600),
                now: now
            ))
            #expect(!AppleHealthSymptomTimestamps.arePlausible(start: now, end: now.addingTimeInterval(3600), now: now))
            #expect(!AppleHealthSymptomTimestamps.arePlausible(start: Date(timeIntervalSince1970: -3_000_000_000), end: now, now: now))
            let backwards = AppleHealthSymptomEntryDTO(
                code: "FEVER",
                occurredAt: now,
                endAt: now.addingTimeInterval(-60),
                intensity: 5,
                externalId: "x"
            )
            #expect(backwards.endAt == nil)
        }

        @Test("a delete wins over an older queued upload of the same id")
        func deletePrunesQueuedUploads() async throws {
            let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { Self.owner })
            let page = OutboxQueue.Payloads.UploadAppleHealthSymptoms(entries: Self.symptoms(["keep-1", "gone-1"]))
            let gone = OutboxQueue.Payloads.UploadAppleHealthSymptoms(entries: Self.symptoms(["gone-2"]))
            try await outbox.enqueue(.init(
                kind: .uploadAppleHealthSymptoms,
                payload: JSONEncoder.hlDefault.encode(page),
                idempotencyKey: "k1"
            ))
            try await outbox.enqueue(.init(
                kind: .uploadAppleHealthSymptoms,
                payload: JSONEncoder.hlDefault.encode(gone),
                idempotencyKey: "k2"
            ))
            let removed = await outbox.pruneQueuedAppleHealthUploads(
                .uploadAppleHealthSymptoms,
                removing: ["gone-1", "gone-2"],
                ownerUserID: Self.owner
            )
            #expect(removed == 2)
            let rows = await outbox.snapshot
            #expect(rows.count == 1)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let left = try decoder.decode(OutboxQueue.Payloads.UploadAppleHealthSymptoms.self, from: rows[0].payload)
            #expect(left.entries.map(\.externalId) == ["keep-1"])
            #expect(rows[0].idempotencyKey != "k1", "a changed body takes a new key")
        }

        // MARK: - Tombstones (server 1.48.2)

        @Test("a re-posted deleted workout answers duplicate: done, not an error")
        func workoutTombstoneDuplicateIsDone() throws {
            let json = #"{"processed":1,"inserted":0,"duplicates":1,"entries":[{"index":0,"status":"duplicate"}]}"#
            let response = try JSONDecoder().decode(WorkoutBatchResponseDTO.self, from: Data(json.utf8))
            #expect(throws: Never.self) { try WorkoutBatchAcceptance.validate(postedCount: 1, response: response) }
        }
    }

#endif

// swiftlint:enable force_unwrapping
