import Foundation
@testable import HealthLog
import Testing

/// **S2 (#115, server comments of 2026-10-01) — the ECG sweep finishes at any
/// rate limit.**
///
/// The reporter's log: 61 posts in one sync, 43 `duplicate`, 17 `updated`,
/// one `429`. Build 287 stopped on the 429 and held the one shared anchor, so
/// the next wake re-posted the same 61 and the 61st was refused again — a sweep
/// holding more recordings than the per-minute limit could never finish, and
/// the newest ECG never arrived.
///
/// These tests drive the coordinator against a server-shaped limiter
/// (``EcgIngestLimiter``, v1.39.8 refusal: 429 + `Retry-After`) on a clock the
/// test owns; the pause seam (``EcgSyncPause``) advances that clock instead of
/// sleeping.
///
/// `.serialized` — the suite installs the process-global `MockURLProtocol.handler`.
@Suite("EcgSyncCoordinator — Fortschritt bei jedem Limit (S2)", .serialized, .mockURLSession)
struct EcgSyncSweepProgressTests {
    private static let heldBy287 = Data("anchor-held-by-287".utf8)
    private static let advanced = Data("anchor-after-sweep".utf8)

    private struct Harness {
        let coordinator: EcgSyncCoordinator
        let limiter: EcgIngestLimiter
        let clock: EcgTestClock
        let source: FakeEcgSource
        let defaults: @Sendable () -> UserDefaults
    }

    /// An installation of 287 with a held anchor and `count` recordings
    /// waiting, against an ECG limit of `limit` per minute.
    private func installation(count: Int, limit: Int) -> Harness {
        let (api, keychain) = EcgSyncTestSupport.makeClient()
        let clock = EcgTestClock()
        let limiter = EcgIngestLimiter(limit: limit, clock: clock)
        MockURLProtocol.install { req in limiter.handle(req) }
        let defaults = EcgSyncTestSupport.isolatedDefaults()
        defaults().set(Self.heldBy287, forKey: EcgSyncTestSupport.anchorKey)
        let recordings = EcgSyncProgressFixtures.history(count)
        let source = FakeEcgSource(
            recordings: recordings,
            volts: EcgSyncProgressFixtures.volts(for: recordings),
            nextAnchor: Self.advanced
        )
        let coordinator = EcgSyncTestSupport.makeCoordinator(
            api: api,
            keychain: keychain,
            source: source,
            defaultsProvider: defaults,
            clock: { clock.now }
        )
        return Harness(coordinator: coordinator, limiter: limiter, clock: clock, source: source, defaults: defaults)
    }

    /// A wake whose pause advances the test clock.
    private func wake(_ harness: Harness, pauses: EcgPauseRecorder) async -> EcgSyncSummary {
        let sleeper: @Sendable (TimeInterval) async throws -> Void = { seconds in
            pauses.record(seconds)
            harness.clock.advance(by: seconds)
        }
        return await EcgSyncPause.$sleep.withValue(sleeper) {
            await harness.coordinator.sync()
        }
    }

    /// A wake that cannot wait: the background window ends at the first pause.
    private func expiringWake(_ harness: Harness) async -> EcgSyncSummary {
        let windowEnds: @Sendable (TimeInterval) async throws -> Void = { _ in throw CancellationError() }
        return await EcgSyncPause.$sleep.withValue(windowEnds) {
            await harness.coordinator.sync()
        }
    }

    // MARK: - Update path (287 → this build)

