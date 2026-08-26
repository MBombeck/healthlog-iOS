import Foundation
import Observation

/// **SWR adoption (PA5 Bottleneck #2, v0.5.x):** the Meds tab used to fire
/// 3 fresh network requests on every mount with zero cache-paint capability
/// — skeleton+spinner until the network landed (200-600 ms cellular).
/// The CacheKeys (`.medicationsList`, `.medicationsTodayIntakes`,
/// `.medicationsCompliance(_:)`) already existed; this store now consults
/// `SWRCoordinator.observe` for each of the three surfaces in parallel,
/// mirroring `DashboardStore`'s + `InsightsStore`'s shape.
///
/// Falls back to the direct-fetch path when `swr` is `nil` (unit tests
/// construct the store without a coordinator). Preserves the single-emit
/// post-load semantics existing tests rely on.
@MainActor
@Observable
public final class MedicationsStore {
    /// Splitting note: the CRUD + intake-mark surfaces live in
    /// `MedicationsStore+CRUD.swift` / `MedicationsStore+IntakeMutations.swift`
    /// (file_length split, pure code movement). Members below that are
    /// `internal(set)` / internal instead of `private` are accessed from
    /// those sibling extension files.
    public internal(set) var medications: [Medication] = []
    /// **v0.14.8 INV-home-compliance-slot — meds-loaded signal.** `false` until
    /// the medications observe stream has emitted at least one value (cached,
    /// fresh, or failed-with-last-known) — i.e. the medication list is hydrated
    /// from cache or network. The `ComplianceReconciler` reads this to tell a
    /// genuine COLD START (meds not yet loaded → trust the server snapshot) apart
    /// from "loaded, legitimately 0 slots scheduled today" (→ prefer the empty
    /// day-anchored local view over a stale server count). Stays an empty-array
    /// `medications == []` is ambiguous (a user can genuinely have zero meds), so
    /// a dedicated flag is required.
    public private(set) var hasLoadedMedications: Bool = false
    public internal(set) var todayIntakes: [MedicationIntake] = []
    public private(set) var compliance: [ComplianceDay] = []
    /// **M2 (AUDIT-PARITY-v11612) — per-account list layout.** The saved view
    /// (cards/table) + manual medication order from `/api/medications/layout`.
    /// Defaults to the server default (cards, no manual order) until the fetch
    /// lands; `activeMedications` applies the `order` so the list matches the
    /// web/other devices. Fetched best-effort on `load()` — any failure
    /// (offline / standalone / older server) leaves the default and the list
    /// keeps the plain server order.
    public internal(set) var listLayout: MedicationListLayout = .default
    /// **v0.6.1.4 Y4.2 — per-medication card snapshots.** Server-fetched 7-/30-day
    /// compliance rates keyed by medication id, hydrated on `load()` + refreshed
    /// after each `markIntakeQuick`. `MedicationCard` reads via
    /// `cardComplianceSnapshot(for:)`, with a local-algorithm fallback. Empty on logout.
    public private(set) var complianceCardSnapshots: [String: ComplianceCardSnapshot] = [:]
    public private(set) var isLoading: Bool = false
    public internal(set) var error: HLError?
    /// Set when any of the three visible payloads was served from cache
    /// (SWR `.cached` arm). Drives the "showing cached" tile-badge on
    /// the Meds surface so the user knows revalidation is still inflight.
    public private(set) var isShowingStaleCache: Bool = false

    /// **audit-release 05 C-1 — critical-med AlarmKit scheduling failures.**
    ///
    /// Medication ids whose critical (life-safety) alarm failed to arm on the
    /// last reconcile (auth revoked mid-session, per-app alarm limit exceeded,
    /// config rejected). Previously such a failure was logged + swallowed with
    /// NO user signal — the med showed as alarm-owned while no alarm was set.
    /// `MedicationsScreen` renders a persistent warning naming these meds
    /// (``criticalAlarmFailureNames``) so a missed critical dose alarm is never
    /// invisible. Wired via `AppContainer.reconcileCriticalAlarms`'
    /// `onSchedulingFailures` callback; an empty set on a successful reconcile
    /// clears the warning. Always empty on iOS < 26 / non-AlarmKit builds.
    public private(set) var criticalAlarmFailureIDs: Set<String> = []

    /// **audit-v0162 H-3 — optimistic-mutation generation guard.** Bumped on
    /// every optimistic `todayIntakes` / `medications` write (mark / synth-mark /
    /// retro-mutate / delete-intake / undo / CRUD). The `consumeIntakes` /
    /// `consumeMeds` observe loops capture it at load-start and drop any
    /// `.cached`/`.fresh`/`.failed(lastKnown)` payload from a superseded
    /// generation — so a revalidation that began before an in-flight
    /// `markIntakeQuick` can't repaint the marked dose pending / climb the app
    /// badge back up. Guard helpers live in
    /// `MedicationsStore+GenerationGuard.swift` (the stored property must stay in
    /// the class body). `@ObservationIgnored` — control state, never rendered.
    @ObservationIgnored var mutationGeneration: UInt64 = 0

    /// Account-generation fence for every authenticated medication effect.
    /// Standalone/test stores own an anonymous registry; AppContainer replaces
    /// it with the shared authenticated registry during composition.
    @ObservationIgnored var authenticatedSessionRegistry = AuthenticatedSessionLeaseRegistry()
    @ObservationIgnored var authenticatedSessionOwnerProvider: @Sendable () -> String? = { "_anonymous" }
    @ObservationIgnored var ownsAuthenticatedSessionRegistry = true
    @ObservationIgnored var medicationsFanoutTask: Task<Void, Never>?

