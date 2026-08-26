import Foundation
import Observation

/// `@Observable` wrapper over `DerivedMetricsRepository`. Hydrates the derived
/// re-frames block on the Insights overview — the server-computed wellness
/// scores + age/HRV re-frames, each with its coverage / confidence /
/// provenance envelope (award-tier transparency, web `vitals-dashboard.tsx` +
/// `wellness-scores.tsx` parity).
///
/// **HONEST-ONLY.** The store surfaces ONLY the envelopes the server returns;
/// it never fabricates a band or score. An `insufficient` envelope is kept
/// (the card renders its gating state) but is NOT presented as a value; a
/// `404`/`422` arm is dropped entirely (the metric simply does not appear).
///
/// **Server-derived.** Pure server compute, no on-device fallback — the call
/// site additionally gates the block on `BackendAvailability.hasServer` so it
/// hides in standalone / no-server.
@MainActor
@Observable
public final class DerivedInsightsStore {
    /// The derived metric ids the overview block surfaces, in display order.
    /// The composite scores lead (the "Whoop/Oura" wellness bar), then the
    /// age/HRV re-frames. Forward-compatible: an id the server's closed
    /// registry rejects 422s → the repo drops it → it simply does not appear.
    public nonisolated static let surfacedMetrics: [String] = [
        "READINESS",
        "SLEEP_SCORE",
        "RECOVERY_SCORE",
        "STRESS_SCORE",
        "STRAIN_SCORE",
        "FITNESS_AGE",
        // I-2 — "Signale des Tages" (transparent deviation COUNT, NOT a score,
        // NOT AI). Rendered as an honest count card, never a ring. Fetched here
        // so the same batch round-trip carries it; the overview partitions it
        // out of the ring-card lane.
        "COINCIDENT_DEVIATION",
        "VASCULAR_AGE_DELTA",
        "HRV_BALANCE"
    ]

    public private(set) var metrics: [DerivedMetricDTO] = []

    // MARK: - CU-30 / C5 — Same-Time-Baseline

    /// The latest `SAME_TIME_BASELINE` envelope, kept OUT of ``metrics``.
    ///
    /// Two reasons it does not ride the overview grid: it is per-type (the grid
    /// is per-id), and it must be read through the uncached single route
    /// because its numbers move every hour. `nil` means "not read yet / route
    /// absent"; a gated envelope is a VALUE here, not an absence — the card
    /// renders `learning_usual_day` and `no_intraday_today` as honest states.
    public private(set) var sameTimeBaseline: DerivedMetricDTO?
    /// The type the envelope in ``sameTimeBaseline`` was read for.
    public private(set) var sameTimeBaselineType: SameTimeBaselineType = .default
    /// `true` once a Same-Time-Baseline read settled this session — lets the
    /// card tell "still loading" from "settled with nothing to show".
    public private(set) var sameTimeBaselineSettled: Bool = false

    public private(set) var isLoading: Bool = false
    /// v0.14.1 — `true` while the server is still computing at least one
    /// surfaced score out of band (any envelope returned `revalidating: true`)
    /// and a bounded in-session re-poll is scheduled. Lets the overview show a
    /// calm "Einschätzung wird erstellt…" placeholder during the warm window
    /// instead of an empty block — mirrors ``NarrativeStore/warming``. Cleared
    /// the moment the grid settles (no envelope still warming) or the re-poll
    /// cap is hit.
    public private(set) var warming: Bool = false

    private let repo: DerivedMetricsRepository

    /// v0.14.1 — number of warm re-polls already issued this session (capped so
    /// a never-warming server can't loop forever). Reset once the grid settles.
    private var revalidatePolls: Int = 0
    /// The pending warm re-poll, held so logout can cancel it.
    ///
    /// N5.2 (v0.14.8 tech audit) — a SINGLE handle is correct here (unlike
    /// `NarrativeStore`, which polls per period): this store has exactly one
    /// load scope (the whole batch grid), so the newest schedule legitimately
    /// supersedes any prior one. Cancellation relies on `clearOnLogout()`,
    /// which IS wired into the logout cascade
    /// (`AppContainer+Logout` → `serverStatsStores.derivedMetrics`).
    private var revalidateTask: Task<Void, Never>?
    /// Re-poll cap + delay for the warm-in-flight case (mirrors NarrativeStore).
    private static let maxRevalidatePolls = 3
    private static let revalidatePollDelay: Duration = .seconds(4)

