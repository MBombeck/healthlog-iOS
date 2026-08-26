import Foundation
import Observation

/// **SWR adoption (PA5 Bottleneck #2, v0.5.x):** chart-detail navigation
/// used to fire a fresh `/api/measurements/series?kind=…&days=…` GET on
/// every metric-tap with zero cache-paint capability. The
/// `.measurementSeries(kind:days:)` CacheKey already existed with
/// `staleAfter: 30`; only the wiring was missing.
///
/// The store now consults `SWRCoordinator.observe` per (kind, days)
/// tuple. Picker-changes still cancel inflight via `inflight?.cancel()`
/// so the user's latest selection wins. Downsampling stays UI-time
/// (after the cached/fresh emit) so chart-rendering never blocks on
/// re-sampling already-cached data.
///
/// Falls back to direct-fetch when `swr` is `nil` (unit tests).
@MainActor
@Observable
public final class ChartsStore {
    public private(set) var series: MeasurementSeries?
    public private(set) var isLoading: Bool = false
    public private(set) var error: HLError?
    /// Set when the visible series was served from cache (SWR `.cached`
    /// arm). Kept for parity with the other SWR-backed stores; the
    /// chart-detail surface doesn't render the badge yet.
    public private(set) var isShowingStaleCache: Bool = false

    private let repo: MeasurementsRepository
    private let swr: SWRCoordinator?
    private var inflight: Task<Void, Never>?

    public init(repo: MeasurementsRepository, swr: SWRCoordinator? = nil) {
        self.repo = repo
        self.swr = swr
    }

    public func load(kind: MetricKind, days: Int) async {
        // Cancel any pending request — neuer Picker-Wechsel hat Vorrang.
        inflight?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            await runLoad(kind: kind, days: days)
        }
        inflight = task
        await task.value
    }

    private func runLoad(kind: MetricKind, days: Int) async {
        // 14-06 — `load` cancels the previous inflight task on every picker
        // change, and the `Task.isCancelled` fence below is a bare `return`
        // sitting ahead of every arm that would lower the flag. The last load
        // before the screen goes away therefore stranded it.
        defer {
            if isLoading {
                StoreEffectDiagnostics.recordRefusal(.loadInterrupted, store: .charts)
            }
            isLoading = false
        }
        guard let swr else {
            await loadDirect(kind: kind, days: days)
            return
        }
        let repo = repo
        for await state in await swr.observe(
            .measurementSeries(kind: kind, days: days),
            decoding: MeasurementSeries.self,
            fetch: { try await repo.series(kind: kind, days: days) }
        ) {
            if Task.isCancelled { return }
            switch state {
            case .empty:
                isLoading = true
                error = nil
            case let .cached(value, _):
                await applySeries(value, days: days)
                isShowingStaleCache = true
                isLoading = false
            case let .fresh(value):
                await applySeries(value, days: days)
                isShowingStaleCache = false
                isLoading = false
                error = nil
            case let .failed(err, lastKnown):
                if let lastKnown {
                    await applySeries(lastKnown, days: days)
                    isShowingStaleCache = true
                }
                isLoading = false
                error = err
            }
        }
    }

    /// Direct-fetch path — used when no SWR coordinator is injected
    /// (unit tests). Mirrors the legacy single-emit behaviour expected by
    /// `StoreErrorSurfacingTests`.
    private func loadDirect(kind: MetricKind, days: Int) async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let result = try await repo.series(kind: kind, days: days)
            if !Task.isCancelled {
                await applySeries(result, days: days)
            }
        } catch let err as HLError {
            if !Task.isCancelled { error = err }
        } catch {
            if !Task.isCancelled { self.error = .unknown(String(describing: error)) }
        }
    }

    /// Apply the raw series payload — downsamples client-side when the
    /// range is wide enough that SwiftUI Charts would stutter (A3 §4.1,
    /// ~1.5k marks). Cached payloads always pay this cost since we cache
    /// the raw upstream shape; that's intentional because users flip
    /// `.days` more often than they revisit the same window.
    private func applySeries(_ result: MeasurementSeries, days: Int) async {
        // v0.12 W8-6 — the group-by downsample over ~1.5k points runs off the
        // main actor so it can't stutter a range flip. `SeriesDownsampler` is a
        // pure enum over value types and `MeasurementSeries`/`SeriesPoint` are
        // `Sendable`, so the inputs + result hop safely.
        let points = result.points
        let downsampled = await Task.detached(priority: .userInitiated) {
            SeriesDownsampler.downsampleIfNeeded(points, rangeDays: days)
        }.value
        series = MeasurementSeries(
            kind: result.kind,
            points: downsampled,
            stats: result.stats, // server-seitig berechnet, bleibt original
            unit: result.unit // W-B187 (#29) — preserve the server-resolved unit
        )
    }

    public func clearOnLogout() {
        series = nil
        error = nil
        isShowingStaleCache = false
    }
}
