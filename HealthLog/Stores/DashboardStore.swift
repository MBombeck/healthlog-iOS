import Foundation
import Observation

@MainActor
@Observable
public final class DashboardStore {
    // W-FILELEN — `internal(set)` (not `private(set)`) so the
    // `DashboardStore+MetricStates.swift` same-module extension can write these.
    // Public read API is unchanged; only the setter widens from private to
    // internal. Pure visibility relax; no behaviour change.
    public internal(set) var summary: DashboardSummary?
    public private(set) var isLoading: Bool = false
    public private(set) var error: HLError?
    /// Set when the visible payload was served from cache (SWR `.cached` arm).
    /// Stream Bravo's dashboard UI uses this to badge the tiles with
    /// "showing cached" while the revalidation request is in flight.
    public private(set) var isShowingStaleCache: Bool = false
    /// Wall-clock when the visible payload was last refreshed (cache write
    /// time for cached-state, network response time for fresh-state).
    public private(set) var lastUpdatedAt: Date?

    /// Per-metric `MetricDataState` keyed by `MetricKind`. The PA4 unified-
    /// data-source projection — every tile reads through this map so the
    /// tile + chart-detail can never disagree (BP/Pulse "Tile leer, Detail
    /// voll" regression class). Populated by `refreshMetricStates(...)`
    /// which the dashboard view kicks off after `summary` lands.
    ///
    /// The summary endpoint stays the cold-launch seed (sub-100ms first
    /// paint); once a per-kind state resolves it shadows the summary's
    /// `latestValue` for the tile's empty-vs-ready predicate.
    public internal(set) var metricStates: [MetricKind: MetricDataState] = [:]

    /// Wall-clock when the most recent `refreshMetricStates` call returned —
    /// regardless of whether it succeeded, failed or fell short for some
    /// kinds. `nil` while the first fan-out is still in flight on cold
    /// launch. Drives `DashboardEmptyTilePolicy.shouldAutoHide`'s
    /// loading-too-long fallback: tiles whose per-kind state never moved
    /// past `.unknown`/`.loading` after fan-out settled get auto-hidden
    /// (operator-reported N1: tiles "stick" in loading state forever when
    /// `recentAll()` throws and the per-kind derivation never runs).
    public internal(set) var fanOutSettledAt: Date?

    /// **V052-R3 A-H1 fix.** Monotonically-increasing counter bumped on the
    /// post-settle policy re-evaluation tick. The dashboard view reads
    /// `metricStates` and `fanOutSettledAt` to drive `shouldAutoHide`, but
    /// once `fanOutSettledAt` is written there is no further observable
    /// state change — so a cold-launch where HK + network both fail (catch
    /// branch sets `fanOutSettledAt = now`, render runs immediately with
    /// `delta ≈ 0 < 1.5s`, tiles render `.loading`) would never recompute
    /// past the grace window. Workaround the user had was pull-to-refresh.
    ///
    /// Real fix: after settle, fire `Task { try? await Task.sleep(for:
    /// .seconds(1.6)); policyTick &+= 1 }` so the view re-renders past the
    /// 1.5s timeout and the auto-hide branch can apply. The view simply
    /// needs to depend on `policyTick` to observe the tick — any read of
    /// the property suffices (we use it via `orderedMetrics`'s observable
    /// dependency chain).
    ///
    /// `scheduledPolicyTickAt` guards against multiple-settle pile-up: when
    /// `refreshMetricStates` is called multiple times in rapid succession
    /// (refreshable + scenePhase combo), only the FIRST settle schedules a
    /// tick task; subsequent settles within the grace window are absorbed.
    public internal(set) var policyTick: Int = 0
    /// W-FILELEN — internal so the +MetricStates extension can guard/schedule the tick.
    var scheduledPolicyTickAt: Date?
    /// Retained so terminal cleanup can cancel and later drain the delayed
    /// policy publication instead of relying on cooperative cancellation alone.
    var policyTickTask: Task<Void, Never>?

