import Foundation
import Observation

@MainActor
@Observable
public final class MeasurementsStore {
    /// v0.14.8 W3 — `internal(set)` (not `private(set)`) so the focused
    /// `MeasurementsStore+BulkDelete.swift` extension can apply the optimistic
    /// multi-row removal (mirrors the `seriesBackedByKind` seam below).
    public internal(set) var recent: [Measurement] = [] {
        didSet { onRecentDidChange?(recent) }
    }

    /// **v0.15 companion-#3** — fires whenever the `recent` page changes
    /// (cache emit, fresh fetch, optimistic insert/delete, logout-clear).
    /// `AppContainer+Widgets` chains onto this to refresh the App Group
    /// latest-measurement widget snapshot from the newest reading. Plain
    /// closure (not `@Observable`) so it drives the widget side-effect without
    /// entering the view-observation graph. The writer diff-skips no-ops, so a
    /// chatty `didSet` is cheap.
    public var onRecentDidChange: (@MainActor ([Measurement]) -> Void)?
    /// **W1 Fix 2 — series-backed per-kind cache for cumulative/stats kinds.**
    /// Kinds where `MetricKind.prefersSeriesForRecent` is `true` (today
    /// `.steps`) are stored server-side as one `stats:<id>:<day>` row per day.
    /// A HK-power-user's per-sample step rows overflow the global 400-row
    /// `/api/measurements` page (`recent`), so the Trends/Charts list-row
    /// sparkline read "No data yet" even though the (series-routed) detail
    /// screen rendered fine — an operator-confirmed data-source mismatch. This
    /// cache holds the series-routed slice (same source the detail uses,
    /// `repo.recent(kind:)` → `/api/measurements/series`) so the list rows
    /// project a sparkline from the dense per-day frame. Hydrated by `load()`;
    /// read via `samples(forKind:)`. `internal(set)` (not `private(set)`) so
    /// the focused `MeasurementsStore+SeriesBacked.swift` extension can write it.
    public internal(set) var seriesBackedByKind: [MetricKind: [Measurement]] = [:]
    public private(set) var isLoading: Bool = false
    /// v0.14.8 W3 — `internal(set)` so `+BulkDelete.swift` can surface its
    /// failure through the same banner binding every other write uses.
    public internal(set) var error: HLError?
    /// v0.13.1 IC — per-kind **has-data availability**, sourced from the cheap
    /// all-time summaries slice (`repo.availableKinds()`). The Insights strip
    /// gates each metric pill on this set UNION the live `recent` snapshot —
    /// the slice catches low-frequency kinds (blood-pressure / weight) that fall
    /// out of the last-400 `recent` window on a HealthKit power-user (the
    /// operator-reported "BP/pulse missing" bug), while `recent` keeps freshly
    /// captured kinds lit instantly before the slice revalidates. Empty until
    /// `loadAvailability()` lands; empty in standalone (the repo no-ops offline
    /// and `recent` already carries the on-device union there).
    public internal(set) var availableKinds: Set<MetricKind> = []
    /// W-B187 QOL-2 — fires with `availableKinds` on availability (re)load so
    /// `AppContainer` re-indexes the kinds into CoreSpotlight (neutral title +
    /// Insights deep-link, no value).
    public var onAvailabilityDidChange: (@MainActor (Set<MetricKind>) -> Void)?
    /// Set when the visible `recent` page came from the SWR cache (the
    /// `.cached` arm of `SWRCoordinator.observe`). Mirrors the same flag
    /// on `DashboardStore` / `ChartsStore` so a future "showing cached"
    /// affordance can read a single property. Stays `false` when no SWR
    /// coordinator is wired (tests / headless contexts).
    /// `internal(set)` (audit-v0162 H-3) so the focused
    /// `MeasurementsStore+GenerationGuard.swift` extension can flip it from the
    /// generation-guarded apply helpers.
    public internal(set) var isShowingStaleCache: Bool = false
    /// Wall-clock when the visible `recent` page was last refreshed —
    /// cache write time for cached emits, network response time for
    /// fresh emits. `nil` until the first `load()` lands. `internal(set)`
    /// (audit-v0162 H-3) for the `+GenerationGuard.swift` apply helpers.
    public internal(set) var lastUpdatedAt: Date?

