import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// Verifiziert, dass der `MeasurementBatchUploader` nach jedem erfolgreichen
/// POST den `successNotifier` aufruft — der Hook hängt im AppContainer am
/// `HKReadinessStore.noteSuccessfulSync` und treibt das "Zuletzt synchronisiert"-
/// Surface in Settings → Apple Health (F7 §5).
@Suite("MeasurementBatchUploader successNotifier")
struct MeasurementBatchUploaderNotifierTests {
    private static let entries: [HealthKitBatchEntryDTO] = [
        .init(
            hkIdentifier: "HKQuantityTypeIdentifierStepCount",
            value: 1234, unit: "count",
            startDate: Date(timeIntervalSince1970: 1_715_673_600),
            endDate: Date(timeIntervalSince1970: 1_715_716_800),
            externalId: "ext-0"
        )
    ]

    @Test("Notifier feuert exakt einmal pro Chunk auf 2xx")
    func notifierFiresOnSuccess() async throws {
        let api = NotifierStubAPI()
        let throttle = BatchSyncThrottle(maxPerWindow: 60, window: 60.0, jitter: 0 ... 0)
        let uploader = MeasurementBatchUploader(api: api, throttle: throttle)

        let collector = TimestampCollector()
        await uploader.setSuccessNotifier { date in
            await collector.append(date)
        }

        _ = try await uploader.upload(Self.entries)

        let timestamps = await collector.values
        #expect(timestamps.count == 1)
        #expect(api.callCount == 1)
    }

    @Test("Notifier feuert pro Chunk separat — chunked 1200 entries = 3 calls")
    func notifierFiresPerChunk() async throws {
        let entries: [HealthKitBatchEntryDTO] = (0 ..< 1200).map { idx in
            .init(
                hkIdentifier: "HKQuantityTypeIdentifierStepCount",
                value: Double(idx), unit: "count",
                startDate: Date(timeIntervalSince1970: TimeInterval(idx)),
                endDate: Date(timeIntervalSince1970: TimeInterval(idx + 60)),
                externalId: "ext-\(idx)"
            )
        }
        let api = NotifierStubAPI()
        let throttle = BatchSyncThrottle(maxPerWindow: 60, window: 60.0, jitter: 0 ... 0)
        let uploader = MeasurementBatchUploader(api: api, throttle: throttle)

        let collector = TimestampCollector()
        await uploader.setSuccessNotifier { date in
            await collector.append(date)
        }

        _ = try await uploader.upload(entries)

        let timestamps = await collector.values
        #expect(timestamps.count == 3) // 500 + 500 + 200 = 3 chunks
        #expect(api.callCount == 3)
    }

    @Test("Notifier feuert NICHT wenn der POST wirft (Server-Fehler)")
    func notifierSkipsOnFailure() async throws {
        let api = NotifierStubAPI(shouldThrow: true)
        let throttle = BatchSyncThrottle(maxPerWindow: 60, window: 60.0, jitter: 0 ... 0)
        let uploader = MeasurementBatchUploader(api: api, throttle: throttle)

        let collector = TimestampCollector()
        await uploader.setSuccessNotifier { date in
            await collector.append(date)
        }

        do {
            _ = try await uploader.upload(Self.entries)
            Issue.record("Erwartet Throw, kam keiner")
        } catch {
            // expected
        }

        let timestamps = await collector.values
        #expect(timestamps.isEmpty)
    }
}

// MARK: - Helpers

private actor TimestampCollector {
    private(set) var values: [Date] = []
    func append(_ date: Date) {
        values.append(date)
    }
}

private final class NotifierStubAPI: APIClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _callCount = 0
    private let shouldThrow: Bool

    init(shouldThrow: Bool = false) {
        self.shouldThrow = shouldThrow
    }

    var callCount: Int {
        lock.withLock { _callCount }
    }

    func send<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> T {
        if shouldThrow {
            throw HLError.unknown("stub: forced failure")
        }
        lock.withLock { _callCount += 1 }
        guard let body = request.body else {
            throw HLError.unknown("stub: no body")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(HealthKitBatchPayload.self, from: body)
        let entries = payload.entries.enumerated().map { idx, _ in
            HealthKitBatchResponseDTO.EntryResult(index: idx, status: .inserted)
        }
        let response = HealthKitBatchResponseDTO(
            processed: payload.entries.count,
            inserted: payload.entries.count,
            duplicates: 0,
            skipped: [],
            entries: entries
        )
        guard let typed = response as? T else {
            throw HLError.unknown("stub: T mismatch")
        }
        return typed
    }

    func sendVoid(_: APIRequest<EmptyPayload>) async throws {
        lock.withLock { _callCount += 1 }
    }

    func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
        throw HLError.unknown("stub: download not implemented")
    }
}
