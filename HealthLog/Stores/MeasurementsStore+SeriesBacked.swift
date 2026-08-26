import Foundation

// MARK: - W1 Fix 2 — series-backed list-row source for cumulative/stats kinds

extension MeasurementsStore {
    func hydrateSeriesBackedKinds() async {
        guard let lease = captureAuthenticatedSessionLease() else { return }
        await hydrateSeriesBackedKinds(lease: lease)
    }

    /// Refreshes the series-backed per-kind cache for every kind whose
    /// `prefersSeriesForRecent` is `true` (today `.steps`). Routes through
    /// `repo.recent(kind:)`, which for these kinds hits
    /// `/api/measurements/series` (the SAME source the chart-detail screen
    /// uses) and synthesizes per-day `Measurement` rows — so the Trends/Charts
    /// list-row sparkline projects the dense per-day frame instead of slicing
    /// the global page (which can hold zero step rows for HK-power-users). A
    /// per-kind fetch failure is logged + skipped; it never clears an
    /// already-populated slice so a transient network blip doesn't blank a row
    /// that was rendering.
    func hydrateSeriesBackedKinds(lease: AuthenticatedSessionLease) async {
        for kind in MetricKind.allCases where kind.prefersSeriesForRecent {
            do {
                try lease.requireCurrent()
                let samples = try await repo.recent(kind: kind, limit: 400)
                try lease.requireCurrent()
                seriesBackedByKind[kind] = samples
            } catch {
                guard authenticatedEffectIsCurrent(lease) else { return }
                HLLog.api.warning(
                    "Series-backed recent fetch failed for \(kind.rawValue, privacy: .public): \(LogSanitizer.redact(String(describing: error)))"
                )
            }
        }
    }

    /// Canonical per-kind sample source for list-row projections (Trends/Charts
    /// sparkline + latest-value caption). For `prefersSeriesForRecent` kinds
    /// returns the series-routed slice (matching the chart-detail source); for
    /// every other kind returns the per-kind filter of the global `recent`
    /// page (unchanged behaviour). Returns an empty array for a series-backed
    /// kind whose cache hasn't hydrated yet — callers already render the
    /// "No data yet" affordance in that case.
    public func samples(forKind kind: MetricKind) -> [Measurement] {
        if kind.prefersSeriesForRecent {
            return seriesBackedByKind[kind] ?? []
        }
        return recent.filter { $0.kind == kind }
    }
}
