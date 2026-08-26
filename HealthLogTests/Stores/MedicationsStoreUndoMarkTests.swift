import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// MEDS-QUICK-MARK-UNDO (v0.11 W26) — store-level reversal tests for
/// `MedicationsStore.markIntakeQuickReturningUndo` + `undoIntakeMark(_:)`.
///
/// Real APIClient over `MockURLProtocol` (PROJECT_GUIDE.md: never a mock server on
/// the outbox-replay path). The undo of a card mark must return the dose to
/// `.pending` — these lock that round-trip for the real-intake path and the
/// synth-placeholder (PRN / off-day weekly) path.
@Suite("MedicationsStore — undo intake-mark reversal", .serialized)
struct MedicationsStoreUndoMarkTests {
    private static let scheduled = Date(timeIntervalSince1970: 1_714_550_400)
    private static let now = scheduled.addingTimeInterval(3600)

    private func pending(id: String = "intake-1", medId: String = "med-1") -> MedicationIntake {
        MedicationIntake(
            id: id,
            medicationId: medId,
            scheduledAt: Self.scheduled,
            takenAt: nil,
            status: .pending
        )
    }

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

    private static func ok(_ request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    }

    // MARK: - Real intake: taken → undo → pending

    @Test("Real-intake undo: a token is returned on success and reverses the row to .pending")
    @MainActor
    func realIntakeUndoRestoresPending() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        // Echo back whatever status the POST carried so the optimistic patch
        // resolves: taken on the forward mark, pending on the undo re-mark.
        MockURLProtocol.handler = { req in
            let skipped = false
            let body = """
            {"data":{"id":"intake-1","medicationId":"med-1",\
            "scheduledFor":"2026-05-01T08:00:00Z","takenAt":null,\
            "skipped":\(skipped),"snoozedUntil":null}}
            """
            return (Self.ok(req), Data(body.utf8))
        }
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)
        store._testForceSet(todayIntakes: [pending()])

        // Forward mark → taken.
        let (outcome, undo) = await store.markIntakeQuickReturningUndo(
            intakeId: "intake-1", status: .taken, now: Self.now
        )
        #expect(outcome == .success)
        let token = try #require(undo, "A landed mark must yield an undo token")

        // The token must capture the pre-mark pending snapshot.
        if case let .realIntake(snapshot) = token.kind {
            #expect(snapshot.status == .pending)
            #expect(snapshot.id == "intake-1")
        } else {
            Issue.record("Expected .realIntake token, got \(token.kind)")
        }

        // Undo → the row returns to pending.
        await store.undoIntakeMark(token)
        #expect(
            store.todayIntakes.first?.status == .pending,
            "Undo must reverse the mark back to .pending"
        )
    }

    // MARK: - Synth placeholder: skipped → undo deletes the disposition

    @Test("Synth-placeholder undo deletes the created server disposition and restores pending")
    @MainActor
    func synthUndoReuploadsPending() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        nonisolated(unsafe) var requests: [(method: String, path: String)] = []
        // Bulk-intake endpoint returns the BulkIntakeResponse shape on success
        // including the event id required for a real inverse DELETE.
        MockURLProtocol.handler = { req in
            requests.append((req.httpMethod ?? "", req.url?.path ?? ""))
            if req.httpMethod == "DELETE" {
                return (
                    HTTPURLResponse(
                        url: req.url!,
                        statusCode: 200,
                        httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    Data(#"{"data":null,"error":null}"#.utf8)
                )
            }
            let body = #"{"processed":1,"inserted":1,"duplicates":0,"entries":[{"index":0,"status":"inserted","id":"row-1","reason":null}]}"#
            return (Self.ok(req), Data(body.utf8))
        }
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)

        let synthID = MedicationIntake.synthesizedPlaceholderID(
            medicationId: "med-PRN",
            scheduledAt: Self.scheduled
        )

        let (outcome, undo) = await store.markIntakeQuickReturningUndo(
            intakeId: synthID, status: .skipped, now: Self.now
        )
        #expect(outcome == .success)
        let token = try #require(undo, "A landed synth mark must yield an undo token")

        if case let .synthesized(
            medicationId,
            scheduledAt,
            intakeId,
            serverEventID,
            queuedOperationID
        ) = token.kind {
            #expect(medicationId == "med-PRN")
            #expect(scheduledAt == Self.scheduled)
            #expect(intakeId == synthID)
            #expect(serverEventID == "row-1")
            #expect(queuedOperationID == nil)
        } else {
            Issue.record("Expected .synthesized token, got \(token.kind)")
        }

        // Undo must delete the created terminal disposition. The bulk endpoint
        // deliberately rejects `pending`, so a second POST can never be the
        // inverse operation.
        await store.undoIntakeMark(token)
        #expect(
            !store.todayIntakes.contains { $0.id == synthID && $0.status == .skipped },
            "Undo must drop the optimistic skipped synth row"
        )
        #expect(requests.filter { $0.method == "POST" }.count == 1)
        #expect(
            requests.contains {
                $0.method == "DELETE" && $0.path == "/api/medications/med-PRN/intake/row-1"
            }
        )
        #expect(store.error == nil)
    }

    @Test("Queued synth undo cancels the durable mark before it can replay")
    @MainActor
    func queuedSynthUndoCancelsOutbox() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        nonisolated(unsafe) var requests: [(method: String, path: String)] = []
        MockURLProtocol.handler = { request in
            requests.append((request.httpMethod ?? "", request.url?.path ?? ""))
            throw URLError(.notConnectedToInternet)
        }
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)
        let synthID = MedicationIntake.synthesizedPlaceholderID(
            medicationId: "med-queued",
            scheduledAt: Self.scheduled
        )

        let (outcome, undo) = await store.markIntakeQuickReturningUndo(
            intakeId: synthID, status: .skipped, now: Self.now
        )
        #expect(outcome == .queued)
        #expect(await outbox.snapshot.count == 1)
        let postCountBeforeUndo = requests.filter { $0.method == "POST" }.count

        try await store.undoIntakeMark(#require(undo))

        #expect(await outbox.snapshot.isEmpty, "Undo must prevent a later skipped replay")
        #expect(!store.todayIntakes.contains { $0.id == synthID && $0.status == .skipped })
        #expect(requests.filter { $0.method == "POST" }.count == postCountBeforeUndo)
        #expect(requests.allSatisfy { $0.method != "DELETE" })
        #expect(store.error == nil)
    }

    // MARK: - No token on failure

    @Test("No undo token when the mark fails (nothing landed, nothing to undo)")
    @MainActor
    func noTokenOnFailure() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        MockURLProtocol.handler = { req in
            (
                HTTPURLResponse(url: req.url!, statusCode: 422, httpVersion: "HTTP/1.1", headerFields: nil)!,
                Data(#"{"error":"validation"}"#.utf8)
            )
        }
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)
        store._testForceSet(todayIntakes: [pending()])

        let (outcome, undo) = await store.markIntakeQuickReturningUndo(
            intakeId: "intake-1", status: .taken, now: Self.now
        )

        if case .failed = outcome {} else {
            Issue.record("Expected .failed, got \(outcome)")
        }
        #expect(undo == nil, "A failed mark must not produce an undo token")
        #expect(store.todayIntakes.first?.status == .pending)
    }
}

// swiftlint:enable force_unwrapping
