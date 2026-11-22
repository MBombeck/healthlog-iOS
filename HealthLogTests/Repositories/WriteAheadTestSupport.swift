import Foundation
@testable import HealthLog
import SwiftData
import Synchronization
import Testing

// swiftlint:disable force_unwrapping

// Fixtures for the suites that follow one write from a repository to the
// wire, through a failed persist, and through a restart.

/// One request as it left: enough to tell a second delivery from the first.
struct WAWireCall: Sendable, Equatable {
    let method: String
    let path: String
    let key: String
}

final class WAWireLog: Sendable {
    private let calls = Mutex<[WAWireCall]>([])

    var all: [WAWireCall] {
        calls.withLock { $0 }
    }

    func add(_ call: WAWireCall) {
        calls.withLock { $0.append(call) }
    }

    func record(_ req: URLRequest) {
        add(WAWireCall(
            method: req.httpMethod ?? "",
            path: req.url?.path ?? "",
            key: req.value(forHTTPHeaderField: "Idempotency-Key") ?? ""
        ))
    }
}

/// The request bodies as they left, as text.
final class WABodyLog: Sendable {
    private let bodies = Mutex<[String]>([])

    var all: [String] {
        bodies.withLock { $0 }
    }

    func add(_ req: URLRequest) {
        bodies.withLock { $0.append(String(bytes: req.waBody, encoding: .utf8) ?? "") }
    }
}

/// A server that never answers. The request leaves and its caller waits until
/// the task is cancelled, which is what a write looks like at the moment the
/// process dies under it.
final class WAStalledAPI: APIClientProtocol, Sendable {
    let log = WAWireLog()
    private let arrivals: AsyncStream<Void>
    private let arrived: AsyncStream<Void>.Continuation

    init() {
        (arrivals, arrived) = AsyncStream<Void>.makeStream()
    }

    /// Returns once the next request is out.
    func requestLeft() async {
        for await _ in arrivals {
            return
        }
    }

    private func stall(_ method: HTTPMethod, _ path: String, _ key: IdempotencyKey) async throws -> Never {
        log.add(WAWireCall(method: method.rawValue, path: path, key: key.raw))
        arrived.yield()
        let (never, hold) = AsyncStream<Void>.makeStream()
        for await _ in never {}
        hold.finish()
        throw CancellationError()
    }

    func send<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> T {
        try await stall(request.method, request.path, request.idempotencyKey)
    }

    func sendVoid(_ request: APIRequest<EmptyPayload>) async throws {
        try await stall(request.method, request.path, request.idempotencyKey)
    }

    func download(_ request: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
        try await stall(request.method, request.path, request.idempotencyKey)
    }
}

/// Every request fails with one given error and is counted.
struct WAFailingAPI: APIClientProtocol {
    let error: HLError
    let log = WAWireLog()

    private func fail(_ method: HTTPMethod, _ path: String, _ key: IdempotencyKey) throws -> Never {
        log.add(WAWireCall(method: method.rawValue, path: path, key: key.raw))
        throw error
    }

    func send<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> T {
        try fail(request.method, request.path, request.idempotencyKey)
    }

    func sendVoid(_ request: APIRequest<EmptyPayload>) async throws {
        try fail(request.method, request.path, request.idempotencyKey)
    }

    func download(_ request: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
        try fail(request.method, request.path, request.idempotencyKey)
    }
}

/// iOS grants no background execution time, so the outbox refuses the write.
struct WARefusingLease: BackgroundExecutionLeasing {
    func withLease<T: Sendable>(
        named _: String,
        _: @escaping @Sendable () async throws -> T
    ) async throws -> T? {
        nil
    }
}

/// iOS grants background time for the first writes and then for no more.
final class WAExhaustedLease: BackgroundExecutionLeasing {
    private let left: Mutex<Int>

    init(grants: Int) {
        left = Mutex(grants)
    }

    func withLease<T: Sendable>(
        named _: String,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T? {
        let granted = left.withLock { left in
            guard left > 0 else { return false }
            left -= 1
            return true
        }
        return granted ? try await body() : nil
    }
}

enum WAFixture {
    static let owner = "account-wa"