    /// **audit-v0162 H-3 — optimistic-mutation generation guard.** Bumped on
    /// every optimistic `recent` write; an SWR observe stream captures it at
    /// load-start and drops any payload from a superseded generation, so a fetch
    /// that began before a concurrent delete can't resurrect the removed row.
    /// Helpers: `MeasurementsStore+GenerationGuard.swift`. `@ObservationIgnored`.
    @ObservationIgnored var mutationGeneration: UInt64 = 0

    /// Session-owned work started by `load()`. These handles are retained so
    /// terminal teardown can cancel and await every measurement side effect.
    @ObservationIgnored var seriesHydrationTask: Task<Void, Never>?
    @ObservationIgnored var latestPageMirrorTask: Task<Void, Never>?
    @ObservationIgnored var historicalBackfillTask: Task<Void, Never>?
    @ObservationIgnored var historicalBackfillTaskID: UUID?

    /// W1 Fix 2 — `internal` (not `private`) so the series-backed cache
    /// hydration in `MeasurementsStore+SeriesBacked.swift` can reach the repo.
    let repo: MeasurementsRepository
    /// Internal (not private) so the `MeasurementsStore+QuickCapture.swift`
    /// extension's HK-mirror write can reach it.
    let healthKit: AnyHealthKitWriter?
    /// Optional undo affordance — set when the composition-root wires the
    /// shared `UndoCoordinator`. `nil` in tests + headless contexts so the
    /// delete-undo wiring stays inert outside the live app.
    private let undoCoordinator: UndoCoordinator?
    /// v0.5.5.6 RECONCILE-CELEBRATE — optional PR celebration channel +
    /// snapshot source. When the composition-root wires both, the
    /// capture-success path compares the freshly-saved value against the
    /// existing max-per-kind from the enriched records and fires a
    /// celebration when the new value beats the bucket leader. `nil` in
    /// tests + headless contexts so existing call-sites keep compiling
    /// without a second dependency.
    private let celebrationCoordinator: CelebrationCoordinator?
    private let personalRecordsSnapshot: (@MainActor () -> [PersonalRecord])?
    /// v0.6.2.3 F2-CHARTLAG — SWR coordinator wired by `AppContainer`.
    /// Routes `load()` through the standard `.empty → .cached → .fresh`
    /// observe ladder so the Trends/Charts list first-paint hits the
    /// cached page instantly instead of swallowing a cold network
    /// round-trip. `nil` keeps the legacy direct-fetch behaviour for
    /// unit tests that don't construct a coordinator.
    private let swr: SWRCoordinator?
    /// v0.14 RISK-1 (dedup option B) — standalone-mode predicate. When `true`,
    /// a manually-captured measurement is NOT mirror-written to HealthKit. The
    /// reason: in offline/standalone mode the row is uploaded as `MANUAL` on the
    /// later pair; if we ALSO wrote it to HK, the HK observer would re-ingest it
    /// as `APPLE_HEALTH` on pair, producing a duplicate of the same physical
    /// reading. Suppressing the mirror-write at the source keeps exactly one row
    /// (the MANUAL upload). Reads the persisted sync-mode live (the same
    /// `@Sendable` predicate the repos/gate use), so a Settings standalone↔paired
    /// flip is observed without rebuilding the store. `nil` → never standalone
    /// (tests + the paired default), so the existing mirror path is unchanged.
    /// Internal (not private) so the `MeasurementsStore+QuickCapture.swift`
    /// extension can gate the HK-mirror write in standalone mode.
    let isStandalone: (@Sendable () -> Bool)?
    /// **W-HKBACKFILL** — current keychain user-id, read fresh per call (no
    /// caching) so a logout + re-login as a different user partitions the
    /// one-shot historical-backfill run-once marker correctly. `nil` (tests +
    /// the legacy default) partitions under `_anonymous`. Internal (not private)
    /// so the `MeasurementsStore+HistoricalBackfill.swift` extension can key the
    /// per-user run-once flag.
    let userIDProvider: (@Sendable () -> String?)?
    /// **W-HKBACKFILL** — UserDefaults the historical-backfill run-once marker
    /// is persisted in. Injectable so the test suite can pin the gate against an
    /// isolated suite store. Defaults to `.standard`. Internal so the
    /// `+HistoricalBackfill.swift` extension reaches it.
    let backfillDefaults: UserDefaults
    private(set) var authenticatedSessionRegistry: AuthenticatedSessionLeaseRegistry?

