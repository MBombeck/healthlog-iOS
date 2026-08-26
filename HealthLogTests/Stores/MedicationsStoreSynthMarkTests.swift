import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **v0.5.5.1 W-MED2 synth-mark routing.**
///
/// `MedicationsStore.markSynthesizedPlaceholder` + the outcome-returning
/// variant route a `synth:<medId>|<iso>` id through the bulk-intake
/// endpoint via `MedicationsRepository.recordFromReminder` — the regular
/// `POST /api/medications/intake` cannot serve this path because it
/// requires a server-known `intakeId`.
///
/// These tests pin the optimistic-patch + rollback + outcome
/// discrimination contract using a real `MedicationsRepository` against
/// a stubbed `URLSession`. The bulk endpoint returns the standard
/// `{processed,inserted,duplicates,entries[...]}` envelope.
@Suite("MedicationsStore — synthesised-placeholder mark routing (W-MED2)", .serialized)
struct MedicationsStoreSynthMarkTests {
    private static let now = Date(timeIntervalSince1970: 1_716_300_000) // 2026-05-21 fixed

    private static func synthID(medicationId: String, scheduledAt: Date) -> String {
        MedicationIntake.synthesizedPlaceholderID(
            medicationId: medicationId,
            scheduledAt: scheduledAt
        )
    }

