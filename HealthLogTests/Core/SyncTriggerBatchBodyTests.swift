import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

// swiftlint:disable force_unwrapping

/// **CU-21 (1) — Akzeptanz: der Batch-Request trägt den korrekten Trigger pro
/// Pfad, geprüft am tatsächlich gesendeten Body.**
///
/// Echter `APIClient` über `MockURLProtocol` (kein Mock-Server), echter
/// `MeasurementBatchUploader`. Assertiert wird auf dem rohen JSON, das über den
/// Draht ging — nicht auf einem Zwischenobjekt, denn genau die Wire-Form ist der
/// Vertrag.
///
/// `.serialized`, weil die Suite am prozessglobalen `MockURLProtocol.handler`
/// hängt.
@Suite("CU-21 — syncTrigger im Batch-Body (Uploader-Pfad)", .serialized)
struct SyncTriggerBatchBodyTests {
    // MARK: - Fixtures

    static let env = AppEnvironment(
        baseURL: URL(string: "https://test.healthlog.local")!,
        bundleID: "dev.healthlog.app",
        appVersion: "0.1.0",
        buildNumber: "1"
    )

    static func makeAPI() -> APIClient {
        let keychain = InMemoryKeychain()
        try? keychain.setString("token", forKey: KeychainKey.authToken)
        return APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock())
    }

    static let entry = HealthKitBatchEntryDTO(
        hkIdentifier: "HKQuantityTypeIdentifierStepCount",
        value: 1234,
        unit: "count",
        startDate: Date(timeIntervalSince1970: 1_715_673_600),
        endDate: Date(timeIntervalSince1970: 1_715_716_800),
        externalId: "ext-0"
    )

    /// Nimmt die abgeschickten Bodies auf, damit die Zusicherung am echten
    /// Draht-JSON hängt. `@unchecked Sendable` + `NSLock` ist das etablierte
    /// Test-Support-Muster (wie `MockURLProtocol` selbst).
    final class BodyRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var bodies: [Data] = []

        func record(_ data: Data) {
            lock.withLock { bodies.append(data) }
        }

        var count: Int {
            lock.withLock { bodies.count }
        }

        func decodedLast() -> [String: Any]? {
            guard let data = lock.withLock({ bodies.last }),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return obj
        }
    }

    static func installRecordingHandler(_ recorder: BodyRecorder) {
        MockURLProtocol.handler = { req in
            if let body = req.httpBody ?? req.bodyStreamData() {
                recorder.record(body)
            }
            let response = HTTPURLResponse(
                url: req.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            let json = #"{"processed":1,"inserted":1,"duplicates":0,"skipped":[],"entries":[{"index":0,"status":"inserted"}]}"#
            return (response, Data(json.utf8))
        }
    }

    static func makeUploader(context: SyncTriggerContext) -> MeasurementBatchUploader {
        MeasurementBatchUploader(
            api: makeAPI(),
            throttle: BatchSyncThrottle(maxPerWindow: 60, window: 60.0, jitter: 0 ... 0),
            syncTrigger: context
        )
    }

    // MARK: - Tests

    @Test("Vordergrund-Sweep: kein offenes Fenster ⇒ Body trägt `syncTrigger: \"foreground\"`")
    func foregroundSweep() async throws {
        let recorder = BodyRecorder()
        Self.installRecordingHandler(recorder)
        let uploader = Self.makeUploader(context: SyncTriggerContext())

        _ = try await uploader.upload([Self.entry])

        let body = recorder.decodedLast()
        #expect(body?["syncTrigger"] as? String == "foreground")
        // Top-Level-Feld, Geschwister von `entries` — nicht pro Eintrag.
        #expect(body?["entries"] is [Any])
        let entries = body?["entries"] as? [[String: Any]]
        #expect(entries?.first?["syncTrigger"] == nil)
    }

    @Test("BGTask-Fenster ⇒ Body trägt `syncTrigger: \"background\"`")
    func backgroundSweep() async throws {
        let recorder = BodyRecorder()
        Self.installRecordingHandler(recorder)
        let context = SyncTriggerContext()
        let uploader = Self.makeUploader(context: context)

        try await context.withTrigger(.background) {
            _ = try await uploader.upload([Self.entry])
        }

        #expect(recorder.decodedLast()?["syncTrigger"] as? String == "background")
    }

    @Test("Push-Fenster ⇒ Body trägt `syncTrigger: \"push\"`")
    func pushSweep() async throws {
        let recorder = BodyRecorder()
        Self.installRecordingHandler(recorder)
        let context = SyncTriggerContext()
        let uploader = Self.makeUploader(context: context)

        try await context.withTrigger(.push) {
            _ = try await uploader.upload([Self.entry])
        }

        #expect(recorder.decodedLast()?["syncTrigger"] as? String == "push")
    }

    @Test("Jeder Chunk eines großen Sweeps trägt denselben Auslöser")
    func everyChunkCarriesTheTrigger() async throws {
        let recorder = BodyRecorder()
        MockURLProtocol.handler = { req in
            let body = req.httpBody ?? req.bodyStreamData() ?? Data()
            recorder.record(body)
            let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            let posted = (object?["entries"] as? [Any])?.count ?? 0
            let response = HTTPURLResponse(
                url: req.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            let responseObject: [String: Any] = [
                "processed": posted,
                "inserted": posted,
                "duplicates": 0,
                "skipped": [],
                "entries": (0 ..< posted).map { ["index": $0, "status": "inserted"] }
            ]
            return (response, try? JSONSerialization.data(withJSONObject: responseObject))
        }
        let context = SyncTriggerContext()
        let uploader = Self.makeUploader(context: context)
        let entries: [HealthKitBatchEntryDTO] = (0 ..< 600).map { idx in
            .init(
                hkIdentifier: "HKQuantityTypeIdentifierStepCount",
                value: Double(idx),
                unit: "count",
                startDate: Date(timeIntervalSince1970: TimeInterval(idx)),
                endDate: Date(timeIntervalSince1970: TimeInterval(idx + 60)),
                externalId: "ext-\(idx)"
            )
        }

        try await context.withTrigger(.background) {
            _ = try await uploader.upload(entries)
        }

        // 600 Einträge ⇒ zwei Chunks (500 + 100); beide müssen markiert sein.
        #expect(recorder.count == 2)
        #expect(recorder.decodedLast()?["syncTrigger"] as? String == "background")
    }

    @Test("Ohne Kontext-Wert bleibt die Wire-Form kompatibel: das Feld ist weglassbar")
    func fieldIsOmittableWhenNil() throws {
        let payload = HealthKitBatchPayload(entries: [Self.entry], syncTrigger: nil)
        let data = try JSONEncoder.hlBatch.encode(payload)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["syncTrigger"] == nil)
        #expect(obj?.keys.contains("syncTrigger") == false)
    }
}

// MARK: - URLRequest body-stream helper

private extension URLRequest {
    /// `URLSession` pipes the body through a stream for these configurations, so
    /// `httpBody` is nil. Drain it synchronously — Testpfad, kleine Requests.
    func bodyStreamData() -> Data? {
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buf.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buf, maxLength: 4096)
            if read <= 0 { break }
            data.append(buf, count: read)
        }
        return data.isEmpty ? nil : data
    }
}

// swiftlint:enable force_unwrapping
