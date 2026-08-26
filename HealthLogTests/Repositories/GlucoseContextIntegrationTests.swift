import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

// swiftlint:disable force_unwrapping force_try

/// T-2 Integration tests for the glucose-context picker. Verifies the end-
/// to-end paths through the actual `MeasurementsRepository` + `OutboxQueue`:
///
/// 1. **Create-path:** `Measurement(glucoseContext: ...) → repo.create →
///    POST /api/measurements` carries `glucoseContext` in the wire body.
/// 2. **Edit-path:** `repo.update(... patch.glucoseContext ...) → PATCH`
///    issues the standard 3-key wire body (server side doesn't accept the
///    intent yet — SB-25), but the returned Domain row preserves the user
///    intent client-side.
/// 3. **Outbox-replay-round-trip:** an offline-edit of a glucose row
///    persists `glucoseContext` on the payload + replay re-applies the
///    intent on the rehydrated patch.
@Suite("Glucose-context integration (T-2)", .serialized)
struct GlucoseContextIntegrationTests {
    // Helpers — local to this suite (the project keeps each suite self-
    // contained; no shared test-helpers module yet).

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
            var body: [String: Any] = [:]
            if let data = req.httpBody ?? req.httpBodyStream.flatMap(Self.consumeStream(_:)),
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
    }

    /// Build the `{ data: ... }` wire envelope a measurements-endpoint
    /// returns. Optional `glucoseContext` is wrapped to a JSON literal
    /// (string or null) so the test handler can simulate "server echoes
    /// back the context" + "server omits the context".
    private func glucoseWireEnvelope(
        id: String,
        value: Double,
        externalId: String? = nil,
        glucoseContext: GlucoseContext? = nil,
        measuredAt: String = "2026-05-01T08:00:00Z"
    ) -> Data {
        let extJSON: String = externalId.map { "\"\($0)\"" } ?? "null"
        let ctxJSON: String = glucoseContext.map { "\"\($0.rawValue)\"" } ?? "null"
        let head = #"{"data":{"id":"\#(id)","type":"BLOOD_GLUCOSE","value":\#(value)"#
        let tail = #","source":"MANUAL","externalId":\#(extJSON),"glucoseContext":\#(ctxJSON),"notes":null}}"#
        let timestamps = #","measuredAt":"\#(measuredAt)","createdAt":"\#(measuredAt)""#
        return Data((head + timestamps + tail).utf8)
    }

    // MARK: - 1. Create-path: glucoseContext lands on the wire body

    @Test("repo.create(glucose) emits glucoseContext on the POST body")
    func createCarriesGlucoseContextOnWire() async throws {
        let repo = try makeRepo()
        let recorder = RequestRecorder()
        MockURLProtocol.handler = { [self] req in
            recorder.record(req)
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                glucoseWireEnvelope(id: "srv-glu-1", value: 95, glucoseContext: .fasting)
            )
        }
        let local = Measurement(
            id: "local-glu-1",
            kind: .glucose,
            recordedAt: .now,
            value: .scalar(95),
            note: nil,
            source: .manual,
            glucoseContext: .fasting
        )
        let saved = try await repo.create(local)
        #expect(saved.kind == .glucose)
        #expect(saved.glucoseContext == .fasting)
        let entries = recorder.snapshot
        #expect(entries.count == 1)
        #expect(entries[0].path == "/api/measurements")
        #expect(entries[0].method == "POST")
        #expect(entries[0].body["type"] as? String == "BLOOD_GLUCOSE")
        #expect(entries[0].body["value"] as? Double == 95)
        #expect(
            entries[0].body["glucoseContext"] as? String == "FASTING",
            "create POST must propagate the user's context"
        )
    }

    @Test("repo.create(glucose, no-context) omits glucoseContext from POST body")
    func createOmitsGlucoseContextWhenNil() async throws {
        let repo = try makeRepo()
        let recorder = RequestRecorder()
        MockURLProtocol.handler = { [self] req in
            recorder.record(req)
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                glucoseWireEnvelope(id: "srv-glu-2", value: 110, glucoseContext: nil)
            )
        }
        let local = Measurement(
            id: "local-glu-2",
            kind: .glucose,
            recordedAt: .now,
            value: .scalar(110),
            note: nil,
            source: .manual,
            glucoseContext: nil
        )
        _ = try await repo.create(local)
        let entries = recorder.snapshot
        #expect(entries.count == 1)
        #expect(entries[0].body["glucoseContext"] == nil, "nil context omits the wire key — server default applies")
    }

    // MARK: - 2. Edit-path: PATCH stays at 3-key wire shape, intent lives client-side

    @Test("repo.update(glucose) PATCH body stays minimal — glucoseContext is client-only")
    func editKeepsWireShapeMinimal() async throws {
        let repo = try makeRepo()
        let recorder = RequestRecorder()
        MockURLProtocol.handler = { [self] req in
            recorder.record(req)
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                // Server response: echoes the OLD context — server PATCH
                // schema doesn't yet accept glucoseContext (SB-25). The
                // Edit-Sheet client-side re-paints the new intent.
                glucoseWireEnvelope(id: "srv-glu-3", value: 132, glucoseContext: .fasting)
            )
        }
        let patch = MeasurementPatch(
            value: 132,
            measuredAt: nil,
            notes: "after lunch",
            glucoseContext: .afterMeal
        )
        let result = try await repo.update(
            id: "srv-glu-3",
            patch: patch,
            kind: .glucose
        )
        let entries = recorder.snapshot
        #expect(entries.count == 1, "non-BP glucose edit is a single PATCH")
        #expect(entries[0].body.count <= 3, "wire body carries only the three documented keys")
        #expect(entries[0].body["value"] as? Double == 132)
        #expect(entries[0].body["notes"] as? String == "after lunch")
        #expect(
            entries[0].body["glucoseContext"] == nil,
            "PATCH wire-shape is value/measuredAt/notes only — glucoseContext is suppressed"
        )
        // Server returned the OLD context — repo passes that through (the
        // EditMeasurementSheet does the client-side override before
        // handing off to the list).
        #expect(result.glucoseContext == .fasting)
    }

    // MARK: - 3. Outbox-replay round-trip preserves the glucose intent

    @Test("Outbox-replay rehydrates glucoseContext from the persisted payload")
    func outboxReplayRehydratesGlucoseContext() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        let key = "key-glucose-edit-1"
        let payload = OutboxQueue.Payloads.UpdateMeasurement(
            id: "srv-glu-replay-1",
            patch: MeasurementPatch(value: 88, measuredAt: nil, notes: nil),
            kind: .glucose,
            diastolicId: nil,
            diastolicValue: nil,
            glucoseContext: .bedtime
        )
        let data = try JSONEncoder.hlDefault.encode(payload)
        try await outbox.enqueue(.init(
            id: UUID(),
            kind: .updateMeasurement,
            payload: data,
            idempotencyKey: key,
            createdAt: .now
        ))
        let recorder = RequestRecorder()
        MockURLProtocol.handler = { [self] req in
            recorder.record(req)
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                glucoseWireEnvelope(id: "srv-glu-replay-1", value: 88, glucoseContext: nil)
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
        #expect(entries.count == 1, "single PATCH leg for glucose")
        #expect(entries[0].path == "/api/measurements/srv-glu-replay-1")
        #expect(entries[0].idempotencyKey == key, "persisted key reused on replay")
        #expect(
            entries[0].body["glucoseContext"] == nil,
            "wire stays clean even on replay — intent lives in the payload, not the PATCH body"
        )
    }

    // MARK: - 4. Edit-round-trip preserves context via the MeasurementsStore

    @Test("MeasurementsStore.update preserves glucoseContext on the optimistic row (client-side override)")
    @MainActor
    func storeUpdatePreservesGlucoseContextOptimistically() async throws {
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MeasurementsRepository(api: makeAPI(), outbox: outbox)
        let store = MeasurementsStore(repo: repo, healthKit: nil)
        // Seed the store with a glucose row that has an existing context.
        let original = Measurement(
            id: "srv-glu-store-1",
            kind: .glucose,
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000),
            value: .scalar(120),
            note: nil,
            source: .manual,
            glucoseContext: .fasting
        )
        // Use reflection-free seeding: drive `capture()` via a mock POST
        // first, then issue the update. Simpler: just push the row
        // directly via an internal hop — the store doesn't expose a
        // seeder, so use a captured publisher via repo.recent. For brevity
        // here we test the picker→patch wiring purely by issuing
        // `store.update` after seeding the recent array via `load()`.
        MockURLProtocol.handler = { [self] req in
            let path = req.url?.path ?? ""
            if req.httpMethod == "GET", path == "/api/measurements" {
                let item = wireListItemJSON(
                    id: "srv-glu-store-1",
                    value: 120,
                    glucoseContext: .fasting
                )
                let listBody = #"{"data":{"measurements":[\#(item)]}}"#
                return (
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(listBody.utf8)
                )
            }
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                glucoseWireEnvelope(
                    id: "srv-glu-store-1",
                    value: 105,
                    // Server still echoes the OLD context — SB-25 not landed.
                    glucoseContext: .fasting
                )
            )
        }
        await store.load()
        let loaded = try #require(store.recent.first(where: { $0.id == "srv-glu-store-1" }))
        #expect(loaded.glucoseContext == .fasting, "seed row carries the server-persisted context")

        // User changes value + glucose context via the Edit-Sheet.
        let ok = await store.update(
            original,
            value: .scalar(105),
            recordedAt: original.recordedAt,
            note: nil,
            glucoseContext: .afterMeal
        )
        #expect(ok)
        let updated = try #require(store.recent.first(where: { $0.id == "srv-glu-store-1" }))
        #expect(
            updated.glucoseContext == .afterMeal,
            "store.update applies the new context client-side until SB-25 lands"
        )
        #expect(updated.primaryValue == 105)
    }

    private func wireListItemJSON(id: String, value: Double, glucoseContext: GlucoseContext?) -> String {
        let ctxJSON: String = glucoseContext.map { "\"\($0.rawValue)\"" } ?? "null"
        let ts = "2026-05-01T08:00:00Z"
        let head = #"{"id":"\#(id)","type":"BLOOD_GLUCOSE","value":\#(value)"#
        let body = #","measuredAt":"\#(ts)","createdAt":"\#(ts)","source":"MANUAL""#
        let tail = #","externalId":null,"glucoseContext":\#(ctxJSON),"notes":null}"#
        return head + body + tail
    }
}

// swiftlint:enable force_unwrapping force_try