    /// **v0.8.2 W1b (audit B5) — in-flight mark guard.**
    ///
    /// Keyed by the intake id the operator tapped (the server `intakeId`
    /// for materialised rows, the stable `synth:<medId>|<iso>` id for
    /// placeholders). A mark inserts its key synchronously *before* the
    /// first `await`; the `defer` clears it once the network round-trip
    /// settles. Because the store is `@MainActor`, the check-then-insert
    /// is atomic — no actor reentrancy can interleave between them — so a
    /// rapid second tap on the same dose sees the key already present and
    /// short-circuits.
    ///
    /// This matters most for SYNTH placeholders: each `recordFromReminder`
    /// is a server CREATE keyed only by `(medicationId, scheduledFor)`, so
    /// two un-guarded rapid taps would create TWO intake rows for one
    /// scheduled dose (real intakes PATCH the same id and are idempotent-
    /// ish). The synth id is stable for a given scheduled slot, so both
    /// taps map to the same guard key and the second is coalesced.
    ///
    /// Views can read `isMarking(intakeId:)` to disable a row's action
    /// buttons while its mark is pending.
    private var inFlightMarkIDs: Set<String> = []

    /// Senior M3 — handle for the detached card-compliance refresh `Task` (spawned
    /// after each `markIntakeQuick`), cancelled in `clearOnLogout()` so a stale
    /// previous-user value can't flash for the next user on a shared device.
    var complianceRefreshTask: Task<Void, Never>?

    // MARK: - v0.14.2 H4 — compliance fan-out throttle + dedup

    /// Medication-ids whose card-compliance fetch is currently in flight. Keeps
    /// the bounded fan-out from re-fetching the same med concurrently (two
    /// overlapping `refreshAllCardComplianceSnapshots` runs, or a single-med
    /// refresh racing the fan-out) → at most one `GET …/compliance` per med at a
    /// time. `@MainActor`, so check-then-insert is atomic.
    var inFlightComplianceFetchIDs: Set<String> = []

    /// The active med-id set the last fan-out actually ran against, plus the
    /// instant it ran. The SWR stream emits `.cached` then `.fresh` (and
    /// re-emits identical rows on revalidate), so without a guard a single
    /// screen-open fired the full N-request fan-out 2-3×. The `.fresh` re-fire
    /// now no-ops when the med-id set is unchanged AND the prior fan-out is
    /// inside `complianceFanoutThrottle` — compliance doesn't change just
    /// because the list re-emitted identical rows.
    var lastComplianceFanoutIDs: Set<String> = []
    var lastComplianceFanoutAt: Date?

    /// **W-COMPLIANCE-INV — per-med fetch-failure marker.** A med-id lands
    /// here when its `GET …/compliance` round-trip failed (offline / 5xx) and
    /// leaves on the next success. `cardComplianceSnapshot` only runs the
    /// local-algorithm OFFLINE FALLBACK for ids in this set — before the
    /// first settle the accessor returns `nil` so the card paints a skeleton
    /// instead of a local interim value that would jump on server arrival.
    var failedComplianceFetchIDs: Set<String> = []

    /// Coalescing window for the redundant `.fresh` re-fire (M5/H4).
    static let complianceFanoutThrottle: TimeInterval = 30

    // MARK: - W-PERF-SWR (Med/High) — foreground revalidation throttle

    /// Instant the last *foreground-triggered* forced load ran. A rapid
    /// background→foreground flap (notification-center peek, control-center
    /// pull, app-switcher scrub) fires `scenePhase == .active` repeatedly; each
    /// previously ran a full `load(force: true)` = 3 SWR force-revalidate
    /// fetches + a compliance fan-out. The throttle coalesces flaps inside
    /// `foregroundRevalidateThrottle` into one round-trip. Correctness is
    /// preserved: compliance authority stays the server ledger (unchanged), and
    /// a genuine resume past the window still forces a fresh reconcile.
    private var lastForegroundLoadAt: Date?

    /// Minimum gap between foreground-triggered forced loads. Short enough that
    /// a real resume after a glance still revalidates promptly, long enough to
    /// swallow a multi-event scenePhase flap.
    static let foregroundRevalidateThrottle: TimeInterval = 3

    /// W-PERF-SWR — throttled foreground revalidation entry point for the
    /// `scenePhase == .active` hook. Runs a forced `load` at most once per
    /// `foregroundRevalidateThrottle`; intermediate flaps are dropped (the prior
    /// forced load already reconciled the canonical state). Pass `now` for tests.
    public func loadOnForeground(now: Date = .now) async {
        guard shouldRunForegroundLoad(now: now) else { return }
        lastForegroundLoadAt = now
        await load(force: true)
    }

    /// Pure throttle decision — `true` when no foreground load has run, or the
    /// last one is older than `foregroundRevalidateThrottle`. Extracted so the
    /// flap-coalescing contract is unit-testable without network plumbing.
    /// Marking `now` is the caller's responsibility (`loadOnForeground` records
    /// it only when it actually proceeds, so a dropped flap doesn't slide the
    /// window forward).
    func shouldRunForegroundLoad(now: Date) -> Bool {
        guard let last = lastForegroundLoadAt else { return true }
        return now.timeIntervalSince(last) >= Self.foregroundRevalidateThrottle
    }

    /// Test seam — record a foreground-load instant without running the load, so
    /// the throttle's window can be exercised deterministically.
    func recordForegroundLoad(at instant: Date) {
        lastForegroundLoadAt = instant
    }

    /// Max concurrent `GET …/compliance` requests in the fan-out. Caps a
    /// 20-med catalog from opening 20 sockets at once (radio-wake / battery).
    static let complianceFanoutConcurrency = 4

    let repo: MedicationsRepository
    let swr: SWRCoordinator?
    /// Optional undo affordance — wires the archive flow into the shared
    /// `Rückgängig`-pill. `nil` in headless / unit-test contexts.
    let undoCoordinator: UndoCoordinator?
    /// v0.11 W2 — live standalone-mode predicate. Default `{ false }` keeps the
    /// store on the existing server intake path (paired invariant). When the
    /// composition-root wires the standalone gate this returns the live mode, so
    /// a logged dose lands in the local mirror + reads back in the list. Full
    /// on-device compliance is the W2b follow-up; this only routes the WRITE.
    let isStandalone: @Sendable () -> Bool