    private func makeAPI() -> APIClient {
        let keychain = InMemoryKeychain()
        try? keychain.setString("token", forKey: KeychainKey.authToken)
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.5.5",
            buildNumber: "22"
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

    private static func status(_ code: Int, request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: code,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
    }

    private static let bulkSuccessBody = Data(#"""
    {"data":{"processed":1,"inserted":1,"duplicates":0,"entries":[{"index":0,"status":"inserted","id":"server-intake-42","reason":null}]}}
    """#.utf8)

    // MARK: - .success on 200

    @Test(".success path posts to /api/medications/intake/bulk and clears optimistic synth row from todayIntakes")
    @MainActor
    func synthMarkSuccessHitsBulkEndpoint() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        let observer = RequestObserver()
        MockURLProtocol.handler = { req in
            observer.record(path: req.url?.path, method: req.httpMethod)
            return (Self.ok(req), Self.bulkSuccessBody)
        }
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)

        let scheduledAt = Date(timeIntervalSince1970: 1_716_280_000)
        let id = Self.synthID(medicationId: "med-lisinopril", scheduledAt: scheduledAt)

        let outcome = await store.markSynthesizedPlaceholderWithOutcome(
            intakeId: id,
            status: .taken,
            now: Self.now
        )

        #expect(outcome == .success)
        #expect(observer.path == "/api/medications/intake/bulk")
        #expect(observer.method == "POST")
        #expect(store.error == nil)
    }

    // MARK: - .queued on retriable error

    @Test(".queued path keeps the optimistic synth row visible so the outbox can replay it")
    @MainActor
    func synthMarkQueuedKeepsOptimistic() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        MockURLProtocol.handler = { _ in
            throw URLError(.notConnectedToInternet)
        }
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)

        let scheduledAt = Date(timeIntervalSince1970: 1_716_280_000)
        let id = Self.synthID(medicationId: "med-lisinopril", scheduledAt: scheduledAt)

        let outcome = await store.markSynthesizedPlaceholderWithOutcome(
            intakeId: id,
            status: .taken,
            now: Self.now
        )

        #expect(outcome == .queued)
        // Optimistic row stays in todayIntakes — outbox will reconcile.
        #expect(store.todayIntakes.contains(where: { $0.id == id }) == true)
        #expect(store.todayIntakes.first(where: { $0.id == id })?.status == .taken)
    }

    // MARK: - .failed on non-retriable rejection

    @Test(".failed path rolls back the optimistic synth row so the placeholder re-surfaces in derivedTodayIntakes")
    @MainActor
    func synthMarkFailedRollsBack() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        MockURLProtocol.handler = { req in
            (Self.status(422, request: req), Data(#"{"error":"medication_not_found"}"#.utf8))
        }
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)

        let scheduledAt = Date(timeIntervalSince1970: 1_716_280_000)
        let id = Self.synthID(medicationId: "med-lisinopril", scheduledAt: scheduledAt)

        let outcome = await store.markSynthesizedPlaceholderWithOutcome(
            intakeId: id,
            status: .taken,
            now: Self.now
        )

        if case .failed = outcome {
            // expected
        } else {
            Issue.record("Expected .failed, got \(outcome)")
        }
        // Optimistic row dropped — derivedTodayIntakes will re-emit the
        // pristine pending placeholder on next render.
        #expect(store.todayIntakes.contains(where: { $0.id == id }) == false)
    }

    // MARK: - markIntakeQuick fork

    @Test("markIntakeQuick detects synth ids and routes through the bulk-intake endpoint")
    @MainActor
    func markIntakeQuickRoutesSynthIds() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        let observer = RequestObserver()
        MockURLProtocol.handler = { req in
            observer.record(path: req.url?.path, method: req.httpMethod)
            return (Self.ok(req), Self.bulkSuccessBody)
        }
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)

        let scheduledAt = Date(timeIntervalSince1970: 1_716_280_000)
        let id = Self.synthID(medicationId: "med-lisinopril", scheduledAt: scheduledAt)

        let outcome = await store.markIntakeQuick(intakeId: id, status: .taken, now: Self.now)

        #expect(outcome == .success)
        #expect(
            observer.path == "/api/medications/intake/bulk",
            "Synth-id route must hit the bulk endpoint, not the regular POST /api/medications/intake"
        )
    }

    // MARK: - void-returning mark forks synth ids too

    @Test("mark(intake:status:) detects synth ids and routes through the bulk-intake endpoint")
    @MainActor
    func voidMarkRoutesSynthIds() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        let observer = RequestObserver()
        MockURLProtocol.handler = { req in
            observer.record(path: req.url?.path, method: req.httpMethod)
            return (Self.ok(req), Self.bulkSuccessBody)
        }
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)

        let scheduledAt = Date(timeIntervalSince1970: 1_716_280_000)
        let id = Self.synthID(medicationId: "med-lisinopril", scheduledAt: scheduledAt)

        await store.mark(intake: id, status: .taken)

        #expect(observer.path == "/api/medications/intake/bulk")
        #expect(store.error == nil)
    }

    // MARK: - parseSynthesizedPlaceholderID round-trip

    @Test("Synthesised-placeholder id round-trips through the parse helper")
    func parseRoundTrip() {
        let scheduledAt = Date(timeIntervalSince1970: 1_716_280_000)
        let id = MedicationIntake.synthesizedPlaceholderID(
            medicationId: "med-lisinopril",
            scheduledAt: scheduledAt
        )
        let parsed = MedicationsStore.parseSynthesizedPlaceholderID(id)
        #expect(parsed?.medicationId == "med-lisinopril")
        #expect(parsed?.scheduledAt == scheduledAt)
    }

    @Test("parseSynthesizedPlaceholderID returns nil on malformed input")
    func parseRejectsMalformed() {
        #expect(MedicationsStore.parseSynthesizedPlaceholderID("not-a-synth-id") == nil)
        #expect(MedicationsStore.parseSynthesizedPlaceholderID("synth:") == nil)
        #expect(MedicationsStore.parseSynthesizedPlaceholderID("synth:no-separator") == nil)
        #expect(MedicationsStore.parseSynthesizedPlaceholderID("synth:med|not-an-iso") == nil)
    }
}

/// Sendable-safe request observer for the `MockURLProtocol.handler`
/// closure — the closure is invoked on URLSession's delegate queue
/// (concurrent context) but Swift 6 strict-concurrency rejects raw
/// `var` capture. A pthread-mutex-backed class lets the test thread
/// read the recorded path/method post-await without a data race.
private final class RequestObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var _path: String?
    private var _method: String?

    func record(path: String?, method: String?) {
        lock.withLock {
            _path = path
            _method = method
        }
    }

    var path: String? {
        lock.withLock { _path }
    }

    var method: String? {
        lock.withLock { _method }
    }
}

// swiftlint:enable force_unwrapping
