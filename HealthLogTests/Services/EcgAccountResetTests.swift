import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **Phase 07 / plan 07-06 — the ECG teardown targets the account it captured.**
///
/// `resetAnchor()` used to pick its key from a live Keychain read at the moment
/// it ran. Every caller reaches it from inside the logout cascade, which wipes
/// the Keychain user id and dispatches the HealthKit cleanup separately — so the
/// read could land on the `_anonymous` partition (stranding the account's real
/// cursor) or, once a replacement account had signed in, on **that** account's
/// partition. Both are mutations of a partition the reset never owned.
///
/// These tests pin the replacement: the owner is captured before the first
/// suspension, in-flight owned work is cancelled and drained, and only then is
/// that exact partition cleared.
///
/// `.serialized` — the suite installs the process-global `MockURLProtocol.handler`.
@Suite("ECG teardown — captured owner, drained work, exact partition", .serialized)
struct EcgAccountResetTests {
    private static let accountA = "user-123"
    private static let accountB = "user-456"

    private func admission(keychain: InMemoryKeychain, registry: AuthenticatedSessionLeaseRegistry)
        -> HealthSyncImporterAdmission
    {
        .keychainBound(keychain: keychain, registry: registry)
    }

    // MARK: - The partition a reset clears

    @Test("logout clears the partition the sweep was admitted for, never the replacement account's")
    func resetClearsTheCapturedPartition() async throws {
        let (api, keychain) = EcgSyncTestSupport.makeClient()
        let registry = AuthenticatedSessionLeaseRegistry()
        registry.activate(ownerID: Self.accountA)
        let reply = EcgSyncTestSupport.okResponse("inserted", code: 201)
        MockURLProtocol.handler = { reply($0) }
        let defaults = EcgSyncTestSupport.isolatedDefaults()
        let source = FakeEcgSource(
            recordings: [EcgSyncTestSupport.recording(id: "a-1")],
            volts: ["a-1": [0.001]],
            nextAnchor: Data("cursor-a".utf8)
        )
        let coordinator = EcgSyncTestSupport.makeCoordinator(
            api: api,
            keychain: keychain,
            source: source,
            defaultsProvider: defaults,
            admission: admission(keychain: keychain, registry: registry)
        )

        let summary = await coordinator.sync()
        #expect(summary.inserted == 1)
        let keyA = EcgSyncTestSupport.anchorKey(for: Self.accountA)
        let keyB = EcgSyncTestSupport.anchorKey(for: Self.accountB)
        #expect(defaults().data(forKey: keyA) != nil)

        // A→B: the previous account signs out and the next one signs in, while
        // the teardown for A is still on its way to the coordinator.
        defaults().set(Data("cursor-b".utf8), forKey: keyB)
        try keychain.setString(Self.accountB, forKey: KeychainKey.userID)
        registry.activate(ownerID: Self.accountB)

        await coordinator.resetAnchor()

        #expect(defaults().data(forKey: keyA) == nil, "the admitted account's cursor was not cleared")
        #expect(defaults().data(forKey: keyB) != nil, "the replacement account's cursor was cleared")
        #expect(keyA != keyB)
    }

    @Test("a reset that runs after the keychain is already wiped still clears the captured account")
    func resetSurvivesAWipedKeychain() async throws {
        let (api, keychain) = EcgSyncTestSupport.makeClient()
        let registry = AuthenticatedSessionLeaseRegistry()
        registry.activate(ownerID: Self.accountA)
        let reply = EcgSyncTestSupport.okResponse("inserted", code: 201)
        MockURLProtocol.handler = { reply($0) }
        let defaults = EcgSyncTestSupport.isolatedDefaults()
        let source = FakeEcgSource(
            recordings: [EcgSyncTestSupport.recording(id: "a-1")],
            volts: ["a-1": [0.001]],
            nextAnchor: Data("cursor-a".utf8)
        )
        let coordinator = EcgSyncTestSupport.makeCoordinator(
            api: api,
            keychain: keychain,
            source: source,
            defaultsProvider: defaults,
            admission: admission(keychain: keychain, registry: registry)
        )
        _ = await coordinator.sync()
        let keyA = EcgSyncTestSupport.anchorKey(for: Self.accountA)
        #expect(defaults().data(forKey: keyA) != nil)

        // The 401 bridge wipes the credentials first and dispatches the HealthKit
        // cleanup afterwards. A live read here resolves to the anonymous
        // partition — which is exactly the key this reset must NOT choose.
        try keychain.remove(forKey: KeychainKey.userID)
        try keychain.remove(forKey: KeychainKey.authToken)
        registry.invalidate()

        await coordinator.resetAnchor()

        #expect(defaults().data(forKey: keyA) == nil)
    }

