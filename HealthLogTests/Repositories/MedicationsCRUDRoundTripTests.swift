import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping force_try

/// T-3 commit 6 — full integration: `MedicationsStore` → real
/// `MedicationsRepository` → real `APIClient` (with `MockURLProtocol`
/// driving HTTP) → real `OutboxQueue`. T-0 already covers the
/// outbox-replay drain in isolation; these tests pin the **happy** path
/// + the **offline-then-replay** path end-to-end through the store
/// surface the UI actually consumes.
@Suite("MedicationsStore CRUD round-trip — APIClient + Outbox", .serialized)
struct MedicationsCRUDRoundTripTests {
    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            cfAccessClientID: nil,
            cfAccessClientToken: nil,
            bundleID: "dev.healthlog.app",
            appVersion: "0.5.0",
            buildNumber: "1"
        )
        let keychain = InMemoryKeychain()
        try? keychain.setString("token", forKey: KeychainKey.authToken)
        return APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock())
    }

    private func makeReplay(api: APIClient, outbox: OutboxQueue) -> OutboxReplayService {
        OutboxReplayService(
            outbox: outbox,
            measurementsRepo: MeasurementsRepository(api: api, outbox: outbox),
            moodRepo: MoodRepository(api: api, outbox: outbox),
            medicationsRepo: MedicationsRepository(api: api, outbox: outbox),
            maxAttempts: 4
        )
    }

    private static let medResp = """
    {"id":"srv-med-1","name":"Ozempic","dose":"1.0 mg","treatmentClass":"GENERIC",\
    "dosesPerUnit":4,"category":"OTHER","active":true,\
    "notificationsEnabled":true,"schedules":[{"windowStart":"08:00","windowEnd":"08:00",\
    "daysOfWeek":null,"label":null,"dose":null}],"lastTakenAt":null,"todayEventCount":0}
    """

    @MainActor
    @Test("create() happy: POSTs /api/medications and inserts the server row")
    func createOnlineHappyPath() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)

        let captured = MethodPathRecorder()
        MockURLProtocol.handler = { [resp = Self.medResp] req in
            captured.record(method: req.httpMethod ?? "", path: req.url?.path ?? "")
            let body = #"{"data":\#(resp)}"#
            return (
                HTTPURLResponse(
                    url: req.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(body.utf8)
            )
        }

        let outcome = await store.create(.init(
            name: "Ozempic",
            dose: "1.0 mg",
            treatmentClass: "GENERIC",
            category: "OTHER",
            active: true,
            notificationsEnabled: true,
            schedules: [MedicationScheduleDTO(windowStart: "08:00", windowEnd: "08:00")]
        ))

        #expect(outcome == .success)
        #expect(store.medications.count == 1)
        #expect(store.medications.first?.id == "srv-med-1")
        let snap = await outbox.snapshot
        #expect(snap.isEmpty, "Happy path must not enqueue an outbox row")
        #expect(captured.contains(method: "POST", path: "/api/medications"))
    }

    @MainActor
    @Test("create() offline → enqueue → replay drains the row")
    func createOfflineReplayRoundTrip() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)

        // Phase 1 — offline create (network unreachable error).
        MockURLProtocol.handler = { _ in
            throw URLError(.notConnectedToInternet)
        }
        let outcome = await store.create(.init(
            name: "Ozempic",
            dose: "1.0 mg",
            schedules: [MedicationScheduleDTO(windowStart: "08:00", windowEnd: "08:00")]
        ))
        #expect(outcome == .queued)
        let queued = await outbox.snapshot
        #expect(queued.count == 1)
        #expect(queued.first?.kind == .createMedication)
        let queuedKey = queued.first?.idempotencyKey

        // Phase 2 — network recovers, replay drains the row.
        let captured = MethodPathRecorder()
        MockURLProtocol.handler = { [resp = Self.medResp] req in
            captured.record(method: req.httpMethod ?? "", path: req.url?.path ?? "")
            captured.recordKey(req.value(forHTTPHeaderField: "Idempotency-Key"))
            let body = #"{"data":\#(resp)}"#
            return (
                HTTPURLResponse(
                    url: req.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(body.utf8)
            )
        }
        let replay = makeReplay(api: api, outbox: outbox)
        await replay.runOnce()
        let drained = await outbox.snapshot
        #expect(drained.isEmpty, "Replay must drain the createMedication row")
        #expect(captured.contains(method: "POST", path: "/api/medications"))
        if let key = queuedKey {
            #expect(captured.keys.contains(key), "Replay must reuse the persisted Idempotency-Key")
        }
    }

    @MainActor
    @Test("update() offline → enqueue → replay PUTs /api/medications/[id]")
    func updateOfflineReplayRoundTrip() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)
        store._testForceSet(medications: [medT3Domain(id: "srv-med-1", name: "Old", dose: "1 mg")])

        MockURLProtocol.handler = { _ in
            throw URLError(.notConnectedToInternet)
        }
        let outcome = await store.update(id: "srv-med-1", patch: .init(name: "New"))
        #expect(outcome == .queued)

        let captured = MethodPathRecorder()
        MockURLProtocol.handler = { [resp = Self.medResp] req in
            captured.record(method: req.httpMethod ?? "", path: req.url?.path ?? "")
            let body = #"{"data":\#(resp)}"#
            return (
                HTTPURLResponse(
                    url: req.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(body.utf8)
            )
        }
        let replay = makeReplay(api: api, outbox: outbox)
        await replay.runOnce()
        #expect(await (outbox.snapshot).isEmpty)
        #expect(captured.contains(method: "PUT", path: "/api/medications/srv-med-1"))
    }

    /// **08-21 (#219 / v1.37.19) — the raw half of the medication contract, on
    /// the wire the store actually puts.**
    ///
    /// `schedules` is a REPLACE, so this is the exact request in which a raw
    /// per-slot override either survives or is destroyed. The body is read off
    /// the live `URLRequest` rather than from an encoder in the test, so a
    /// repository, store or encoder change that dropped the field would fail
    /// here even though every unit-level assertion still passed.
    @MainActor
    @Test("update() PUTs raw per-slot doses, an explicit clear as omission, and no server truth")
    func updateCarriesRawSlotDosesAndNoServerTruth() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)
        store._testForceSet(medications: [medT3Domain(id: "srv-med-1", name: "Metformin", dose: "1000 mg")])

        // The form state a two-slot server medication prefills: morning
        // inherits (raw null / resolved 1), evening overrides (raw ½).
        let medication = try MedicationServerTruthDecodeTests.wire("slotAwareTruth").toDomain()
        let state = EditMedicationFormState(from: medication)
        let value = MedicationCadenceLogic.encode(state.cadenceKind, state.cadenceSub)

        func schedules(_ intents: MedicationCadenceLogic.SlotDoseIntents) -> [MedicationScheduleDTO] {
            MedicationCadenceLogic.buildSchedules(
                value: value,
                times: state.times,
                graceMinutes: state.graceMinutes,
                slotUnitsPerDose: MedicationCadenceLogic.resolveSlotUnitsPerDose(
                    existing: state.slotUnitsPerDose,
                    intents: intents
                )
            )
        }

        let captured = MethodPathRecorder()
        MockURLProtocol.handler = { [resp = Self.medResp] req in
            captured.record(method: req.httpMethod ?? "", path: req.url?.path ?? "")
            captured.recordBody(req.materializedBody())
            let body = #"{"data":\#(resp)}"#
            return (
                HTTPURLResponse(
                    url: req.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(body.utf8)
            )
        }

        // 1. An untouched save keeps the evening slot's explicit ½.
        #expect(await store.update(id: "srv-med-1", patch: .init(schedules: schedules([:]))) == .success)
        let untouched = try #require(captured.bodies.last)
        #expect(untouched.contains("\"unitsPerDose\":0.5"))
        #expect(!untouched.contains("resolvedUnitsPerDose"))
        #expect(!untouched.contains("stockDosesRemaining"))
        #expect(!untouched.contains("runwayDays"))

        // 2. An explicit clear sends the slot with NO `unitsPerDose` key —
        //    which is how the accepted `MedicationScheduleInput` spells
        //    inheritance, and the only spelling its bare `type: number`
        //    accepts. The rest of the schedule is unchanged.
        #expect(
            await store.update(id: "srv-med-1", patch: .init(schedules: schedules(["20:00": .clear])))
                == .success
        )
        let cleared = try #require(captured.bodies.last)
        #expect(!cleared.contains("unitsPerDose"))
        #expect(cleared.contains("\"timesOfDay\":[\"08:00\",\"20:00\"]"))

        // 3. An explicit override travels verbatim alongside the untouched one.
        #expect(
            await store.update(id: "srv-med-1", patch: .init(schedules: schedules(["08:00": .set(0.25)])))
                == .success
        )
        let set = try #require(captured.bodies.last)
        #expect(set.contains("\"unitsPerDose\":0.25"))
        #expect(set.contains("\"unitsPerDose\":0.5"))
        #expect(!set.contains("resolvedUnitsPerDose"))

        #expect(captured.contains(method: "PUT", path: "/api/medications/srv-med-1"))
        #expect(await (outbox.snapshot).isEmpty, "an online PUT must not enqueue")
    }

    @MainActor
    @Test("archive() offline → enqueue → replay DELETEs /api/medications/[id]")
    func archiveOfflineReplayRoundTrip() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)
        store._testForceSet(medications: [medT3Domain(id: "srv-med-1", name: "Ozempic", dose: "1 mg")])

        // Offline.
        MockURLProtocol.handler = { _ in
            throw URLError(.notConnectedToInternet)
        }
        let outcome = await store.archive(id: "srv-med-1")
        #expect(outcome == .queued)
        // Optimistic patch held locally:
        await MainActor.run {
            #expect(store.medications.first?.active == false)
        }

        let captured = MethodPathRecorder()
        MockURLProtocol.handler = { req in
            captured.record(method: req.httpMethod ?? "", path: req.url?.path ?? "")
            // DELETE returns 204 + empty body.
            return (
                HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: "HTTP/1.1", headerFields: nil)!,
                Data()
            )
        }
        let replay = makeReplay(api: api, outbox: outbox)
        await replay.runOnce()
        #expect(await (outbox.snapshot).isEmpty)
        #expect(captured.contains(method: "DELETE", path: "/api/medications/srv-med-1"))
    }
}