    @Test("Update von 287: gehaltener Anker, 100 Aufnahmen, Limit 60/min — ein Wake wartet die Minute ab und wird fertig")
    func updatePathCompletesInOneWakeByPausing() async {
        let harness = installation(count: 100, limit: 60)
        let pauses = EcgPauseRecorder()

        let summary = await wake(harness, pauses: pauses)

        #expect(harness.source.lastAnchorSeen == Self.heldBy287, "the sweep resumes from the anchor 287 held")
        #expect(summary.inserted == 100)
        #expect(summary.updated == 0, "no recording is written twice")
        #expect(summary.stoppedBecause == nil)
        #expect(harness.limiter.refused == 1, "one 429, then the named wait")
        #expect(harness.limiter.posts.count == 101)
        #expect(pauses.sleeps == [60], "the pause is the server's Retry-After, once")
        #expect(harness.limiter.outcomes.values.allSatisfy { $0 == ["inserted"] })
        #expect(harness.defaults().data(forKey: EcgSyncTestSupport.anchorKey) == Self.advanced)
        #expect(
            harness.defaults().object(forKey: EcgSyncTestSupport.confirmedKey) == nil,
            "the ledger lets go of what the anchor now covers"
        )
    }

    @Test("Update von 287 über mehrere Wakes: endet das Fenster beim 429, macht der nächste Wake an derselben Stelle weiter")
    func updatePathResumesAcrossWakes() async {
        let harness = installation(count: 100, limit: 60)

        let first = await expiringWake(harness)
        #expect(first.inserted == 60)
        #expect(first.stoppedBecause == .rateLimited)
        #expect(harness.defaults().data(forKey: EcgSyncTestSupport.anchorKey) == Self.heldBy287)

        harness.clock.advance(by: 60)
        let second = await expiringWake(harness)

        #expect(second.alreadyConfirmed == 60, "confirmed recordings are not posted again")
        #expect(second.inserted == 40)
        #expect(second.updated == 0)
        #expect(second.stoppedBecause == nil)
        #expect(harness.limiter.posts.count == 101, "60 + one refused + the remaining 40")
        #expect(harness.limiter.outcomes.count == 100)
        #expect(harness.limiter.outcomes.values.allSatisfy { $0 == ["inserted"] })
        #expect(harness.defaults().data(forKey: EcgSyncTestSupport.anchorKey) == Self.advanced)
    }

    @Test("Die Schleife aus #115: auch bei 61 wartenden Aufnahmen und Limit 60 endet der Sweep spätestens im zweiten Wake")
    func reportersLoopTerminates() async {
        let harness = installation(count: 61, limit: 60)

        _ = await expiringWake(harness)
        harness.clock.advance(by: 60)
        let second = await expiringWake(harness)

        #expect(second.inserted == 1)
        #expect(second.stoppedBecause == nil)
        #expect(harness.limiter.outcomes.count == 61)
        #expect(harness.defaults().data(forKey: EcgSyncTestSupport.anchorKey) == Self.advanced)
    }

    // MARK: - Newest first

    @Test("Neueste zuerst: ein frisches EKG wartet nicht hinter der Historie")
    func newestRecordingGoesFirst() async {
        let harness = installation(count: 5, limit: 1)

        let first = await expiringWake(harness)

        #expect(first.inserted == 1)
        #expect(harness.limiter.storedOrder == ["ecg-004"], "the newest strip is the one the full bucket let through")

        for _ in 0 ..< 4 {
            harness.clock.advance(by: 60)
            _ = await expiringWake(harness)
        }
        #expect(harness.limiter.storedOrder == ["ecg-004", "ecg-003", "ecg-002", "ecg-001", "ecg-000"])
        #expect(harness.defaults().data(forKey: EcgSyncTestSupport.anchorKey) == Self.advanced)
    }

    @Test("Reihenfolge: nach recordedAt absteigend, Gleichstand behält die HealthKit-Reihenfolge")
    func newestFirstOrdering() {
        let history = EcgSyncProgressFixtures.history(3)
        let tie = EcgSourceRecording(
            id: "tie",
            recordedAt: history[2].recordedAt,
            samplingFrequency: 512,
            averageHeartRate: nil,
            classification: nil,
            lead: "I",
            sampleCount: 3
        )
        let ordered = EcgSyncCoordinator.newestFirst(history + [tie])
        #expect(ordered.map(\.id) == ["ecg-002", "tie", "ecg-001", "ecg-000"])
    }

    // MARK: - Pacer

    @Test("Ohne genannte Wartezeit verdoppelt sich der Rückzug, gedeckelt; eine Zustellung setzt ihn zurück")
    func pacerFallbackAndCeilings() {
        var pacer = EcgRateLimitPacer()
        let now = EcgSyncProgressFixtures.base
        pacer.recordRateLimit(retryAfter: nil, now: now)
        #expect(pacer.remainingHold(now: now) == 30)
        pacer.recordRateLimit(retryAfter: nil, now: now)
        #expect(pacer.remainingHold(now: now) == 60)
        pacer.recordRateLimit(retryAfter: 0, now: now)
        #expect(pacer.remainingHold(now: now) == 1, "never below a second")
        pacer.recordRateLimit(retryAfter: 86400, now: now)
        #expect(pacer.remainingHold(now: now) == EcgRateLimitPacer.holdCeiling)
        pacer.recordDelivery()
        #expect(pacer.remainingHold(now: now) == nil)
        #expect(pacer.consecutive == 0)
    }
}
