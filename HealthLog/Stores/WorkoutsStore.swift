import Foundation
import Observation

/// `@Observable` wrapper over `WorkoutsRepository`. Drives the Workouts
/// surface in the consuming screens (chart-detail trend, future
/// dedicated workouts tab).
///
/// **State semantics:**
///   - `workouts` — the canonical list, after server-side
///     `pickCanonicalWorkoutRows()` dedup.
///   - `meta` — the page envelope (total / limit / offset / dropped).
///   - `isLoading` — true between `load()` start and the first non-nil
///     `workouts` arrival.
///   - `error` — last network failure; survives across a successful
///     refresh-from-stale (the repo returns stale on error) so the UI
///     can surface "showing cached" + the failure both.
///
/// Forward-compat: extends naturally to filters (sportType picker,
/// date-range scrub) by adding setters that drive the next `load()`.
@MainActor
@Observable
public final class WorkoutsStore {
    public private(set) var workouts: [WorkoutListEntryDTO] = []
    public private(set) var meta: WorkoutListResponseDTO.Meta?
    public private(set) var isLoading: Bool = false
    public private(set) var error: HLError?

    public private(set) var currentLimit: Int = 50
    public private(set) var currentOffset: Int = 0
    public private(set) var currentSportType: String?

    // MARK: - Detail surface (v0.5.4-SP5)

    /// Last-loaded rich detail (per workout id). Survives a refresh of
    /// the list so the detail screen can paint cache-first.
    public private(set) var detail: WorkoutListEntryDTO?
    /// HR-time-series read from HK for the currently loaded detail. nil
    /// while the fetch is in-flight or when HK didn't return anything
    /// (no auth, no samples, Withings/Manual source).
    public private(set) var detailHRSeries: [WorkoutHRSample]?
    public private(set) var detailLoading: Bool = false
    public private(set) var detailError: HLError?

    private let repo: WorkoutsRepository
    private let hkDetail: HealthKitWorkoutDetailServicing?

    /// A2-M4 — appear-revalidation freshness gate (60s TTL, matching the
    /// repo-level SWR window). Lets the list re-validate the partial-then-stale
    /// case on re-entry instead of only reloading when empty.
    @ObservationIgnored private var revalidationGate = RevalidationGate(ttl: 60)

    public init(
        repo: WorkoutsRepository,
        hkDetail: HealthKitWorkoutDetailServicing? = nil
    ) {
        self.repo = repo
        self.hkDetail = hkDetail
    }