    /// **v0.14 DATA — server-profile day-anchoring timezone.**
    ///
    /// `derivedTodayIntakes` builds today's `[startOfToday, endOfToday)` window
    /// and the recurrence-engine `Context` against this zone. The composition
    /// root sets it from the server profile's IANA timezone (PROJECT_GUIDE.md mandate:
    /// Berlin-day anchoring, NOT device TZ) once settings hydrate; until then it
    /// defaults to `.current` so the derive is byte-unchanged. When the device
    /// TZ ≠ server-profile TZ, anchoring on the profile zone keeps a dose due
    /// "now" inside today's window instead of sliding it out and falsely
    /// dropping it from the due surfaces.
    ///
    /// A provider closure so a later settings hydration (the SWR profile
    /// emission) is honoured without re-constructing the store. Defaults to
    /// `.current`; the composition root points it at `settingsStore.profile`.
    public var profileTimeZoneProvider: () -> TimeZone = { .current }

    /// Resolved server-profile day-anchoring zone, falling back to `.current`.
    var profileTimeZone: TimeZone {
        profileTimeZoneProvider()
    }

    /// **audit-v0162 M-7 — derived-intake synthesis gate.** `derivedTodayIntakes`
    /// synthesises client-side placeholders for schedule slots the server hasn't
    /// materialised. On a MODERN (slot-materialising) server that synthesis
    /// double-counts a slot whose server `scheduledFor` diverges >5 min from the
    /// client projection (schedule-era edit / DST / profile-TZ seam), inflating
    /// the due surfaces + app badge. When this returns `false` the derivation
    /// trusts the server rows verbatim (no synth).
    ///
    /// **Wired since audit-v0162 M-7.** `AppContainer.configureRuntimeWiring`
    /// points this at `MedicationSlotMaterializationGate.synthesisEnabled` —
    /// the persisted verdict from `GET /api/version` against
    /// ``MedicationSlotMaterialization/minimumServerVersion`` (v1.8.1) — OR'd
    /// with standalone mode, where there is no server ledger at all and the
    /// synthesis is the only source of "due today". The bare default stays
    /// `true` for stores built outside the composition root (tests, previews):
    /// synthesising is the historically-correct behaviour for a store with no
    /// server-capability knowledge attached. A provider so a later version
    /// probe is honoured without rebuilding the store.
    public var derivedIntakeSynthesisEnabledProvider: () -> Bool = { true }

    /// **v0.14.1 INV-med-cadence-phantom (BUG 2) — day-anchored today-intakes
    /// cache key.** The `.medicationsTodayIntakes` row is keyed on the current
    /// calendar day in the SAME profile timezone the medication "today" window /
    /// compliance bucket use (`profileTimeZone`), so a new calendar day is a
    /// STRUCTURAL cache miss. This prevents a prior-day optimistic `.taken`
    /// snapshot from being SWR-served (`.cached`) and rendering a phantom "taken
    /// today" across a midnight rollover. Every observe / writeThrough /
    /// invalidate of the today-intakes key inside the store routes through this
    /// single accessor so they always agree on the day discriminator.
    var todayIntakesKey: CacheKey {
        .medicationsTodayIntakes(day: MedicationDayKey.string(timeZone: profileTimeZone))
    }

    /// **v0.14.8 INV-home-compliance-slot — day-anchored dashboard-summary key.**
    /// Every intake mutation invalidates `.dashboardSummary` so the Home
    /// compliance ring re-fetches. The key is now day-anchored on the SAME
    /// profile timezone as `todayIntakesKey` (the zone `DashboardStore` observes
    /// with), so the invalidation hits the exact row the dashboard is reading.
    /// Mirrors `todayIntakesKey`.
    var dashboardSummaryKey: CacheKey {
        .dashboardSummary(day: MedicationDayKey.string(timeZone: profileTimeZone))
    }

    /// **v0.6.1.3 Y4.1 — App-Badge recompute hook.**
    ///
    /// AppContainer wires this to `NotificationService.refreshBadge(from:)`
    /// so every mark / snooze / load mutation that changes the pending
    /// dose count produces a fresh badge number. `nil` in tests + macOS
    /// builds so the store can be exercised without a UN dependency. The
    /// closure is `@MainActor` because the store is — callers don't need
    /// a hop.
    public var onIntakesDidChange: (@MainActor () -> Void)?

    /// **v0.9.0 W2 — per-med critical-alarm opt-in predicate provider.**
    ///
    /// AppContainer wires this to produce a fresh
    /// `DeliveryPreferencesStore.enabledPredicate(for: .criticalAlarm)`
    /// `@Sendable` snapshot on each reconcile, so the Spezi-scheduler pass can
    /// route alarm-owned meds onto the AlarmKit channel (coexistence =
    /// REPLACE) and exclude them from the UNNotification set. The provider is
    /// `@MainActor` (the store is) so it reads the store without an
    /// `assumeIsolated`. `nil` (→ "all off") in tests + macOS builds so the
    /// store still routes everything through the existing UN path unchanged.
    public var criticalAlarmEnabledProvider: (@MainActor () -> @Sendable (String) -> Bool)?

