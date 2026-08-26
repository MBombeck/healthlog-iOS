import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// Lock-basierter Test-Clock — sync API damit der Throttle ihn als `() -> Date`
/// einhängen kann. Sammelt sleep-Aufrufe + advance't den virtuellen Clock dabei
/// um genau die Sleep-Dauer (Production-Sleep wäre `Task.sleep`, für Tests reicht
/// ein No-Op + Clock-Advance).
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private var sleeps: [TimeInterval] = []

    init(start: Date) {
        current = start
    }

    func now() -> Date {
        lock.withLock { current }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(interval) }
    }

    func recordSleep(_ interval: TimeInterval) {
        lock.withLock {
            sleeps.append(interval)
            current = current.addingTimeInterval(interval)
        }
    }

    var sleepCalls: [TimeInterval] {
        lock.withLock { sleeps }
    }
}

@Suite("BatchSyncThrottle (sliding window)")
struct BatchSyncThrottleTests {
    @Test("Erste maxPerWindow Aufrufe akzeptieren ohne Sleep")
    func acceptsBurstUpToWindowMax() async throws {
        let clock = TestClock(start: Date(timeIntervalSince1970: 0))
        let throttle = BatchSyncThrottle(
            maxPerWindow: 3,
            window: 60.0,
            jitter: 0 ... 0,
            now: { [clock] in clock.now() },
            sleep: { [clock] interval in clock.recordSleep(interval) }
        )
        for _ in 0 ..< 3 {
            try await throttle.acquire()
        }
        #expect(clock.sleepCalls.isEmpty)
        #expect(await throttle.inFlightCount == 3)
    }

    @Test("Aufruf maxPerWindow+1 schläft bis das älteste Token (oldest + window) herausfällt")
    func acquiresWaitsForOldestToExpire() async throws {
        let clock = TestClock(start: Date(timeIntervalSince1970: 0))
        let throttle = BatchSyncThrottle(
            maxPerWindow: 2,
            window: 60.0,
            jitter: 0 ... 0,
            now: { [clock] in clock.now() },
            sleep: { [clock] interval in clock.recordSleep(interval) }
        )
        try await throttle.acquire()
        try await throttle.acquire()
        clock.advance(by: 10.0)
        try await throttle.acquire()

        let sleeps = clock.sleepCalls
        #expect(sleeps.count == 1)
        #expect(abs((sleeps.first ?? 0) - 50.0) < 0.001)
    }

    @Test("Sliding-Window: Aufrufe weit außerhalb von window expiren ohne Sleep")
    func slidingWindowEvictsOld() async throws {
        let clock = TestClock(start: Date(timeIntervalSince1970: 0))
        let throttle = BatchSyncThrottle(
            maxPerWindow: 2,
            window: 30.0,
            jitter: 0 ... 0,
            now: { [clock] in clock.now() },
            sleep: { [clock] interval in clock.recordSleep(interval) }
        )
        try await throttle.acquire()
        try await throttle.acquire()
        clock.advance(by: 31.0)
        try await throttle.acquire()
        try await throttle.acquire()

        #expect(clock.sleepCalls.isEmpty)
        #expect(await throttle.inFlightCount == 2)
    }

    @Test("Jitter wird zur Wartezeit addiert")
    func jitterIncreasesWait() async throws {
        let clock = TestClock(start: Date(timeIntervalSince1970: 0))
        let throttle = BatchSyncThrottle(
            maxPerWindow: 1,
            window: 10.0,
            jitter: 1.0 ... 1.0,
            now: { [clock] in clock.now() },
            sleep: { [clock] interval in clock.recordSleep(interval) }
        )
        try await throttle.acquire()
        try await throttle.acquire()

        let sleeps = clock.sleepCalls
        #expect(sleeps.count == 1)
        #expect(abs((sleeps.first ?? 0) - 11.0) < 0.001)
    }
}
