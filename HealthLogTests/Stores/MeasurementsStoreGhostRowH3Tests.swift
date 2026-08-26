import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **audit-v0162 H-3 regression coverage (ghost-row resurrection).**
///
/// Reproduces the exact interleaving the audit flagged: a screen-appear
/// `load()` paints the `.cached` page, its network revalidation is still in
/// flight, the user swipe-deletes a row, and then the stale `.fresh` (computed
/// by the server BEFORE the DELETE landed, so it still contains the row)
/// resolves and wholesale-reassigns `recent = value` — RESURRECTING the deleted
/// row while the undo toast is still up.
///
/// The test drives the REAL `SWRCoordinator.observe` ladder through a real
/// `MeasurementsRepository` + a gated `StubAPIClient`, so it fails on the
/// pre-fix code (no generation guard → M reappears) and passes once the
/// per-store mutation-generation guard drops the superseded fetch.
@Suite("MeasurementsStore — H-3 ghost-row generation guard")
struct MeasurementsStoreGhostRowH3Tests {
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

    /// Two-phase gate: the gated request signals `enter` (so the test knows the
    /// fetch is in flight), then blocks until the test calls `open`.
    private actor RaceGate {
        private var entered = false
        private var enterWaiters: [CheckedContinuation<Void, Never>] = []
        private var opened = false
        private var openWaiters: [CheckedContinuation<Void, Never>] = []

        func enterAndWaitOpen() async {
            entered = true
            for w in enterWaiters {
                w.resume()
            }
            enterWaiters.removeAll()
            if opened { return }
            await withCheckedContinuation { openWaiters.append($0) }
        }

        func waitEntered() async {
            if entered { return }
            await withCheckedContinuation { enterWaiters.append($0) }
        }

        func open() {
            opened = true
            for w in openWaiters {
                w.resume()
            }
            openWaiters.removeAll()
        }
    }

    @Test("A stale .fresh landing after an optimistic delete does NOT resurrect the deleted row")
    @MainActor
    func staleFreshDoesNotResurrectDeletedRow() async throws {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        // Seed the recent page with two rows [A, M] as a STALE row so the observe
        // ladder paints `.cached` then goes to the network revalidation (which we
        // gate). Backdated well past the 45 s TTL.
        let mA = HealthLog.Measurement(
            id: "A", kind: .weight,
            recordedAt: Date(timeIntervalSince1970: 1_700_000_100), value: .scalar(70)
        )
        let mM = HealthLog.Measurement(
            id: "M", kind: .weight,
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000), value: .scalar(72)
        )
        let payload = try JSONEncoder.hlDefault.encode([mA, mM])
        try await cache.write(.measurementsRecent(limit: 400), payload: payload, at: Date().addingTimeInterval(-120))

        let coordinator = SWRCoordinator(cache: cache, reachability: StubReach(online: true))
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MeasurementsRepository(api: api, outbox: outbox, swr: coordinator)
        let store = MeasurementsStore(repo: repo, swr: coordinator)

        let gate = RaceGate()
        // The stale fresh page the server computed BEFORE the delete: still has M.
        let stalePage = MeasurementListWireResponse(measurements: [
            MeasurementWireDTO(id: "A", type: .weight, value: 70, measuredAt: mA.recordedAt),
            MeasurementWireDTO(id: "M", type: .weight, value: 72, measuredAt: mM.recordedAt)
        ])
        await api.setHandler { anyReq in
            if let getReq = anyReq as? APIRequest<MeasurementListWireResponse> {
                // Gate only the global recent-page GET (no `type` filter).
                let isRecentPage = getReq.method == .get
                    && getReq.path == "/api/measurements"
                    && !getReq.query.contains { $0.0 == "type" }
                if isRecentPage { await gate.enterAndWaitOpen() }
                return stalePage
            }
            if anyReq is APIRequest<EmptyResponse> {
                return EmptyResponse() // DELETE 204
            }
            throw HLError.offline // series/other GETs — swallowed by callers
        }

        let loadTask = Task { @MainActor in await store.load(limit: 400) }

        // Wait until the recent GET is in-flight AND the cached page has painted.
        await gate.waitEntered()
        var spins = 0
        while store.recent.count < 2, spins < 100_000 {
            await Task.yield()
            spins += 1
        }
        #expect(store.recent.count == 2, "the .cached arm should paint [A, M] before the delete")

        // Optimistic delete of M while the stale fresh is still gated in-flight.
        let deleted = await store.delete(mM)
        #expect(deleted, "DELETE returns 204 → success")
        #expect(store.recent.map(\.id) == ["A"], "optimistic delete removes M immediately")

        // Release the stale fresh (still contains M). The H-3 guard must drop it.
        await gate.open()
        await loadTask.value

        #expect(
            store.recent.map(\.id) == ["A"],
            "H-3: a stale .fresh whose fetch began before the delete must NOT resurrect the row"
        )
    }
}