    /// **v0.10 W-Meds-A2 (v1.7.0 SB-LA-1 / SB-AK-1) — medications-loaded hook.**
    ///
    /// Fires on every medications mutation (alongside the scheduler reconcile)
    /// with the fresh snapshot so AppContainer can fold the per-medication
    /// `liveActivityEnabled` / `criticalAlarmEnabled` server booleans into the
    /// `DeliveryPreferencesStore` server-default cache
    /// (`ingestServerDefaults(from:)`). The gating predicates then resolve those
    /// defaults with no scheduler-side change. `nil` in tests + macOS builds.
    public var onMedicationsDidChange: (@MainActor ([Medication]) -> Void)?
    /// W-B187 QOL-2 — fires the fresh snapshot on list-settle so `AppContainer`
    /// re-indexes meds into CoreSpotlight (a slot distinct from `onMedicationsDidChange`).
    public var onMedicationsListSettled: (@MainActor ([Medication]) -> Void)?
    /// Days window passed to `repo.compliance` + matching `CacheKey`.
    /// **#13 (2026-06-11):** 182 = the 26-week MAXIMUM of the new
    /// Settings -> Erscheinungsbild window picker (4/8/12/26 weeks), so every
    /// pick renders fully populated from the one cached payload — the
    /// heatmap slices the trailing N weeks client-side, no refetch on
    /// pick-change. `nonisolated` + internal so
    /// `MutationKind.*.affectedKeys` in `CacheInvalidator` references the
    /// SAME constant instead of a drift-prone literal — the canonical value
    /// lives on `CacheKey.complianceWindowDays` (Cache layer, shared into the
    /// Intents extension, which does not compile this Stores layer); this is
    /// the store-side alias.
    nonisolated static let complianceDaysWindow = CacheKey.complianceWindowDays

    public init(
        repo: MedicationsRepository,
        swr: SWRCoordinator? = nil,
        undoCoordinator: UndoCoordinator? = nil,
        isStandalone: @escaping @Sendable () -> Bool = { false }
    ) {
        self.repo = repo
        self.swr = swr
        self.undoCoordinator = undoCoordinator
        self.isStandalone = isStandalone
        authenticatedSessionRegistry.activate(ownerID: "_anonymous")
    }

    // MARK: - v0.8.2 W1b (audit B5) — in-flight mark guard

    /// `true` while a mark for `intakeId` is awaiting its network
    /// round-trip. Views observe this (`@Observable`) to disable a row's
    /// Genommen / Übersprungen / Snooze controls so a rapid second tap
    /// can't fire a duplicate `record` / `recordFromReminder`.
    public func isMarking(intakeId: String) -> Bool {
        inFlightMarkIDs.contains(intakeId)
    }

    /// Claim the in-flight slot for `intakeId`. Returns `false` when a
    /// mark for the same id is already pending — the caller must then
    /// short-circuit (coalesce the duplicate tap). The check-and-insert
    /// runs synchronously on the MainActor, so two taps in the same run
    /// loop can never both win the claim.
    func beginMark(_ intakeId: String) -> Bool {
        inFlightMarkIDs.insert(intakeId).inserted
    }

    /// Release the in-flight slot once the network attempt has settled
    /// (success, queued, or failed — all paths must clear it).
    func endMark(_ intakeId: String) {
        inFlightMarkIDs.remove(intakeId)
    }

