import Foundation
import Observation

/// `@Observable` wrapper over `WorkoutsRepository`. Drives the Workouts
/// surface in the consuming screens (More → Workouts and the Insights
/// Workouts page).
///
/// **State semantics:**
///   - `workouts` — the canonical list, after server-side
///     `pickCanonicalWorkoutRows()` dedup, accumulated page by page.
///   - `meta` — the envelope of the most recent page (total / limit /
///     offset / dropped). `meta.total` is the server's count of canonical
///     rows for the active filter, not the page size.
///   - `isLoading` — true while the first page is in flight.
///   - `isLoadingMore` — true while a follow-up page is in flight.
///   - `error` — last first-page failure; survives across a successful
///     refresh-from-stale (the repo returns stale on error) so the UI
///     can surface "showing cached" + the failure both.
///   - `loadMoreError` — last follow-up-page failure. Blocks further
///     automatic page loads until `retryNextPage()` (#19).
///
/// **Paging (#19):** `load()` fetches page one and resets paging;
/// `loadNextPage()` appends `GET /api/workouts?offset=<next>` until the
/// server's `meta.total` is reached. The server dedups over the whole
/// filtered set and slices afterwards (`src/lib/workouts/list-read.ts`),
/// so `offset` counts canonical rows and pages never overlap by design;
/// every page is merged into the held rows by its window in the server
/// order (`WorkoutPageMerge`), so a row that moved between two page reads
/// is neither duplicated nor kept after it was deleted, and a background
/// revalidation never truncates a scrolled list.
@MainActor
@Observable
public final class WorkoutsStore {
    public private(set) var workouts: [WorkoutListEntryDTO] = []
    public private(set) var meta: WorkoutListResponseDTO.Meta?
    public private(set) var isLoading: Bool = false
    public private(set) var error: HLError?
    public private(set) var isLoadingMore: Bool = false
    public private(set) var loadMoreError: HLError?

    public private(set) var currentLimit: Int = 50
    /// Offset of the next page to request (canonical rows received so far).
    public private(set) var currentOffset: Int = 0
    public private(set) var currentSportType: String?

    /// Set when the server answered a follow-up page with no rows although
    /// `meta.total` promised more (the total shrank under us). Stops paging
    /// instead of asking for the same empty slice forever.
    @ObservationIgnored private var pagingExhausted = false
    /// Bumped by every page-one load. A follow-up page that lands after a
    /// refresh or filter change belongs to the old list and is discarded.
    @ObservationIgnored private var generation = 0
    /// A follow-up page reported a different `meta.total` than the page
    /// before it: rows moved while paging.
    @ObservationIgnored private var totalDrifted = false
    /// The end-of-list check of page one ran; not repeated until the next
    /// load or revalidation, so a churning total cannot loop.
    @ObservationIgnored private var settled = false
    @ObservationIgnored private var isRevalidating = false

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

    /// Wall clock for the appear-revalidation window (injectable for tests).
    @ObservationIgnored private let now: @Sendable () -> Date

    public init(
        repo: WorkoutsRepository,
        hkDetail: HealthKitWorkoutDetailServicing? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.repo = repo
        self.hkDetail = hkDetail
        self.now = now
    }

    /// Loads the first page and resets paging. Defaults match the server's
    /// defaults (limit=50). The `sportType` filter is sticky on the store.
    public func load(limit: Int? = nil) async {
        if let limit { currentLimit = limit }
        generation += 1
        let token = generation
        isLoading = true
        isLoadingMore = false
        isRevalidating = false
        error = nil
        defer { if token == generation { isLoading = false } }
        do {
            let response = try await fetchPage(offset: 0)
            guard token == generation else { return }
            workouts = Self.uniqued(response.workouts)
            meta = response.meta
            currentOffset = response.workouts.count
            pagingExhausted = false
            totalDrifted = false
            settled = false
            loadMoreError = nil
            revalidationGate.markLoaded(now: now())
        } catch {
            guard token == generation else { return }
            self.error = Self.mapped(error)
        }
    }

    /// Pull-to-refresh: starts again from page one with the current
    /// (sticky) sport filter.
    public func refresh() async {
        await load(limit: currentLimit)
    }

    /// Changes the sticky sport filter and reloads from page one. The rows
    /// of the old filter are dropped at once so the two lists never mix.
    public func setSportType(_ sportType: String?) async {
        guard sportType != currentSportType else { return }
        currentSportType = sportType
        workouts = []
        meta = nil
        currentOffset = 0
        await load()
    }

    /// True while a page is due: rows beyond the offset, or (once) a check
    /// of page one when the drain ended out of step with `meta.total`.
    public var hasMorePages: Bool {
        guard let meta, !pagingExhausted else { return false }
        if currentOffset < meta.total { return true }
        return needsSettle(meta.total)
    }

