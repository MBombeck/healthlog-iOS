import Foundation
@testable import HealthLog
import SwiftData
import Testing

// W-PERF-SWR — locks the behaviour-preserving speedups from the perf audit:
//  1. SWR write-through returns `fresh` WITHOUT awaiting the SwiftData persist;
//     the detached write still lands so a later cold read sees the value.
//  2. `ModuleGate.dashboardDisabledMetricKinds()` memoizes on `modules` —
//     identical output, recomputes only on a map change.
//  3. The hoisted shared `RelativeDateTimeFormatter` produces identical strings.
//  4. The meds foreground-revalidation throttle coalesces a rapid flap.

// MARK: - 1. SWR non-blocking write-through (C2)

@Suite("W-PERF-SWR — non-blocking SWR write-through (C2)")
struct WPerfSWRWriteTests {
    private struct Payload: Codable, Equatable {
        let id: String
        let value: Int
    }

    private final class StubReach: ReachabilityProviding, @unchecked Sendable {
        let online: Bool
        init(online: Bool) {
            self.online = online
        }

        var isOnlineStream: AsyncStream<Bool> {
            get async { AsyncStream { c in c.yield(online)
                c.finish()
            } }
        }

        func isCurrentlyOnline() async -> Bool {
            online
        }
    }

    /// The observe ladder still emits `cached → fresh` exactly as before — the
    /// fresh value reaches the store on the SAME pass, not gated behind the
    /// disk flush.
    @Test("observe still emits cached → fresh (write-through is non-blocking)")
    func observeStillEmitsFresh() async throws {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        // Pre-seed a stale row so the ladder revalidates.
        let old = Payload(id: "old", value: 1)
        try await cache.write(.healthScore, payload: JSONEncoder.hlDefault.encode(old), at: Date().addingTimeInterval(-120))
        let coordinator = SWRCoordinator(cache: cache, reachability: StubReach(online: true))

        var sequence: [String] = []
        let stream = await coordinator.observe(.healthScore, decoding: Payload.self) {
            Payload(id: "new", value: 2)
        }
        for await state in stream {
            switch state {
            case .empty: sequence.append("empty")
            case let .cached(value, _): sequence.append("cached(\(value.id))")
            case let .fresh(value): sequence.append("fresh(\(value.id))")
            case .failed: sequence.append("failed")
            }
        }
        #expect(sequence == ["cached(old)", "fresh(new)"])
    }

    /// Read-after-write: the store receives `fresh` from the single-value SWR
    /// path immediately, and the DETACHED persist still backfills the cache so a
    /// subsequent cold read sees the new value once the write drains.
    @Test("fresh returns before persist; detached write still lands for cold read")
    func freshBeforePersistThenColdReadSeesIt() async throws {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        let coordinator = SWRCoordinator(cache: cache, reachability: StubReach(online: true))

        // 1. Cold cache → fetchCachingFirst returns fresh.
        let fresh = try await coordinator.fetchCachingFirst(.healthScore, decoding: Payload.self) {
            Payload(id: "fresh", value: 9)
        }
        #expect(fresh == Payload(id: "fresh", value: 9))

        // 2. The persist is detached. Immediately after the call the row MAY not
        //    be on disk yet — but draining the detached writes makes it
        //    deterministic, and afterwards a cold cache read sees the value.
        await coordinator.drainPendingWrites()
        let coldRead: Cached<Payload>? = await cache.read(.healthScore, as: Payload.self)
        #expect(coldRead?.value == Payload(id: "fresh", value: 9))
    }

    /// A second `fetchCachingFirst` after the drain serves the now-fresh cache
    /// WITHOUT re-fetching — proving the detached write produced a real,
    /// read-after-write-correct persisted row (not just an in-memory echo).
    @Test("post-drain cache is fresh enough to short-circuit a re-fetch")
    func postDrainCacheServesWithoutRefetch() async throws {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        let coordinator = SWRCoordinator(cache: cache, reachability: StubReach(online: true))

        _ = try await coordinator.fetchCachingFirst(.healthScore, decoding: Payload.self) {
            Payload(id: "first", value: 1)
        }
        await coordinator.drainPendingWrites()

        // healthScore staleAfter = 60s; the row was just written, so it's fresh.
        // The fetch closure here would throw if it ran — it must NOT.
        let second = try await coordinator.fetchCachingFirst(.healthScore, decoding: Payload.self) {
            throw HLError.unknown("re-fetch should not run — cache is fresh")
        }
        #expect(second == Payload(id: "first", value: 1))
    }
}

// MARK: - 2. ModuleGate dashboardDisabledMetricKinds memoization

@MainActor
@Suite("W-PERF-SWR — ModuleGate.dashboardDisabledMetricKinds memoization")
struct WPerfModuleGateMemoTests {
    @Test("nil map → empty disabled set (fails open)")
    func nilMapEmpty() {
        let gate = ModuleGate(modules: nil)
        #expect(gate.dashboardDisabledMetricKinds().isEmpty)
    }

