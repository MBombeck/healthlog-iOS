import Foundation
@testable import HealthLog
import SwiftData
import Testing

// swiftlint:disable force_unwrapping

/// v0.6.2.3 F2-CHARTLAG — pins the contract that:
///
/// 1. `MeasurementsStore.load()` routes through `SWRCoordinator.observe`
///    when a coordinator is wired, emitting the standard
///    `.empty → .cached → .fresh` ladder so first paint can serve cached
///    rows without waiting for the cold network round-trip.
/// 2. When the SWR cache is pre-seeded, `recent` populates on the
///    `.cached` arm and `isShowingStaleCache` flips true.
/// 3. Without a coordinator (legacy unit-test shape), `load()` still works
///    via the direct-fetch fallback path — preserves the back-compat
///    behaviour the existing test suite relies on.
@Suite("MeasurementsStore — SWR observe ladder (v0.6.2.3 F2-CHARTLAG)")
struct MeasurementsStoreSWRTests {
    private final class StubReach: ReachabilityProviding, @unchecked Sendable {
        let online: Bool
        init(online: Bool) {
            self.online = online
        }

        var isOnlineStream: AsyncStream<Bool> {
            get async {
                AsyncStream { c in c.yield(online)
                    c.finish()
                }
            }
        }

        func isCurrentlyOnline() async -> Bool {
            online
        }
    }

    private func sampleMeasurements(count: Int) -> [HealthLog.Measurement] {
        (0 ..< count).map { i in
            HealthLog.Measurement(
                id: "m-\(i)",
                kind: .weight,
                recordedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(i) * 60),
                value: .scalar(72.0 + Double(i) * 0.1),
                note: nil,
                source: .manual
            )
        }
    }

    @Test("load() with empty cache + SWR wired: recent populates from fresh fetch")
    @MainActor
    func swrEmptyCacheColdFetch() async throws {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        let coordinator = SWRCoordinator(cache: cache, reachability: StubReach(online: true))

        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MeasurementsRepository(api: api, outbox: outbox, swr: coordinator)
        let store = MeasurementsStore(repo: repo, swr: coordinator)

        // Stub returns one weight row via the wire DTO + envelope.
        await api.setHandler { _ in
            MeasurementListWireResponse(measurements: [
                MeasurementWireDTO(
                    id: "srv-1",
                    type: .weight,
                    value: 72.5,
                    measuredAt: Date(timeIntervalSince1970: 1_700_000_000)
                )
            ])
        }

        await store.load(limit: 400)

        #expect(store.recent.count == 1, "fresh fetch must populate recent")
        #expect(store.isShowingStaleCache == false, "cold cache → fresh emit clears stale flag")
        #expect(store.lastUpdatedAt != nil, "fresh emit stamps lastUpdatedAt")
        #expect(store.isLoading == false)
    }

    @Test("load() with pre-seeded cache: recent populates from .cached arm")
    @MainActor
    func swrPreSeededCacheServesCached() async throws {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        let seed = sampleMeasurements(count: 5)
        let payload = try JSONEncoder.hlDefault.encode(seed)
        // Pre-seed BOTH the limit=400 key (what store reads) AND mark it
        // fresh-enough so the observe ladder serves cached without
        // touching the network.
        try await cache.write(
            .measurementsRecent(limit: 400),
            payload: payload
        )

        // Offline so the observe ladder skips the revalidate step entirely
        // after the cached emit (matches the SWRCoordinator contract for
        // "cached + offline → finish without network").
        let coordinator = SWRCoordinator(cache: cache, reachability: StubReach(online: false))

        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MeasurementsRepository(api: api, outbox: outbox, swr: coordinator)
        let store = MeasurementsStore(repo: repo, swr: coordinator)

        await store.load(limit: 400)

        #expect(store.recent.count == seed.count, "cached arm populates recent immediately")
        #expect(store.isShowingStaleCache == true, ".cached arm flips the stale flag")
        #expect(store.lastUpdatedAt != nil)
        #expect(store.isLoading == false)
    }

    @Test("load() without SWR coordinator: legacy direct-fetch still works")
    @MainActor
    func legacyDirectFetchStillWorks() async throws {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MeasurementsRepository(api: api, outbox: outbox)
        // No swr: param → falls through to loadDirect()
        let store = MeasurementsStore(repo: repo)

        await api.setHandler { _ in
            MeasurementListWireResponse(measurements: [
                MeasurementWireDTO(
                    id: "srv-direct",
                    type: .weight,
                    value: 71.0,
                    measuredAt: Date(timeIntervalSince1970: 1_700_000_000)
                )
            ])
        }

        await store.load(limit: 400)

        #expect(store.recent.count == 1, "direct fetch populates recent")
        #expect(store.isShowingStaleCache == false)
        #expect(store.lastUpdatedAt != nil)
        #expect(store.isLoading == false)
    }

    @Test("clearOnLogout() resets the new stale-cache + lastUpdatedAt fields")
    @MainActor
    func clearOnLogoutResetsStateFields() async throws {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MeasurementsRepository(api: api, outbox: outbox)
        let store = MeasurementsStore(repo: repo)

        await api.setHandler { _ in
            MeasurementListWireResponse(measurements: [
                MeasurementWireDTO(
                    id: "srv-1",
                    type: .weight,
                    value: 72.5,
                    measuredAt: Date()
                )
            ])
        }
        await store.load(limit: 400)
        #expect(store.lastUpdatedAt != nil)

        store.clearOnLogout()
        #expect(store.recent.isEmpty)
        #expect(store.lastUpdatedAt == nil)
        #expect(store.isShowingStaleCache == false)
    }
}

/// Pins the bootstrap warm-up list. v0.6.2.3 F2-CHARTLAG sourced it from
/// `TrendsOverlayStore.defaultSelection`; 1.4 B4 deleted the overlay store and
/// gave the warm-up its own list, which the live Insights metric page reads.
@Suite("AppContainer.prefetchSeriesKinds — bootstrap series warm-up")
struct PrefetchSeriesKindsTests {
    @Test("the warm-up covers the three vital-sign kinds {BP, Weight, Pulse} at 30 days")
    func warmsVitalSignsAtThirtyDays() {
        #expect(Set(AppContainer.prefetchSeriesKinds) == [.bloodPressure, .weight, .pulse])
        #expect(AppContainer.prefetchSeriesKinds.count == 3)
        // The Insights metric page opens on its 30-day range (`ChartDetailStore.Range.month`).
        #expect(AppContainer.prefetchSeriesDays == 30)
    }

    @Test("every warmed kind is one the series endpoint accepts")
    func warmedKindsSupportSeries() {
        for kind in AppContainer.prefetchSeriesKinds {
            #expect(ChartDetailStore.kindSupportsSeries(kind), "warm-up kind \(kind.rawValue) must support series")
        }
    }
}