    public init(
        repo: MeasurementsRepository,
        healthKit: AnyHealthKitWriter? = nil,
        undoCoordinator: UndoCoordinator? = nil,
        celebrationCoordinator: CelebrationCoordinator? = nil,
        personalRecordsSnapshot: (@MainActor () -> [PersonalRecord])? = nil,
        swr: SWRCoordinator? = nil,
        isStandalone: (@Sendable () -> Bool)? = nil,
        userIDProvider: (@Sendable () -> String?)? = nil,
        backfillDefaults: UserDefaults = .standard
    ) {
        self.repo = repo
        self.healthKit = healthKit
        self.undoCoordinator = undoCoordinator
        self.celebrationCoordinator = celebrationCoordinator
        self.personalRecordsSnapshot = personalRecordsSnapshot
        self.swr = swr
        self.isStandalone = isStandalone
        self.userIDProvider = userIDProvider
        self.backfillDefaults = backfillDefaults
    }

    func bindAuthenticatedSessionRegistry(_ registry: AuthenticatedSessionLeaseRegistry) {
        precondition(authenticatedSessionRegistry == nil, "authenticated registry already bound")
        authenticatedSessionRegistry = registry
    }

    /// Captures immutable authenticated identity before a caller's first
    /// suspension. Legacy/headless stores without a registry receive a
    /// cancellation-aware local lease so their established behavior remains
    /// unchanged; live AppContainer stores must match the active registry owner.
    /// **14-06 — the settle-and-account epilogue of an SWR load.**
    ///
    /// `.empty` raises `isLoading`, and before this both other exits — the
    /// bare-return lease fence and the stream simply ending under cancellation
    /// — left it raised for the life of the process. This lowers the FLAG and
    /// publishes nothing else, so the fence's data protection is untouched.
    ///
    /// `reachedTerminal == false` means the load published nothing at all. That
    /// is recorded rather than left silent, because a store cut off mid-load is
    /// otherwise indistinguishable from an account that genuinely has no data.
    ///
    /// Extracted rather than inlined so the covering defer costs `load` two
    /// lines instead of eight — inlining it pushed `load` over
    /// `function_body_length` and would have meant recording new lint debt for
    /// a comment.
    /// 14-06 — `captureAuthenticatedSessionLease()` returning nil was a silent
    /// `return`. Doing nothing is correct; doing it invisibly is what made a
    /// store that shows nothing undiagnosable.
    private func captureLeaseOrRecordRefusal() -> AuthenticatedSessionLease? {
        guard let lease = captureAuthenticatedSessionLease() else {
            StoreEffectDiagnostics.recordRefusal(.leaseUnavailable, store: .measurements)
            return nil
        }
        return lease
    }

    /// 14-06 — the per-emission fence, with the refusal made countable. Returns
    /// `false` when this emission belongs to an account that is no longer here.
    private func admitsPublication(_ lease: AuthenticatedSessionLease) -> Bool {
        guard authenticatedEffectIsCurrent(lease) else {
            StoreEffectDiagnostics.recordRefusal(.leaseRetired, store: .measurements)
            return false
        }
        return true
    }

    /// **14-06 — the settle-and-account epilogue of the SWR load.**
    ///
    /// `.empty` raises `isLoading`, and before this both other exits — the
    /// bare-return lease fence and the stream ending under cancellation — left
    /// it raised for the life of the process. This lowers the FLAG and
    /// publishes nothing else, so the fence's data protection is untouched.
    ///
    /// A flag still raised on entry means the load published nothing at all and
    /// left the surface waiting for a result that never came. Recorded rather
    /// than left silent: a store cut off mid-load is otherwise indistinguishable
    /// from an account that genuinely has no data.
    ///
    /// Extracted rather than inlined so the covering defer costs `load` one line
    /// instead of six — inlining it pushed `load` over `function_body_length`,
    /// and recording new lint debt to carry a comment is not a trade worth
    /// making.
    /// Guarded on `ownsRegistryGeneration`, not `isCurrent` — see
    /// ``MedicationsStore/load(force:)``. Cancellation must still settle the
    /// flag; a superseded account must publish nothing, "not loading" included.
    private func settleLoad(_ lease: AuthenticatedSessionLease) {
        guard lease.ownsRegistryGeneration else { return }
        if isLoading {
            StoreEffectDiagnostics.recordRefusal(.loadInterrupted, store: .measurements)
        }
        isLoading = false
    }

    func captureAuthenticatedSessionLease() -> AuthenticatedSessionLease? {
        let ownerID = userIDProvider?()?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let authenticatedSessionRegistry {
            guard let ownerID, !ownerID.isEmpty else { return nil }
            return authenticatedSessionRegistry.capture(ownerID: ownerID)
        }
        return AuthenticatedSessionLease(
            ownerID: ownerID.flatMap { $0.isEmpty ? nil : $0 } ?? "_anonymous",
            generation: 0,
            current: { true }
        )
    }

