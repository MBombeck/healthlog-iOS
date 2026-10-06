import Foundation
@testable import HealthLog
import Testing

/// **S2 (#115) — confirmed progress survives every way a sweep can end, and
/// never crosses an account.**
///
/// Abort in the background, 5xx, a 429 longer than the wake, an account switch
/// and logout. In each case nothing is lost (the anchor holds until every
/// recording of the fetch is confirmed) and nothing the server already
/// confirmed is posted again by the same account.
///
/// `.serialized` — the suite installs the process-global `MockURLProtocol.handler`.
@Suite("EcgSyncCoordinator — kein Verlust, kein Doppelversand (S2)", .serialized, .mockURLSession)
struct EcgSyncProgressLossTests {
    private static let advanced = Data("anchor-after-sweep".utf8)

    /// Recording ids posted to the ECG route, in wire order. `reset()` clears
    /// the id list between wakes; the call number `record` returns keeps
    /// counting, so a handler keyed on it fails exactly one request.
    private final class PostLog: @unchecked Sendable {
        private let lock = NSLock()
        private let recorder = EcgRequestRecorder()
        private var _ids: [String] = []
        private var total = 0

        var ids: [String] {
            lock.withLock { _ids }
        }

        func record(_ req: URLRequest) -> Int {
            recorder.record(req)
            let id = recorder.lastJSON()?["externalRecordingId"] as? String ?? "?"
            return lock.withLock {
                _ids.append(id)
                total += 1
                return total
            }
        }

        func reset() {
            lock.withLock { _ids.removeAll() }
        }
    }

    private func source(_ ids: [String]) -> FakeEcgSource {
        let recordings = ids.map { EcgSyncTestSupport.recording(id: $0) }
        return FakeEcgSource(
            recordings: recordings,
            volts: EcgSyncProgressFixtures.volts(for: recordings),
            nextAnchor: Self.advanced
        )
    }

    // MARK: - 5xx

    @Test("5xx mitten im Sweep: der nächste Wake sendet nur, was noch nicht bestätigt ist")
    func serverErrorKeepsConfirmedProgress() async {
        let (api, keychain) = EcgSyncTestSupport.makeClient()
        let log = PostLog()
        MockURLProtocol.install { req in
            let call = log.record(req)
            return call == 2 ? EcgSyncProgressFixtures.serverError(req) : EcgSyncProgressFixtures.ok(req, status: "inserted")
        }
        let defaults = EcgSyncTestSupport.isolatedDefaults()
        let coordinator = EcgSyncTestSupport.makeCoordinator(
            api: api, keychain: keychain, source: source(["a", "b", "c"]), defaultsProvider: defaults
        )

        let first = await coordinator.sync()
        #expect(first.inserted == 1)
        #expect(first.stoppedBecause == .transport)
        #expect(defaults().data(forKey: EcgSyncTestSupport.anchorKey) == nil, "nothing is lost: the anchor holds")
        #expect(defaults().stringArray(forKey: EcgSyncTestSupport.confirmedKey) == ["a"])

        log.reset()
        let second = await coordinator.sync()

        #expect(log.ids == ["b", "c"], "a is not posted again")
        #expect(second.alreadyConfirmed == 1)
        #expect(second.inserted == 2)
        #expect(defaults().data(forKey: EcgSyncTestSupport.anchorKey) == Self.advanced)
        #expect(defaults().object(forKey: EcgSyncTestSupport.confirmedKey) == nil)
    }

    // MARK: - Background expiry

    @Test("Abbruch zwischen zwei Aufnahmen (Hintergrundfenster endet): die erste bleibt bestätigt")
    func cancellationKeepsConfirmedProgress() async {
        let (api, keychain) = EcgSyncTestSupport.makeClient()
        let log = PostLog()
        MockURLProtocol.install { req in
            _ = log.record(req)
            return EcgSyncProgressFixtures.ok(req, status: "inserted")
        }
        let defaults = EcgSyncTestSupport.isolatedDefaults()
        let barrier = EcgVoltageBarrier()
        let calls = EcgCallCounter()
        let recordings = [EcgSyncTestSupport.recording(id: "a"), EcgSyncTestSupport.recording(id: "b")]
        let fake = FakeEcgSource(
            recordings: recordings,
            volts: EcgSyncProgressFixtures.volts(for: recordings),
            nextAnchor: Self.advanced,
            beforeVoltages: { if calls.next() == 2 { await barrier.wait() } }
        )
        let coordinator = EcgSyncTestSupport.makeCoordinator(
            api: api, keychain: keychain, source: fake, defaultsProvider: defaults
        )

        let run = Task { await coordinator.sync() }
        await barrier.waitUntilEntered()
        run.cancel()
        await barrier.release()
        let first = await run.value

        #expect(first.inserted == 1)
        #expect(first.stoppedBecause == .transport)
        #expect(log.ids == ["a"])
        #expect(defaults().data(forKey: EcgSyncTestSupport.anchorKey) == nil)

        log.reset()
        let second = await coordinator.sync()
        #expect(log.ids == ["b"])
        #expect(second.alreadyConfirmed == 1)
        #expect(defaults().data(forKey: EcgSyncTestSupport.anchorKey) == Self.advanced)
    }

