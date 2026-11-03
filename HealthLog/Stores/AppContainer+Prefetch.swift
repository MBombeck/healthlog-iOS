import Foundation

public extension AppContainer {
    /// W3 (v0.11 #22) — builds the per-metric assessment repo (Berlin-day daily
    /// SWR cache) together with the daily Insights cache-warmer. Kept out of
    /// `AppContainer.init` so the composition-root file stays under its
    /// `file_length` budget.
    ///
    /// The warmer's `shouldWarm` gate is evaluated on the MainActor (it reads
    /// `BackendAvailability`): the warm fires only when the Insights surface
    /// exists (`canShowCloudInsights`) AND a request would plausibly land
    /// (`isReachable`), so standalone / backend-down / offline never fire a
    /// doomed fetch. `availability` is held weakly so the closure never extends
    /// the composition root's lifetime.
    @MainActor
    static func makeMetricInsights(
        apiClient: APIClient,
        consentGate: @escaping @Sendable () async -> Bool,
        swr: SWRCoordinator,
        targetsRepo: InsightsTargetsRepository,
        insightsRepo: InsightsRepository,
        availability: BackendAvailability,
        aiCapabilities: any AICapabilityReading
    ) -> (MetricInsightsRepository, InsightsPrefetchService) {
        let metricInsightsRepo = MetricInsightsRepository(
            api: apiClient, consentGate: consentGate, swr: swr, aiCapabilities: aiCapabilities // #115 0.2
        )
        let prefetch = InsightsPrefetchService(
            metricInsightsRepo: metricInsightsRepo,
            targetsRepo: targetsRepo,
            insightsRepo: insightsRepo,
            shouldWarm: { [weak availability] in
                await MainActor.run {
                    guard let availability else { return false }
                    return availability.canShowCloudInsights && availability.isReachable
                }
            }
        )
        return (metricInsightsRepo, prefetch)
    }

    /// The series kinds `prefetchTopMetricsSeries()` warms. 1.4 B4 — the list
    /// used to be read from the Trends overlay's default selection; the overlay
    /// and its store are gone, but the Insights metric page still reads these
    /// 30-day series rows (`DashboardScreen` pre-warms the same key per tap),
    /// so the warm-up keeps its own list. `nonisolated` so tests read it off
    /// the main actor.
    nonisolated static let prefetchSeriesKinds: [MetricKind] = [.bloodPressure, .weight, .pulse]

    /// The series window the warm-up requests, in days — the 30-day window the
    /// Insights metric page and the per-tap pre-warm read.
    nonisolated static let prefetchSeriesDays = 30

    /// Concurrency cap for the prefetch fan-out. Mirrors the bounded
    /// `withTaskGroup` window FW1-B added to the compliance fan-out
    /// (`MedicationsStore.complianceFanoutConcurrency`): the series list is
    /// only three kinds today, but capping here means a future widening of
    /// `prefetchSeriesKinds` can never open an unbounded number of warm-up
    /// sockets at once.
    static let prefetchFanoutConcurrency = 4

    /// W1-3 — fire-and-forget warm-up of the SWR cache for the chart series
    /// users tap most often + the wide measurements page used for tile-state
    /// derivation. Called by `HealthLogApp` immediately after
    /// `authStore.bootstrap()` resolves. Non-blocking: bootstrap itself
    /// stays on its critical path; the prefetch task races independently
    /// and silently no-ops on auth failures / errors.
    ///
    /// By the time the user lands on the dashboard and taps a tile, the
    /// SWR cache rows for the most-tapped detail screens are warm — same
    /// latency win as W1-2's per-tap pre-warm, but covers the very first
    /// tap of the session too.
    func prefetchTopMetricsSeries() {
        let repo = measurementsRepo
        let kinds = Self.prefetchSeriesKinds
        let seriesDays = Self.prefetchSeriesDays
        let cap = Self.prefetchFanoutConcurrency
        // One closure per warm-up unit (each series kind + the wide recentAll
        // page), fed through a sliding-window task group so at most `cap` run
        // concurrently regardless of how long the kind list grows.
        var work: [@Sendable () async -> Void] = kinds.map { kind in
            { _ = try? await repo.series(kind: kind, days: seriesDays) }
        }
        work.append { _ = try? await repo.recentAll(limit: 400) }
        Task.detached(priority: .utility) {
            var iterator = work.makeIterator()
            await withTaskGroup(of: Void.self) { group in
                for _ in 0 ..< cap {
                    guard let unit = iterator.next() else { break }
                    group.addTask { await unit() }
                }
                while await group.next() != nil {
                    if let unit = iterator.next() {
                        group.addTask { await unit() }
                    }
                }
            }
        }
    }
}
