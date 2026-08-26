// F8 hotfix v0.4.1.1 — POST-Backoff Tests
//
// Verifizieren: nach >5 Failures in 60s aktiviert `MeasurementBatchUploader`
// einen exponentiellen Backoff (15s → 60s → 5min → 30min). Pre-Flight-Check
// wirft `BatchBackoffError.throttled` solange der Block aktiv ist. Erster
// Erfolg resettet den Counter.

import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

@Suite("MeasurementBatchUploader POST-Backoff (F8 hotfix v0.4.1.1)")
struct MeasurementBatchUploaderBackoffTests {
    /// Hilfs-DTO, das in 1er-Chunks resultiert (jeder POST ist ein Chunk).
    private static func makeEntry(externalId: String) -> HealthKitBatchEntryDTO {
        .init(
            hkIdentifier: "HKQuantityTypeIdentifierStepCount",
            value: 100,
            unit: "count",
            startDate: Date(timeIntervalSince1970: 1_715_673_600),
            endDate: Date(timeIntervalSince1970: 1_715_677_200),
            externalId: externalId
        )
    }

    @Test("Pre-flight-check laesst Calls durch wenn keine Failures")
    func cleanStateAllowsCall() async throws {
        let api = BackoffStubAPI(failure: false)
        let throttle = BatchSyncThrottle(maxPerWindow: 1000, jitter: 0 ... 0)
        let uploader = MeasurementBatchUploader(api: api, throttle: throttle)

        let outcomes = try await uploader.upload([Self.makeEntry(externalId: "e1")])
        #expect(outcomes.count == 1)
        let snap = await uploader.backoffSnapshot()
        #expect(snap.failuresInWindow == 0)
        #expect(snap.blockedUntil == nil)
        #expect(snap.step == 0)
    }

    @Test("Failures unter Threshold loesen KEINEN Backoff aus")
    func subThresholdNoBlock() async {
        let api = BackoffStubAPI(failure: true)
        let throttle = BatchSyncThrottle(maxPerWindow: 1000, jitter: 0 ... 0)
        let uploader = MeasurementBatchUploader(api: api, throttle: throttle)

        // 5 failures = threshold, brauchen STRICT >5 fuer Block
        for i in 0 ..< 5 {
            _ = try? await uploader.upload([Self.makeEntry(externalId: "e\(i)")])
        }
        let snap = await uploader.backoffSnapshot()
        #expect(snap.failuresInWindow == 5)
        #expect(snap.blockedUntil == nil)
    }

    @Test("Mehr als Threshold-Failures aktiviert Backoff-Block")
    func overThresholdActivatesBlock() async {
        let api = BackoffStubAPI(failure: true)
        let throttle = BatchSyncThrottle(maxPerWindow: 1000, jitter: 0 ... 0)
        let uploader = MeasurementBatchUploader(api: api, throttle: throttle)

        for i in 0 ..< 6 {
            _ = try? await uploader.upload([Self.makeEntry(externalId: "e\(i)")])
        }
        let snap = await uploader.backoffSnapshot()
        #expect(snap.failuresInWindow == 6)
        #expect(snap.blockedUntil != nil)
        #expect(snap.step == 1) // 15s war Stufe 0, naechste ist Stufe 1
    }

    @Test("Backoff-Block wirft BatchBackoffError.throttled")
    func blockedCallThrowsThrottled() async throws {
        let api = BackoffStubAPI(failure: true)
        let throttle = BatchSyncThrottle(maxPerWindow: 1000, jitter: 0 ... 0)
        let uploader = MeasurementBatchUploader(api: api, throttle: throttle)

        // Erst die Failures bauen, damit blockedUntil gesetzt ist
        for i in 0 ..< 6 {
            _ = try? await uploader.upload([Self.makeEntry(externalId: "e\(i)")])
        }
        // Naechste Call sollte vom Pre-Flight-Check geblockt werden
        var sawThrottled = false
        do {
            _ = try await uploader.upload([Self.makeEntry(externalId: "block")])
        } catch let BatchBackoffError.throttled(retryAfter) {
            sawThrottled = true
            #expect(retryAfter > Date())
        } catch {
            // Anderer Fehler ist okay — solange wenigstens der Throttled-Pfad
            // gewinnt wenn er greift. Hier muss er greifen.
            Issue.record("Erwartet BatchBackoffError.throttled, bekommen: \(error)")
        }
        #expect(sawThrottled)
    }

    @Test("Erster Success leert Failure-Window komplett")
    func firstSuccessResetsCounter() async throws {
        let api = BackoffStubAPI(failure: true)
        let throttle = BatchSyncThrottle(maxPerWindow: 1000, jitter: 0 ... 0)
        let uploader = MeasurementBatchUploader(api: api, throttle: throttle)

        for i in 0 ..< 3 {
            _ = try? await uploader.upload([Self.makeEntry(externalId: "fail\(i)")])
        }
        let before = await uploader.backoffSnapshot()
        #expect(before.failuresInWindow == 3)

        // Switch to success, naechster Call ist erfolgreich
        await api.setFailure(false)
        _ = try await uploader.upload([Self.makeEntry(externalId: "good")])

        let after = await uploader.backoffSnapshot()
        #expect(after.failuresInWindow == 0)
        #expect(after.blockedUntil == nil)
        #expect(after.step == 0)
    }
}

// MARK: - Stub API

private actor BackoffStubAPI: APIClientProtocol {
    private var shouldFail: Bool

    init(failure: Bool) {
        shouldFail = failure
    }

    func setFailure(_ value: Bool) {
        shouldFail = value
    }

    func send<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> T {
        if shouldFail {
            throw HLError.unknown("backoff-stub: simulated failure")
        }
        // Default-Success-Antwort fuer den `/api/measurements/batch`-Pfad.
        guard let body = request.body else {
            throw HLError.unknown("backoff-stub: missing body")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(HealthKitBatchPayload.self, from: body)
        let entries: [HealthKitBatchResponseDTO.EntryResult] = payload.entries.enumerated().map { idx, _ in
            .init(index: idx, status: .inserted)
        }
        let response = HealthKitBatchResponseDTO(
            processed: payload.entries.count,
            inserted: payload.entries.count,
            duplicates: 0,
            skipped: [],
            entries: entries
        )
        guard let typed = response as? T else {
            throw HLError.unknown("backoff-stub: T mismatch")
        }
        return typed
    }

    func sendVoid(_: APIRequest<EmptyPayload>) async throws {}

    func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
        throw HLError.unknown("backoff-stub: download not implemented")
    }
}
