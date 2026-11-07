import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

private let testBaseURL = URL(string: "https://test.healthlog.local")!

/// 1.5 FIX-DATA (#157 point 1) — deleting a blood-pressure reading takes the
/// whole reading: systolic, diastolic and the cuff's pulse with the same source
/// at the identical time. From server 1.46.2 one `DELETE` does it server-side and
/// one restore undoes it; before, both halves go through the bulk delete.
///
/// Real `APIClient` over `MockURLProtocol`; the server version comes from an
/// isolated `UserDefaults` suite so parallel suites never see it.
@MainActor
@Suite("Blood pressure — delete and undo the whole reading", .serialized, .mockURLSession)
struct BloodPressureReadingDeleteTests {
    private final class Recorder: @unchecked Sendable {
        struct Entry {
            let method: String
            let path: String
            let body: Data?
        }

        private let lock = NSLock()
        private var entries: [Entry] = []

        func record(_ req: URLRequest) {
            let body = req.httpBody ?? req.httpBodyStream.flatMap(Self.consume)
            lock.withLock {
                entries.append(Entry(method: req.httpMethod ?? "", path: req.url?.path ?? "", body: body))
            }
        }

        var all: [Entry] {
            lock.withLock { entries }
        }

        /// Writes only: the reads a store fires on the side are not the point.
        var writes: [Entry] {
            all.filter { $0.method != "GET" }
        }