    func authenticatedEffectIsCurrent(_ lease: AuthenticatedSessionLease?) -> Bool {
        lease?.isCurrent == true
    }

    /// Loads the recent measurements page. `limit` defaults to **400** so
    /// downstream consumers that filter by kind (OnDeviceBriefingHero,
    /// TrendObservationCard, LocalDoctorReportStore) get roughly a week of
    /// coverage even for HK-heavy users where Steps + Pulse-every-few-
    /// seconds dominate the page. The 50-row default that the repo carries
    /// is fine for "Recent Measurements" list UIs but starves the briefing
    /// + trend-observation surfaces of input data.
    ///
    /// DASHBOARD-BUG-FIX-2 (2026-05-16): the operator reported the daily
    /// briefing on Insights/Dashboard rendering "keine Messungen /
    /// HealthScore: keine Daten" because nobody called `load()` and even
    /// when called the 50-row default was too narrow. Both gaps closed
    /// here + at the InsightsScreen/DashboardScreen task sites.
    /// - Parameter force: when `true`, bypasses the `measurementsRecent` TTL
    ///   so an explicit pull-to-refresh always revalidates against the network
    ///   (W8-B1). Default `false` lets a warm tab-switch / foreground bounce
    ///   inside the TTL window paint from cache without a round-trip.
    public func load(limit: Int = 400, force: Bool = false) async {
        guard let lease = captureLeaseOrRecordRefusal() else { return }
        defer { settleLoad(lease) }
        // W1 Fix 2 — hydrate the series-backed per-kind cache for cumulative/
        // stats kinds concurrently with the global recent page. The global
        // page can carry zero rows for these kinds (steps overflow it), so the
        // list-row sparkline must read the series-routed slice instead. Kicked
        // off the critical path so it doesn't gate the recent-page paint; it
        // writes `seriesBackedByKind` on the main actor when it lands. `weak
        // self` keeps a mid-flight hydration from retaining a torn-down store.
        if let previousHydration = seriesHydrationTask {
            previousHydration.cancel()
            await previousHydration.value
            guard authenticatedEffectIsCurrent(lease) else { return }
        }
        let hydrationTask = Task { [weak self] in
            guard let self else { return }
            await hydrateSeriesBackedKinds(lease: lease)
        }
        seriesHydrationTask = hydrationTask
        // v0.6.2.3 F2-CHARTLAG — SWR-aware path. Same `.empty → .cached →
        // .fresh` ladder `DashboardStore` / `ChartsStore` use so the
        // Trends/Charts tab + Insights tab paint the cached page on
        // first frame instead of waiting for the cold round-trip. The
        // repo's `recent(limit:)` already routes through the same
        // `measurementsRecent(limit:)` cache key, so the observe stream
        // sees the cached emit even before the network response.
        guard let swr else {
            await loadDirect(limit: limit, lease: lease)
            return
        }
        let repo = repo
        // audit-v0162 H-3 — capture the mutation generation at observe-start.
        // A `.cached`/`.fresh` emission whose fetch began before a concurrent
        // optimistic delete/edit (which bumps the generation) is dropped so it
        // can't resurrect the removed row or clobber the edit.
        let loadGeneration = mutationGeneration
        for await state in await swr.observe(
            .measurementsRecent(limit: limit),
            decoding: [Measurement].self,
            forceRevalidate: force,
            fetch: { try await repo.recent(limit: limit) }
        ) {
            guard admitsPublication(lease) else { return }
            switch state {
            case .empty:
                // Cold cache — keep the existing skeleton up; `isLoading`
                // drives the spinner. We deliberately don't clear `recent`
                // here so a previous logout-cleared state stays intact
                // until the network response lands.
                isLoading = true
                error = nil
            case let .cached(value, _):
                // First paint from cache — no spinner flicker on tab
                // switches or pop/re-mount cycles. H-3 generation-guarded.
                applyCachedRecent(value, loadGeneration: loadGeneration)
                isLoading = false
            case let .fresh(value):
                // H-3 — drop a stale fresh that a concurrent mutation superseded.
                let applied = applyFreshRecent(value, loadGeneration: loadGeneration)
                isLoading = false
                error = nil
                // W-HKMIRROR — mirror server-origin readings (web / other
                // device / import) into Apple Health so this iPhone's Health
                // app isn't missing rows the user didn't type here. Anti-dup +
                // idempotency live in the writer; suppressed in standalone (no
                // server page would mean nothing to mirror anyway, but the
                // create-time guard reasoning applies symmetrically). Detached
                // off the critical path so the HK round-trip can't gate paint.
                // Skipped when the fresh page was dropped (H-3) — mirroring a
                // superseded page would re-introduce the deleted row into HK.
                if applied, isStandalone?() != true, let healthKit {
                    let page = value
                    if let previousMirror = latestPageMirrorTask {
                        previousMirror.cancel()
                        await previousMirror.value
                        guard authenticatedEffectIsCurrent(lease) else { return }
                    }
                    latestPageMirrorTask = Task { [weak self] in
                        guard let self, authenticatedEffectIsCurrent(lease) else { return }
                        await healthKit.mirrorServerMeasurements(page)
                    }
                    // W-HKBACKFILL — one-shot historical backfill. The
                    // latest-page mirror above only ever sees this 400-row page;
                    // server-origin history older than the page (Withings /
                    // import) never reaches Apple Health without this pass. Gated
                    // by a per-user run-once marker, standalone-suppressed (same
                    // guard above), and kicked off detached at `.utility` so the
                    // full-history walk can NEVER gate first paint.
                    runHistoricalHealthKitBackfillIfNeeded(healthKit: healthKit)
                }
            case let .failed(err, lastKnown):
                // H-3 — `lastKnown` is the pre-fetch cached page; applying it
                // after a concurrent delete would resurrect the removed row.
                // Only repaint it when no optimistic mutation intervened.
                if let lastKnown, mutationGeneration == loadGeneration {
                    recent = lastKnown
                    isShowingStaleCache = true
                }
                isLoading = false
                error = err
            }
        }
    }

