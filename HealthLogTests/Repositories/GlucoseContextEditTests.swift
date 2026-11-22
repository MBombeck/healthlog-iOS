import Foundation
@testable import HealthLog
import Synchronization
import Testing

// swiftlint:disable force_unwrapping

/// Server 1.48.0 takes `glucoseContext` on `PUT /api/measurements/{id}`
/// (#182, part C): `null` clears it, an absent key keeps it. The app sends
/// it only when the context changed and only to a server known to take it; an
/// older server keeps the old wire shape and the sheet offers no change.
@Suite("Glucose context on edit (server 1.48)", .serialized, .mockURLSession)
struct GlucoseContextEditTests {
    /// Bodies of every request the mock answered, as JSON objects.
    final class BodyLog: Sendable {
        private let raw = Mutex<[Data]>([])

        func record(_ req: URLRequest) {
            let data = req.httpBody ?? req.httpBodyStream.flatMap(Self.read) ?? Data()
            raw.withLock { $0.append(data) }
        }

        var snapshot: [[String: Any]] {
            raw.withLock { $0 }.map { (try? JSONSerialization.jsonObject(with: $0) as? [String: Any]) ?? [:] }
        }

        private static func read(_ stream: InputStream) -> Data? {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var chunk = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&chunk, maxLength: chunk.count)
                guard count > 0 else { break }
                data.append(chunk, count: count)
            }
            return data
        }
    }

    private static func makeAPI() -> APIClient {
        APIClient(
            environment: AppEnvironment(
                baseURL: URL(string: "https://test.healthlog.local")!,
                bundleID: "dev.healthlog.app",
                appVersion: "1.7.0",
                buildNumber: "1"
            ),
            keychain: InMemoryKeychain(),
            sessionConfiguration: .mock()
        )
    }

    private static func echo(id: String, value: Double, context: String) -> Data {
        Data(
            (#"{"data":{"id":"\#(id)","type":"BLOOD_GLUCOSE","value":\#(value),"measuredAt":"2026-11-01T08:00:00Z","#
                + #""createdAt":"2026-11-01T08:00:00Z","source":"MANUAL","externalId":null,"glucoseContext":\#(context),"notes":null}}"#)
                .utf8
        )
    }

    private static func install(_ log: BodyLog, id: String = "srv-glu-1", echoContext: String = "null") {
        MockURLProtocol.install { req in
            log.record(req)
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                echo(id: id, value: 110, context: echoContext)
            )
        }
    }

    private static func defaults(version: String?) throws -> UserDefaults {
        let defaults = try #require(UserDefaults(suiteName: "glucose.edit.\(UUID().uuidString)"))
        if let version {
            defaults.set(version, forKey: KnownServerVersion.defaultsKey)
        }
        return defaults
    }

    // MARK: - Version gate

    @Test("The sheet offers the change from server 1.48.0; older or unknown servers do not")
    func versionGate() throws {
        #expect(try GlucoseContextEdit.isSupported(defaults: Self.defaults(version: "1.48.0")))
        #expect(try GlucoseContextEdit.isSupported(defaults: Self.defaults(version: "1.48.1")))
        #expect(try !GlucoseContextEdit.isSupported(defaults: Self.defaults(version: "1.47.6")))
        #expect(try !GlucoseContextEdit.isSupported(defaults: Self.defaults(version: nil)), "unknown counts as older")
    }

    @Test("A save sends the context only for a changed glucose row on a server that takes it")
    func sendsOnlyWhenChanged() {
        #expect(GlucoseContextEdit.sends(kind: .glucose, initial: .fasting, edited: .afterMeal, supported: true))
        #expect(GlucoseContextEdit.sends(kind: .glucose, initial: .fasting, edited: nil, supported: true), "clearing is a change")
        #expect(GlucoseContextEdit.sends(kind: .glucose, initial: nil, edited: .random, supported: true))
        #expect(!GlucoseContextEdit.sends(kind: .glucose, initial: .fasting, edited: .fasting, supported: true))
        #expect(!GlucoseContextEdit.sends(kind: .glucose, initial: .fasting, edited: .afterMeal, supported: false))
        #expect(!GlucoseContextEdit.sends(kind: .weight, initial: nil, edited: .fasting, supported: true))
    }

    @Test("The edit patch: the reading keeps its diastolic, only a glucose row carries a context")
    func editPatchFactory() {
        let at = Date(timeIntervalSince1970: 1_780_000_000)
        let glucose = Measurement(
            id: "g", kind: .glucose, recordedAt: at, value: .scalar(110), note: nil, source: .manual, glucoseContext: .fasting
        )
        let changed = MeasurementPatch.edit(glucose, to: .scalar(115), at: at, notes: nil, context: .random, serverTakesContext: true)
        #expect(changed.value == 115)
        #expect(changed.glucoseContext == .random)
        #expect(changed.sendsGlucoseContext)
        let older = MeasurementPatch.edit(glucose, to: .scalar(115), at: at, notes: nil, context: .random, serverTakesContext: false)
        #expect(!older.sendsGlucoseContext)

        let reading = Measurement(id: "bp", kind: .bloodPressure, recordedAt: at, value: .bloodPressure(systolic: 120, diastolic: 80))
        let bp = MeasurementPatch.edit(
            reading,
            to: .bloodPressure(systolic: 125, diastolic: 82),
            at: at,
            notes: "x",
            context: .fasting,
            serverTakesContext: true
        )
        #expect(bp.value == 125)
        #expect(bp.diastolic == 82)
        #expect(bp.glucoseContext == nil)
        #expect(!bp.sendsGlucoseContext)
    }

    // MARK: - Wire shape

    @Test("The patch carries the server literal, null to clear, nothing when not sent")
    func patchEncoding() throws {
        let set = MeasurementPatch(value: 110, glucoseContext: .afterMeal, sendsGlucoseContext: true)
        let setJSON = try #require(String(data: JSONEncoder.hlDefault.encode(set), encoding: .utf8))
        #expect(setJSON.contains(#""glucoseContext":"POSTPRANDIAL""#))

        let clear = MeasurementPatch(value: 110, glucoseContext: nil, sendsGlucoseContext: true)
        let clearJSON = try #require(String(data: JSONEncoder.hlDefault.encode(clear), encoding: .utf8))
        #expect(clearJSON.contains(#""glucoseContext":null"#))

        let kept = MeasurementPatch(value: 110, glucoseContext: .afterMeal)
        let keptJSON = try #require(String(data: JSONEncoder.hlDefault.encode(kept), encoding: .utf8))
        #expect(!keptJSON.contains("glucoseContext"), "an older server, or an unchanged context, keeps the old wire shape")
    }

    @Test("A persisted patch keeps whether it sends the context")
    func patchDecoding() throws {
        let decode = { (json: String) in try JSONDecoder.hlDefault.decode(MeasurementPatch.self, from: Data(json.utf8)) }
        let set = try decode(#"{"value":99,"glucoseContext":"RANDOM"}"#)
        #expect(set.sendsGlucoseContext)
        #expect(set.glucoseContext == .random)
        let clear = try decode(#"{"value":99,"glucoseContext":null}"#)
        #expect(clear.sendsGlucoseContext)
        #expect(clear.glucoseContext == nil)
        let absent = try decode(#"{"value":99}"#)
        #expect(!absent.sendsGlucoseContext)
    }

    // MARK: - Repository

    @Test("1.48: the PUT carries the changed context; clearing sends null")
    func repositorySendsContext() async throws {
        let log = BodyLog()
        Self.install(log, echoContext: #""POSTPRANDIAL""#)
        let repo = try MeasurementsRepository(api: Self.makeAPI(), outbox: OutboxQueue(inMemory: true))
        let saved = try await repo.update(
            id: "srv-glu-1",
            patch: MeasurementPatch(value: 110, glucoseContext: .afterMeal, sendsGlucoseContext: true),
            kind: .glucose
        )
        #expect(saved.glucoseContext == .afterMeal, "the server's echo now holds the new context")
        _ = try await repo.update(
            id: "srv-glu-1",
            patch: MeasurementPatch(value: 110, glucoseContext: nil, sendsGlucoseContext: true),
            kind: .glucose
        )
        let bodies = log.snapshot
        #expect(bodies.count == 2)
        #expect(bodies.first?["glucoseContext"] as? String == "POSTPRANDIAL")
        #expect(bodies.last?["glucoseContext"] is NSNull)
    }

    @Test("Offline edit: the outbox replay sends the context it was saved with")
    func replaySendsContext() async throws {
        let outbox = try OutboxQueue(inMemory: true)
        let payload = OutboxQueue.Payloads.UpdateMeasurement(
            id: "srv-glu-1",
            patch: MeasurementPatch(value: 110, glucoseContext: .random, sendsGlucoseContext: true),
            kind: .glucose,
            glucoseContext: .random
        )
        try await outbox.enqueue(.init(
            id: UUID(),
            kind: .updateMeasurement,
            payload: JSONEncoder.hlDefault.encode(payload),
            idempotencyKey: "key-glucose-edit-replay",
            createdAt: .now
        ))
        let log = BodyLog()
        Self.install(log, echoContext: #""RANDOM""#)
        let api = Self.makeAPI()
        let replay = OutboxReplayService(
            outbox: outbox,
            measurementsRepo: MeasurementsRepository(api: api, outbox: outbox),
            moodRepo: MoodRepository(api: api, outbox: outbox),
            medicationsRepo: MedicationsRepository(api: api, outbox: outbox),
            maxAttempts: 4
        )
        await replay.runOnce()
        #expect(await outbox.snapshot.isEmpty)
        #expect(log.snapshot.first?["glucoseContext"] as? String == "RANDOM")
    }

    // MARK: - Store

    @MainActor
    @Test("Store edit: 1.48 sends the changed context, an older server keeps the old wire shape", arguments: [
        ("1.48.0", true),
        ("1.47.6", false)
    ])
    func storeFollowsServerVersion(version: String, sends: Bool) async throws {
        let log = BodyLog()
        Self.install(log, id: "srv-glu-store", echoContext: #""FASTING""#)
        let outbox = try OutboxQueue(inMemory: true)
        let store = try MeasurementsStore(
            repo: MeasurementsRepository(api: Self.makeAPI(), outbox: outbox),
            healthKit: nil,
            serverVersionDefaults: Self.defaults(version: version)
        )
        let row = Measurement(
            id: "srv-glu-store",
            kind: .glucose,
            recordedAt: Date(timeIntervalSince1970: 1_780_000_000),
            value: .scalar(110),
            note: nil,
            source: .manual,
            glucoseContext: .fasting
        )
        let ok = await store.update(row, value: .scalar(110), recordedAt: row.recordedAt, note: nil, glucoseContext: .bedtime)
        #expect(ok)
        let body = try #require(log.snapshot.last)
        if sends {
            #expect(body["glucoseContext"] as? String == "BEDTIME")
        } else {
            #expect(body["glucoseContext"] == nil)
        }
    }
}

// swiftlint:enable force_unwrapping
