#if canImport(HealthKit) && canImport(SpeziHealthKit)
    import Foundation
    import HealthKit
    @testable import HealthLog
    import os
    import Testing

    // swiftlint:disable force_unwrapping

    // A5 (1.4, R3 S4) — doubles for the Apple Health deletion suites: a server
    // that keeps every delete-by-external-ids body, and the fixtures that put
    // a real `HealthLogStandard` with a real repository and outbox behind the
    // collector.

    /// The route as the server has it: `DELETE /api/measurements/by-external-ids`
    /// with `{ externalIds }`. Every request is kept; the answer is scripted.
    final class DeletionWire: Sendable {
        enum Answer: Sendable {
            case deleted
            case offline
            case refused
        }

        struct Request: Sendable {
            let method: String
            let path: String
            let keys: Set<String>
            let externalIds: [String]
        }

        private let requests = OSAllocatedUnfairLock<[Request]>(initialState: [])
        private let mode = OSAllocatedUnfairLock<Answer>(initialState: .deleted)

        var all: [Request] {
            requests.withLock { $0 }
        }

        var deletedIDs: [String] {
            all.flatMap(\.externalIds)
        }

        func answer(_ next: Answer) {
            mode.withLock { $0 = next }
        }

        func install() {
            MockURLProtocol.install { [self] request in
                let body = request.httpBody ?? request.httpBodyStream.map(Self.drain) ?? Data()
                let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
                let note = Request(
                    method: request.httpMethod ?? "",
                    path: request.url?.path ?? "",
                    keys: Set(object.keys),
                    externalIds: object["externalIds"] as? [String] ?? []
                )
                let current = mode.withLock { $0 }
                if current == .offline { throw URLError(.notConnectedToInternet) }
                requests.withLock { $0.append(note) }
                let refused = current == .refused
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: refused ? 422 : 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
                let reply = refused
                    ? #"{"data":null,"error":"Validation failed"}"#
                    : #"{"data":{"deletedCount":\#(note.externalIds.count)},"error":null}"#
                return (response, Data(reply.utf8))
            }
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

    /// Records every batch the forwarder sends, without a network.
    final class RecordingDeletionServer: MeasurementDeletionReconciler, Sendable {
        private let batches = OSAllocatedUnfairLock<[[String]]>(initialState: [])
        private let failure: HLError?

        init(failing failure: HLError? = nil) {
            self.failure = failure
        }

        var sent: [[String]] {
            batches.withLock { $0 }
        }

        func reconcileDeletedExternalIDs(_ ids: [String]) async throws {
            batches.withLock { $0.append(ids) }
            if let failure { throw failure }
        }
    }

    /// A retry queue that keeps sample pages but no deletions (the protocol
    /// default refuses them).
    actor PagesOnlyRetryQueue: HealthSyncBatchRetryEnqueuing {
        func enqueueHealthKitRetry(
            _: [HealthKitBatchEntryDTO],
            idempotencyKey _: String,
            requiringCurrentOwner _: String
        ) async throws {}
    }

    enum DeletionFixture {
        static let owner = "account-a"
        static let weight = HKQuantityTypeIdentifier.bodyMass.rawValue
        static let systolic = HKQuantityTypeIdentifier.bloodPressureSystolic.rawValue
        static let diastolic = HKQuantityTypeIdentifier.bloodPressureDiastolic.rawValue

        static let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "1.4.0",
            buildNumber: "1"
        )

        /// The real client over this test's mock session, signed in as `owner`.
        static func api() -> APIClient {
            let keychain = InMemoryKeychain()
            try? keychain.setString("token-account-a", forKey: KeychainKey.authToken)
            try? keychain.setString(owner, forKey: KeychainKey.userID)
            return APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock())
        }

        static func outbox() throws -> OutboxQueue {
            try OutboxQueue(inMemory: true, currentOwnerProvider: { owner })
        }

        /// A real standard with the production attachments: the outbox as its
        /// retry queue, the repository as its deletion reconciler.
        static func standard(
            api: APIClient,
            outbox: OutboxQueue,
            reconciler: (any MeasurementDeletionReconciler)? = nil,
            retryQueue: (any HealthSyncBatchRetryEnqueuing)? = nil
        ) async -> HealthLogStandard {
            let standard = HealthLogStandard()
            await standard.attachUploader(
                MeasurementBatchUploader(api: api, throttle: BatchSyncThrottle(maxPerWindow: 1000, jitter: 0 ... 0)),
                featureFlags: nil,
                retryQueue: retryQueue ?? outbox
            )
            await standard.attachDeletionReconciler(reconciler)
            return standard
        }

        /// The production migration state for every type: replaying, so the
        /// live leg may read.
        static func cursors(
            for types: [String],
            lease: HealthSyncAuthenticatedLease
        ) async throws -> (DurableHealthCursorStore, [String: HealthSyncCursorKey]) {
            let store = DurableHealthCursorStore(storage: CollectorCursorBacking().storage)
            var keys: [String: HealthSyncCursorKey] = [:]
            for type in types {
                let key = try #require(HealthSyncCursorKey(ownerID: lease.ownerID, source: .speziSamples, typeIdentifier: type))
                _ = try await store.migrate(
                    key,
                    legacyKey: "edu.stanford.Spezi.SpeziHealthKit.queryAnchors.\(type)",
                    ownership: .unownedGlobal,
                    requiring: lease
                )
                keys[type] = key
            }
            return (store, keys)
        }

        /// A page that reports only deletions, the way HealthKit answers after
        /// a person removed readings in the Health app.
        static func deletions(_ ids: [String], anchor: Int) -> AnchoredHealthSamplePage {
            AnchoredHealthSamplePage(
                samples: [],
                deletedObjectCount: ids.count,
                newAnchor: HKQueryAnchor(fromValue: anchor),
                mayHaveMore: false,
                deletedSampleIDs: ids
            )
        }

        /// A6 — what HealthKit keeps of an object it deleted: its UUID and,
        /// of all its metadata, only the sync identifier and version (Apple,
        /// `HKDeletedObject.metadata`).
        static func deletedObject(of object: HKObject) -> (uuid: UUID, metadata: [String: Any]?) {
            let kept = object.metadata?.filter { [HKMetadataKeySyncIdentifier, HKMetadataKeySyncVersion].contains($0.key) }
            return (object.uuid, kept?.isEmpty == false ? kept : nil)
        }

        /// A6 — a page that reports deleted objects, split the way the live
        /// source splits them (``HealthKitCopySyncIdentity/split(_:)``).
        static func deletions(
            of objects: [(uuid: UUID, metadata: [String: Any]?)],
            anchor: Int
        ) -> AnchoredHealthSamplePage {
            let split = HealthKitCopySyncIdentity.split(objects)
            return AnchoredHealthSamplePage(
                samples: [],
                deletedObjectCount: objects.count,
                newAnchor: HKQueryAnchor(fromValue: anchor),
                mayHaveMore: false,
                deletedSampleIDs: split.sampleIDs,
                deletedCopyServerIDs: split.copyServerIDs
            )
        }

        /// A6 — a copy as 1.3.0 wrote it: the server id and the origin marker,
        /// no sync identifier.
        static func legacyCopy(of measurement: HealthLog.Measurement, kilograms: Double) -> HKQuantitySample {
            HKQuantitySample(
                type: HKQuantityType(.bodyMass),
                quantity: HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: kilograms),
                start: measurement.recordedAt,
                end: measurement.recordedAt,
                metadata: [
                    HKMetadataKeyExternalUUID: measurement.id,
                    HealthKitSampleOwnership.appOriginMetadataKey: HealthKitSampleOwnership.appOriginMetadataValue
                ]
            )
        }

        static func replay(outbox: OutboxQueue, api: APIClient) -> OutboxReplayService {
            OutboxReplayService(
                outbox: outbox,
                measurementsRepo: MeasurementsRepository(api: api, outbox: outbox),
                moodRepo: MoodRepository(api: api, outbox: outbox),
                medicationsRepo: MedicationsRepository(api: api, outbox: outbox),
                currentUserProvider: { owner },
                maxAttempts: 8,
                attemptBackoff: 0
            )
        }
    }
#endif
