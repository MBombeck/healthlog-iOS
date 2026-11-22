import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// A landed edit or delete in the store reaches the HealthKit writer's
/// own-copy path, in order. The server answers from a URL protocol mock, so no
/// request leaves the test.
@MainActor
@Suite("MeasurementsStore — HealthKit copies of edited and deleted readings", .serialized, .mockURLSession)
struct MeasurementsStoreHealthKitCopyTests {
    private func makeAPI() -> APIClient {
        let keychain = InMemoryKeychain()
        try? keychain.setString("token", forKey: KeychainKey.authToken)
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.5.0",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock())
    }

    private nonisolated static func reply(_ request: URLRequest) -> (HTTPURLResponse, Data) {
        let body = switch (request.httpMethod, request.url?.path) {
        case ("PUT", _):
            #"{"data":{"id":"w-1","type":"WEIGHT","value":82,"measuredAt":"2023-11-14T22:13:20Z"}}"#
        case (_, "/api/measurements/bulk-delete"):
            #"{"data":{"deleted":1}}"#
        case ("DELETE", _):
            #"{"data":{"deleted":true}}"#
        default:
            #"{"data":[]}"#
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(body.utf8))
    }

    private struct Fixture {
        let store: MeasurementsStore
        let recorder: CopyRecorder
        let row: HealthLog.Measurement
    }

    private func makeStore() throws -> Fixture {
        MockURLProtocol.install { Self.reply($0) }
        let repo = try MeasurementsRepository(api: makeAPI(), outbox: OutboxQueue(inMemory: true))
        let recorder = CopyRecorder()
        let store = MeasurementsStore(repo: repo, healthKit: recorder, undoCoordinator: UndoCoordinator())
        let row = HealthLog.Measurement(
            id: "w-1",
            kind: .weight,
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000),
            value: .scalar(820),
            source: .manual
        )
        store.recent = [row]
        return Fixture(store: store, recorder: recorder, row: row)
    }

    @Test("an edit hands the old and the saved row to the writer")
    func updateReplaces() async throws {
        let fixture = try makeStore()
        let (store, recorder, row) = (fixture.store, fixture.recorder, fixture.row)

        let ok = await store.update(row, value: .scalar(82), recordedAt: row.recordedAt, note: nil)
        await HealthKitCopyEditQueue.shared.drain()

        #expect(ok)
        let calls = recorder.calls
        #expect(calls.count == 1)
        #expect(calls.first?.hasPrefix("replace:\(row.id)") == true)
    }

    @Test("a delete hands the row to the writer")
    func deleteRemoves() async throws {
        let fixture = try makeStore()
        let (store, recorder, row) = (fixture.store, fixture.recorder, fixture.row)

        let ok = await store.delete(row)
        await HealthKitCopyEditQueue.shared.drain()

        #expect(ok)
        #expect(recorder.calls == ["remove:\(row.id)"])
    }

    @Test("a bulk delete hands every row to the writer")
    func bulkDeleteRemoves() async throws {
        let fixture = try makeStore()
        let (store, recorder, row) = (fixture.store, fixture.recorder, fixture.row)

        let ok = await store.bulkDelete([row])
        await HealthKitCopyEditQueue.shared.drain()

        #expect(ok)
        #expect(recorder.calls == ["remove:\(row.id)"])
    }
}

/// Records the own-copy calls; every other writer method does nothing.
private final class CopyRecorder: AnyHealthKitWriter, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []

    var calls: [String] {
        lock.withLock { _calls }
    }

    func replaceOwnCopy(of old: HealthLog.Measurement, with new: HealthLog.Measurement) async {
        lock.withLock { _calls.append("replace:\(old.id)->\(new.id)") }
    }

    func removeOwnCopies(of measurement: HealthLog.Measurement) async {
        lock.withLock { _calls.append("remove:\(measurement.id)") }
    }

    func write(_: HealthLog.Measurement) async throws {}
    func writeMood(_: MoodEntry) async throws {}
    func deleteMood(id _: String) async throws {}
    func requestMoodAuthorization() async throws {}
    func startMoodImport(repo _: MoodRepository, userID _: String?) async {}
    func stopMoodImport() async {}
    func resetMoodImport() async {}
    func activateBackgroundDeliveries() async throws {}
    func runBackgroundSyncPass() async {}
    func attachUploader(_: MeasurementBatchUploader) async {}
    func attachDeletionReconciler(_: MeasurementDeletionReconciler) async {}
    func setInitialBackfillCutoff(_: Date?) async {}
}

// swiftlint:enable force_unwrapping