    // MARK: - Drain before clear

    @Test("a reset cancels and drains the sweep it owns before clearing the cursor")
    func resetDrainsOwnedWorkBeforeClearing() async throws {
        let (api, keychain) = EcgSyncTestSupport.makeClient()
        let registry = AuthenticatedSessionLeaseRegistry()
        registry.activate(ownerID: Self.accountA)
        let recorder = EcgRequestRecorder()
        let reply = EcgSyncTestSupport.okResponse("inserted", code: 201)
        MockURLProtocol.handler = { req in
            if req.targets("/api/insights/ecg") { recorder.record(req) }
            return reply(req)
        }
        let defaults = EcgSyncTestSupport.isolatedDefaults()
        let keyA = EcgSyncTestSupport.anchorKey(for: Self.accountA)
        defaults().set(Data("cursor-old".utf8), forKey: keyA)

        let barrier = EcgVoltageBarrier()
        let source = FakeEcgSource(
            recordings: [EcgSyncTestSupport.recording(id: "a-1")],
            volts: ["a-1": [0.001]],
            nextAnchor: Data("cursor-a".utf8),
            beforeVoltages: { await barrier.wait() }
        )
        let coordinator = EcgSyncTestSupport.makeCoordinator(
            api: api,
            keychain: keychain,
            source: source,
            defaultsProvider: defaults,
            admission: admission(keychain: keychain, registry: registry)
        )

        let sweep = Task { await coordinator.runOwnedSweep() }
        await barrier.waitUntilEntered()

        let teardown = Task { await coordinator.resetAnchor() }
        // Give the teardown the moment it needs to take the actor and cancel the
        // sweep, then release the suspension the sweep is parked on. A sweep that
        // was not cancelled would resume straight into the upload.
        try await Task.sleep(nanoseconds: 150_000_000)
        await barrier.release()
        await teardown.value
        let summary = await sweep.value

        #expect(recorder.isEmpty, "the cancelled sweep still reached the wire")
        #expect(summary.accepted == 0)
        #expect(summary.stoppedBecause != nil)
        #expect(defaults().data(forKey: keyA) == nil)
    }

    // MARK: - Two authorities, one account

    @Test("a sweep whose admitted account is not the one it captured runs nothing")
    func mismatchedAdmissionRefusesTheSweep() async throws {
        let (api, keychain) = EcgSyncTestSupport.makeClient()
        let registry = AuthenticatedSessionLeaseRegistry()
        registry.activate(ownerID: Self.accountB)
        let leaseForB = try HealthSyncAuthenticatedLease.admit(
            from: registry,
            ownerID: Self.accountB,
            source: .ecg,
            bearerProvider: { "bearer-b" }
        )
        let recorder = EcgRequestRecorder()
        let reply = EcgSyncTestSupport.okResponse("inserted", code: 201)
        MockURLProtocol.handler = { req in
            recorder.record(req)
            return reply(req)
        }
        let source = FakeEcgSource(
            recordings: [EcgSyncTestSupport.recording(id: "a-1")],
            volts: ["a-1": [0.001]]
        )
        // The Keychain still names account A (the bearer capture), while the
        // admitted session is already account B. Two authorities, two accounts —
        // the honest answer is to run nothing.
        let coordinator = EcgSyncTestSupport.makeCoordinator(
            api: api,
            keychain: keychain,
            source: source,
            admission: HealthSyncImporterAdmission { _ in leaseForB }
        )

        let summary = await coordinator.sync()

        #expect(summary.stoppedBecause == .unauthorized)
        #expect(summary.accepted == 0)
        #expect(recorder.isEmpty)
        #expect(source.fetchCount == 0)
    }

    @Test("an admitted sweep of the same account is unchanged")
    func admittedSweepStillUploads() async {
        let (api, keychain) = EcgSyncTestSupport.makeClient()
        let registry = AuthenticatedSessionLeaseRegistry()
        registry.activate(ownerID: Self.accountA)
        let reply = EcgSyncTestSupport.okResponse("inserted", code: 201)
        MockURLProtocol.handler = { reply($0) }
        let source = FakeEcgSource(
            recordings: [EcgSyncTestSupport.recording(id: "a-1")],
            volts: ["a-1": [0.001]]
        )
        let coordinator = EcgSyncTestSupport.makeCoordinator(
            api: api,
            keychain: keychain,
            source: source,
            admission: admission(keychain: keychain, registry: registry)
        )

        let summary = await coordinator.sync()

        #expect(summary.inserted == 1)
        #expect(summary.stoppedBecause == nil)
    }
}

// swiftlint:enable force_unwrapping