    /// - Parameter force: when `true`, bypasses the `medicationsList` /
    ///   `medicationsTodayIntakes` TTLs so an explicit pull-to-refresh always
    ///   revalidates (W8-B1). Default `false` lets a foreground bounce inside
    ///   the window paint from cache without redundant round-trips. The
    ///   compliance stream keeps its own 5min TTL regardless — it is not a
    ///   per-bounce hot key.
    /// - Parameter intent: **21-03 (D-14-06-C)** — who asked. `.system` (every
    ///   caller here today) keeps the single-flight collapse exactly as it was;
    ///   `.userInitiated` — which `MedicationsScreen`'s pull now passes — takes
    ///   the bounded-attach path in `SWRCoordinator.revalidateSingleFlight`
    ///   instead of inheriting an in-flight winner's whole latency.
    ///
    /// **D-14-06-B (coalescing overlapping triggers) is NOT closed here.** It
    /// was written, it worked, and it was reverted: coalescing needs a shared
    /// `Task` handle, and adding one to this file moves 11 effects from
    /// `load-1` to a helper symbol and introduces a new `owned-task` hit — drift
    /// in the FROZEN Phase-06 effect census, which a 21-xx plan may not
    /// disposition. See `.planning/phases/21-first-paint/deferred-items.md`
    /// (D-21-03-A) for the working shape and the two regressions it must keep
    /// guarding.
    public func load(force: Bool = false, intent: RefreshIntent = .system) async {
        guard let sessionLease = captureAuthenticatedSessionLease() else {
            // 14-06 — this was a silent `return`, exactly as 13-03 found in
            // `DashboardStore`. A refused lease and a finished load looked
            // identical in the field.
            StoreEffectDiagnostics.recordRefusal(.leaseUnavailable, store: .medications)
            return
        }
        // 14-06 (the operator's blank medications list) — `consumeMeds` raises
        // `isLoading` on the `.empty` emission a cold cache produces, and used
        // to have no way of lowering it again on any exit but a terminal
        // emission. Both other exits are reached constantly in production:
        //
        //  - the per-emission fence is a bare `return` sitting AHEAD of every
        //    arm that would lower the flag, and
        //  - `AuthenticatedSessionLease.isCurrent` folds in `!Task.isCancelled`,
        //    so the 250 ms foreground pass trips the fence AND ends the
        //    `for await` on the same cancellation.
        //
        // `MedicationsScreen` gates its skeleton on `isLoading &&
        // medications.isEmpty && todayIntakes.isEmpty`, so a stranded flag over
        // an empty list is a permanent skeleton — "die Medikamente werden gar
        // nicht angezeigt", exactly.
        //
        // The defer lowers the FLAG and publishes nothing else, so the fence's
        // data protection is untouched: a refused emission still publishes no
        // medications and no error. Saying "this load is no longer running" is
        // true of a refused load; saying "here is the data" would not be.
        //
        // The other half is made countable by the flag itself: if `isLoading` is
        // STILL up when this returns, then this load raised the skeleton and
        // never took it down — it published nothing at all, and the surface was
        // left waiting for a result that never came. That is the operator's
        // screen, stated as a condition. Without the line, a store cut off
        // mid-load is indistinguishable from an account with no medications.
        //
        // Declared before the first suspension point deliberately: it is the
        // placement 13-03 used, it covers the `loadDirect` arm below as well
        // (idempotently — that arm settles its own flag), and it keeps the
        // Phase-06 effect census unchanged, since the scanner attributes only
        // those effects that follow an `await`.
        //
        // Guarded on `ownsRegistryGeneration`, NOT on `isCurrent`. The two
        // differ exactly where it matters: cancellation must still settle the
        // flag (that is this whole fix), but a load whose account has been
        // superseded must publish nothing at all — including "not loading",
        // because the flag now belongs to the new owner's in-flight load.
        defer {
            if sessionLease.ownsRegistryGeneration {
                if isLoading {
                    StoreEffectDiagnostics.recordRefusal(.loadInterrupted, store: .medications)
                }
                isLoading = false
            }
        }
        guard let swr else {
            await loadDirect(sessionLease: sessionLease)
            return
        }
        let repo = repo
        // audit-v0162 H-3 — capture the mutation generation at observe-start so a
        // revalidation that began before a concurrent mark/CRUD is dropped rather
        // than repainting a marked dose pending / a deleted med back into the list.
        let loadGeneration = mutationGeneration
        async let medsStream: () = consumeMeds(
            stream: swr.observe(
                .medicationsList,
                decoding: [Medication].self,
                forceRevalidate: force,
                intent: intent,
                fetch: { try await repo.list() }
            ),
            loadGeneration: loadGeneration,
            sessionLease: sessionLease
        )
        async let intakesStream: () = consumeIntakes(
            stream: swr.observe(
                todayIntakesKey,
                decoding: [MedicationIntake].self,
                forceRevalidate: force,
                intent: intent,
                fetch: { try await repo.todayIntakes() }
            ),
            loadGeneration: loadGeneration,
            sessionLease: sessionLease
        )
        async let complianceStream: () = consumeCompliance(
            stream: swr.observe(
                .medicationsCompliance(days: Self.complianceDaysWindow),
                decoding: [ComplianceDay].self,
                fetch: { try await repo.compliance(days: Self.complianceDaysWindow) }
            ),
            sessionLease: sessionLease
        )
        async let layoutFetch: () = fetchListLayout(sessionLease: sessionLease)
        _ = await (medsStream, intakesStream, complianceStream, layoutFetch)
        guard authenticatedEffectIsCurrent(sessionLease) else {
            // 14-06 — the same silence as the lease-nil above, one emission later.
            StoreEffectDiagnostics.recordRefusal(.leaseRetired, store: .medications)
            return
        }
        // v0.6.1.4 Y4.2 — fan out per-medication server-canonical
        // snapshots once the medication list has settled. Quietly
        // drops failures (cold cache / offline) so the screen still
        // paints via the local-algorithm fallback.
        // v0.14.2 H4 — throttled so this load + the SWR `.fresh` re-emit it
        // races coalesce into ONE fan-out per screen-open (was N×2-3 GETs).
        await refreshAllCardComplianceSnapshotsThrottled(sessionLease: sessionLease)
    }

    /// Direct-fetch path — used when no SWR coordinator is injected
    /// (unit tests). Keeps the old single-emit semantics so the existing
    /// `MedicationsStore` test expectations still hold.
    private func loadDirect(sessionLease: AuthenticatedSessionLease) async {
        guard authenticatedEffectIsCurrent(sessionLease) else { return }
        isLoading = true
        error = nil
        // 14-06 — the condition used to be `authenticatedEffectIsCurrent`, which
        // folds in cancellation, so on the one exit that needed the defer it did
        // not fire. This is the `LabsStore` twin 13-03 closed, in a store 13-03
        // never touched. `ownsRegistryGeneration` fires on cancellation (which
        // is the fix) and still declines when the account has been superseded
        // (which keeps a retired generation from publishing).
        defer {
            if sessionLease.ownsRegistryGeneration { isLoading = false }
        }
        do {
            async let meds = repo.list()
            async let today = repo.todayIntakes()
            async let comp = repo.compliance(days: Self.complianceDaysWindow)
            let fetched = try await meds
            try sessionLease.requireCurrent()
            medications = preservingLocalArchivedAt(in: fetched)
            hasLoadedMedications = true
            onMedicationsListSettled?(medications)
            let fetchedToday = try await today
            try sessionLease.requireCurrent()
            todayIntakes = fetchedToday
            let fetchedCompliance = try await comp
            try sessionLease.requireCurrent()
            compliance = fetchedCompliance
            await fetchListLayout(sessionLease: sessionLease)
            try sessionLease.requireCurrent()
            reconcileSpeziSchedulerIfAvailable()
            // v0.6.1.4 Y4.2 — fan out per-medication compliance
            // snapshots after the medication list has settled. The
            // refresh tolerates failures so unit-test fixtures that
            // omit the `/api/medications/[id]/compliance` stub keep
            // the existing direct-fetch contract — the dict stays
            // empty and the card falls back to the local algorithm.
            await refreshAllCardComplianceSnapshots(sessionLease: sessionLease)
        } catch let err as HLError {
            guard authenticatedEffectIsCurrent(sessionLease) else { return }
            error = err
        } catch {
            guard authenticatedEffectIsCurrent(sessionLease) else { return }
            self.error = .unknown(String(describing: error))
        }
    }