    private let repo: DashboardRepository
    private let swr: SWRCoordinator?
    private var authenticatedSessionRegistry: AuthenticatedSessionLeaseRegistry?
    private var userIDProvider: (@Sendable () -> String?)?

    /// **v0.14.8 INV-home-compliance-slot — server-profile day-anchoring zone.**
    ///
    /// The `.dashboardSummary` SWR key must roll over on the SAME midnight the
    /// medication "today"/compliance bucket uses (`MedicationsStore.profileTimeZone`
    /// == the server `userTz`), otherwise a prior-day `summary.compliance`
    /// snapshot is SWR-served via the `.cached` arm on the next calendar day and
    /// the Home `ComplianceRingCard` renders a phantom "2 von 2 genommen". The
    /// composition root points this at the same provider `MedicationsStore` uses
    /// (`settingsStore.profile` timezone). Defaults to `.current` so unit tests +
    /// the pre-settings-hydration window stay byte-unchanged.
    public var profileTimeZoneProvider: () -> TimeZone = { .current }

    /// **v0.14.8 INV-home-compliance-slot — day-anchored summary cache key.**
    /// The `.dashboardSummary` row is keyed on the current calendar day in the
    /// profile timezone, so a new calendar day is a STRUCTURAL cache miss (the
    /// stale prior-day `summary.compliance` can never be SWR-served across
    /// midnight). Every observe of the summary key routes through this single
    /// accessor — mirrors `MedicationsStore.todayIntakesKey`.
    var dashboardSummaryKey: CacheKey {
        .dashboardSummary(day: MedicationDayKey.string(timeZone: profileTimeZoneProvider()))
    }

    public init(repo: DashboardRepository, swr: SWRCoordinator? = nil) {
        self.repo = repo
        self.swr = swr
    }

    /// Live composition-root initializer. The public initializer above remains
    /// test-safe for isolated/headless stores without exposing the internal
    /// session-boundary primitive as public API.
    init(
        repo: DashboardRepository,
        swr: SWRCoordinator? = nil,
        authenticatedSessionRegistry: AuthenticatedSessionLeaseRegistry,
        userIDProvider: @escaping @Sendable () -> String?
    ) {
        self.repo = repo
        self.swr = swr
        self.authenticatedSessionRegistry = authenticatedSessionRegistry
        self.userIDProvider = userIDProvider
    }

    /// Captures identity before the operation's first suspension. Legacy unit
    /// stores without a registry receive a cancellation-aware local lease;
    /// AppContainer stores fail closed unless their authenticated owner is active.
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

    func authenticatedEffectIsCurrent(_ sessionLease: AuthenticatedSessionLease?) -> Bool {
        sessionLease?.isCurrent == true
    }