    /// Legacy direct-fetch path. Used when no SWR coordinator is injected
    /// (unit tests). Keeps the original single-emit semantics so existing
    /// test expectations against `recent` after `load()` still hold.
    private func loadDirect(limit: Int, lease: AuthenticatedSessionLease) async {
        isLoading = true
        error = nil
        do {
            let value = try await repo.recent(limit: limit)
            guard authenticatedEffectIsCurrent(lease) else { return }
            recent = value
            lastUpdatedAt = Date()
            isShowingStaleCache = false
        } catch let err as HLError {
            guard authenticatedEffectIsCurrent(lease) else { return }
            error = err
        } catch {
            guard authenticatedEffectIsCurrent(lease) else { return }
            self.error = .unknown(String(describing: error))
        }
        guard authenticatedEffectIsCurrent(lease) else { return }
        isLoading = false
    }

    public func clearOnLogout() {
        recent = []
        seriesBackedByKind = [:]
        availableKinds = []
        isLoading = false
        error = nil
        isShowingStaleCache = false
        lastUpdatedAt = nil
    }

    /// Optimistic delete — drops the row immediately, restores it on
    /// network failure. Server returns 204 on success.
    ///
    /// **Undo (v0.5.5.1):** if an `UndoCoordinator` was injected, the
    /// optimistic remove is paired with an undo affordance enqueued BEFORE
    /// the network call. Tapping `Rückgängig` re-inserts the snapshot row
    /// locally and re-posts it via the standard create path — the server
    /// allocates a fresh id and the original id is lost (documented
    /// trade-off, see W-IMPL-UNDO brief). On a non-retriable failure we
    /// roll back the optimistic remove AND dismiss the toast (the row
    /// still lives on the server, so the undo affordance would do harm).
    public func delete(_ measurement: Measurement) async -> Bool {
        guard let lease = captureAuthenticatedSessionLease() else { return false }
        let snapshot = recent
        let removed = measurement
        // audit-v0162 H-3 — bump BEFORE the optimistic removal so an in-flight
        // `.fresh` (fetched before this delete) is dropped instead of re-adding
        // the row. Ordering matters: bump-then-mutate, so any observe emission
        // that lands after this point sees the advanced generation.
        bumpMutationGeneration()
        recent.removeAll { $0.id == measurement.id }
        // Queue undo BEFORE the network round-trip so a fast double-tap can
        // recover even while the DELETE is still in flight.
        undoCoordinator?.enqueue(
            message: String(localized: "undo.measurement.removed")
        ) { [weak self] in
            await self?.restoreDeletedMeasurement(removed)
        }
        do {
            try lease.requireCurrent()
            try await repo.delete(id: measurement.id)
            try lease.requireCurrent()
            return true
        } catch let err as HLError {
            guard authenticatedEffectIsCurrent(lease) else { return false }
            error = err
            // A durably-enqueued DELETE (retriable OR a transient-refresh 401
            // the repo just queued) keeps the optimistic removal — the row is
            // gone from the UI and the Outbox replays the DELETE later. Leave
            // the undo affordance live so the user can still recover. Only a
            // genuinely-dropped DELETE resurrects the row + dismisses undo.
            if !err.shouldPersistToOutbox {
                recent = snapshot
                undoCoordinator?.dismiss(reason: .cancelled)
            }
            return false
        } catch {
            guard authenticatedEffectIsCurrent(lease) else { return false }
            self.error = .unknown(String(describing: error))
            recent = snapshot
            undoCoordinator?.dismiss(reason: .cancelled)
            return false
        }
    }

