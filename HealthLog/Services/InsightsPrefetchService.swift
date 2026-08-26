import Foundation

/// W3 (v0.11 Wave #22) — warms the **daily-generated** Insights caches ahead
/// of the user opening the Insights tab.
///
/// The server regenerates the per-metric assessments, the comprehensive
/// digest, and the advisor briefing roughly **once per Berlin calendar day**
/// (RESEARCH §B). Without a prefetch the user pays a cold network round-trip
/// the first time they open a per-metric page each day. This service downloads
/// that content on **app launch** and on **scenePhase-foreground** so the
/// per-metric screen (W2) and the Übersicht tab paint cache-first (≤100-200 ms
/// budget) from the persistent `CachedSnapshot` rows the SWR layer manages.
///
/// **Gating (no doomed fetch):** the whole warm is skipped unless the backend
/// is paired + authenticated + online (`shouldWarm`). In standalone /
/// backend-down there is no server to talk to, so firing would only churn the
/// reachability probe and log noise. The LLM-backed legs (status + briefing)
/// additionally pass through their repos' own AI-consent gate, so a closed
/// consent never transmits health data here either.
///
/// **Off the critical path:** every leg is fire-and-forget on a utility task —
/// `warm()` returns immediately; bootstrap / foreground handling never blocks
/// on the network. Each leg is independently best-effort (`try?`): one failing
/// fetch never aborts the others, and the SWR single-flight collapses any
/// overlap with a concurrent user-driven open of the same key.
///
/// **`actor`** so a launch-warm and a foreground-warm that race share the
/// `inFlight` re-entry guard without a data race — a second `warm()` while one
/// is already running is a cheap no-op rather than a duplicate fan-out.
public actor InsightsPrefetchService {
    /// Metrics that have a deployed `*-status` endpoint today (mirrors
    /// `MetricInsightsRepository.endpoint(for:)`). Only these warm an
    /// assessment row; the rest legitimately have no server assessment (the
    /// per-metric screen shows the same empty state as web). Adding a metric
    /// here when its endpoint ships is the one-line extension point.
    ///
    /// **Must mirror `MetricInsightsRepository.endpoint(for:)`** — the four kinds
    /// with a deployed `*-status` route: blood-pressure / weight / pulse / bmi
    /// (W5 wired `.bmi → /api/insights/bmi-status`; W22-audit added it here so the
    /// BMI assessment paints cache-first like the others instead of paying a cold
    /// round-trip on first open).
    static let statusMetrics: [MetricKind] = [.bloodPressure, .weight, .pulse, .bmi]

    private let metricInsightsRepo: MetricInsightsRepository
    private let targetsRepo: InsightsTargetsRepository
    private let insightsRepo: InsightsRepository
    /// `true` iff a server warm should fire right now (paired + authed +
    /// online). Evaluated on the MainActor (it reads `BackendAvailability`),
    /// so the closure hops there. Re-checked on every `warm()` so a mode flip
    /// (standalone → paired after onboarding, or a reconnect) is honoured.
    private let shouldWarm: @Sendable () async -> Bool
    /// BCP-47 language tag for the assessment prose (de/en), resolved fresh per
    /// warm so a language change is reflected on the next foreground.
    private let resolveLocale: @Sendable () -> String

    /// Re-entry guard — collapses a launch-warm racing a foreground-warm into
    /// the first one's fan-out. Cheap: the SWR single-flight already dedupes at
    /// the key level, but skipping the whole fan-out avoids spinning N tasks
    /// that would each immediately await an in-flight key.
    private var inFlight = false

    public init(
        metricInsightsRepo: MetricInsightsRepository,
        targetsRepo: InsightsTargetsRepository,
        insightsRepo: InsightsRepository,
        shouldWarm: @escaping @Sendable () async -> Bool,
        resolveLocale: @escaping @Sendable () -> String = {
            Locale.autoupdatingCurrent.language.languageCode?.identifier ?? "de"
        }
    ) {
        self.metricInsightsRepo = metricInsightsRepo
        self.targetsRepo = targetsRepo
        self.insightsRepo = insightsRepo
        self.shouldWarm = shouldWarm
        self.resolveLocale = resolveLocale
    }

    /// Warm the daily Insights caches. Returns immediately; the fan-out runs on
    /// a detached utility task so the caller's path (bootstrap / foreground) is
    /// never blocked. No-op when the backend is unavailable or a warm is
    /// already in flight.
    public func warm() {
        Task { await self.warmAndAwait() }
    }

    /// Awaitable variant — used by tests to assert the warm path completed (and
    /// by callers that want to sequence after the warm). Same gating + best-
    /// effort semantics as ``warm()``.
    public func warmAndAwait() async {
        guard !inFlight else { return }
        // D-14-07-B. The claim is made BEFORE the first suspension, not after
        // it. An actor method that awaits is reentrant (09-03's lesson, and
        // this file's own `actor` rationale above depends on it): `shouldWarm()`
        // hops to the MainActor, and a second warm arriving during that hop
        // used to pass a guard the first warm had already decided to take, so
        // both fanned out. Witnessed as `/api/insights/comprehensive` hit twice
        // by `InsightsDailyCacheTests.reentryGuardCollapses`, which was red on
        // roughly half of the isolated runs measured at plan 14-07 — a real
        // race whose visibility depends on scheduling, not a flaky assertion.
        //
        // The `defer` releases the claim on every exit, including the
        // backend-unavailable one, so a skipped warm does not latch the guard.
        inFlight = true
        defer { inFlight = false }
        guard await shouldWarm() else {
            HLLog.api.info("InsightsPrefetch.warm skipped — backend unavailable")
            return
        }

        let metricInsightsRepo = metricInsightsRepo
        let targetsRepo = targetsRepo
        let insightsRepo = insightsRepo
        let locale = resolveLocale()
        let metrics = Self.statusMetrics

        await withTaskGroup(of: Void.self) { group in
            // Targets — one payload covers every metric's Ziel block.
            group.addTask { _ = try? await targetsRepo.fetch() }
            // Comprehensive digest (overview empty-gate + per-metric summaries).
            group.addTask { _ = try? await insightsRepo.comprehensive() }
            // Advisor briefing (Übersicht tab). Consent-gated inside the repo.
            group.addTask { _ = try? await insightsRepo.generateBriefing(force: false) }
            // Per-metric daily assessments for the metrics that have a status
            // endpoint. Each is consent-gated + Berlin-day-keyed inside the repo.
            for metric in metrics {
                group.addTask {
                    _ = try? await metricInsightsRepo.fetch(metric: metric, locale: locale)
                }
            }
        }
    }
}