    /// - Parameter force: when `true`, bypasses the SWR staleness TTL so an
    ///   explicit pull-to-refresh always hits the network (W8-B1). Default
    ///   `false` respects the `dashboardSummary` TTL — a quick foreground
    ///   bounce inside the window serves from cache.
    public func load(force: Bool = false) async {
        guard let sessionLease = captureAuthenticatedSessionLease() else {
            // 13-03 (H-A1c) — this was a silent `return`. A refused lease and a
            // finished load looked identical in the field, which is why "the
            // dashboard sometimes shows nothing" stayed undiagnosable for as
            // long as it did. One counter, no identifiers.
            StoreEffectDiagnostics.recordRefusal(.leaseUnavailable, store: .dashboard)
            return
        }
        // 13-03 (H-A1b) — no exit from this method may leave the skeleton up.
        //
        // The SWR arm raises `isLoading` on `.empty` and had no way of lowering
        // it again on any exit but a terminal emission. Every other exit — the
        // per-emission fence refusing a late result, the stream ending because
        // the task was cancelled — left it raised forever, and
        // `DashboardMetricsSectionState.resolve` requires `hasError &&
        // !isLoading`, so the stranded flag suppressed the very #67 error card
        // built for this symptom. Only pull-to-refresh could recover.
        //
        // The defer lowers the FLAG and nothing else: the fence's data
        // protection is untouched, so a refused emission still publishes no
        // summary and no error. Announcing "not loading" about a load that was
        // refused is the truth; announcing its data would not be.
        //
        // It sits HERE, ahead of the direct-fetch fallback, for two reasons:
        // it covers that arm's own conditional defer as well, and the Phase-06
        // authenticated-effect scanner records an effect only once a suspension
        // boundary has been seen in the symbol. Above the first `await` this is
        // not a new inventoried effect in `load#1`, which is the honest
        // outcome — the frozen assignment contract is about publications that
        // could carry another account's data across a session boundary, and
        // lowering a loading flag carries none.
        //
        // 20-02 (D-14-06-A) — and it is guarded on `ownsRegistryGeneration`,
        // not left unconditional. 13-03 was right that cancellation must still
        // settle; it did not have the predicate that could say so without also
        // letting a SUPERSEDED generation settle. `isLoading` is an observable,
        // so a retired load writing `false` to it is a retired generation
        // publishing — over the skeleton the account that IS here is
        // legitimately showing. `ownsRegistryGeneration` is registry currency
        // WITHOUT the cancellation fold, so cancellation still settles (13-03's
        // whole point survives) and a superseded load publishes nothing, "not
        // loading" included. `clearOnLogout()` is what settles the flag on the
        // boundary, and it always runs there — so refusing here strands nothing.
        defer {
            if sessionLease.ownsRegistryGeneration {
                isLoading = false
            }
        }
        // SWR-aware path — kicks in once `swr` is wired by `AppContainer`.
        // Falls back to the direct-fetch behaviour when nil (e.g. unit tests
        // that don't construct a coordinator).
        guard let swr else {
            await loadDirect(sessionLease: sessionLease)
            return
        }
        // Reference repo via a local capture so the `@Sendable` closure
        // doesn't reach back into `self` (MainActor isolation).
        let repo = repo
        for await state in await swr.observe(dashboardSummaryKey, decoding: DashboardSummary.self, forceRevalidate: force, fetch: {
            try sessionLease.requireCurrent()
            let value = try await repo.summary()
            try sessionLease.requireCurrent()
            return value
        }) {
            guard authenticatedEffectIsCurrent(sessionLease) else {
                // 13-03 — the refusal is now countable. It is the same silence
                // as the lease-nil above, one emission later.
                StoreEffectDiagnostics.recordRefusal(.leaseRetired, store: .dashboard)
                return
            }
            switch state {
            case .empty:
                // First-ever load on this device, no cache yet. UI keeps the
                // existing skeleton; isLoading drives the spinner.
                isLoading = true
                error = nil
            case let .cached(value, _):
                // FIRST PAINT — sub-100ms when SwiftData is warm.
                // v0150 nav-scroll (Bug 3): only WRITE the @Observable `summary`
                // when the value actually changed. The SWR `.cached` → `.fresh`
                // emit pair on every foreground revalidate otherwise reassigned
                // an identical summary, rebuilding the whole dashboard subtree
                // under the restored scroll offset (return-jump). Other state
                // (lastUpdatedAt / stale / loading) still updates unconditionally.
                assignSummaryIfChanged(value)
                lastUpdatedAt = Date()
                isShowingStaleCache = true
                isLoading = false
            case let .fresh(value):
                assignSummaryIfChanged(value)
                lastUpdatedAt = Date()
                isShowingStaleCache = false
                isLoading = false
                error = nil
            case let .failed(err, lastKnown):
                if let lastKnown {
                    assignSummaryIfChanged(lastKnown)
                    isShowingStaleCache = true
                }
                isLoading = false
                error = err
            }
        }
    }

