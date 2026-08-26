import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

@Suite("MeasurementBatchUploader cursor-advance contract")
struct BatchUploadOutcomeTests {
    /// Decoder mit iso8601 — symmetrisch zu `JSONEncoder.hlBatch`.
    static func batchDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static let chunk: [HealthKitBatchEntryDTO] = [
        .init(
            hkIdentifier: "HKQuantityTypeIdentifierStepCount",
            value: 1234, unit: "count",
            startDate: Date(timeIntervalSince1970: 1_715_673_600),
            endDate: Date(timeIntervalSince1970: 1_715_716_800),
            externalId: "ext-0"
        ),
        .init(
            hkIdentifier: "HKQuantityTypeIdentifierStepCount",
            value: 2345, unit: "count",
            startDate: Date(timeIntervalSince1970: 1_715_716_800),
            endDate: Date(timeIntervalSince1970: 1_715_760_000),
            externalId: "ext-1"
        ),
        .init(
            hkIdentifier: "HKQuantityTypeIdentifierMadeUpType",
            value: 99, unit: "x",
            startDate: Date(timeIntervalSince1970: 1_715_760_000),
            endDate: Date(timeIntervalSince1970: 1_715_803_200),
            externalId: "ext-2"
        )
    ]

    @Test("inserted + duplicate + skipped sind ALLE cursor-advance — externalIds enthalten alle drei")
    func cursorAdvancesPastAllStatuses() {
        let response = HealthKitBatchResponseDTO(
            processed: 3,
            inserted: 1,
            duplicates: 1,
            skipped: [.init(index: 2, reason: "unmappable_identifier")],
            entries: [
                .init(index: 0, status: .inserted),
                .init(index: 1, status: .duplicate),
                .init(index: 2, status: .skipped, reason: "unmappable_identifier")
            ]
        )
        let outcome = BatchUploadOutcome(chunk: Self.chunk, response: response)
        #expect(outcome.consumedIndexes == [0, 1, 2])
        #expect(outcome.successfulExternalIds == ["ext-0", "ext-1", "ext-2"])
        #expect(outcome.skipped.count == 1)
        #expect(outcome.skipped.first?.reason == "unmappable_identifier")
    }

    @Test("Out-of-range Index in der Antwort wird ignoriert (defensive)")
    func outOfRangeIndexIgnored() {
        let response = HealthKitBatchResponseDTO(
            processed: 3,
            inserted: 1,
            duplicates: 0,
            skipped: [],
            entries: [
                .init(index: 0, status: .inserted),
                .init(index: 99, status: .inserted) // bug-on-server, wir crashen nicht
            ]
        )
        let outcome = BatchUploadOutcome(chunk: Self.chunk, response: response)
        #expect(outcome.successfulExternalIds == ["ext-0"])
        // consumedIndexes reflektiert den Server (auch invalide), nur die externalId-
        // Lookup ist defensive.
        #expect(outcome.consumedIndexes == [0, 99])
    }

    @Test("Empty entries liefert leere outcomes")
    func emptyEntriesShortCircuit() async throws {
        let api = BatchUploaderStubAPI()
        let throttle = BatchSyncThrottle(maxPerWindow: 60, window: 60.0, jitter: 0 ... 0)
        let uploader = MeasurementBatchUploader(api: api, throttle: throttle)
        let outcomes = try await uploader.upload([])
        #expect(outcomes.isEmpty)
        #expect(api.callCount == 0)
    }

    @Test("Chunked >500 Entries → mehrere POSTs mit unterschiedlichen Idempotency-Keys")
    func chunksAtFiveHundred() async throws {
        let entries: [HealthKitBatchEntryDTO] = (0 ..< 1200).map { idx in
            .init(
                hkIdentifier: "HKQuantityTypeIdentifierStepCount",
                value: Double(idx), unit: "count",
                startDate: Date(timeIntervalSince1970: TimeInterval(idx)),
                endDate: Date(timeIntervalSince1970: TimeInterval(idx + 60)),
                externalId: "ext-\(idx)"
            )
        }
        let api = BatchUploaderStubAPI { _, body in
            // Mirror the 1:1 inserted-status response for whatever was sent.
            let payload = try Self.batchDecoder().decode(HealthKitBatchPayload.self, from: body)
            let entries = payload.entries.enumerated().map { idx, _ in
                HealthKitBatchResponseDTO.EntryResult(index: idx, status: .inserted)
            }
            return HealthKitBatchResponseDTO(
                processed: payload.entries.count,
                inserted: payload.entries.count,
                duplicates: 0,
                skipped: [],
                entries: entries
            )
        }
        let throttle = BatchSyncThrottle(maxPerWindow: 60, window: 60.0, jitter: 0 ... 0)
        let uploader = MeasurementBatchUploader(api: api, throttle: throttle)
        let outcomes = try await uploader.upload(entries)
        // 1200 / 500 = 3 Batches (500 + 500 + 200).
        #expect(outcomes.count == 3)
        #expect(outcomes.map(\.chunk.count) == [500, 500, 200])
        #expect(api.callCount == 3)
        // Idempotency-Keys sind pro Batch unique — der erste Header darf nicht der
        // zweite sein. Wir loggen die Keys im Stub.
        let keys = api.idempotencyKeys
        #expect(Set(keys).count == 3)
    }
}

// MARK: - Stub API client

private final class BatchUploaderStubAPI: APIClientProtocol, @unchecked Sendable {
    typealias Responder = @Sendable (String, Data) throws -> HealthKitBatchResponseDTO

    private let lock = NSLock()
    private var _callCount = 0
    private var _idempotencyKeys: [String] = []
    private let responder: Responder?

    init(responder: Responder? = nil) {
        self.responder = responder
    }

    var callCount: Int {
        lock.withLock { _callCount }
    }

    var idempotencyKeys: [String] {
        lock.withLock { _idempotencyKeys }
    }

    func send<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> T {
        lock.withLock {
            _callCount += 1
            _idempotencyKeys.append(request.idempotencyKey.headerValue)
        }
        guard let body = request.body else {
            throw HLError.unknown("test stub: no body")
        }
        // Default: pretend everything inserted.
        let response: HealthKitBatchResponseDTO
        if let responder {
            response = try responder(request.path, body)
        } else {
            let payload = try BatchUploadOutcomeTests.batchDecoder().decode(HealthKitBatchPayload.self, from: body)
            let entryResults: [HealthKitBatchResponseDTO.EntryResult] = payload.entries.enumerated().map { idx, _ in
                HealthKitBatchResponseDTO.EntryResult(index: idx, status: .inserted)
            }
            response = HealthKitBatchResponseDTO(
                processed: payload.entries.count,
                inserted: payload.entries.count,
                duplicates: 0,
                skipped: [],
                entries: entryResults
            )
        }
        guard let typed = response as? T else {
            throw HLError.unknown("test stub: T mismatch")
        }
        return typed
    }

    func sendVoid(_: APIRequest<EmptyPayload>) async throws {
        lock.withLock { _callCount += 1 }
    }

    func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
        throw HLError.unknown("test stub: download not implemented")
    }
}