    private func consumeMeds(
        stream: AsyncStream<SWRState<[Medication]>>,
        loadGeneration: UInt64,
        sessionLease: AuthenticatedSessionLease
    ) async {
        for await state in stream {
            guard authenticatedEffectIsCurrent(sessionLease) else {
                // 14-06 — the refusal is countable now. `load`'s defer settles
                // the flag this bare `return` used to strand.
                StoreEffectDiagnostics.recordRefusal(.leaseRetired, store: .medications)
                return
            }
            switch state {
            case .empty:
                isLoading = true
                error = nil
            case let .cached(value, _):
                // H-3 — drop a stale cache page superseded by a concurrent CRUD.
                guard mutationGeneration == loadGeneration else {
                    isLoading = false
                    continue
                }
                medications = preservingLocalArchivedAt(in: value)
                hasLoadedMedications = true
                isShowingStaleCache = true
                isLoading = false
                reconcileSpeziSchedulerIfAvailable()
                onMedicationsListSettled?(medications)
            case let .fresh(value):
                // H-3 — drop a stale fresh page superseded by a concurrent CRUD
                // (optimistic create/archive/unarchive bumps the generation).
                guard mutationGeneration == loadGeneration else {
                    isLoading = false
                    error = nil
                    continue
                }
                medications = preservingLocalArchivedAt(in: value)
                hasLoadedMedications = true
                isShowingStaleCache = false
                isLoading = false
                error = nil
                reconcileSpeziSchedulerIfAvailable()
                onMedicationsListSettled?(medications)
                // v0.6.1.4 Y4.2 — refresh per-medication snapshots in
                // the background. New medications enter the array
                // here (post-`create`, post-`unarchive`), so the
                // snapshot dict needs to catch up.
                // v0.14.2 H4 — route through the THROTTLED variant: the SWR
                // stream re-emits `.fresh` with identical rows on every
                // revalidate, and re-running the full N-request fan-out each
                // time is radio-wake waste. The throttle no-ops when the active
                // med-id set is unchanged inside the window, but still fires for
                // a genuinely new/removed med (set change).
                medicationsFanoutTask?.cancel()
                medicationsFanoutTask = _Concurrency.Task { @MainActor [weak self] in
                    await self?.refreshAllCardComplianceSnapshotsThrottled(sessionLease: sessionLease)
                }
            case let .failed(err, lastKnown):
                // H-3 — `lastKnown` is the pre-fetch page; don't repaint it over
                // a concurrent optimistic CRUD.
                if let lastKnown, mutationGeneration == loadGeneration {
                    medications = preservingLocalArchivedAt(in: lastKnown)
                    hasLoadedMedications = true
                    isShowingStaleCache = true
                }
                isLoading = false
                error = err
            }
        }
    }

    /// v0.6.0.7 Spezi Phase E — fan out the current medication array
    /// to the SpeziScheduler reconcile path. The actual lookup +
    /// `MedicationsSchedulerModule.reconcile(medications:)` call lives
    /// in `AppContainer+MedicationsScheduler.swift` so the
    /// SpeziScheduler import doesn't leak into this store; here we
    /// only refer to the public static accessor.
    ///
    /// No-op when Spezi is not linked into the build configuration —
    /// the `#if canImport(SpeziScheduler)` gate keeps tests + macOS
    /// builds untouched.
    func reconcileSpeziSchedulerIfAvailable() {
        // v0.10 W-Meds-A2 — fold the per-medication v1.7.0 delivery booleans
        // into the DeliveryPreferences server-default cache BEFORE the reconcile
        // reads the gating predicates, so a Live Activity / critical alarm only
        // arms when the resolved value is true.
        onMedicationsDidChange?(medications)
        // v0.9.0 W2 — critical-med AlarmKit reconcile runs FIRST and returns
        // the subset that stays on the UN/Spezi path (coexistence = REPLACE).
        // On iOS < 26 / no AlarmKit this is the identity, so the Spezi path is
        // unchanged. Falls back to "all off" when the predicate isn't wired
        // (tests / macOS) so everything still routes through the UN path.
        let alarmEnabled: @Sendable (String) -> Bool = if let provider = criticalAlarmEnabledProvider {
            provider()
        } else {
            { _ in false }
        }
        let schedulerMeds = AppContainer.reconcileCriticalAlarms(
            medications: medications,
            alarmEnabled: alarmEnabled,
            // audit-release 05 C-1 — surface a critical-alarm scheduling failure
            // as a persistent, user-visible warning instead of swallowing it.
            onSchedulingFailures: { [weak self] failedIDs in
                self?.criticalAlarmFailureIDs = failedIDs
            }
        )
        #if canImport(SpeziScheduler)
            AppContainer.reconcileMedicationsScheduler(medications: schedulerMeds)
        #endif
    }

    /// Server doesn't return `archivedAt` (clientside-only field per the
    /// Medication model). Merge incoming rows with the in-memory map so
    /// that a fresh `load()` doesn't drop the local timestamp the user
    /// just saw when they archived. Pre-existing timestamps win only
    /// when the incoming row is still `active = false` — if the server
    /// has reactivated the medication, we drop the stale timestamp.
    private func preservingLocalArchivedAt(in incoming: [Medication]) -> [Medication] {
        let localTimestamps: [String: Date] = Dictionary(uniqueKeysWithValues: medications
            .compactMap { medication -> (String, Date)? in
                guard let archivedAt = medication.archivedAt else { return nil }
                return (medication.id, archivedAt)
            })
        guard !localTimestamps.isEmpty else { return incoming }
        return incoming.map { row in
            guard !row.active, row.archivedAt == nil, let preserved = localTimestamps[row.id] else {
                return row
            }
            return Medication(
                id: row.id,
                name: row.name,
                dose: row.dose,
                treatmentClass: row.treatmentClass,
                category: row.category,
                dosesPerUnit: row.dosesPerUnit,
                schedule: row.schedule,
                lastTakenAt: row.lastTakenAt,
                todayEventCount: row.todayEventCount,
                notificationsEnabled: row.notificationsEnabled,
                active: row.active,
                archivedAt: preserved
            )
        }
    }

