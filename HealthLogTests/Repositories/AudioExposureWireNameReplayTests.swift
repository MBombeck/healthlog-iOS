import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **POLISH-B B6 (1.5, REG public #13).** Until REG, the environmental noise
/// event went out under HealthKit's run-time string
/// `HKCategoryTypeIdentifierAudioExposureEvent`, which the server (v1.47.0)
/// does not map. Every such row came back `unmappable_identifier`, and the
/// importer parked it in the durable outbox. Those parked rows carry the old
/// name in their persisted bytes; a replay must send them under the server's
/// name, or they are refused again on every pass for ever.
///
/// The update path: the row is written exactly as a 1.4.1 installation wrote
/// it (same DTO, same encoder, old name), then replayed by this build.
@Suite("POLISH-B B6 — parked noise events replay under the server's name", .serialized, .mockURLSession)
struct AudioExposureWireNameReplayTests {
    static let oldName = "HKCategoryTypeIdentifierAudioExposureEvent"
    static let serverName = "HKCategoryTypeIdentifierEnvironmentalAudioExposureEvent"

    static let parkedEntry = HealthKitBatchEntryDTO(
        hkIdentifier: oldName,
        value: 1,
        unit: "count",
        startDate: Date(timeIntervalSince1970: 1_760_000_000),
        endDate: Date(timeIntervalSince1970: 1_760_000_600),
        categoryValue: 1,
        externalId: "hk:noise-1"
    )

    /// The server's answer: it maps only its own name.
    static func answer(for body: Data) -> Data {
        let sent = try? JSONDecoder.hlDefault.decode(HealthKitBatchPayload.self, from: body)
        let mapped = sent?.entries.first?.hkIdentifier == serverName
        let skipped = #"{"index":0,"reason":"unmappable_identifier"}"#
        let refused = #"{"index":0,"status":"skipped","reason":"unmappable_identifier"}"#
        let json = mapped
            ? #"{"data":{"processed":1,"inserted":1,"duplicates":0,"skipped":[],"entries":[{"index":0,"status":"inserted"}]},"error":null}"#
            : #"{"data":{"processed":1,"inserted":0,"duplicates":0,"skipped":["# + skipped + #"],"entries":["# + refused
            + #"]},"error":null}"#
        return Data(json.utf8)
    }

    private final class Bodies: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Data] = []
        func append(_ data: Data) {
            lock.lock()
            defer { lock.unlock() }
            stored.append(data)
        }

        var all: [Data] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    private func makeAPI() -> APIClient {
        let environment = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            cfAccessClientID: nil,
            cfAccessClientToken: nil,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        return APIClient(environment: environment, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
    }

    @Test("a row parked by 1.4.1 under the old name is sent under the server's name and drains")
    func parkedRowReplaysUnderServerName() async throws {
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { "user-a" })
        let key = try #require(
            HealthSyncRetryEnvelope(ownerID: "user-a", source: .speziSamples, stableIdentity: "hk:noise-1")
        ).idempotencyKey
        try await outbox.enqueueHealthKitBatch(
            [Self.parkedEntry],
            encoder: .hlBatch,
            idempotencyKey: key,
            requiringCurrentOwner: "user-a"
        )
        let persisted = try #require(await outbox.snapshot.first)
        let stored = try JSONDecoder.hlDefault.decode(HealthKitBatchPayload.self, from: persisted.payload)
        #expect(stored.entries.first?.hkIdentifier == Self.oldName, "the fixture is the 1.4.1 row")

        let bodies = Bodies()
        MockURLProtocol.install { request in
            let body = request.audioExposureBodyBytes()
            if request.targets("/api/measurements/batch") { bodies.append(body) }
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Self.answer(for: body)
            )
        }
        let api = makeAPI()
        let replay = OutboxReplayService(
            outbox: outbox,
            measurementsRepo: MeasurementsRepository(api: api, outbox: outbox),
            moodRepo: MoodRepository(api: api, outbox: outbox),
            medicationsRepo: MedicationsRepository(api: api, outbox: outbox),
            currentUserProvider: { "user-a" },
            maxAttempts: 8,
            attemptBackoff: 0
        )
        await replay.runOnce()

        let sent = try #require(bodies.all.first, "the replay posted the row")
        let payload = try JSONDecoder.hlDefault.decode(HealthKitBatchPayload.self, from: sent)
        #expect(payload.entries.map(\.hkIdentifier) == [Self.serverName])
        #expect(payload.entries.map(\.externalId) == ["hk:noise-1"], "same row, same identity")
        #expect(await outbox.snapshot.isEmpty, "accepted under the server's name, the row drains")
    }

    @Test("every other identifier replays byte-for-byte unchanged")
    func otherIdentifiersUnchanged() async throws {
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { "user-a" })
        let key = try #require(
            HealthSyncRetryEnvelope(ownerID: "user-a", source: .speziSamples, stableIdentity: "hk:mass-1")
        ).idempotencyKey
        let mass = HealthKitBatchEntryDTO(
            hkIdentifier: "HKQuantityTypeIdentifierBodyMass",
            value: 81,
            unit: "kg",
            startDate: Date(timeIntervalSince1970: 1_760_000_000),
            endDate: Date(timeIntervalSince1970: 1_760_000_000),
            externalId: "hk:mass-1"
        )
        try await outbox.enqueueHealthKitBatch([mass], encoder: .hlBatch, idempotencyKey: key, requiringCurrentOwner: "user-a")
        let persisted = try #require(await outbox.snapshot.first).payload

        let bodies = Bodies()
        MockURLProtocol.install { request in
            let body = request.audioExposureBodyBytes()
            if request.targets("/api/measurements/batch") { bodies.append(body) }
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(
                    #"{"data":{"processed":1,"inserted":1,"duplicates":0,"skipped":[],"entries":[{"index":0,"status":"inserted"}]},"error":null}"#
                        .utf8
                )
            )
        }
        let api = makeAPI()
        await OutboxReplayService(
            outbox: outbox,
            measurementsRepo: MeasurementsRepository(api: api, outbox: outbox),
            moodRepo: MoodRepository(api: api, outbox: outbox),
            medicationsRepo: MedicationsRepository(api: api, outbox: outbox),
            currentUserProvider: { "user-a" },
            maxAttempts: 8,
            attemptBackoff: 0
        ).runOnce()

        let sent = try #require(bodies.all.first)
        let sentEntries = try JSONDecoder.hlDefault.decode(HealthKitBatchPayload.self, from: sent).entries
        let storedEntries = try JSONDecoder.hlDefault.decode(HealthKitBatchPayload.self, from: persisted).entries
        #expect(sentEntries == storedEntries)
    }
}