/// Tiny actor-safe recorder for HTTP method + path + idempotency-key.
/// Used inside `MockURLProtocol.handler` closures which run on URLSession's
/// background queue. Mirror of the `KeyRecorder` pattern in
/// `OutboxKindsV05xTests` (which is fileprivate over there).
private final class MethodPathRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(method: String, path: String)] = []
    private(set) var keys: [String] = []
    /// Request bodies as text, in call order — the wire this plan asserts on.
    private(set) var bodies: [String] = []

    func record(method: String, path: String) {
        lock.lock()
        defer { lock.unlock() }
        calls.append((method, path))
    }

    func recordBody(_ body: String?) {
        guard let body else { return }
        lock.lock()
        defer { lock.unlock() }
        bodies.append(body)
    }

    func recordKey(_ key: String?) {
        guard let key else { return }
        lock.lock()
        defer { lock.unlock() }
        keys.append(key)
    }

    func contains(method: String, path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return calls.contains { $0.method == method && $0.path == path }
    }
}

private extension URLRequest {
    /// `URLProtocol` moves `httpBody` onto `httpBodyStream`; re-materialize
    /// either as text. Same idiom as `CoachFeedbackTests` / `HealthRecordExportTests`.
    func materializedBody() -> String? {
        if let body = httpBody { return String(data: body, encoding: .utf8) }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return String(data: data, encoding: .utf8)
    }
}

// swiftlint:enable force_unwrapping force_try