        private static func consume(_ stream: InputStream) -> Data? {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                guard read > 0 else { break }
                data.append(buffer, count: read)
            }
            return data
        }
    }

    private static let readingTime = Date(timeIntervalSince1970: 1_793_000_000)

    private static let reading = Measurement(
        id: "sys-1",
        kind: .bloodPressure,
        recordedAt: readingTime,
        value: .bloodPressure(systolic: 128, diastolic: 84),
        source: .withings,
        bloodPressureDiastolicId: "dia-1"
    )
    /// The cuff's pulse: same source, identical time.
    private static let cuffPulse = Measurement(
        id: "pulse-1", kind: .pulse, recordedAt: readingTime, value: .scalar(66), source: .withings
    )
    /// Same time, another source: not part of the reading.
    private static let watchPulse = Measurement(
        id: "pulse-watch", kind: .pulse, recordedAt: readingTime, value: .scalar(70), source: .appleHealth
    )
    /// Same source and time, but an hour of heart rate (`stats:`), never part of a reading.
    private static let hourBucket = Measurement(
        id: "pulse-hour",
        kind: .pulse,
        recordedAt: readingTime,
        value: .scalar(72),
        source: .withings,
        externalUUID: "stats:HKQuantityTypeIdentifierHeartRate:2026-10-27T10"
    )
    /// Same source, a minute later: a pulse of its own.
    private static let laterPulse = Measurement(
        id: "pulse-later", kind: .pulse, recordedAt: readingTime.addingTimeInterval(60), value: .scalar(64), source: .withings
    )

    private struct Harness {
        let store: MeasurementsStore
        let undo: UndoCoordinator
        let recorder: Recorder
        let outbox: OutboxQueue
    }

    private func makeHarness(serverVersion: String?, restoreStatus: Int = 200, deletedCount: Int = 3) throws -> Harness {
        let keychain = InMemoryKeychain()
        try keychain.setString("token", forKey: KeychainKey.authToken)
        let api = APIClient(
            environment: AppEnvironment(
                baseURL: testBaseURL,
                bundleID: "dev.healthlog.app",
                appVersion: "1.5.0",
                buildNumber: "1"
            ),
            keychain: keychain,
            sessionConfiguration: .mock()
        )
        let defaults = try #require(UserDefaults(suiteName: "hl.test.bp-delete.\(UUID().uuidString)"))
        if let serverVersion {
            KnownServerVersion.record(ServerVersionInfo(version: serverVersion), defaults: defaults)
        }
        let outbox = try OutboxQueue(inMemory: true)
        let undo = UndoCoordinator()
        let store = MeasurementsStore(
            repo: MeasurementsRepository(api: api, outbox: outbox),
            undoCoordinator: undo,
            serverVersionDefaults: defaults
        )
        store.recent = [Self.laterPulse, Self.reading, Self.cuffPulse, Self.watchPulse, Self.hourBucket]
        let recorder = Recorder()
        MockURLProtocol.install { req in
            recorder.record(req)
            let path = req.url?.path ?? ""
            let (status, body): (Int, String) = switch (req.httpMethod ?? "", path) {
            case ("DELETE", _): (200, #"{"data":{"deleted":true}}"#)
            case ("POST", "/api/measurements/bulk-delete"): (200, "{\"data\":{\"deleted\":\(deletedCount)}}")
            case ("POST", "/api/measurements/restore"): (restoreStatus, #"{"data":{"restored":3}}"#)
            case ("POST", "/api/measurements"):
                (200, #"{"data":{"id":"new-sys","type":"BLOOD_PRESSURE_SYS","value":128,"measuredAt":"2026-11-04T10:00:00Z"}}"#)
            default: (200, #"{"data":{"measurements":[],"points":[]}}"#)
            }
            let response = HTTPURLResponse(
                url: req.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(body.utf8))
        }
        return Harness(store: store, undo: undo, recorder: recorder, outbox: outbox)
    }

    private static func ids(_ body: Data?) throws -> [String] {
        let object = try #require(try JSONSerialization.jsonObject(with: body ?? Data()) as? [String: Any])
        return try #require(object["ids"] as? [String])
    }

    private static func remainingIDs(_ store: MeasurementsStore) -> Set<String> {
        Set(store.recent.map(\.id))
    }

    // MARK: - (a) server 1.46.2

    @Test("(a) 1.46.2: one DELETE, the reading and its pulse leave the list, undo restores all three")
    func newServerDeletesAndRestoresTheReading() async throws {
        let h = try makeHarness(serverVersion: "1.46.2")

        let ok = await h.store.delete(Self.reading)

        #expect(ok)
        let deletes = h.recorder.writes
        #expect(deletes.count == 1, "one request deletes the whole reading")
        #expect(deletes.first?.method == "DELETE")
        #expect(deletes.first?.path == "/api/measurements/sys-1")
        #expect(Self.remainingIDs(h.store) == ["pulse-later", "pulse-watch", "pulse-hour"])

        await h.undo.performUndo()

        let restores = h.recorder.writes.filter { $0.path == "/api/measurements/restore" }
        #expect(restores.count == 1)
        #expect(try Self.ids(restores.first?.body) == ["sys-1"], "the systolic id restores the reading")
        #expect(!h.recorder.writes.contains { $0.method == "POST" && $0.path == "/api/measurements" }, "no re-create")
        #expect(Self.remainingIDs(h.store) == ["pulse-later", "sys-1", "pulse-1", "pulse-watch", "pulse-hour"])
        // Rows with the same instant have no defined order; the list stays newest first.
        let times = h.store.recent.map(\.recordedAt)
        #expect(times == times.sorted(by: >), "newest first")
        #expect(h.store.recent.first?.id == "pulse-later")
        #expect(h.store.error == nil)
    }

    @Test("(a) 1.46.2: bulk delete with a count of 3 for 2 ids is success and takes the pulse")
    func newServerBulkCountLargerThanIDsIsSuccess() async throws {
        let h = try makeHarness(serverVersion: "1.46.6", deletedCount: 3)

        let ok = await h.store.bulkDelete([Self.reading])

        #expect(ok)
        #expect(h.store.error == nil)
        let posts = h.recorder.writes
        #expect(posts.count == 1)
        #expect(try Self.ids(posts.first?.body) == ["sys-1", "dia-1"])
        #expect(Self.remainingIDs(h.store) == ["pulse-later", "pulse-watch", "pulse-hour"])
    }

    @Test("(a) 1.46.2: a failed restore takes the rows out again and shows the error")
    func newServerFailedRestoreRollsBack() async throws {
        let h = try makeHarness(serverVersion: "1.46.2", restoreStatus: 422)

        _ = await h.store.delete(Self.reading)
        await h.undo.performUndo()

        #expect(h.store.error != nil)
        #expect(Self.remainingIDs(h.store) == ["pulse-later", "pulse-watch", "pulse-hour"])
        #expect(!h.recorder.writes.contains { $0.method == "POST" && $0.path == "/api/measurements" })
    }

    @Test("(a) a queued DELETE is undone by re-creating, never by a restore that finds nothing")
    func queuedDeleteUndoesByRecreate() async throws {
        let h = try makeHarness(serverVersion: "1.46.2")
        let recorder = h.recorder
        MockURLProtocol.install { req in
            recorder.record(req)
            if req.httpMethod == "DELETE" {
                return (HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, nil)
            }
            let body = #"{"data":{"id":"new-sys","type":"BLOOD_PRESSURE_SYS","value":128,"measuredAt":"2026-11-04T10:00:00Z"}}"#
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }

        let ok = await h.store.delete(Self.reading)
        #expect(!ok)
        #expect(await h.outbox.snapshot.first?.kind == .deleteMeasurement, "the DELETE waits in the outbox")
        #expect(!Self.remainingIDs(h.store).contains("sys-1"))

        await h.undo.performUndo()

        #expect(!h.recorder.writes.contains { $0.path == "/api/measurements/restore" })
        #expect(h.recorder.writes.contains { $0.method == "POST" && $0.path == "/api/measurements" })
    }

    // MARK: - (b) server 1.46.1 and unknown

    @Test("(b) 1.46.1: both halves go through the bulk delete, the pulse stays", arguments: ["1.46.1", nil] as [String?])
    func olderServerBulkDeletesBothHalves(version: String?) async throws {
        let h = try makeHarness(serverVersion: version, deletedCount: 2)

        let ok = await h.store.delete(Self.reading)

        #expect(ok)
        let writes = h.recorder.writes
        #expect(writes.count == 1)
        #expect(writes.first?.method == "POST")
        #expect(writes.first?.path == "/api/measurements/bulk-delete")
        #expect(try Self.ids(writes.first?.body) == ["sys-1", "dia-1"])
        // The older server keeps the pulse, so the list keeps showing it.
        #expect(Self.remainingIDs(h.store) == ["pulse-later", "pulse-1", "pulse-watch", "pulse-hour"])

        await h.undo.performUndo()

        #expect(!h.recorder.writes.contains { $0.path == "/api/measurements/restore" })
        #expect(h.recorder.writes.contains { $0.method == "POST" && $0.path == "/api/measurements" }, "undo re-creates as before")
    }

    @Test("a pulse is deleted on its own, whatever the server version")
    func pulseAloneStaysAlone() async throws {
        let h = try makeHarness(serverVersion: "1.46.2")

        _ = await h.store.delete(Self.cuffPulse)

        #expect(h.recorder.writes.map(\.path) == ["/api/measurements/pulse-1"])
        #expect(Self.remainingIDs(h.store) == ["pulse-later", "sys-1", "pulse-watch", "pulse-hour"])
    }

    @Test("standalone mode deletes both halves locally even when the last server was 1.46.2")
    func standaloneNeverTrustsTheServerRule() throws {
        let defaults = try #require(UserDefaults(suiteName: "hl.test.bp-delete.\(UUID().uuidString)"))
        KnownServerVersion.record(ServerVersionInfo(version: "1.46.2"), defaults: defaults)
        let api = APIClient(
            environment: AppEnvironment(
                baseURL: testBaseURL,
                bundleID: "dev.healthlog.app",
                appVersion: "1.5.0",
                buildNumber: "1"
            ),
            keychain: InMemoryKeychain(),
            sessionConfiguration: .mock()
        )
        let store = try MeasurementsStore(
            repo: MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true)),
            isStandalone: { true },
            serverVersionDefaults: defaults
        )
        store.recent = [Self.reading, Self.cuffPulse]

        let plan = store.deletePlan(for: Self.reading)

        #expect(plan.wire == .bulk(["sys-1", "dia-1"]))
        #expect(plan.pulseRows.isEmpty)
        #expect(!plan.serverTakesWholeReading)
    }
}

// MARK: - Outbox replay

/// The replay drains a queued bulk delete whose answer counts more rows than
/// it named (a 1.46.2 server counts the pulse), and a queued single DELETE
/// whose answer is `{ deleted: true }`.
@Suite("Blood pressure — replayed deletes accept the larger count", .serialized, .mockURLSession)
struct BloodPressureReadingDeleteReplayTests {
    @Test("bulk delete replay with deleted 3 for 2 ids drains; single DELETE replay drains")
    func replayDrains() async throws {
        let api = APIClient(
            environment: AppEnvironment(
                baseURL: testBaseURL,
                bundleID: "dev.healthlog.app",
                appVersion: "1.5.0",
                buildNumber: "1"
            ),
            keychain: InMemoryKeychain(),
            sessionConfiguration: .mock()
        )
        let outbox = try OutboxQueue(inMemory: true)
        try await outbox.enqueue(.init(
            kind: .bulkDeleteMeasurements,
            payload: JSONEncoder.hlDefault.encode(OutboxQueue.Payloads.BulkDeleteMeasurements(ids: ["sys-1", "dia-1"])),
            idempotencyKey: "bulk-key"
        ))
        try await outbox.enqueue(.init(
            kind: .deleteMeasurement,
            payload: JSONEncoder.hlDefault.encode(OutboxQueue.Payloads.DeleteMeasurement(id: "sys-2")),
            idempotencyKey: "single-key"
        ))
        MockURLProtocol.install { req in
            let body = req.httpMethod == "DELETE" ? #"{"data":{"deleted":true}}"# : #"{"data":{"deleted":3}}"#
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let replay = OutboxReplayService(
            outbox: outbox,
            measurementsRepo: MeasurementsRepository(api: api, outbox: outbox),
            moodRepo: MoodRepository(api: api, outbox: outbox),
            medicationsRepo: MedicationsRepository(api: api, outbox: outbox)
        )

        await replay.runOnce()

        #expect(await outbox.snapshot.isEmpty)
    }
}

// swiftlint:enable force_unwrapping
