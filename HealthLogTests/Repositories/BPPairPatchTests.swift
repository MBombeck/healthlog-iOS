import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

// swiftlint:disable force_unwrapping force_try

/// T-1 BP-DIA paired-patch fix. Pre-T-1 jeder Edit eines BP-Measurements
/// dropte den diastolischen Wert silently: `MeasurementPatch.value` trug
/// nur einen Double und PATCH ging gegen die systolische Wire-Row alleine.
/// Diese Suite lockt das neue Verhalten fest:
///
/// - `MeasurementAggregator.mergeBloodPressure` populiert
///   `bloodPressureDiastolicId` mit der diastolischen Wire-ID.
/// - `MeasurementPatch.diastolic` lebt nur clientseitig — die Wire-JSON
///   enthält das Feld nicht.
/// - `MeasurementsRepository.update(... kind: .bloodPressure ...)` issuet
///   ZWEI PATCH-Requests (sys-row, dia-row) mit derselben
///   `Idempotency-Key`, returnt das aggregierte Domain-Measurement.
/// - Outbox-Replay re-issuet beide Legs nach App-Restart.
/// - Non-BP-Edits gehen unverändert durch den Single-PATCH-Pfad.
@Suite("BP-pair paired-patch (T-1)", .serialized)
struct BPPairPatchTests {
    // MARK: - Helpers

    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            cfAccessClientID: nil,
            cfAccessClientToken: nil,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
    }

    private func makeRepo() throws -> MeasurementsRepository {
        let api = makeAPI()
        return try MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true))
    }

    /// Records each PATCH request's `(path, body, idempotencyKey)` so a
    /// test can assert "two legs, one shared key, correct payload values."
    private final class RequestRecorder: @unchecked Sendable {
        struct Entry {
            let path: String
            let method: String
            let body: [String: Any]
            let idempotencyKey: String?
        }

        private let lock = NSLock()
        private var entries: [Entry] = []

        func record(_ req: URLRequest) {
            lock.lock()
            defer { lock.unlock() }
            // `URLProtocol.canonicalRequest(for:)` strips the `httpBodyStream`
            // bytes (Foundation copies them into an opaque stream on send),
            // so we read the body via the cached property on the original
            // request. Tests use ephemeral sessions so the body survives.
            var body: [String: Any] = [:]
            if let data = req.httpBody ?? req.httpBodyStream.flatMap(BPPairPatchTests.consumeStream(_:)),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            {
                body = json
            }
            entries.append(Entry(
                path: req.url?.path ?? "",
                method: req.httpMethod ?? "",
                body: body,
                idempotencyKey: req.value(forHTTPHeaderField: "Idempotency-Key")
            ))
        }

        var snapshot: [Entry] {
            lock.lock()
            defer { lock.unlock() }
            return entries
        }
    }

    /// `URLProtocol` swaps `httpBody` for `httpBodyStream` before delivering
    /// the request. Re-materialize the bytes so assertions can read them.
    nonisolated static func consumeStream(_ stream: InputStream) -> Data? {
        stream.open()
        defer { stream.close() }
        var buf = Data()
        let chunkSize = 4096
        var raw = [UInt8](repeating: 0, count: chunkSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&raw, maxLength: chunkSize)
            guard read > 0 else { break }
            buf.append(raw, count: read)
        }
        return buf.isEmpty ? nil : buf
    }

    /// Minimal triple used by handler-routers to pick which leg's wire
    /// envelope to return based on the request path. Keeps swiftlint's
    /// `large_tuple` rule happy (3-arity tuples otherwise trip it).
    private struct WireLeg {
        let id: String
        let type: String
        let value: Double
    }

    /// Build a `MeasurementWireDTO` JSON envelope. Server returns the
    /// `{data: ...}` envelope per `APIClient.decodePayload`. Single-line
    /// JSON keeps the raw-string free of line-continuation backslashes
    /// (which `JSONSerialization` would reject).
    private func wireEnvelope(
        id: String,
        type: String,
        value: Double,
        externalId: String,
        measuredAt: String = "2026-05-01T10:00:00Z"
    ) -> Data {
        let body =
            #"{"data":{"id":"\#(id)","type":"\#(type)","value":\#(value),"measuredAt":"\#(measuredAt)","createdAt":"\#(measuredAt)","source":"MANUAL","externalId":"\#(externalId)","notes":null}}"#
        return Data(body.utf8)
    }

    // MARK: - 1. Aggregator populates diastolic peer-id

    @Test("Aggregator merges sys + dia and exposes both peer ids")
    func aggregatorCarriesDiastolicId() throws {
        let ts = try #require(ISO8601DateFormatter().date(from: "2026-05-01T10:00:00Z"))
        let sys = MeasurementWireDTO(
            id: "srv-sys-1",
            type: .bloodPressureSystolic,
            value: 120,
            measuredAt: ts,
            source: .manual,
            externalId: "shared-uuid"
        )
        let dia = MeasurementWireDTO(
            id: "srv-dia-1",
            type: .bloodPressureDiastolic,
            value: 80,
            measuredAt: ts,
            source: .manual,
            externalId: "shared-uuid"
        )
        let merged = MeasurementAggregator.mergeBloodPressure([sys, dia])
        #expect(merged.count == 1)
        let bp = try #require(merged.first)
        #expect(bp.id == "srv-sys-1", "primary id stays systolic (UI-visible)")
        #expect(bp.bloodPressureDiastolicId == "srv-dia-1", "diastolic peer-id captured for edit fan-out")
        #expect(bp.value == .bloodPressure(systolic: 120, diastolic: 80))
    }

    // MARK: - 2. Patch wire-shape suppresses diastolic

    @Test("MeasurementPatch.diastolic is suppressed from JSON wire-shape")
    func patchDiastolicNotSerialized() throws {
        let patch = MeasurementPatch(value: 120, measuredAt: nil, notes: "morning", diastolic: 80)
        let data = try JSONEncoder.hlDefault.encode(patch)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["value"] as? Double == 120)
        #expect(json["notes"] as? String == "morning")
        #expect(json["diastolic"] == nil, "diastolic is a client-side fan-out intent, not a server field")
    }

    @Test("MeasurementPatch round-trip drops diastolic (wire shape only)")
    func patchRoundTripDropsDiastolic() throws {
        let original = MeasurementPatch(value: 120, diastolic: 80)
        let data = try JSONEncoder.hlDefault.encode(original)
        let decoded = try JSONDecoder.hlDefault.decode(MeasurementPatch.self, from: data)
        #expect(decoded.value == 120)
        #expect(decoded.diastolic == nil, "diastolic only travels via outbox payload, not wire envelope")
    }

    // MARK: - 3. update() fans out to two PATCH legs (BP path)

    @Test("update(kind: .bloodPressure) issues two PATCHes with shared Idempotency-Key")
    func bpUpdateFanout() async throws {
        let repo = try makeRepo()
        let recorder = RequestRecorder()
        MockURLProtocol.handler = { [self] req in
            recorder.record(req)
            let path = req.url?.path ?? ""
            let leg = path.hasSuffix("/srv-sys-1")
                ? WireLeg(id: "srv-sys-1", type: "BLOOD_PRESSURE_SYS", value: 125)
                : WireLeg(id: "srv-dia-1", type: "BLOOD_PRESSURE_DIA", value: 82)
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                wireEnvelope(id: leg.id, type: leg.type, value: leg.value, externalId: "shared-uuid")
            )
        }
        let patch = MeasurementPatch(value: 125, measuredAt: nil, notes: nil, diastolic: 82)
        let result = try await repo.update(
            id: "srv-sys-1",
            patch: patch,
            kind: .bloodPressure,
            diastolicId: "srv-dia-1"
        )
        // Domain result: both peers merged back together.
        #expect(result.value == .bloodPressure(systolic: 125, diastolic: 82))
        #expect(result.bloodPressureDiastolicId == "srv-dia-1")
        let entries = recorder.snapshot
        #expect(entries.count == 2, "BP edit issues two PATCH legs")
        let paths = entries.map(\.path)
        #expect(paths.contains("/api/measurements/srv-sys-1"))
        #expect(paths.contains("/api/measurements/srv-dia-1"))
        // Same Idempotency-Key on both legs — server dedup catches replay races.
        let keys = Set(entries.compactMap(\.idempotencyKey))
        #expect(keys.count == 1, "both legs share one Idempotency-Key")
        // Values land on the right legs.
        let sysLeg = try #require(entries.first(where: { $0.path.hasSuffix("/srv-sys-1") }))
        let diaLeg = try #require(entries.first(where: { $0.path.hasSuffix("/srv-dia-1") }))
        #expect(sysLeg.body["value"] as? Double == 125)
        #expect(diaLeg.body["value"] as? Double == 82)
        #expect(sysLeg.body["diastolic"] == nil, "wire body has no diastolic key")
        #expect(diaLeg.body["diastolic"] == nil, "wire body has no diastolic key")
    }

    // MARK: - 4. Non-BP edit keeps single-PATCH semantics

    @Test("update(kind: .weight) keeps single-PATCH path unaffected")
    func nonBPSinglePatch() async throws {
        let repo = try makeRepo()
        let recorder = RequestRecorder()
        MockURLProtocol.handler = { req in
            recorder.record(req)
            let body =
                #"{"data":{"id":"srv-w-1","type":"WEIGHT","value":72.4,"measuredAt":"2026-05-01T10:00:00Z","createdAt":"2026-05-01T10:00:00Z","source":"MANUAL","externalId":null,"notes":"updated"}}"#
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(body.utf8)
            )
        }
        _ = try await repo.update(
            id: "srv-w-1",
            patch: MeasurementPatch(value: 72.4, measuredAt: nil, notes: "updated"),
            kind: .weight
        )
        let entries = recorder.snapshot
        #expect(entries.count == 1, "non-BP edit remains a single PATCH")
        #expect(entries[0].path == "/api/measurements/srv-w-1")
        #expect(entries[0].body["value"] as? Double == 72.4)
    }

    // MARK: - 5. Outbox round-trip preserves the paired fan-out on replay

    @Test("Outbox-replay re-issues both BP legs with persisted Idempotency-Key")
    func outboxReplayFansOut() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        let key = "key-bp-paired-1"
        // Persist a BP-pair update with both peer-ids + values.
        let payload = OutboxQueue.Payloads.UpdateMeasurement(
            id: "srv-sys-9",
            patch: MeasurementPatch(value: 130, measuredAt: nil, notes: nil),
            kind: .bloodPressure,
            diastolicId: "srv-dia-9",
            diastolicValue: 85
        )
        let data = try JSONEncoder.hlDefault.encode(payload)
        try await outbox.enqueue(.init(
            id: UUID(),
            kind: .updateMeasurement,
            payload: data,
            idempotencyKey: key,
            createdAt: .now
        ))
        // Round-trip through replay confirms both legs go out.
        let recorder = RequestRecorder()
        MockURLProtocol.handler = { [self] req in
            recorder.record(req)
            let path = req.url?.path ?? ""
            let leg = path.hasSuffix("/srv-sys-9")
                ? WireLeg(id: "srv-sys-9", type: "BLOOD_PRESSURE_SYS", value: 130)
                : WireLeg(id: "srv-dia-9", type: "BLOOD_PRESSURE_DIA", value: 85)
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                wireEnvelope(id: leg.id, type: leg.type, value: leg.value, externalId: "shared-uuid-9")
            )
        }
        let replay = OutboxReplayService(
            outbox: outbox,
            measurementsRepo: MeasurementsRepository(api: api, outbox: outbox),
            moodRepo: MoodRepository(api: api, outbox: outbox),
            medicationsRepo: MedicationsRepository(api: api, outbox: outbox),
            maxAttempts: 4
        )
        await replay.runOnce()
        #expect(await (outbox.snapshot).isEmpty, "successful replay drains the row")
        let entries = recorder.snapshot
        #expect(entries.count == 2, "replay fans out exactly the two paired PATCHes")
        let paths = entries.map(\.path)
        #expect(paths.contains("/api/measurements/srv-sys-9"))
        #expect(paths.contains("/api/measurements/srv-dia-9"))
        // Both legs reuse the persisted key.
        let keys = Set(entries.compactMap(\.idempotencyKey))
        #expect(keys == [key], "persisted Idempotency-Key flows into both legs")
    }

    // MARK: - 6. Outbox payload round-trip preserves the new fields

    @Test("UpdateMeasurement payload Codable round-trip preserves diastolic peer info")
    func payloadRoundTrip() throws {
        let original = OutboxQueue.Payloads.UpdateMeasurement(
            id: "srv-sys-7",
            patch: MeasurementPatch(value: 122, measuredAt: nil, notes: "after sport"),
            kind: .bloodPressure,
            diastolicId: "srv-dia-7",
            diastolicValue: 81
        )
        let data = try JSONEncoder.hlDefault.encode(original)
        let decoded = try JSONDecoder.hlDefault.decode(OutboxQueue.Payloads.UpdateMeasurement.self, from: data)
        #expect(decoded.id == "srv-sys-7")
        #expect(decoded.diastolicId == "srv-dia-7")
        #expect(decoded.diastolicValue == 81)
        #expect(decoded.kind == .bloodPressure)
        #expect(decoded.patch.value == 122)
        #expect(decoded.patch.notes == "after sport")
    }
}

// swiftlint:enable force_unwrapping force_try
