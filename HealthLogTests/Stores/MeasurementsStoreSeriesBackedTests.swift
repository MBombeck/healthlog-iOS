import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **W1 Fix 2 — series-backed list-row sparkline source.**
///
/// Steps are stored server-side as one `stats:<id>:<day>` row per day, but a
/// HK-power-user's per-sample step rows overflow the global 400-row
/// `/api/measurements` page — so the Trends/Charts list-row sparkline read
/// `MeasurementsStore.recent` and rendered "No data yet" while the
/// (series-routed) chart-detail screen worked. These tests pin that
/// `samples(forKind:)` now routes `prefersSeriesForRecent` kinds (steps)
/// through the series-backed slice (the SAME source the detail uses) while
/// every other kind keeps slicing the global page.
@Suite("MeasurementsStore — series-backed per-kind source (W1 Fix 2)")
@MainActor
struct MeasurementsStoreSeriesBackedTests {
    /// Routes by request type: the global `/api/measurements` page returns a
    /// weight-only page with ZERO steps rows (the real-world overflow case);
    /// the `/api/measurements/series` call returns a dense per-day steps frame.
    private func makeStore() async throws -> MeasurementsStore {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MeasurementsRepository(api: api, outbox: outbox)
        let store = MeasurementsStore(repo: repo)

        let stepsSeries = MeasurementSeries(
            kind: .steps,
            points: (0 ..< 5).map { i in
                SeriesPoint(
                    id: "steps-day-\(i)",
                    at: Date(timeIntervalSince1970: 1_700_000_000 + Double(i) * 86400),
                    value: 8000 + Double(i) * 500,
                    secondary: nil
                )
            },
            stats: SeriesStats(mean: 9000, min: 8000, max: 10000, stdDev: 700, count: 5)
        )

        await api.setHandler { request in
            // The series fetch (steps) is `APIRequest<MeasurementSeries>`; the
            // global recent page is `APIRequest<MeasurementListWireResponse>`.
            if request is APIRequest<MeasurementSeries> {
                return stepsSeries
            }
            // Global page: a single weight row, deliberately NO steps row —
            // mirrors the overflow case where steps fall off the 400-row page.
            return MeasurementListWireResponse(measurements: [
                MeasurementWireDTO(
                    id: "w-1",
                    type: .weight,
                    value: 72.5,
                    measuredAt: Date(timeIntervalSince1970: 1_700_000_000)
                )
            ])
        }
        return store
    }

    @Test("steps (prefersSeriesForRecent) reads the series-backed slice, not the empty global page")
    func stepsRoutesThroughSeries() async throws {
        let store = try await makeStore()
        await store.load(limit: 400)
        // The global page hydration may finish before the series-backed
        // hydration that `load()` kicks as a child task; await it explicitly
        // so the assertion sees a settled cache.
        await store.hydrateSeriesBackedKinds()

        // Global page carried zero steps rows — the OLD path would be empty.
        #expect(store.recent.contains { $0.kind == .steps } == false)

        // The new accessor returns the dense series-backed frame instead.
        let stepsSamples = store.samples(forKind: .steps)
        #expect(stepsSamples.count == 5, "steps must come from the series endpoint, not the global page")
        #expect(stepsSamples.allSatisfy { $0.kind == .steps })

        // And the projected sparkline now has enough points to render
        // (>= 2 is the MetricMiniCard "show sparkline" threshold).
        let sparkline = MetricSeriesProjection.project(stepsSamples, kind: .steps)
        #expect(sparkline.count >= 2)
    }

    @Test("non-cumulative kinds (weight) still slice the global recent page")
    func weightStillUsesGlobalPage() async throws {
        let store = try await makeStore()
        await store.load(limit: 400)
        await store.hydrateSeriesBackedKinds()

        let weightSamples = store.samples(forKind: .weight)
        #expect(weightSamples.count == 1, "weight reads the global page unchanged")
        #expect(weightSamples.first?.kind == .weight)
        // Weight must NOT have leaked into the series-backed cache.
        #expect(store.seriesBackedByKind[.weight] == nil)
    }

    @Test("clearOnLogout() also wipes the series-backed cache")
    func clearOnLogoutWipesSeriesCache() async throws {
        let store = try await makeStore()
        await store.load(limit: 400)
        await store.hydrateSeriesBackedKinds()
        #expect(store.seriesBackedByKind[.steps]?.isEmpty == false)

        store.clearOnLogout()
        #expect(store.seriesBackedByKind.isEmpty)
        #expect(store.samples(forKind: .steps).isEmpty)
    }
}