    /// `POST /api/medications/intake`, server v1.47.2: the raw intake row.
    static let intakeLogged = Data(#"""
    {"data":{"id":"evt-1","medicationId":"med-1","scheduledFor":"2026-06-13T06:00:00.000Z",
    "takenAt":"2026-06-13T06:05:00.000Z","skipped":false}}
    """#.utf8)

    static let allergyCreated = Data(#"""
    {"data":{"id":"srv-a-1","substance":"Penicillin","category":"MEDICATION","type":"ALLERGY",
    "severity":"SEVERE","status":"ACTIVE","onsetAt":null,"reaction":null,"note":null,
    "createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}}
    """#.utf8)

    static let takenAt = Date(timeIntervalSince1970: 1_781_330_700)

    static func reply(_ req: URLRequest, _ status: Int, _ body: Data? = nil) -> (HTTPURLResponse, Data?) {
        let fields = ["Content-Type": "application/json"]
        return (HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: fields)!, body)
    }

    /// The real client over the stubbed session. Its in-request retries do
    /// not wait, so an answer that is retried costs no wall-clock time.
    static func api(owner: String = owner) -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "1.5.1",
            buildNumber: "303"
        )
        let keychain = InMemoryKeychain()
        try? keychain.setString("bearer-wa", forKey: KeychainKey.authToken)
        try? keychain.setString(owner, forKey: KeychainKey.userID)
        return APIClient(
            environment: env,
            keychain: keychain,
            sessionConfiguration: .mock(),
            retryClock: APIRetryClock(now: { Date() }, sleep: { _ in })
        )
    }

    /// One queue of one process. A second queue over the same container is
    /// the process after a restart: same rows, nothing carried over in memory.
    static func queue(on container: ModelContainer, owner: String = owner) -> OutboxQueue {
        OutboxQueue(
            testContainer: container,
            currentOwnerProvider: { owner },
            currentAuthTokenProvider: { "bearer-wa" }
        )
    }

    static func replay(
        outbox: OutboxQueue,
        owner: String = owner,
        clock: C4Clock = C4Clock(),
        discards: C4Discards = C4Discards(),
        attemptBackoff: TimeInterval = 0,
        rerunSleep: (@Sendable (TimeInterval) async throws -> Void)? = nil,
        currentUser: (@Sendable () -> String?)? = nil,
        serverHealthDegraded: (@Sendable () async -> Bool)? = nil
    ) -> OutboxReplayService {
        let api = api(owner: owner)
        return OutboxReplayService(
            outbox: outbox,
            measurementsRepo: MeasurementsRepository(api: api, outbox: outbox),
            moodRepo: MoodRepository(api: api, outbox: outbox),
            medicationsRepo: MedicationsRepository(api: api, outbox: outbox),
            allergiesRepo: AllergiesRepository(api: api, outbox: outbox),
            currentUserProvider: currentUser ?? { owner },
            attemptBackoff: attemptBackoff,
            clock: { clock.now },
            serverHealthDegraded: serverHealthDegraded,
            onDiscarded: { notices in discards.add(notices) },
            rerunSleep: rerunSleep
        )
    }

    /// A planned dose marked as taken, queued the way a failed send leaves it.
    static func enqueueIntake(_ outbox: OutboxQueue, key: String = "wa-intake") async throws {
        let body = MedicationsRepository.IntakeUpdate(intakeId: "intake-1", status: "TAKEN", takenAt: takenAt)
        try await outbox.enqueue(.init(
            kind: .takeMedication,
            payload: JSONEncoder.hlDefault.encode(body),
            idempotencyKey: key
        ))
    }
}

extension URLRequest {
    /// The body as the stubbed session sees it: URLProtocol hands it over as
    /// a stream, not as `httpBody`.
    var waBody: Data {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return Data() }
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

/// Waits for something another task brings about, and says so when it never
/// comes instead of hanging the run.
func waUntil(_ what: String, _ condition: @Sendable () async -> Bool) async {
    for _ in 0 ..< 2000 {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("never happened: \(what)")
}

// swiftlint:enable force_unwrapping