    private func consumeIntakes(
        stream: AsyncStream<SWRState<[MedicationIntake]>>,
        loadGeneration: UInt64,
        sessionLease: AuthenticatedSessionLease
    ) async {
        for await state in stream {
            guard authenticatedEffectIsCurrent(sessionLease) else { return }
            switch state {
            case .empty:
                break
            case let .cached(value, _):
                // H-3 generation-guarded — drop if a concurrent mark superseded.
                applyTodayIntakes(value, loadGeneration: loadGeneration)
            case let .fresh(value):
                // H-3 — a stale fresh here would repaint a marked dose pending
                // and climb the app badge back up; drop it when superseded.
                applyTodayIntakes(value, loadGeneration: loadGeneration)
            case let .failed(_, lastKnown):
                if let lastKnown {
                    applyTodayIntakes(lastKnown, loadGeneration: loadGeneration)
                }
            }
        }
    }

    private func consumeCompliance(
        stream: AsyncStream<SWRState<[ComplianceDay]>>,
        sessionLease: AuthenticatedSessionLease
    ) async {
        for await state in stream {
            guard authenticatedEffectIsCurrent(sessionLease) else { return }
            switch state {
            case .empty:
                break
            case let .cached(value, _):
                compliance = value
            case let .fresh(value):
                compliance = value
            case let .failed(_, lastKnown):
                if let lastKnown { compliance = lastKnown }
            }
        }
    }

    /// **v0.6.1.4 Y4.2** — fetch the server-canonical compliance
    /// snapshot for a single medication and patch it into
    /// `complianceCardSnapshots`. On failure the dict stays untouched
    /// (so a previous-good value keeps rendering and the local
    /// fallback covers cold-cache cases). Logged at `debug` level so
    /// future operator triage shows the round-trip + the rate the
    /// server returned.
    ///
    /// Lives on the class (not the extension) because it touches the
    /// private `repo` actor + the `private(set)` snapshot dict — both
    /// would otherwise need internal access escape hatches.
    ///
    /// **W-COMPLIANCE-INV note:** the v0.6.1.15 Y10
    /// `invalidateCardComplianceSnapshot` (drop-cache-on-optimistic-mark so
    /// the LOCAL algorithm paints instantly) is retired: under the
    /// server-only-paint doctrine the last server value stays painted through
    /// the optimistic window and this refresh overwrites it ~200-600 ms later
    /// — one repaint with the canonical number instead of a local-interim
    /// jump. On failure the med-id is marked in `failedComplianceFetchIDs`
    /// so the accessor may run its clearly-marked offline fallback.
    public func refreshCardComplianceSnapshot(for medicationID: String) async {
        guard let sessionLease = captureAuthenticatedSessionLease() else { return }
        await refreshCardComplianceSnapshot(for: medicationID, sessionLease: sessionLease)
    }

    func refreshCardComplianceSnapshot(
        for medicationID: String,
        sessionLease: AuthenticatedSessionLease
    ) async {
        guard authenticatedEffectIsCurrent(sessionLease) else { return }
        // v0.14.2 H4 — dedup: skip if this med's compliance fetch is already in
        // flight (fan-out + a racing single-med refresh) so we never open two
        // concurrent `GET …/compliance` for the same med. Check-then-insert is
        // atomic on the MainActor.
        if inFlightComplianceFetchIDs.contains(medicationID) { return }
        inFlightComplianceFetchIDs.insert(medicationID)
        defer { inFlightComplianceFetchIDs.remove(medicationID) }
        do {
            let payload = try await repo.compliance(medicationID: medicationID)
            // PHI-flash race (QA-b198 M-2): a logout/user-switch mid-fetch must
            // not commit the previous user's adherence onto the next user's card.
            try sessionLease.requireCurrent()
            let snapshot = ComplianceCardSnapshot(
                rate7: payload.compliance7.rate,
                rate30: payload.compliance30.rate,
                displayShortDays: payload.complianceDisplay?.shortDays,
                displayShortRate: payload.complianceDisplay?.short.rate,
                displayLongDays: payload.complianceDisplay?.longDays,
                displayLongRate: payload.complianceDisplay?.long.rate
            )
            complianceCardSnapshots[medicationID] = snapshot
            failedComplianceFetchIDs.remove(medicationID)
            // M-7 triage (v0.14.8 audit Q2.2): the med id is a bare cuid
            // (sanitizer-transparent) and the rates/counts are health-behavior
            // values tied to it, so the whole mixed line goes `.private`.
            HLLog.api.debug(
                """
                card-compliance refreshed med=\(medicationID, privacy: .private) \
                rate7=\(snapshot.rate7 ?? -1, privacy: .private) \
                rate30=\(snapshot.rate30 ?? -1, privacy: .private) \
                expected7=\(payload.compliance7.totalExpected, privacy: .private) \
                taken7=\(payload.compliance7.taken, privacy: .private)
                """
            )
        } catch {
            guard authenticatedEffectIsCurrent(sessionLease) else { return }
            // W-COMPLIANCE-INV — mark the failed round-trip so the card
            // accessor may paint the clearly-marked offline fallback instead
            // of a skeleton forever. A previous-good cached value still wins.
            failedComplianceFetchIDs.insert(medicationID)
            // M-7 triage — same rationale: cuid med id + free-form error text
            // (sanitizer-transparent shapes) → `.private`.
            HLLog.api.debug(
                """
                card-compliance fetch failed med=\(medicationID, privacy: .private) \
                err=\(LogSanitizer.redact(String(describing: error)), privacy: .private)
                """
            )
        }
    }

