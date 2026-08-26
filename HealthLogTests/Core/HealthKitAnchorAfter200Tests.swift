// W2c-A1H — H6 anchor-after-200 contract.
// Diese Suite bestaetigt die `SampleConsumeOutcome`-Policy von
// `HealthKitService.uploadAndDecide`. Ohne ein echtes HealthKit-Mock fokussieren
// wir auf den entkoppelten Hook (statt den HKAnchoredObjectQuery-Callback-Pfad
// per `swizzle` zu manipulieren) — das ist der gleiche Code-Pfad den der
// AnchoredObjectQuery-Callback in Production aufruft.
//
// Anchor-After-200 Policy (siehe A1-Audit H6 + W2c-A1H Impl-Report;
// W2 silent-data-loss-Fix):
//
// | Szenario                                  | Outcome     | Anchor-Save? |
// |-------------------------------------------|-------------|--------------|
// | Alle Chunks 2xx (inserted/dup)            | .consumed   | YES          |
// | 2xx, skipped(value_out_of_range)          | .consumed   | YES          |
// | 2xx, skipped(unmappable_identifier)       | .keepAnchor | NO           |
// | 5xx im einzigen Chunk                     | .keepAnchor | NO           |
// | Network-Drop im einzigen Chunk            | .keepAnchor | NO           |
// | Chunk 1 OK, Chunk 2 throws (>500)         | .keepAnchor | NO           |
//
// Re-Run-Korrektheit: bei `.keepAnchor` re-fetched HK alles seit dem alten
// Anchor; Server dedupliziert via externalId → erfolgreiche Chunks landen als
// `duplicate`, neue/fehlgeschlagene werden frisch versucht.
//
// W2: `unmappable_identifier` ist TRANSIENT (der Server kennt den HK-Typ noch
// nicht) — würde der Anchor advancen, ginge das Sample dauerhaft + still
// verloren. `value_out_of_range` bleibt terminal, sonst loopte ein einzelnes
// bogus-Sample endlos.
#if !SWIFT_PACKAGE && canImport(HealthKit)

    import Foundation
    @testable import HealthLog
    import Testing

    @Suite("HealthKitService anchor-after-200 policy")
    struct HealthKitAnchorAfter200Tests {
        // MARK: - Fixtures

        private static func makeEntry(index idx: Int, prefix: String) -> HealthKitBatchEntryDTO {
            HealthKitBatchEntryDTO(
                hkIdentifier: "HKQuantityTypeIdentifierStepCount",
                value: Double(idx),
                unit: "count",
                startDate: Date(timeIntervalSince1970: TimeInterval(1_715_673_600 + idx * 60)),
                endDate: Date(timeIntervalSince1970: TimeInterval(1_715_673_660 + idx * 60)),
                externalId: "\(prefix)-\(idx)"
            )
        }

        /// Drei distinct Step-Samples, jeweils mit eigener externalId. Reichen fuer
        /// alle Single-Chunk-Tests (Default-Chunk-Size = 500 → < 500 = ein Chunk).
        private static let smallChunk: [HealthKitBatchEntryDTO] = (0 ..< 3).map { idx in
            makeEntry(index: idx, prefix: "ext")
        }

        /// 1200 Entries → 3 Chunks (500 + 500 + 200) bei der Default-Chunk-Size.
        /// Wird vom partial-success-Test verwendet.
        private static let multiChunk: [HealthKitBatchEntryDTO] = (0 ..< 1200).map { idx in
            makeEntry(index: idx, prefix: "multi")
        }

        private static func zeroJitterThrottle() -> BatchSyncThrottle {
            BatchSyncThrottle(maxPerWindow: 60, window: 60.0, jitter: 0 ... 0)
        }

        private static func batchDecoder() -> JSONDecoder {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return decoder
        }

        // MARK: - Happy path: full success → .consumed (Anchor advance OK)

        @Test("Alle Chunks 2xx mit allen inserted → .consumed (Anchor advance OK)")
        func allInsertedConsumes() async {
            let api = AnchorTestStubAPI { _, body in
                let payload = try Self.batchDecoder().decode(HealthKitBatchPayload.self, from: body)
                let entries = payload.entries.indices.map { idx in
                    HealthKitBatchResponseDTO.EntryResult(index: idx, status: .inserted)
                }
                return .success(.init(
                    processed: payload.entries.count,
                    inserted: payload.entries.count,
                    duplicates: 0,
                    skipped: [],
                    entries: entries
                ))
            }
            let uploader = MeasurementBatchUploader(api: api, throttle: Self.zeroJitterThrottle())

            let outcome = await HealthKitService.uploadAndDecide(
                entries: Self.smallChunk,
                uploader: uploader,
                typeIdentifier: "HKQuantityTypeIdentifierStepCount"
            )

            #expect(outcome == .consumed)
            #expect(api.callCount == 1)
        }

        @Test("Mixed inserted + duplicate + skipped(value_out_of_range) → .consumed (alle terminal)")
        func mixedStatusesAllConsume() async {
            let api = AnchorTestStubAPI { _, body in
                let payload = try Self.batchDecoder().decode(HealthKitBatchPayload.self, from: body)
                // ext-0 → inserted, ext-1 → duplicate, ext-2 → skipped (bogus
                // Wert außerhalb Range — terminal, Retry änderte nichts).
                #expect(payload.entries.count == 3)
                let response = HealthKitBatchResponseDTO(
                    processed: 3,
                    inserted: 1,
                    duplicates: 1,
                    skipped: [.init(index: 2, reason: "value_out_of_range")],
                    entries: [
                        .init(index: 0, status: .inserted),
                        .init(index: 1, status: .duplicate),
                        .init(index: 2, status: .skipped, reason: "value_out_of_range")
                    ]
                )
                return .success(response)
            }
            let uploader = MeasurementBatchUploader(api: api, throttle: Self.zeroJitterThrottle())

            let outcome = await HealthKitService.uploadAndDecide(
                entries: Self.smallChunk,
                uploader: uploader,
                typeIdentifier: "HKQuantityTypeIdentifierStepCount"
            )

            #expect(outcome == .consumed)
        }

        @Test("2xx missing one posted index keeps anchor")
        func missingResponseIndexKeepsAnchor() async {
            let api = AnchorTestStubAPI { _, _ in
                .success(.init(
                    processed: 2,
                    inserted: 2,
                    duplicates: 0,
                    skipped: [],
                    entries: [
                        .init(index: 0, status: .inserted),
                        .init(index: 1, status: .inserted)
                    ]
                ))
            }
            let uploader = MeasurementBatchUploader(api: api, throttle: Self.zeroJitterThrottle())

            let outcome = await HealthKitService.uploadAndDecide(
                entries: Self.smallChunk,
                uploader: uploader,
                typeIdentifier: "HKQuantityTypeIdentifierStepCount"
            )

            #expect(outcome == .keepAnchor)
        }

        @Test("2xx duplicate response index keeps anchor")
        func duplicateResponseIndexKeepsAnchor() async {
            let api = AnchorTestStubAPI { _, _ in
                .success(.init(
                    processed: 3,
                    inserted: 3,
                    duplicates: 0,
                    skipped: [],
                    entries: [
                        .init(index: 0, status: .inserted),
                        .init(index: 0, status: .inserted),
                        .init(index: 2, status: .inserted)
                    ]
                ))
            }
            let uploader = MeasurementBatchUploader(api: api, throttle: Self.zeroJitterThrottle())

            let outcome = await HealthKitService.uploadAndDecide(
                entries: Self.smallChunk,
                uploader: uploader,
                typeIdentifier: "HKQuantityTypeIdentifierStepCount"
            )

            #expect(outcome == .keepAnchor)
        }

        @Test("2xx out-of-range response index keeps anchor")
        func outOfRangeResponseIndexKeepsAnchor() async {
            let api = AnchorTestStubAPI { _, _ in
                .success(.init(
                    processed: 3,
                    inserted: 3,
                    duplicates: 0,
                    skipped: [],
                    entries: [
                        .init(index: 0, status: .inserted),
                        .init(index: 1, status: .inserted),
                        .init(index: 99, status: .inserted)
                    ]
                ))
            }
            let uploader = MeasurementBatchUploader(api: api, throttle: Self.zeroJitterThrottle())

            let outcome = await HealthKitService.uploadAndDecide(
                entries: Self.smallChunk,
                uploader: uploader,
                typeIdentifier: "HKQuantityTypeIdentifierStepCount"
            )

            #expect(outcome == .keepAnchor)
        }

        @Test("2xx unknown entry status keeps anchor")
        func unknownEntryStatusKeepsAnchor() async {
            let api = AnchorTestStubAPI { _, _ in
                .success(.init(
                    processed: 3,
                    inserted: 2,
                    duplicates: 0,
                    skipped: [],
                    entries: [
                        .init(index: 0, status: .inserted),
                        .init(index: 1, status: .inserted),
                        .init(index: 2, status: .unknown)
                    ]
                ))
            }
            let uploader = MeasurementBatchUploader(api: api, throttle: Self.zeroJitterThrottle())

            let outcome = await HealthKitService.uploadAndDecide(
                entries: Self.smallChunk,
                uploader: uploader,
                typeIdentifier: "HKQuantityTypeIdentifierStepCount"
            )

            #expect(outcome == .keepAnchor)
        }

        // MARK: - W2 silent-data-loss fix: unmappable_identifier → .keepAnchor

        @Test("2xx mit skipped(unmappable_identifier) → .keepAnchor (kein stiller Datenverlust)")
        func unmappableSkipKeepsAnchor() async {
            // Server quittiert HTTP 200, skippt aber jeden Eintrag mit
            // `unmappable_identifier` (der Typ liegt im server-seitigen
            // `HK_QUANTITY_TYPE_DEFERRED`-Set). Vor dem W2-Fix advancte der
            // Anchor hier → die Samples gingen dauerhaft + still verloren.
            let api = AnchorTestStubAPI { _, body in
                let payload = try Self.batchDecoder().decode(HealthKitBatchPayload.self, from: body)
                let skipped = payload.entries.indices.map { idx in
                    HealthKitBatchResponseDTO.SkippedEntry(index: idx, reason: "unmappable_identifier")
                }
                let entries = payload.entries.indices.map { idx in
                    HealthKitBatchResponseDTO.EntryResult(index: idx, status: .skipped, reason: "unmappable_identifier")
                }
                return .success(.init(
                    processed: payload.entries.count,
                    inserted: 0,
                    duplicates: 0,
                    skipped: skipped,
                    entries: entries
                ))
            }
            let uploader = MeasurementBatchUploader(api: api, throttle: Self.zeroJitterThrottle())

            let outcome = await HealthKitService.uploadAndDecide(
                entries: Self.smallChunk,
                uploader: uploader,
                typeIdentifier: "HKQuantityTypeIdentifierRespiratoryRate"
            )

            // Anchor MUSS stehen bleiben — die Daten bleiben in HK on-device
            // und re-synchen, sobald der Server das Mapping nachzieht.
            #expect(outcome == .keepAnchor)
            #expect(api.callCount == 1)
        }

        @Test("Mix aus inserted + skipped(unmappable_identifier) → .keepAnchor (ein einziger transienter Skip reicht)")
        func partialUnmappableSkipKeepsAnchor() async {
            // Selbst wenn ein Teil des Batches durchgeht, hält ein einziger
            // `unmappable_identifier`-Skip den Anchor — sonst verlöre der
            // ungemappte Eintrag den Re-Sync nach dem Server-Cutover. Server
            // dedupliziert die bereits-inserted Einträge via externalId, der
            // Re-Upload ist also safe.
            let api = AnchorTestStubAPI { _, body in
                let payload = try Self.batchDecoder().decode(HealthKitBatchPayload.self, from: body)
                #expect(payload.entries.count == 3)
                return .success(.init(
                    processed: 3,
                    inserted: 2,
                    duplicates: 0,
                    skipped: [.init(index: 2, reason: "unmappable_identifier")],
                    entries: [
                        .init(index: 0, status: .inserted),
                        .init(index: 1, status: .inserted),
                        .init(index: 2, status: .skipped, reason: "unmappable_identifier")
                    ]
                ))
            }
            let uploader = MeasurementBatchUploader(api: api, throttle: Self.zeroJitterThrottle())

            let outcome = await HealthKitService.uploadAndDecide(
                entries: Self.smallChunk,
                uploader: uploader,
                typeIdentifier: "HKQuantityTypeIdentifierWalkingStepLength"
            )

            #expect(outcome == .keepAnchor)
        }

        // MARK: - 5xx → .keepAnchor

        @Test("5xx im einzigen Chunk → .keepAnchor (Anchor bleibt stehen)")
        func serverErrorKeepsAnchor() async {
            let api = AnchorTestStubAPI { _, _ in
                .failure(HLError.server(status: 500, code: "internal_error", message: "boom"))
            }
            let uploader = MeasurementBatchUploader(api: api, throttle: Self.zeroJitterThrottle())

            let outcome = await HealthKitService.uploadAndDecide(
                entries: Self.smallChunk,
                uploader: uploader,
                typeIdentifier: "HKQuantityTypeIdentifierStepCount"
            )

            #expect(outcome == .keepAnchor)
            #expect(api.callCount == 1)
        }

        // MARK: - Network drop → .keepAnchor

        @Test("Network-Drop im einzigen Chunk → .keepAnchor")
        func networkErrorKeepsAnchor() async {
            let api = AnchorTestStubAPI { _, _ in
                .failure(HLError.network(.connectionLost))
            }
            let uploader = MeasurementBatchUploader(api: api, throttle: Self.zeroJitterThrottle())

            let outcome = await HealthKitService.uploadAndDecide(
                entries: Self.smallChunk,
                uploader: uploader,
                typeIdentifier: "HKQuantityTypeIdentifierStepCount"
            )

            #expect(outcome == .keepAnchor)
        }

        @Test("Offline im einzigen Chunk → .keepAnchor")
        func offlineKeepsAnchor() async {
            let api = AnchorTestStubAPI { _, _ in
                .failure(HLError.offline)
            }
            let uploader = MeasurementBatchUploader(api: api, throttle: Self.zeroJitterThrottle())

            let outcome = await HealthKitService.uploadAndDecide(
                entries: Self.smallChunk,
                uploader: uploader,
                typeIdentifier: "HKQuantityTypeIdentifierStepCount"
            )

            #expect(outcome == .keepAnchor)
        }

        // MARK: - Partial-success: Chunk 1 OK, Chunk 2 throws → .keepAnchor

        @Test("Chunk 1 OK, Chunk 2 throws → .keepAnchor (re-fetch handhabt Server via externalId-Dedup)")
        func partialSuccessKeepsAnchor() async {
            // 1200 Entries werden in 3 Chunks (500 + 500 + 200) gesendet. Chunk 1
            // antwortet 2xx, Chunk 2 wirft 503 — Anchor muss bleiben, sonst gingen
            // die Samples aus Chunk 2 + 3 verloren.
            let callIndex = LockedCounter()
            let api = AnchorTestStubAPI { _, body in
                let n = callIndex.increment()
                if n == 2 {
                    return .failure(HLError.server(status: 503, code: "service_unavailable", message: "downstream"))
                }
                let payload = try Self.batchDecoder().decode(HealthKitBatchPayload.self, from: body)
                let entries = payload.entries.indices.map { idx in
                    HealthKitBatchResponseDTO.EntryResult(index: idx, status: .inserted)
                }
                return .success(.init(
                    processed: payload.entries.count,
                    inserted: payload.entries.count,
                    duplicates: 0,
                    skipped: [],
                    entries: entries
                ))
            }
            let uploader = MeasurementBatchUploader(api: api, throttle: Self.zeroJitterThrottle())

            let outcome = await HealthKitService.uploadAndDecide(
                entries: Self.multiChunk,
                uploader: uploader,
                typeIdentifier: "HKQuantityTypeIdentifierStepCount"
            )

            #expect(outcome == .keepAnchor)
            // Chunk 1 + Chunk 2 wurden versucht, Chunk 3 nie (Uploader bricht beim
            // ersten Throw ab). Anchor bleibt stehen → Re-Run holt alle 1200
            // Samples nochmal; Chunk 1 wird via externalId-Dedup als `duplicate`
            // quittiert, Chunk 2 + 3 gehen frisch durch.
            #expect(api.callCount == 2)
        }

        // MARK: - Empty entries → .consumed (defensive: kein Endlos-Loop)

        @Test("Leere Entries → .consumed (kein POST, Anchor advance OK)")
        func emptyEntriesConsumesWithoutPost() async {
            let api = AnchorTestStubAPI { _, _ in
                Issue.record("uploader sollte bei leerem Entries nichts schicken")
                return .success(.init(processed: 0, inserted: 0, duplicates: 0, skipped: [], entries: []))
            }
            let uploader = MeasurementBatchUploader(api: api, throttle: Self.zeroJitterThrottle())

            let outcome = await HealthKitService.uploadAndDecide(
                entries: [],
                uploader: uploader,
                typeIdentifier: "HKQuantityTypeIdentifierStepCount"
            )

            #expect(outcome == .consumed)
            #expect(api.callCount == 0)
        }

        // MARK: - Rate-Limit (429) → .keepAnchor

        @Test("429 Rate-Limit im Uploader → .keepAnchor")
        func rateLimitKeepsAnchor() async {
            let api = AnchorTestStubAPI { _, _ in
                .failure(HLError.rateLimited(retryAfter: 30))
            }
            let uploader = MeasurementBatchUploader(api: api, throttle: Self.zeroJitterThrottle())

            let outcome = await HealthKitService.uploadAndDecide(
                entries: Self.smallChunk,
                uploader: uploader,
                typeIdentifier: "HKQuantityTypeIdentifierStepCount"
            )

            #expect(outcome == .keepAnchor)
        }
    }

    // MARK: - Stub API client (testet Anchor-Decision-Logic, nicht HK selbst)

    /// Stub-APIClient mit per-call Stub-Funktion. Liefert success oder failure
    /// pro Aufruf; Tracking von callCount + Idempotency-Keys bleibt thread-safe.
    private final class AnchorTestStubAPI: APIClientProtocol, @unchecked Sendable {
        typealias Responder = @Sendable (String, Data) throws -> Result<HealthKitBatchResponseDTO, HLError>

        private let lock = NSLock()
        private var _callCount = 0
        private let responder: Responder

        init(responder: @escaping Responder) {
            self.responder = responder
        }

        var callCount: Int {
            lock.withLock { _callCount }
        }

        func send<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> T {
            lock.withLock { _callCount += 1 }
            guard let body = request.body else {
                throw HLError.unknown("test stub: no body")
            }
            switch try responder(request.path, body) {
            case let .success(response):
                guard let typed = response as? T else {
                    throw HLError.unknown("test stub: T mismatch")
                }
                return typed
            case let .failure(error):
                throw error
            }
        }

        func sendVoid(_: APIRequest<EmptyPayload>) async throws {
            lock.withLock { _callCount += 1 }
        }

        func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
            throw HLError.unknown("test stub: download not implemented")
        }
    }

    /// NSLock-geschuetzter Atomic-Counter — wird vom partial-success-Test gebraucht
    /// um den n-ten Aufruf zu identifizieren ohne Actor-Hop in den Stub.
    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() -> Int {
            lock.withLock {
                value += 1
                return value
            }
        }
    }

#endif
