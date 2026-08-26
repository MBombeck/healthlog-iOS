import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **Build 6.2 — medication lifecycle (pause / reactivate / end).**
///
/// Drives the REAL `APIClient` through `MockURLProtocol` (PROJECT_GUIDE.md rule) so the
/// `PUT /api/medications/{id}` bodies the store's lifecycle methods build go over
/// the production request path. Locks the read-modify-write safety: each action
/// sends ONLY its own key (pause/reactivate flip `active`; end sets `endsOn`),
/// never dropping an unrelated server field.
@MainActor
@Suite("Medication lifecycle — Build 6.2", .serialized)
struct MedicationLifecycleTests {
    private func makeClient() -> APIClient {
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

    private func makeStore() throws -> MedicationsStore {
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: makeClient(), outbox: outbox)
        return MedicationsStore(repo: repo)
    }

    private nonisolated func respondMed(active: Bool) -> String {
        "{\"data\":{\"id\":\"med-1\",\"name\":\"Med\",\"dose\":\"1 mg\",\"active\":\(active)}}"
    }

    /// Captured PUT request from a lifecycle action.
    private struct CapturedPut {
        var method: String?
        var path: String?
        var body: [String: Any]
    }

    private func captureBody(
        respondActive: Bool,
        _ action: (MedicationsStore) async -> MedicationsStore.WriteOutcome
    ) async throws -> CapturedPut {
        let store = try makeStore()
        nonisolated(unsafe) var method: String?
        nonisolated(unsafe) var path: String?
        nonisolated(unsafe) var raw: Data?
        MockURLProtocol.handler = { req in
            method = req.httpMethod
            path = req.url?.path
            raw = req.httpBody ?? Self.readStream(req.httpBodyStream)
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(respondMed(active: respondActive).utf8)
            )
        }
        let outcome = await action(store)
        #expect(outcome == .success)
        let object = (try? JSONSerialization.jsonObject(with: raw ?? Data())) as? [String: Any] ?? [:]
        return CapturedPut(method: method, path: path, body: object)
    }

    @Test("pause sends PUT active:false and nothing else")
    func pauseSendsActiveFalse() async throws {
        let captured = try await captureBody(respondActive: false) { store in
            await store.pauseMedication(id: "med-1")
        }
        #expect(captured.method == "PUT")
        #expect(captured.path == "/api/medications/med-1")
        #expect(captured.body["active"] as? Bool == false)
        #expect(captured.body["endsOn"] == nil, "pause must not touch the course window")
        #expect(captured.body["name"] == nil, "RMW: pause carries only `active`")
    }

    @Test("reactivate sends PUT active:true")
    func reactivateSendsActiveTrue() async throws {
        let captured = try await captureBody(respondActive: true) { store in
            await store.reactivateMedication(id: "med-1")
        }
        #expect(captured.method == "PUT")
        #expect(captured.body["active"] as? Bool == true)
        #expect(captured.body["endsOn"] == nil)
    }

    @Test("end sets endsOn to the given day and does not flip active")
    func endSetsEndsOn() async throws {
        let day = Date(timeIntervalSince1970: 1_781_760_000) // 2026-06-17T20:00:00Z
        let captured = try await captureBody(respondActive: true) { store in
            await store.endMedication(id: "med-1", on: day)
        }
        #expect(captured.method == "PUT")
        let endsOn = try #require(captured.body["endsOn"] as? String)
        // `MedicationCadenceLogic.isoDay` emits a bare `YYYY-MM-DD`.
        #expect(endsOn.count == 10, "endsOn is a bare YYYY-MM-DD course-window day")
        #expect(endsOn == MedicationCadenceLogic.isoDay(day))
        #expect(captured.body["active"] == nil, "ending a course is a schedule edit, not an activity flip")
    }

    private nonisolated static func readStream(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: 1024)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
