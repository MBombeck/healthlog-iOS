import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// H3 (AUDIT-bugs b198) — the bare void-returning `mark(intake:status:)` must
/// apply the SAME `min(scheduledAt, now)` clamp the quick-mark / retro paths
/// use. Without it, marking a PENDING PAST-SCHEDULED dose sends `takenAt = now`,
/// which makes the server re-attribute by window band, tombstone the slot row
/// and mint a phantom ad-hoc row (the bug fixed in ddee4a1a for `markIntakeQuick`).
///
/// Asserts on the real `POST /api/medications/intake` wire body (real
/// `APIClient` over `MockURLProtocol`, per PROJECT_GUIDE.md: no mock server on the
/// write path). The scheduled slot is pinned in 2024 so it is unconditionally
/// in the past relative to the store's internal `Date.now` — the clamp must
/// therefore send the 2024 scheduled instant, never the current wall-clock.
@Suite("MedicationsStore — mark(intake:) clamps a past scheduled slot (H3)", .serialized)
struct MedicationsStoreMarkIntakeClampTests {
    // 2024-05-01T08:00:00Z — a slot unconditionally in the past at test time.
    private static let scheduled = Date(timeIntervalSince1970: 1_714_550_400)
    private static let scheduledWire = "2024-05-01T08:00:00Z"

    private func pending() -> MedicationIntake {
        MedicationIntake(
            id: "intake-1",
            medicationId: "med-1",
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

    private static func bodyData(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    @Test("mark(intake:) on a PENDING PAST slot sends takenAt == scheduledAt (not now)")
    @MainActor
    func pastPendingSlotSendsScheduledTakenAt() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        nonisolated(unsafe) var capturedBody: Data?
        MockURLProtocol.handler = { req in
            capturedBody = Self.bodyData(req)
            let body = """
            {"data":{"id":"intake-1","medicationId":"med-1",\
            "scheduledFor":"2024-05-01T08:00:00Z","takenAt":"2024-05-01T08:00:00Z",\
            "skipped":false,"snoozedUntil":null}}
            """
            return (Self.ok(req), Data(body.utf8))
        }
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)
        store._testForceSet(todayIntakes: [pending()])

        await store.mark(intake: "intake-1", status: .taken)
        #expect(store.error == nil)

        let bodyData = try #require(capturedBody, "The mark must have sent a request body")
        let bodyString = try #require(String(bytes: bodyData, encoding: .utf8))
        #expect(
            bodyString.contains(Self.scheduledWire),
            "mark(intake:) must clamp takenAt to the scheduled slot (\(Self.scheduledWire)), got: \(bodyString)"
        )
        // Defensive: the current year must NOT appear in the body — that would
        // mean `takenAt = now` leaked past the clamp.
        let currentYear = Calendar.current.component(.year, from: .now)
        #expect(
            !bodyString.contains("\"takenAt\":\"\(currentYear)"),
            "mark(intake:) must NOT send the wall-clock now as takenAt. Body: \(bodyString)"
        )
        // Optimistic row keeps its slot + reads taken with the clamped stamp.
        #expect(store.todayIntakes.first?.takenAt == Self.scheduled)
        #expect(store.todayIntakes.first?.status == .taken)
    }

    // MARK: - W-DEDUP-INTAKE — Void `mark` delegates to `markIntakeQuick`

    /// W-DEDUP-INTAKE: the Void `mark(intake:status:)` is now a thin delegate
    /// to `markIntakeQuick`. A non-retriable 422 must roll the optimistic
    /// patch back exactly like the outcome path does — proving the Void
    /// surface inherits the canonical rollback (the duplicated rollback logic
    /// it used to carry was removed).
    @Test("mark(intake:) rolls back the optimistic patch on a non-retriable 422")
    @MainActor
    func voidMarkRollsBackOnNonRetriable() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        MockURLProtocol.handler = { req in
            (
                HTTPURLResponse(
                    url: req.url!,
                    statusCode: 422,
                    httpVersion: "HTTP/1.1",
                    headerFields: nil
                )!,
                Data(#"{"error":"validation"}"#.utf8)
            )
        }
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)
        store._testForceSet(todayIntakes: [pending()])

        await store.mark(intake: "intake-1", status: .taken)

        // Non-retriable error → the canonical rollback restores the pending row.
        #expect(
            store.todayIntakes.first?.status == .pending,
            "mark(intake:) must roll back the optimistic patch on a non-retriable error"
        )
        #expect(store.todayIntakes.first?.takenAt == nil)
    }

    /// W-DEDUP-INTAKE: the Void `mark` and the outcome-returning
    /// `markIntakeQuick` must produce the IDENTICAL optimistic patch (status
    /// + clamped `takenAt`) for the same past-pending slot. Drives both paths
    /// against an identically-seeded store and compares the resulting row.
    @Test("mark(intake:) produces the same optimistic patch as markIntakeQuick")
    @MainActor
    func voidMarkParityWithQuickMark() async throws {
        MockURLProtocol.handler = { req in
            let body = """
            {"data":{"id":"intake-1","medicationId":"med-1",\
            "scheduledFor":"2024-05-01T08:00:00Z","takenAt":"2024-05-01T08:00:00Z",\
            "skipped":false,"snoozedUntil":null}}
            """
            return (Self.ok(req), Data(body.utf8))
        }

        // Void `mark` path.
        let voidOutbox = try OutboxQueue(inMemory: true)
        let voidStore = MedicationsStore(repo: MedicationsRepository(
            api: makeAPI(), outbox: voidOutbox
        ))
        voidStore._testForceSet(todayIntakes: [pending()])
        await voidStore.mark(intake: "intake-1", status: .taken)
        let viaVoid = try #require(voidStore.todayIntakes.first)

        // Outcome-returning `markIntakeQuick` path.
        let quickOutbox = try OutboxQueue(inMemory: true)
        let quickStore = MedicationsStore(repo: MedicationsRepository(
            api: makeAPI(), outbox: quickOutbox
        ))
        quickStore._testForceSet(todayIntakes: [pending()])
        let outcome = await quickStore.markIntakeQuick(intakeId: "intake-1", status: .taken)
        #expect(outcome == .success)
        let viaQuick = try #require(quickStore.todayIntakes.first)

        // Same optimistic patch: status + clamped takenAt + slot identity.
        #expect(viaVoid.status == viaQuick.status)
        #expect(viaVoid.takenAt == viaQuick.takenAt)
        #expect(viaVoid.scheduledAt == viaQuick.scheduledAt)
        #expect(viaVoid.id == viaQuick.id)
        // Both clamp the past-pending slot to scheduledAt (never wall-clock now).
        #expect(viaVoid.takenAt == Self.scheduled)
    }
}

// swiftlint:enable force_unwrapping