    /// Appends the next page when one is due. Safe to call from every
    /// appear event: a page already in flight, a pending first-page load,
    /// a reached total or an unacknowledged page error all make it a no-op.
    public func loadNextPage() async {
        guard hasMorePages, let meta, !isLoading, !isLoadingMore, !isRevalidating,
              loadMoreError == nil else { return }
        let token = generation
        isLoadingMore = true
        defer { if token == generation { isLoadingMore = false } }
        do {
            if currentOffset >= meta.total {
                settled = true
                try await mergeFirstPage(token: token, bypassFreshCache: true)
            } else {
                try await fetchFollowingPages(token: token)
            }
        } catch {
            guard token == generation, !Self.isCancellation(error) else { return }
            loadMoreError = Self.mapped(error)
        }
    }

    /// The retry affordance at the end of the list after a failed page.
    public func retryNextPage() async {
        loadMoreError = nil
        await loadNextPage()
    }

    /// The end was reached but the rows and the total disagree, or the total
    /// moved while paging: a row may have been skipped or deleted behind us.
    private func needsSettle(_ total: Int) -> Bool {
        !settled && (workouts.count != total || totalDrifted)
    }

    /// Fetches the next page. While held rows lie beyond the offset (a tail
    /// marked for re-fetch after a revalidation), keeps going in the same call
    /// until the offset has passed them, so one scroll to the end re-syncs.
    private func fetchFollowingPages(token: Int) async throws {
        var rounds = 0
        repeat {
            let offset = currentOffset
            let response = try await fetchPage(offset: offset)
            guard token == generation else { return }
            if let total = meta?.total, total != response.meta.total { totalDrifted = true }
            workouts = WorkoutPageMerge.merge(workouts, page: response.workouts, offset: offset, limit: currentLimit)
            meta = response.meta
            currentOffset = offset + response.workouts.count
            if response.workouts.isEmpty { pagingExhausted = true }
            revalidationGate.markLoaded(now: now())
            rounds += 1
        } while currentOffset < workouts.count && hasMorePages && rounds < Self.maxPagesPerCall
    }

    /// Re-reads page one and merges it into the held rows (replace, insert,
    /// remove inside the page-one window); later pages stay. See
    /// `WorkoutPageMerge.offsetAfterFirstPage` for where paging continues.
    private func mergeFirstPage(token: Int, bypassFreshCache: Bool) async throws {
        let heldBefore = workouts.count
        let offsetBefore = currentOffset
        let totalBefore = meta?.total ?? 0
        let response = try await fetchPage(offset: 0, bypassFreshCache: bypassFreshCache)
        guard token == generation else { return }
        workouts = WorkoutPageMerge.merge(workouts, page: response.workouts, offset: 0, limit: currentLimit)
        meta = response.meta
        currentOffset = WorkoutPageMerge.offsetAfterFirstPage(
            heldBefore: heldBefore,
            offsetBefore: offsetBefore,
            totalBefore: totalBefore,
            heldAfter: workouts.count,
            pageCount: response.workouts.count,
            newTotal: response.meta.total
        )
        pagingExhausted = false
        totalDrifted = false
        revalidationGate.markLoaded(now: now())
    }

    private func fetchPage(offset: Int, bypassFreshCache: Bool = false) async throws -> WorkoutListResponseDTO {
        try await repo.list(
            limit: currentLimit,
            offset: offset,
            since: nil,
            until: nil,
            sportType: currentSportType,
            bypassFreshCache: bypassFreshCache
        )
    }

    private static func uniqued(_ rows: [WorkoutListEntryDTO]) -> [WorkoutListEntryDTO] {
        var seen = Set<String>()
        return rows.filter { seen.insert($0.id).inserted }
    }

    private static func mapped(_ error: Error) -> HLError {
        (error as? HLError) ?? .unknown(String(describing: error))
    }

    /// A page task torn down with its row (the footer scrolled away) is not
    /// a failure the user has to acknowledge; the next appear asks again.
    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError || Task.isCancelled { return true }
        if case .canceled = error as? HLError { return true }
        return (error as? URLError)?.code == .cancelled
    }

    /// Upper bound for one re-sync pass (200 rows per page max → 10 000 rows).
    private static let maxPagesPerCall = 50

    /// A2-M4 — appear-revalidation entry point. A cold (empty) list loads page
    /// one. Once the freshness window elapsed, page one is re-read and MERGED
    /// into the held rows (#19): the list the user scrolled through is never
    /// cut back to the first page, new or deleted workouts inside page one are
    /// applied, and a change further down marks the tail for re-fetch on the
    /// next scroll. A rapid re-appear inside the window is a no-op.
    public func revalidateIfStale() async {
        if workouts.isEmpty {
            await load()
            return
        }
        guard revalidationGate.isStale(now: now()), !isLoading, !isLoadingMore, !isRevalidating else { return }
        let token = generation
        isRevalidating = true
        defer { if token == generation { isRevalidating = false } }
        settled = false
        do {
            try await mergeFirstPage(token: token, bypassFreshCache: false)
        } catch {
            guard token == generation, !Self.isCancellation(error) else { return }
            self.error = Self.mapped(error)
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
        loadMoreError = nil
        isLoadingMore = false
        pagingExhausted = false
        totalDrifted = false
        settled = false
        isRevalidating = false
        generation += 1
        currentOffset = 0
        currentSportType = nil
        detail = nil
        detailHRSeries = nil
        detailError = nil
    }
}