    // MARK: - 429 longer than the wake

    @Test("429 mit einer Wartezeit über dem Wake-Budget: sofort aufhören, vor dem genannten Zeitpunkt nicht wieder anklopfen")
    func longRateLimitHoldsUntilTheNamedInstant() async {
        let (api, keychain) = EcgSyncTestSupport.makeClient()
        let clock = EcgTestClock()
        let log = PostLog()
        MockURLProtocol.install { req in
            let call = log.record(req)
            return call == 1
                ? EcgSyncProgressFixtures.rateLimited(req, retryAfter: 120, limit: 600)
                : EcgSyncProgressFixtures.ok(req, status: "inserted")
        }
        let defaults = EcgSyncTestSupport.isolatedDefaults()
        let coordinator = EcgSyncTestSupport.makeCoordinator(
            api: api, keychain: keychain, source: source(["a"]), defaultsProvider: defaults,
            clock: { clock.now }
        )
        let pauses = EcgPauseRecorder()
        let sleeper: @Sendable (TimeInterval) async throws -> Void = { seconds in
            pauses.record(seconds)
            clock.advance(by: seconds)
        }
        let sweep: @Sendable () async -> EcgSyncSummary = {
            await EcgSyncPause.$sleep.withValue(sleeper) {
                await coordinator.sync()
            }
        }

        let first = await sweep()
        #expect(first.stoppedBecause == .rateLimited)
        #expect(log.ids.count == 1)
        #expect(pauses.sleeps.isEmpty, "a 120 s wait does not fit a 60 s budget — no sleep at all")

        clock.advance(by: 10)
        let second = await sweep()
        #expect(second.stoppedBecause == .rateLimited)
        #expect(log.ids.count == 1, "the next wake does not knock before the named instant")

        clock.advance(by: 110)
        let third = await sweep()
        #expect(third.inserted == 1)
        #expect(log.ids == ["a", "a"])
        #expect(defaults().data(forKey: EcgSyncTestSupport.anchorKey) == Self.advanced)
    }

    // MARK: - Accounts

    @Test("Kontowechsel: der Fortschritt gehört dem Konto — B sendet seine eigenen, Abmelden räumt A weg")
    func progressIsPartitionedAndClearedWithTheAccount() async throws {
        let (api, keychain) = EcgSyncTestSupport.makeClient()
        let log = PostLog()
        MockURLProtocol.install { req in
            let call = log.record(req)
            return call == 2 ? EcgSyncProgressFixtures.serverError(req) : EcgSyncProgressFixtures.ok(req, status: "inserted")
        }
        let defaults = EcgSyncTestSupport.isolatedDefaults()
        let coordinator = EcgSyncTestSupport.makeCoordinator(
            api: api, keychain: keychain, source: source(["a", "b"]), defaultsProvider: defaults
        )
        let keyA = EcgSyncTestSupport.confirmedKey
        let keyB = EcgSyncCoordinator.confirmedKeyPrefix + HealthKitBackfillWindowStore.partitionToken(for: "user-456")

        _ = await coordinator.sync()
        #expect(defaults().stringArray(forKey: keyA) == ["a"])

        // Logout of A: the cursor and its progress go together.
        await coordinator.resetAnchor()
        #expect(defaults().object(forKey: keyA) == nil)
        #expect(defaults().data(forKey: EcgSyncTestSupport.anchorKey) == nil)

        // B signs in on the same device: A's confirmations never suppress B's
        // uploads, and B's progress lives under B's own key.
        try keychain.setString("user-456", forKey: KeychainKey.userID)
        try keychain.setString("bearer-b", forKey: KeychainKey.authToken)
        log.reset()
        let summaryB = await coordinator.sync()
        #expect(log.ids == ["a", "b"])
        #expect(summaryB.inserted == 2)
        #expect(defaults().object(forKey: keyA) == nil)
        #expect(defaults().object(forKey: keyB) == nil, "pruned once B's anchor moved")
    }

    @Test("Ohne Abmelden: As Bestätigungen gelten nicht für B")
    func confirmationsDoNotCrossAccounts() async throws {
        let (api, keychain) = EcgSyncTestSupport.makeClient()
        let log = PostLog()
        MockURLProtocol.install { req in
            let call = log.record(req)
            return call == 2 ? EcgSyncProgressFixtures.serverError(req) : EcgSyncProgressFixtures.ok(req, status: "inserted")
        }
        let defaults = EcgSyncTestSupport.isolatedDefaults()
        let coordinator = EcgSyncTestSupport.makeCoordinator(
            api: api, keychain: keychain, source: source(["a", "b"]), defaultsProvider: defaults
        )
        _ = await coordinator.sync()
        #expect(defaults().stringArray(forKey: EcgSyncTestSupport.confirmedKey) == ["a"])

        try keychain.setString("user-456", forKey: KeychainKey.userID)
        try keychain.setString("bearer-b", forKey: KeychainKey.authToken)
        log.reset()
        _ = await coordinator.sync()

        #expect(log.ids == ["a", "b"], "B's server has never seen a")
        #expect(defaults().stringArray(forKey: EcgSyncTestSupport.confirmedKey) == ["a"], "A's progress is untouched")
    }
}