    /// Re-inserts a deleted measurement at its original chronological slot
    /// and re-posts it through the standard create path. The new server
    /// row carries a fresh id; the original id is gone for good. This is
    /// the acceptable trade-off documented in the v0.5.5.1 undo brief.
    private func restoreDeletedMeasurement(_ measurement: Measurement) async {
        guard let lease = captureAuthenticatedSessionLease() else { return }
        // audit-v0162 H-3 — a re-insert is an optimistic mutation too; bump so a
        // stale `.fresh` from before the restore can't drop the row again.
        bumpMutationGeneration()
        // Local re-insert: drop the prior row if it somehow stuck around,
        // then insert in newest-first order based on recordedAt.
        recent.removeAll { $0.id == measurement.id }
        let insertIndex = recent.firstIndex { $0.recordedAt < measurement.recordedAt } ?? recent.endIndex
        recent.insert(measurement, at: insertIndex)
        // Re-post via the create path so the server gets the row back.
        // Errors land on `self.error` exactly like a fresh capture would;
        // we deliberately swallow the bool result (re-post outcome already
        // surfaced through error binding for the banner).
        _ = await capture(
            kind: measurement.kind,
            value: measurement.value,
            note: measurement.note,
            glucoseContext: measurement.glucoseContext
        )
        guard authenticatedEffectIsCurrent(lease) else { return }
        // The new row from `capture` carries a different id than the
        // restored snapshot. Drop the snapshot copy now that the real row
        // is in place so the list doesn't show a duplicate.
        recent.removeAll { $0.id == measurement.id }
    }