    /// Loads the first page. Defaults match the server's defaults
    /// (limit=50, offset=0). The `sportType` filter is sticky on the store.
    public func load(limit: Int? = nil, offset: Int = 0) async {
        if let limit { currentLimit = limit }
        currentOffset = offset
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let response = try await repo.list(
                limit: currentLimit,
                offset: currentOffset,
                since: nil,
                until: nil,
                sportType: currentSportType
            )
            workouts = response.workouts
            meta = response.meta
            revalidationGate.markLoaded()
        } catch let err as HLError {
            error = err
        } catch {
            self.error = .unknown(String(describing: error))
        }
    }

    /// Refresh shortcut — re-fetches with the current filter + page.
    public func refresh() async {
        await load(limit: currentLimit, offset: currentOffset)
    }

    /// A2-M4 — appear-revalidation entry point. Reloads when the list is empty
    /// (cold) OR when the freshness window elapsed (partial-then-stale), so a
    /// re-entry after a long absence re-validates instead of showing stale rows;
    /// a rapid re-appear inside the window is a no-op.
    public func revalidateIfStale() async {
        if workouts.isEmpty || revalidationGate.isStale() {
            await load()
        }
    }

    /// v0.5.4-SP5 — loads the rich detail envelope from
    /// `GET /api/workouts/{id}` and, in parallel, fetches the HR-time-
    /// series from HealthKit when the workout's start/end window is
    /// known. Both arms are best-effort: the server detail surfaces
    /// `detailError` on failure; the HR fetch silently keeps the chart
    /// hidden when HK is unauthorised or empty.
    public func loadDetail(id: String) async {
        detailLoading = true
        detailError = nil
        defer { detailLoading = false }
        do {
            let dto = try await repo.workout(id: id)
            detail = dto
            // Resolve the HR curve by source priority (raw server samples → local
            // HK fetch → server-resolved `hrSeries`); see `resolveDetailHRSeries`.
            detailHRSeries = await resolveDetailHRSeries(dto)
        } catch let err as HLError {
            detailError = err
        } catch {
            detailError = .unknown(String(describing: error))
        }
    }

    /// Resolve the detail HR curve by source priority (7.8):
    ///   1. Server `WorkoutSamples` — the raw per-sample stream (highest
    ///      fidelity, source-agnostic).
    ///   2. Local HealthKit fetch — Apple-Watch-recorded workouts, when the
    ///      start/end window is known and HK returns a non-empty series.
    ///   3. Server-resolved `hrSeries` — the bucketed curve (stored samples or
    ///      pulse-window reconstruction). The only path that paints a curve for
    ///      provider workouts (WHOOP / Strava / Fitbit) that never landed in
    ///      HealthKit on this device.
    ///   4. nil — the view hides the chart (avg/max already live in the grid).
    private func resolveDetailHRSeries(_ dto: WorkoutListEntryDTO) async -> [WorkoutHRSample]? {
        if let serverSeries = Self.hrSeries(from: dto.samples), !serverSeries.isEmpty {
            return serverSeries
        }
        // Kick the HK fetch only when both ends of the window are known. List-only
        // rows carry only `startedAt`, so a missing `endedAt` skips HK entirely.
        if let start = dto.startedAt, let end = dto.endedAt, let hk = hkDetail {
            let series = await hk.heartRateSeries(from: start, to: end)
            if !series.isEmpty { return series }
        }
        return Self.hrSeries(from: dto.hrSeries, startedAt: dto.startedAt)
    }

    /// **W-B182** — map the server `WorkoutSamples` blob into the chart's
    /// `WorkoutHRSample` shape, keeping only entries that carry a heart-rate
    /// reading. Returns nil when no HR-bearing samples exist so the caller can
    /// fall back to the local HK fetch.
    static func hrSeries(from samples: WorkoutSamplesDTO?) -> [WorkoutHRSample]? {
        guard let samples else { return nil }
        let mapped = samples.samples.compactMap { sample -> WorkoutHRSample? in
            guard let hr = sample.hr, hr > 0 else { return nil }
            return WorkoutHRSample(timestamp: sample.t, bpm: hr)
        }
        return mapped.isEmpty ? nil : mapped
    }

    /// **7.8** — map the server-resolved, bucketed `hrSeries` into the chart's
    /// `WorkoutHRSample` shape. Each bucket's `tSec` is elapsed seconds from the
    /// workout start, so the wall-clock timestamp is `startedAt + tSec` and the
    /// plotted bpm is the bucket `mean`. Returns nil when the workout has no
    /// start (can't anchor the elapsed axis) or the series is empty.
    static func hrSeries(from series: WorkoutHrSeriesDTO?, startedAt: Date?) -> [WorkoutHRSample]? {
        guard let series, let start = startedAt else { return nil }
        let mapped = series.points.compactMap { point -> WorkoutHRSample? in
            guard point.mean > 0 else { return nil }
            return WorkoutHRSample(
                timestamp: start.addingTimeInterval(TimeInterval(point.tSec)),
                bpm: point.mean
            )
        }
        return mapped.isEmpty ? nil : mapped
    }

    public func clearOnLogout() {
        workouts = []
        meta = nil
        error = nil
        currentOffset = 0
        currentSportType = nil
        detail = nil
        detailHRSeries = nil
        detailError = nil
    }
}
