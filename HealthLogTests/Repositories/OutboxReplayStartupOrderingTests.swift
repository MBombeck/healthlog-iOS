import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

@Suite("Outbox replay startup ordering", .serialized)
struct OutboxReplayStartupOrderingTests {
    @MainActor
    @Test("Immediate-online first dead letter is observed exactly once")
    func immediateOnlineFirstDeadLetterIsObservedExactlyOnce() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        try await enqueueExhaustedOperation(outbox, idempotencyKey: "startup-ordering-first")
        let replay = makeReplay(api: api, outbox: outbox)
        let syncState = SyncStateStore(repo: SyncStateRepository(api: api))
        let reachability = ImmediateOnlineReachability()
        let observer = DeadLetterObserver()
        let firstFrame = FirstFrameSignal()

        let bootstrap = AppContainer.startOutboxReplayBootstrap(
            reachability: reachability,
            replay: replay,
            outbox: outbox,
            firstFrame: firstFrame,
            onDeadLettered: { count in
                await syncState.noteDeadLettered(count)
                await observer.record(count)
            },
            ownerIsAlive: { true }
        )
        // Phase 09 / plan 09-05 — the bootstrap now waits for the app to draw
        // before it warms the store and consumes the first interface edge. The
        // Phase-6 contract below is unchanged *behind* that barrier; this is the
        // frame the launch would have drawn.
        firstFrame.emit()

        let firstEvents = await observer.waitForEventCount(1)
        #expect(firstEvents == [1])
        #expect(syncState.failedDropCount == 1)

        try await enqueueExhaustedOperation(outbox, idempotencyKey: "startup-ordering-later")
        reachability.yieldOnline()
        let allEvents = await observer.waitForEventCount(2)
        #expect(allEvents == [1, 1])
        #expect(syncState.failedDropCount == 2)

        bootstrap.cancel()
        await bootstrap.value
    }

    private func enqueueExhaustedOperation(
        _ outbox: OutboxQueue,
        idempotencyKey: String
    ) async throws {
        try await outbox.enqueue(.init(
            kind: .createAllergy,
            payload: Data(),
            idempotencyKey: idempotencyKey,
            createdAt: Date(timeIntervalSince1970: 1),
            attempts: 8
        ))
    }

    private func makeAPI() -> APIClient {
        APIClient(
            environment: AppEnvironment(
                baseURL: URL(string: "https://test.healthlog.local")!,
                bundleID: "dev.healthlog.app",
                appVersion: "0.16.2",
                buildNumber: "206"
            ),
            keychain: InMemoryKeychain(),
            sessionConfiguration: .mock()
        )
    }

    private func makeReplay(api: APIClient, outbox: OutboxQueue) -> OutboxReplayService {
        OutboxReplayService(
            outbox: outbox,
            measurementsRepo: MeasurementsRepository(api: api, outbox: outbox),
            moodRepo: MoodRepository(api: api, outbox: outbox),
            medicationsRepo: MedicationsRepository(api: api, outbox: outbox),
            allergiesRepo: AllergiesRepository(api: api, outbox: outbox),
            familyHistoryRepo: FamilyHistoryRepository(api: api, outbox: outbox),
            maxAttempts: 8,
            deadLetterMinAge: 0,
            attemptBackoff: 0
        )
    }
}

private actor DeadLetterObserver {
    private var events: [Int] = []
    private var waiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func record(_ count: Int) {
        events.append(count)
        let ready = waiters.filter { events.count >= $0.target }
        waiters.removeAll { events.count >= $0.target }
        ready.forEach { $0.continuation.resume() }
    }

    func waitForEventCount(_ target: Int) async -> [Int] {
        if events.count < target {
            await withCheckedContinuation { continuation in
                waiters.append((target, continuation))
            }
        }
        return events
    }
}

private final class ImmediateOnlineReachability: ReachabilityProviding, @unchecked Sendable {
    private let stream: AsyncStream<Bool>
    private let continuation: AsyncStream<Bool>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: Bool.self)
        continuation.yield(true)
    }

    var isOnlineStream: AsyncStream<Bool> {
        get async {
            stream
        }
    }

    func isCurrentlyOnline() async -> Bool {
        true
    }

    func yieldOnline() {
        continuation.yield(true)
    }
}

// swiftlint:enable force_unwrapping