    public init(repo: DerivedMetricsRepository) {
        self.repo = repo
    }

    /// Only the `status == "ok"` envelopes, ordered by ``surfacedMetrics``.
    /// These are the values the derived block actually renders. `insufficient`
    /// envelopes are intentionally NOT presented as values (honest-only) — the
    /// block self-suppresses a metric with no computable value rather than
    /// painting a "track more days" row on the dense overview (the per-metric
    /// page is the home for the gating nudge).
    public var presentable: [DerivedMetricDTO] {
        let order = Dictionary(
            uniqueKeysWithValues: Self.surfacedMetrics.enumerated().map { ($1, $0) }
        )
        return metrics
            .filter { $0.isOK && $0.value != nil }
            .sorted { (order[$0.metric] ?? .max) < (order[$1.metric] ?? .max) }
    }

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        // v0.12 next — ONE batched request for the whole grid instead of a
        // per-metric fan-out (the server-flagged Prisma-pool starvation). Falls
        // back to the per-id path internally on a 404/422.
        let fresh = await repo.fetchBatch(Self.surfacedMetrics)
        metrics = fresh

        // v0.14.1 — warm-in-flight re-poll. On a cold first-login session the
        // daily derived compute may not have landed yet: the server returns the
        // envelopes with `revalidating: true` (no value / no assessment) while
        // it warms them out of band. Settling here would freeze the empty
        // overview until the next Berlin-day rollover, so instead we mark the
        // block as warming + schedule a short-delay re-poll (capped) so a
        // freshly-warmed grid appears in the SAME session.
        let stillWarming = fresh.contains { $0.revalidating == true }
        if stillWarming, revalidatePolls < Self.maxRevalidatePolls {
            revalidatePolls += 1
            warming = true
            revalidateTask?.cancel()
            revalidateTask = Task { [weak self] in
                try? await Task.sleep(for: Self.revalidatePollDelay)
                if Task.isCancelled { return }
                await self?.load()
            }
        } else {
            // Settled (nothing warming, or the re-poll cap is hit): drop the
            // warming flag + reset the poll counter for the next cold load.
            warming = false
            revalidatePolls = 0
            revalidateTask?.cancel()
            revalidateTask = nil
        }
    }

    public func refresh() async {
        await load()
    }

    // MARK: - CU-30 / C5 — Same-Time-Baseline

    /// Reads the Same-Time-Baseline for one cumulative type through the
    /// uncached single route.
    ///
    /// Idempotent per appearance: a repeat call for the SAME type that already
    /// settled short-circuits unless `force` is set (pull-to-refresh), so a
    /// re-mount does not re-hit the route. Switching type always re-reads.
    ///
    /// A gated envelope is kept, not discarded — `learning_usual_day` and
    /// `no_intraday_today` are the normal, honest states of many accounts and
    /// the card renders them. Only a `404`/`422` (route absent / id rejected)
    /// or a transport error clears the slot, and neither renders as an error.
    public func loadSameTimeBaseline(
        type: SameTimeBaselineType = .default,
        force: Bool = false
    ) async {
        if sameTimeBaselineSettled, sameTimeBaselineType == type, !force { return }
        sameTimeBaselineType = type
        defer { sameTimeBaselineSettled = true }
        sameTimeBaseline = try? await repo.fetchSameTimeBaseline(type: type)
    }

    /// Issue-2 — fetch ONE derived envelope through the per-id route
    /// (`GET /api/insights/derived?metric=<ID>`), which carries the per-score
    /// `assessment` ("Einschätzung"). The overview grid uses the BATCH route,
    /// and the server returns `assessment: null` on the batch by design (it
    /// skips the assessment cost on a multi-item grid read). So the wellness
    /// detail sheet must re-read the single route to obtain the deterministic
    /// assessment text. Best-effort: `nil` on a 404/422/transport error (the
    /// sheet falls back to whatever the batch DTO already carried).
    public func fetchSingle(metric: String) async -> DerivedMetricDTO? {
        try? await repo.fetch(metric: metric)
    }

    public func clearOnLogout() {
        revalidateTask?.cancel()
        revalidateTask = nil
        revalidatePolls = 0
        warming = false
        metrics = []
        sameTimeBaseline = nil
        sameTimeBaselineType = .default
        sameTimeBaselineSettled = false
    }
}