    /// Optimistic update — swaps the row immediately with a synthesized
    /// version, replaces with the server response on success, restores the
    /// original snapshot on failure.
    ///
    /// **BP-pair (T-1):** wenn `value` ein BP-Tupel ist, trägt der Patch
    /// beide Werte und Repo fanoutet auf sys + dia Server-Rows (sofern
    /// `measurement.bloodPressureDiastolicId` gesetzt ist).
    ///
    /// **Glucose-context (T-2):** wenn `measurement.kind == .glucose` und
    /// der Caller einen `glucoseContext` setzt, trägt er als client-side
    /// Intent durch den Patch und landet auf dem optimistic Domain-Row.
    /// Wire-Suppression: der Server kennt das Feld auf PATCH noch nicht
    /// (SB-25), daher überlebt die Intent nur via Outbox-Payload — der
    /// Server-Returned Row trägt weiterhin den ursprünglich gespeicherten
    /// Context. Bei nil bleibt der Server-Wert unverändert auf dem
    /// optimistic Row.
    public func update(
        _ measurement: Measurement,
        value: MeasurementValue,
        recordedAt: Date,
        note: String?,
        glucoseContext: GlucoseContext? = nil
    ) async -> Bool {
        guard let lease = captureAuthenticatedSessionLease() else { return false }
        let snapshot = recent
        // For glucose rows: optimistic row reflects the user's new context
        // if they changed it; otherwise carry the existing context forward.
        let effectiveContext: GlucoseContext? = measurement.kind == .glucose
            ? (glucoseContext ?? measurement.glucoseContext)
            : nil
        let optimistic = Measurement(
            id: measurement.id,
            kind: measurement.kind,
            recordedAt: recordedAt,
            value: value,
            note: note,
            source: measurement.source,
            externalUUID: measurement.externalUUID,
            bloodPressureDiastolicId: measurement.bloodPressureDiastolicId,
            glucoseContext: effectiveContext
        )
        // audit-v0162 H-3 — bump so an in-flight stale `.fresh` can't clobber
        // this optimistic edit back to the server-cached (pre-edit) value.
        bumpMutationGeneration()
        if let i = recent.firstIndex(where: { $0.id == measurement.id }) {
            recent[i] = optimistic
        }
        let diastolicIntent: Double? = if case let .bloodPressure(_, d) = value { d } else { nil }
        let patch = MeasurementPatch(
            value: value.primaryComponent,
            measuredAt: recordedAt,
            notes: note,
            diastolic: diastolicIntent,
            glucoseContext: measurement.kind == .glucose ? glucoseContext : nil
        )
        do {
            try lease.requireCurrent()
            let saved = try await repo.update(
                id: measurement.id,
                patch: patch,
                kind: measurement.kind,
                diastolicId: measurement.bloodPressureDiastolicId
            )
            try lease.requireCurrent()
            if let i = recent.firstIndex(where: { $0.id == measurement.id }) {
                // A360-5 H-2 — preserve the diastolic peer id across the merge.
                // The non-fanout PUT response (or a server that doesn't echo the
                // dia row id) can return a `saved` row with a nil
                // `bloodPressureDiastolicId`, which would unlink the BP pair so a
                // SUBSEQUENT edit falls back to the systolic-only PATCH path and
                // the diastolic row drifts. Carry the original peer id forward
                // whenever the server didn't echo one. The glucose path likewise
                // re-applies its optimistic context until SB-25 lands wire-side
                // support (T-2); for non-glucose, non-BP rows both branches are
                // no-ops over `saved`.
                let mergedDiastolicId = saved.bloodPressureDiastolicId
                    ?? measurement.bloodPressureDiastolicId
                let merged = measurement.kind == .glucose
                    ? Measurement(
                        id: saved.id,
                        kind: saved.kind,
                        recordedAt: saved.recordedAt,
                        value: saved.value,
                        note: saved.note,
                        source: saved.source,
                        externalUUID: saved.externalUUID,
                        bloodPressureDiastolicId: mergedDiastolicId,
                        glucoseContext: effectiveContext
                    )
                    : Measurement(
                        id: saved.id,
                        kind: saved.kind,
                        recordedAt: saved.recordedAt,
                        value: saved.value,
                        note: saved.note,
                        source: saved.source,
                        externalUUID: saved.externalUUID,
                        bloodPressureDiastolicId: mergedDiastolicId,
                        glucoseContext: saved.glucoseContext
                    )
                recent[i] = merged
            }
            return true
        } catch let err as HLError {
            guard authenticatedEffectIsCurrent(lease) else { return false }
            error = err
            // A durably-enqueued PATCH (retriable OR a transient-refresh 401
            // the repo just queued) keeps the optimistic edit visible until
            // the Outbox replays — only a genuinely-dropped write rolls back.
            if !err.shouldPersistToOutbox {
                recent = snapshot
            }
            return false
        } catch {
            guard authenticatedEffectIsCurrent(lease) else { return false }
            self.error = .unknown(String(describing: error))
            recent = snapshot
            return false
        }
    }

    // MARK: - Personal-record detection (RECONCILE-CELEBRATE)

    /// Compares the freshly-committed measurement against the existing
    /// max-per-kind bucket leader from the wired `PersonalRecordsStore`
    /// snapshot. When the new value beats the leader (direction = MAX),
    /// publishes a synthesised `PersonalRecord` event through the
    /// `CelebrationCoordinator` so the root view can overlay the
    /// celebration burst. No-op when:
    ///   - either dependency is unwired (tests / headless),
    ///   - the measurement value is a BP-tuple (BP records use their own
    ///     two-row detection path the server worker owns; iOS does NOT
    ///     synthesize BP records client-side today),
    ///   - the metric kind cannot be mapped to a server `metricType`
    ///     bucket the records list uses,
    ///   - no prior record for the kind exists (avoids celebrating the
    ///     very first sample on a fresh account — would fire on every
    ///     new metric the user touches).
    func detectAndPublishPersonalRecord(for measurement: Measurement) {
        guard let coordinator = celebrationCoordinator,
              let snapshotSource = personalRecordsSnapshot,
              case let .scalar(newValue) = measurement.value else { return }
        let snapshot = snapshotSource()
        guard let event = Self.makeCelebrationEvent(
            for: measurement,
            value: newValue,
            snapshot: snapshot,
            now: Date()
        ) else { return }
        coordinator.celebrate(event)
    }

