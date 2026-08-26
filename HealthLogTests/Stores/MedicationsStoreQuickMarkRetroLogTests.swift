import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// MEDS-RETROLOG-QUICK (RCA-med-compliance, b197) — the quick-mark path must
/// retro-log a PENDING PAST SCHEDULED slot onto its own `scheduledAt` instead
/// of the wall-clock `now`. Sending `takenAt = now` for a slot whose band has
/// already closed makes the server re-attribute by window band, tombstone the
/// original row and mint a new ad-hoc row → the phantom/unassigned intake +
/// dropped compliance count the operator saw on the card.
///
/// These tests assert on the real `POST /api/medications/intake` wire body
/// (real `APIClient` over `MockURLProtocol`, per PROJECT_GUIDE.md: no mock server on
/// the write path), mirroring `MedicationsStoreQuickSiteForwardTests`.
@Suite("MedicationsStore — quick-mark retro-logs a past scheduled slot (RCA b197)", .serialized)
struct MedicationsStoreQuickMarkRetroLogTests {
    // 2024-05-01T08:00:00Z — the scheduled slot instant (ISO8601 wire form).
    private static let scheduled = Date(timeIntervalSince1970: 1_714_550_400)
    private static let scheduledWire = "2024-05-01T08:00:00Z"
    // 09:00:00Z — a later wall-clock "now", outside the daily slot band.
    private static let lateNow = scheduled.addingTimeInterval(3600)
    private static let lateNowWire = "2024-05-01T09:00:00Z"

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

    private static let takenResponseBody = """
    {"data":{"id":"intake-1","medicationId":"med-1",\
    "scheduledFor":"2024-05-01T08:00:00Z","takenAt":"2024-05-01T08:00:00Z",\
    "skipped":false,"snoozedUntil":null}}
    """

    /// Reads either `httpBody` or the `httpBodyStream` URLSession converts a
    /// POST body onto by the time `MockURLProtocol` sees the request.
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

    // MARK: - Past pending scheduled slot → takenAt clamps to scheduledAt

    @Test("Quick-marking a PENDING PAST scheduled dose sends takenAt == scheduledAt (not now)")
    @MainActor
    func pastPendingSlotSendsScheduledTakenAt() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        nonisolated(unsafe) var capturedBody: Data?
        MockURLProtocol.handler = { req in
            capturedBody = Self.bodyData(req)
            return (Self.ok(req), Data(Self.takenResponseBody.utf8))
        }
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)
        store._testForceSet(todayIntakes: [pending()])

        // Mark the 08:00 slot taken at 09:00 — the operator's late-log scenario.
        let outcome = await store.markIntakeQuick(intakeId: "intake-1", status: .taken, now: Self.lateNow)
        #expect(outcome == .success)

        let bodyData = try #require(capturedBody, "The mark must have sent a request body")
        let bodyString = try #require(String(bytes: bodyData, encoding: .utf8))
        #expect(
            bodyString.contains(Self.scheduledWire),
            "Retro-log must pin takenAt to the scheduled slot (\(Self.scheduledWire)), got: \(bodyString)"
        )
        #expect(
            !bodyString.contains(Self.lateNowWire),
            "Retro-log must NOT send the later wall-clock now (\(Self.lateNowWire)) — that triggers server band re-attribution. Body: \(bodyString)"
        )
        // Optimistic row keeps its slot + reads taken with the scheduled stamp.
        #expect(store.todayIntakes.first?.scheduledAt == Self.scheduled)
        #expect(store.todayIntakes.first?.status == .taken)
    }

    // MARK: - On-time / current dose still uses now

    @Test("Quick-marking a current/on-time dose still sends takenAt ~ now")
    @MainActor
    func currentDoseSendsNowTakenAt() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        nonisolated(unsafe) var capturedBody: Data?
        MockURLProtocol.handler = { req in
            capturedBody = Self.bodyData(req)
            // Server echoes the on-time take (takenAt == scheduledAt == now here).
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

        // now == scheduledAt: marking right on time. takenAt must be `now`
        // (which equals scheduledAt here) — the band-safe case is unchanged.
        let outcome = await store.markIntakeQuick(intakeId: "intake-1", status: .taken, now: Self.scheduled)
        #expect(outcome == .success)

        let bodyData = try #require(capturedBody)
        let bodyString = try #require(String(bytes: bodyData, encoding: .utf8))
        #expect(
            bodyString.contains(Self.scheduledWire),
            "On-time mark sends takenAt == now (\(Self.scheduledWire)), got: \(bodyString)"
        )
    }

    // MARK: - Future dose (defensive) → takenAt clamps to now, never future

    @Test("Quick-marking a FUTURE scheduled dose clamps takenAt to now (never the future slot)")
    @MainActor
    func futureDoseSendsNowNotFutureSlot() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        nonisolated(unsafe) var capturedBody: Data?
        MockURLProtocol.handler = { req in
            capturedBody = Self.bodyData(req)
            let body = """
            {"data":{"id":"intake-1","medicationId":"med-1",\
            "scheduledFor":"2024-05-01T08:00:00Z","takenAt":"2024-05-01T07:00:00Z",\
            "skipped":false,"snoozedUntil":null}}
            """
            return (Self.ok(req), Data(body.utf8))
        }
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)
        store._testForceSet(todayIntakes: [pending()])

        // now is BEFORE the scheduled slot (07:00 vs 08:00) — future dose.
        let earlyNow = Self.scheduled.addingTimeInterval(-3600)
        let outcome = await store.markIntakeQuick(intakeId: "intake-1", status: .taken, now: earlyNow)
        #expect(outcome == .success)

        let bodyData = try #require(capturedBody)
        let bodyString = try #require(String(bytes: bodyData, encoding: .utf8))
        #expect(
            bodyString.contains("2024-05-01T07:00:00Z"),
            "Future dose must send now (07:00), never the future slot. Body: \(bodyString)"
        )
        #expect(
            !bodyString.contains(Self.scheduledWire),
            "Future dose must NOT send the future scheduled instant as takenAt. Body: \(bodyString)"
        )
    }
}

// swiftlint:enable force_unwrapping