    /// v0150 nav-scroll (Bug 3): write the `@Observable` `summary` ONLY when the
    /// value differs, so an identical revalidation does not invalidate the
    /// dashboard subtree (Highlight card / compliance ring / metrics grid +
    /// empty-tile policy) and perturb the restored scroll offset on return to
    /// Home. A genuinely-changed summary still propagates.
    private func assignSummaryIfChanged(_ value: DashboardSummary) {
        guard summary != value else { return }
        summary = value
    }

    /// Legacy direct-fetch path. Used when no SWR coordinator is injected
    /// (unit tests). Keeps the old single-emit semantics so existing test
    /// expectations against `summary != nil` after `load()` still hold.
    private func loadDirect(sessionLease: AuthenticatedSessionLease) async {
        isLoading = true
        error = nil
        defer {
            if authenticatedEffectIsCurrent(sessionLease) {
                isLoading = false
            }
        }
        do {
            try sessionLease.requireCurrent()
            let value = try await repo.summary()
            guard assignDirectSummaryIfCurrent(value, sessionLease: sessionLease) else { return }
            lastUpdatedAt = Date()
            isShowingStaleCache = false
        } catch let err as HLError {
            guard authenticatedEffectIsCurrent(sessionLease) else { return }
            error = err
        } catch {
            guard authenticatedEffectIsCurrent(sessionLease) else { return }
            self.error = .unknown(String(describing: error))
        }
    }

    /// Keeps the direct response assignment adjacent to its currency check.
    /// Synchronous on the main actor, so invalidation cannot interleave between
    /// the guard and the observable write.
    private func assignDirectSummaryIfCurrent(
        _ value: DashboardSummary,
        sessionLease: AuthenticatedSessionLease
    ) -> Bool {
        guard authenticatedEffectIsCurrent(sessionLease) else { return false }
        summary = value
        return true
    }

    /// - Parameter force: forwarded to `load(force:)`. Pull-to-refresh passes
    ///   `true` so the explicit user-driven refresh bypasses the TTL.
    public func refresh(force: Bool = false) async {
        await load(force: force)
    }

    public func clearOnLogout() {
        policyTickTask?.cancel()
        policyTickTask = nil
        summary = nil
        error = nil
        // 13-03 — this line was missing. Nine fields were reset and the one
        // that decides whether the skeleton is on screen was not, so a logout
        // during an in-flight load handed the next account a dashboard that
        // was already, permanently, loading.
        isLoading = false
        lastUpdatedAt = nil
        isShowingStaleCache = false
        metricStates = [:]
        fanOutSettledAt = nil
        scheduledPolicyTickAt = nil
        policyTick = 0
    }

    /// Test-only seam: lets unit tests seed `summary` without round-tripping
    /// the SWR coordinator. Production code-paths must stay observation-
    /// driven via `load()` / `refresh()`. Marked `internal` (visible only to
    /// `@testable import HealthLog` consumers) to keep external SDK clients
    /// from depending on it.
    func seedSummaryForTesting(_ value: DashboardSummary) {
        summary = value
    }

    // The per-metric `MetricDataState` machinery —
    // `recomputePolicyForTesting()`, `recomputePolicy()`,
    // `schedulePolicyTickAfterSettle(at:)`, `synthesiseMissingTiles(layout:)`,
    // `placeholder(for:order:)`, `resetMetricStatesForRefresh()`,
    // `refreshMetricStates(...)`, `commitStates(_:)`,
    // `shouldAcceptTransition(from:to:)`, `summaryHasEmptySparkline(for:)`,
    // `fanOutSeriesFallback(...)`, `hydrateSparkline(for:from:)`,
    // `kindSupportsSeries(_:)` — lives in `DashboardStore+MetricStates.swift`
    // to keep this file under the 600-line `file_length` swiftlint budget.
}
