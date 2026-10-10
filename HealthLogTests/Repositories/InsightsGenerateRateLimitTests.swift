import Foundation

// swiftlint:disable force_unwrapping
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// **1.2 V5 — `POST /api/insights/generate` stays inside the server's limits.**
///
/// Production 2026-10-07..09: twelve 429s from `HealthLog-iOS/1.1.1`, in
/// bursts of four within six seconds (`insights.briefing.budget_exceeded`, a
/// refusal with no `Retry-After`). One app call became four requests because
/// the transport re-sent the 429 on its backoff, and the prefetch warmed the
/// route on every foreground. These cases pin the repository's discipline:
/// one request per call, a local hold after a 429, one shared request for
/// concurrent callers.
@Suite("InsightsRepository — generate rate-limit discipline (1.2 V5)", .serialized, .mockURLSession, .timeLimit(.minutes(1)))
struct InsightsGenerateRateLimitTests {
    static let successBody = #"{"insights":{"summary":"S","recommendations":[],"citations":[],"warnings":[]},"cached":true}"#

    // MARK: - Real transport

    @Test("A 429 without Retry-After is sent once, not re-sent on the transport backoff")
    func budget429IsNotRetried() async throws {
        nonisolated(unsafe) var posts = 0
        MockURLProtocol.install { request in
            if request.targets("/api/insights/generate") { posts += 1 }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 429,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            let body = #"{"data":null,"error":"Daily AI token budget reached","meta":{"errorCode":"insights.generate.budgetExceeded"}}"#
            return (response, Data(body.utf8))
        }
        let repo = InsightsRepository(api: Self.makeAPIClient())
        await #expect(throws: HLError.self) {
            _ = try await repo.generateBriefing(force: false)
        }
        #expect(posts == 1, "one call must be one request")
    }

    // MARK: - Hold after a 429

    @Test("After a 429 without Retry-After the next calls stay on the device for an hour")
    func holdsAfter429() async throws {
        let api = GenerateStubAPI(script: [.rateLimited(nil), .success])
        let clock = StepClock()
        let repo = InsightsRepository(api: api, now: { clock.now })

        await #expect(throws: HLError.self) { _ = try await repo.generateBriefing(force: false) }
        clock.advance(by: 30 * 60)
        await #expect(throws: HLError.self) { _ = try await repo.generateBriefing(force: false) }
        await #expect(throws: HLError.self) { _ = try await repo.generateBriefing(force: true) }
        #expect(await api.posts == 1, "held calls must not reach the server")

        clock.advance(by: 31 * 60)
        _ = try await repo.generateBriefing(force: false)
        #expect(await api.posts == 2, "after the hold the next call goes out again")
    }

    @Test("A held call reports the remaining wait as rateLimited")
    func heldCallReportsRemainingWait() async throws {
        let api = GenerateStubAPI(script: [.rateLimited(120)])
        let clock = StepClock()
        let repo = InsightsRepository(api: api, now: { clock.now })

        await #expect(throws: HLError.self) { _ = try await repo.generateBriefing(force: false) }
        clock.advance(by: 20)
        do {
            _ = try await repo.generateBriefing(force: false)
            Issue.record("a held call must throw")
        } catch let HLError.rateLimited(retryAfter) {
            #expect(retryAfter == 100)
        }
        clock.advance(by: 101)
        await #expect(throws: GenerateStubAPI.Exhausted.self) { _ = try await repo.generateBriefing(force: false) }
        #expect(await api.posts == 2, "Retry-After is honoured, not the one-hour default")
    }

    @Test("Other failures do not hold the route")
    func otherFailuresDoNotHold() async throws {
        let api = GenerateStubAPI(script: [.server(422), .success])
        let repo = InsightsRepository(api: api)
        await #expect(throws: HLError.self) { _ = try await repo.generateBriefing(force: false) }
        _ = try await repo.generateBriefing(force: false)
        #expect(await api.posts == 2)
    }

    // MARK: - Coalescing

    @Test("Concurrent non-forced calls share one request")
    func concurrentCallsShareOneRequest() async throws {
        let api = GenerateStubAPI(script: [.success, .success, .success], gated: true)
        let repo = InsightsRepository(api: api)
        async let first = repo.generateBriefing(force: false)
        await api.waitForPosts(1)
        async let second = repo.generateBriefing(force: false)
        async let third = repo.generateBriefing(force: false)
        // Both joiners must have reached the shared request before it answers;
        // the join is the event awaited, no clock involved.
        while await repo.generateJoinCount < 2 {
            await Task.yield()
        }
        await api.open()
        _ = try await (first, second, third)
        #expect(await api.posts == 1)
    }

    @Test("Every generate request goes out with maxRetries 0")
    func requestCarriesNoRetries() async throws {
        let api = GenerateStubAPI(script: [.success, .success])
        let repo = InsightsRepository(api: api)
        _ = try await repo.generateBriefing(force: false)
        _ = try await repo.generateBriefing(force: true)
        #expect(await api.maxRetriesSeen == [0, 0])
    }

    // MARK: - Fixtures

    static func makeAPIClient() -> APIClient {
        let keychain = InMemoryKeychain()
        try? keychain.setString("token", forKey: KeychainKey.authToken)
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "1.2.0",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock())
    }
}

/// A clock the test steps by hand.
private final class StepClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_791_000_000)

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        lock.unlock()
    }
}

/// Scripted `APIClientProtocol` for the generate route: each POST takes the
/// next outcome. `gated` parks every POST until ``open()``.
private actor GenerateStubAPI: APIClientProtocol {
    enum Outcome {
        case success
        case rateLimited(TimeInterval?)
        case server(Int)
    }

    struct Exhausted: Error {}

    private var script: [Outcome]
    private let gated: Bool
    private var isOpen = false
    private var parked: [CheckedContinuation<Void, Never>] = []
    private var postWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var posts = 0
    private(set) var maxRetriesSeen: [Int] = []

    init(script: [Outcome], gated: Bool = false) {
        self.script = script
        self.gated = gated
    }

    func send<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> T {
        posts += 1
        maxRetriesSeen.append(request.maxRetries)
        let reached = posts
        let ready = postWaiters.filter { $0.0 <= reached }
        postWaiters.removeAll { $0.0 <= reached }
        for waiter in ready {
            waiter.1.resume()
        }
        if gated, !isOpen {
            await withCheckedContinuation { parked.append($0) }
        }
        guard !script.isEmpty else { throw Exhausted() }
        switch script.removeFirst() {
        case .success:
            return try JSONDecoder.hlDefault.decode(T.self, from: Data(InsightsGenerateRateLimitTests.successBody.utf8))
        case let .rateLimited(retryAfter):
            throw HLError.rateLimited(retryAfter: retryAfter)
        case let .server(status):
            throw HLError.server(status: status, code: nil, message: "stub")
        }
    }

    func sendVoid(_: APIRequest<EmptyPayload>) async throws {}

    func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
        throw Exhausted()
    }

    func waitForPosts(_ count: Int) async {
        if posts >= count { return }
        await withCheckedContinuation { postWaiters.append((count, $0)) }
    }

    func open() {
        isOpen = true
        let waiting = parked
        parked.removeAll()
        for continuation in waiting {
            continuation.resume()
        }
    }
}