#if canImport(HealthKit) && canImport(SpeziHealthKit)
    /// The other way a refused row comes back: the skip register's re-offer
    /// after an update (or "Resend skipped").
    @Suite("POLISH-B B6 — re-offered noise events go out under the server's name")
    struct AudioExposureWireNameReofferTests {
        @Test("a register row with the old name is offered under the server's name and leaves the register")
        func reofferUsesServerName() async throws {
            let register = HealthKitSkippedRowRegister(storage: SkipRegisterBacking().storage)
            try await register.record(
                [HealthKitSkippedEntry(entry: AudioExposureWireNameReplayTests.parkedEntry, reason: "unmappable_identifier")],
                ownerID: "user-a",
                build: "299"
            )
            let offered = OfferedNames()
            let reoffer = HealthKitSkippedRowReoffer(register: register) { entries in
                offered.set(entries.map(\.hkIdentifier))
                let body = try JSONEncoder.hlBatch.encode(HealthKitBatchPayload(entries: entries))
                let envelope = AudioExposureWireNameReplayTests.answer(for: body)
                let response = try JSONDecoder.hlDefault.decode(APIEnvelope<HealthKitBatchResponseDTO>.self, from: envelope)
                return try [BatchUploadOutcome(chunk: entries, response: #require(response.data))]
            }
            let summary = await reoffer.run(ownerID: "user-a", build: "300", force: true)

            #expect(offered.names == [AudioExposureWireNameReplayTests.serverName])
            #expect(summary.stored == 1)
            #expect(await register.rows(ownerID: "user-a").isEmpty)
        }

        private final class OfferedNames: @unchecked Sendable {
            private let lock = NSLock()
            private var stored: [String] = []
            func set(_ names: [String]) {
                lock.lock()
                defer { lock.unlock() }
                stored = names
            }

            var names: [String] {
                lock.lock()
                defer { lock.unlock() }
                return stored
            }
        }
    }
#endif

private extension URLRequest {
    /// `httpBody` or the upload stream URLSession turned it into.
    func audioExposureBodyBytes() -> Data {
        if let body = httpBody { return body }
        guard let stream = httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: 4096)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

// swiftlint:enable force_unwrapping
