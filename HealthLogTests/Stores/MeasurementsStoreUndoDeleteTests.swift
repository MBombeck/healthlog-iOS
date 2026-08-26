import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// MEDS-QUICK-MARK-UNDO sibling (v0.11 W26) — measurement-delete undo.
///
/// `MeasurementListScreen` now routes deletes through
/// `MeasurementsStore.delete`, which optimistically removes the row, enqueues
/// a `Rückgängig` toast, and re-POSTs the row on undo. Real APIClient over
/// `MockURLProtocol` so the DELETE + the restore POST exercise the real wire
/// (PROJECT_GUIDE.md: never a mock server on the outbox-replay path).
@MainActor
@Suite("MeasurementsStore — delete undo", .serialized)
struct MeasurementsStoreUndoDeleteTests {
    private func makeAPI() -> APIClient {
        let keychain = InMemoryKeychain()
        try? keychain.setString("token", forKey: KeychainKey.authToken)
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.5.0",
            buildNumber: "1"
        )
        return APIClient(
            environment: env,
            keychain: keychain,
            sessionConfiguration: .mock()
        )
    }

    private nonisolated static func response(_ code: Int, request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: code,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    }

    /// Seed `store.recent` with a single WEIGHT row via the real `load()`
    /// path (no direct setter on the store). The list reply uses the
    /// `{"data":{"measurements":[…]}}` envelope; `load()` also fires a
    /// parallel series-hydration fetch which our handler tolerates (returns
    /// an empty series for non-`/measurements` reads).
    private func seedOneWeight(store: MeasurementsStore, id: String) async {
        MockURLProtocol.handler = { req in
            if req.url?.path.contains("/series") == true {
                return (Self.response(200, request: req), Data(#"{"data":{"points":[]}}"#.utf8))
            }
            let body = """
            {"data":{"measurements":[{"id":"\(id)","type":"WEIGHT",\
            "value":72.4,"measuredAt":"2023-11-14T22:13:20Z"}]}}
            """
            return (Self.response(200, request: req), Data(body.utf8))
        }
        await store.load()
    }

    @Test("delete removes the row optimistically and enqueues a Rückgängig action")
    func deleteEnqueuesUndo() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MeasurementsRepository(api: api, outbox: outbox)
        let undo = UndoCoordinator()
        let store = MeasurementsStore(repo: repo, undoCoordinator: undo)
        await seedOneWeight(store: store, id: "m-1")
        let row = try #require(store.recent.first { $0.id == "m-1" })

        MockURLProtocol.handler = { req in
            (Self.response(200, request: req), Data("{}".utf8))
        }
        let ok = await store.delete(row)

        #expect(ok)
        #expect(!store.recent.contains { $0.id == "m-1" }, "Delete must optimistically remove the row")
        #expect(undo.current != nil, "Delete must enqueue a Rückgängig action")
    }

    @Test("undo of a delete re-creates the measurement (new server id)")
    func undoRestoresMeasurement() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MeasurementsRepository(api: api, outbox: outbox)
        let undo = UndoCoordinator()
        let store = MeasurementsStore(repo: repo, undoCoordinator: undo)
        await seedOneWeight(store: store, id: "m-1")
        let row = try #require(store.recent.first { $0.id == "m-1" })

        MockURLProtocol.handler = { req in
            if req.httpMethod == "DELETE" {
                return (Self.response(200, request: req), Data("{}".utf8))
            }
            if req.url?.path.contains("/series") == true {
                return (Self.response(200, request: req), Data(#"{"data":{"points":[]}}"#.utf8))
            }
            // Restore POST → server returns the re-created wire row.
            let body = """
            {"data":{"id":"m-restored","type":"WEIGHT","value":72.4,\
            "measuredAt":"2023-11-14T22:13:20Z"}}
            """
            return (Self.response(200, request: req), Data(body.utf8))
        }

        _ = await store.delete(row)
        #expect(!store.recent.contains { $0.id == "m-1" })

        // Fire the undo closure the toast would call.
        await undo.performUndo()

        #expect(
            store.recent.contains { $0.kind == .weight },
            "Undo must re-create the deleted measurement"
        )
        #expect(undo.current == nil)
    }
}

// swiftlint:enable force_unwrapping