    @Test("sleep + glucose OFF → their kinds disabled; repeated calls identical")
    func disabledKindsAndStableAcrossCalls() {
        let gate = ModuleGate(modules: ["sleep": false, "glucose": false, "mood": true])
        let first = gate.dashboardDisabledMetricKinds()
        #expect(first == [.sleep, .glucose])
        // Memoized: a second call returns the identical set without recompute.
        let second = gate.dashboardDisabledMetricKinds()
        #expect(second == first)
    }

    @Test("recomputes on a modules change (cache keyed on the map)")
    func recomputesOnMapChange() {
        let gate = ModuleGate(modules: ["sleep": false])
        #expect(gate.dashboardDisabledMetricKinds() == [.sleep])
        // Flip glucose off too → the memo must invalidate and recompute.
        gate.apply(modules: ["sleep": false, "glucose": false])
        #expect(gate.dashboardDisabledMetricKinds() == [.sleep, .glucose])
        // Turn everything back on → empty again.
        gate.apply(modules: ["sleep": true, "glucose": true])
        #expect(gate.dashboardDisabledMetricKinds().isEmpty)
    }

    @Test("matches the un-memoized reference computation for any map")
    func matchesReference() {
        let map: [String: Bool] = ["sleep": false, "glucose": true]
        let gate = ModuleGate(modules: map)
        var reference: Set<MetricKind> = []
        for key in ModuleKey.allCases where !gate.isEnabled(key) {
            reference.formUnion(key.dashboardMetricKinds)
        }
        #expect(gate.dashboardDisabledMetricKinds() == reference)
    }
}

// MARK: - 3. Shared RelativeDateTimeFormatter parity

@MainActor
@Suite("W-PERF-SWR — shared archive formatter parity")
struct WPerfSharedFormatterTests {
    /// The hoisted static formatter produces the SAME string a freshly
    /// allocated, identically configured formatter would — for several offsets.
    @Test("shared formatter output == per-call formatter output")
    func sharedMatchesFreshAlloc() {
        let reference = Date(timeIntervalSinceReferenceDate: 700_000_000)
        let offsets: [TimeInterval] = [
            -60, -3600, -86400, -7 * 86400, -30 * 86400, -365 * 86400
        ]
        for offset in offsets {
            let date = reference.addingTimeInterval(offset)
            let shared = ArchivedMedicationsSection.relativeArchiveLabel(for: date, relativeTo: reference)
            // Build a one-off formatter configured exactly like the old per-row code.
            let oneOff = RelativeDateTimeFormatter()
            oneOff.unitsStyle = .full
            oneOff.locale = Locale(identifier: "de_DE")
            let expected = "Archiviert \(oneOff.localizedString(for: date, relativeTo: reference))"
            #expect(shared == expected, "offset \(offset)")
        }
    }
}

// MARK: - 4. Meds foreground-revalidation throttle

@MainActor
@Suite("W-PERF-SWR — meds foreground-revalidation throttle")
struct WPerfMedsForegroundThrottleTests {
    private final class StubAPI: APIClientProtocol, @unchecked Sendable {
        func send<T: Decodable & Sendable>(_: APIRequest<T>) async throws -> T {
            throw HLError.unknown("no network in throttle test")
        }

        func sendVoid(_: APIRequest<EmptyPayload>) async throws {
            throw HLError.unknown("no network in throttle test")
        }

        func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
            throw HLError.unknown("no network in throttle test")
        }
    }

    private func makeStore() throws -> MedicationsStore {
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: StubAPI(), outbox: outbox)
        return MedicationsStore(repo: repo)
    }

    @Test("first foreground load is always allowed")
    func firstLoadAllowed() throws {
        let store = try makeStore()
        #expect(store.shouldRunForegroundLoad(now: Date()) == true)
    }

    @Test("a flap inside the window is dropped, past the window is allowed")
    func flapCoalesces() throws {
        let store = try makeStore()
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
        store.recordForegroundLoad(at: t0)
        // Inside the throttle window → dropped.
        #expect(store.shouldRunForegroundLoad(now: t0.addingTimeInterval(1)) == false)
        #expect(store.shouldRunForegroundLoad(
            now: t0.addingTimeInterval(MedicationsStore.foregroundRevalidateThrottle - 0.01)
        ) == false)
        // At/after the window boundary → allowed.
        #expect(store.shouldRunForegroundLoad(
            now: t0.addingTimeInterval(MedicationsStore.foregroundRevalidateThrottle)
        ) == true)
        #expect(store.shouldRunForegroundLoad(
            now: t0.addingTimeInterval(MedicationsStore.foregroundRevalidateThrottle + 5)
        ) == true)
    }
}