    /// Pure helper — synthesises a celebration `PersonalRecord` from the
    /// just-committed measurement IF it beats the prior bucket leader.
    /// Returns `nil` when no celebration is warranted (no prior record,
    /// new value below leader, unknown kind). Pure so tests can pin the
    /// detection contract without spinning up the coordinator.
    nonisolated static func makeCelebrationEvent(
        for measurement: Measurement,
        value: Double,
        snapshot: [PersonalRecord],
        now: Date
    ) -> PersonalRecord? {
        guard let metricType = personalRecordMetricType(for: measurement.kind) else {
            return nil
        }
        // Find the prior bucket leader for this metric type (max value
        // among existing PR rows). When none exists we deliberately do
        // NOT celebrate — the first capture on a fresh account would
        // otherwise burst-confetti on every brand-new metric the user
        // tries, which dilutes the moment.
        let priorRecords = snapshot.filter { $0.base.metricType.uppercased() == metricType }
        guard let priorLeader = priorRecords.max(by: { $0.base.value < $1.base.value }) else {
            return nil
        }
        // Strictly greater — equal values are not new records (defends
        // against floating-point ties + duplicate commits).
        guard value > priorLeader.base.value else { return nil }
        // Synthesize a client-side DTO + enriched record. The id is
        // measurement-scoped so back-to-back commits at the same value
        // produce distinct slots (replace semantics already covered by
        // the coordinator). `source` = "HEALTHLOG_CLIENT" matches the
        // derived-records source label used elsewhere; the server
        // worker will overwrite once the canonical row is emitted.
        let dto = PersonalRecordDTO(
            id: "celebrate.\(measurement.id)",
            userId: priorLeader.base.userId,
            metricType: metricType,
            metricSlot: nil,
            direction: .max,
            value: value,
            unit: priorLeader.base.unit,
            achievedAt: measurement.recordedAt,
            sourceMeasurementId: measurement.id,
            source: "HEALTHLOG_CLIENT",
            externalId: nil,
            createdAt: now
        )
        let bucket = TimeBucket.classify(achievedAt: measurement.recordedAt, now: now)
        return PersonalRecord(
            id: dto.id,
            base: dto,
            kind: measurement.kind,
            sparklineValues: priorLeader.sparklineValues,
            peakIndex: priorLeader.peakIndex,
            previousValue: priorLeader.base.value,
            bucket: bucket,
            impressiveness: PersonalRecordsStore.impressivenessScore(
                record: dto,
                bucket: bucket,
                now: now
            )
        )
    }

    /// Maps an iOS `MetricKind` to the canonical server `metricType`
    /// string used by `PersonalRecordDTO.metricType`. Mirrors the
    /// reverse direction of `MetricTypeKindResolver`. Returns `nil` for
    /// kinds that don't have a stable server metric-type bucket yet
    /// (the iOS-local walking/BMI cluster) so the celebration stays
    /// silent rather than guessing.
    ///
    /// **Why a dictionary, not a switch:** swiftlint's
    /// `cyclomatic_complexity` rule trips on the 17-case mapping that a
    /// switch would produce. The dictionary keeps the lookup O(1), the
    /// mapping declarative + single-source, and stays well below the
    /// complexity cap. Unmapped kinds fall through to `nil` exactly
    /// like the original switch's `default` arm.
    nonisolated static func personalRecordMetricType(for kind: MetricKind) -> String? {
        celebrationMetricTypeByKind[kind]
    }

    /// Static metric-type bucket map for `personalRecordMetricType(for:)`.
    /// Single source of truth for the iOS-kind → wire-string mapping the
    /// celebration detector uses. Kinds that don't have a stable server
    /// metric-type bucket today are deliberately absent so `nil` falls
    /// through (BP uses two-row server detection; walking / BMI / body-
    /// water / bone-mass don't have server enums yet).
    private nonisolated static let celebrationMetricTypeByKind: [MetricKind: String] = [
        .weight: "WEIGHT",
        .bodyFat: "BODY_FAT",
        .pulse: "PULSE",
        .restingHeartRate: "RESTING_HEART_RATE",
        .hrv: "HEART_RATE_VARIABILITY",
        .vo2Max: "VO2_MAX",
        .spo2: "OXYGEN_SATURATION",
        .bodyTemperature: "BODY_TEMPERATURE",
        .steps: "ACTIVITY_STEPS",
        .sleep: "SLEEP_DURATION",
        .glucose: "BLOOD_GLUCOSE"
    ]
}