    /// **Build 6.3 — batched card compliance.** Fetches every scheduled card's
    /// snapshot in one round trip (`MedicationsRepository.complianceSummary` →
    /// `GET /api/medications/compliance`) and patches the server-canonical rates
    /// into `complianceCardSnapshots`, replacing the per-card N-request fan-out.
    /// Returns the set of medication ids the batch covered so the caller fans out
    /// only over the remainder (PRN meds, excluded server-side). Returns an empty
    /// set on any failure (offline / standalone / pre-batch server 404) so the
    /// caller's per-med fan-out runs as the full fallback — no behaviour lost,
    /// just fewer requests on the happy path.
    ///
    /// Lives on the class (not the `+CardCompliance` extension) because it sets
    /// the `public private(set)` snapshot dict, whose setter is file-scoped —
    /// same reason as `refreshCardComplianceSnapshot(for:)`. Never
    /// client-recomputes: the server value is the only painted source
    /// (`W-COMPLIANCE-INV`).
    func refreshCardComplianceViaBatch() async -> Set<String> {
        guard let sessionLease = captureAuthenticatedSessionLease() else { return [] }
        return await refreshCardComplianceViaBatch(sessionLease: sessionLease)
    }

    func refreshCardComplianceViaBatch(sessionLease: AuthenticatedSessionLease) async -> Set<String> {
        guard authenticatedEffectIsCurrent(sessionLease) else { return [] }
        do {
            let entries = try await repo.complianceSummary()
            // PHI-flash race (mirror `refreshCardComplianceSnapshot`): a
            // logout/user-switch mid-fetch must not commit the previous user's
            // adherence onto the next user's cards. Treat the ids as "covered"
            // so the caller does not then fan out on the cleared store.
            try sessionLease.requireCurrent()
            for entry in entries {
                complianceCardSnapshots[entry.medicationId] = ComplianceCardSnapshot(
                    rate7: entry.compliance7.rate,
                    rate30: entry.compliance30.rate,
                    displayShortDays: entry.complianceDisplay?.shortDays,
                    displayShortRate: entry.complianceDisplay?.short.rate,
                    displayLongDays: entry.complianceDisplay?.longDays,
                    displayLongRate: entry.complianceDisplay?.long.rate
                )
                failedComplianceFetchIDs.remove(entry.medicationId)
            }
            return Set(entries.map(\.medicationId))
        } catch {
            guard authenticatedEffectIsCurrent(sessionLease) else { return [] }
            // Fall back to the per-med fan-out. A previous-good cached value
            // still wins in the accessor; a cold card paints its skeleton until
            // the fan-out lands.
            return []
        }
    }

    /// **audit-release 05 C-1** — display names of the medications whose critical
    /// alarm failed to arm on the last reconcile, in stable list order. Empty
    /// when every alarm-owned med armed (or none opted in). `MedicationsScreen`
    /// renders these in the persistent failure warning so the user knows exactly
    /// which life-safety alarm is not set. Resolves ids against the live
    /// `medications` snapshot; an id with no matching row (raced archive) is
    /// simply dropped from the banner.
    public var criticalAlarmFailureNames: [String] {
        guard !criticalAlarmFailureIDs.isEmpty else { return [] }
        return medications
            .filter { criticalAlarmFailureIDs.contains($0.id) }
            .map(\.name)
    }

    public func clearOnLogout() {
        rotateOwnedAuthenticatedSessionBoundary()
        medications = []
        hasLoadedMedications = false
        todayIntakes = []
        compliance = []
        complianceCardSnapshots = [:]
        failedComplianceFetchIDs = []
        criticalAlarmFailureIDs = [] // C-1 — no stale alarm warning into the cleared store
        error = nil
        isLoading = false
        isShowingStaleCache = false
        inFlightMarkIDs = []
        complianceRefreshTask?.cancel() // M3 — no stale value into cleared store
        complianceRefreshTask = nil
        medicationsFanoutTask?.cancel()
        medicationsFanoutTask = nil
        // Reconcile against the now-empty medications array — the
        // SpeziScheduler module purges every `med-*` task because none
        // are in the desired-id set. Prevents the next user from
        // seeing the previous user's reminders.
        reconcileSpeziSchedulerIfAvailable()
    }

    #if DEBUG
        /// Test-only seam — forces the medications array without going
        /// through `load()` (which would otherwise need a stubbed network).
        /// Mirrors `MedicationDetailStore._testInject`. Production code
        /// must never reach this; it stays `internal` so unit tests in
        /// the same module can call it via `@testable import HealthLog`.
        @MainActor
        // swiftlint:disable:next identifier_name
        func _testForceSet(medications: [Medication]) {
            self.medications = medications
        }

        /// Test-only seam for `todayIntakes` (T-4 retro-mutate tests seed the
        /// intake list to verify optimistic-patch + sibling-invalidate semantics).
        @MainActor
        // swiftlint:disable:next identifier_name
        func _testForceSet(todayIntakes: [MedicationIntake]) {
            self.todayIntakes = todayIntakes
        }

        /// v0.6.1.4 Y4.2 test-only seam — seeds a single
        /// `ComplianceCardSnapshot` into the dict so contract tests
        /// can assert the `cardComplianceSnapshot(for:windowIntakes:)`
        /// accessor reads from the cache before hitting the fallback.
        @MainActor
        // swiftlint:disable:next identifier_name
        func _testForceSet(cardSnapshot: ComplianceCardSnapshot, for medicationID: String) {
            complianceCardSnapshots[medicationID] = cardSnapshot
        }

        /// audit-release 05 C-1 test seam — drives the critical-alarm
        /// scheduling-failure set directly (the real path runs through AlarmKit,
        /// unavailable in unit tests) so the store→UI surfacing (the property +
        /// `criticalAlarmFailureNames` mapping) is verifiable.
        @MainActor
        // swiftlint:disable:next identifier_name
        func _testSetCriticalAlarmFailureIDs(_ ids: Set<String>) {
            criticalAlarmFailureIDs = ids
        }
    #endif
}
