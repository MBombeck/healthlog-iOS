import Foundation
import Observation

/// `@Observable` wrapper over ``MoodRelationsRepository``. Hydrates the mood
/// "relations" cards on the Insights → Mood page — the **tag-influence** rows
/// (with-vs-without daily-mean delta + Welch confidence band) and the ranked
/// **"better days"** board — from `GET /api/mood/insights` (server v1.11.5).
///
/// **ASSOCIATION, NEVER CAUSE.** The store carries the server's observational
/// associations through verbatim; it adds no causal framing. The cards render
/// "X hängt mit besserer Stimmung zusammen", never "X verbessert deine
/// Stimmung". Sample-size + confidence floors are honoured server-side; the
/// cards downgrade or hide rather than imply fake precision.
///
/// **HONEST-ONLY + self-suppressing.** The store surfaces ONLY what the server
/// returns. A payload that pre-dates v1.11.5 decodes to an empty
/// ``MoodRelationsResponse`` (tolerant DTO) so ``hasContent`` is `false` and the
/// region collapses to the calm "not enough data yet" empty state — never a
/// fabricated correlation, never an error box.
///
/// **Server-derived.** Pure server compute, no on-device fallback — the call
/// site additionally gates on `BackendAvailability.canShowCloudInsights` so the
/// region hides in standalone / no-server.
@MainActor
@Observable
public final class MoodRelationsStore {
    /// The decoded relations slices, or `nil` until the first load resolves.
    public private(set) var response: MoodRelationsResponse?
    public private(set) var isLoading: Bool = false
    /// Latched once any load (success OR failure) has settled, so the page can
    /// distinguish "still loading" from "loaded, genuinely empty" and show the
    /// calm empty state only in the latter.
    public private(set) var hasSettledOnce: Bool = false

    private let repo: MoodRelationsRepository

    public init(repo: MoodRelationsRepository) {
        self.repo = repo
    }

    /// Structured-tag influence rows, strongest swing first (`|delta|` desc).
    /// We lead with the curated taxonomy axis because those carry an icon +
    /// localized label (a calmer, more scannable read than free-text tags).
    public var structuredInfluence: [TagInfluenceRow] {
        (response?.tagInfluence.structured ?? []).sorted { abs($0.delta) > abs($1.delta) }
    }

    /// Flat free-text influence rows, strongest swing first.
    public var flatInfluence: [TagInfluenceRow] {
        (response?.tagInfluence.flat ?? []).sorted { abs($0.delta) > abs($1.delta) }
    }

    /// The unified "better days" board, ranked exactly as the server delivered
    /// it (effect-size desc, then confidence). We do NOT re-sort: the server's
    /// cross-source ranking (Cohen's d for tags vs |r| for metrics) is the
    /// authoritative one.
    public var betterDays: [BetterDayFactor] {
        response?.betterDays ?? []
    }

    /// v0.14.8 — the RATED-factor × metric crosstab rows (`factorCrosstab`,
    /// server v1.14.0), most-significant first (smallest adjusted q-value). The
    /// server already FDR-filters the family, so every row here cleared the gate;
    /// we only re-order for the lead-with-the-strongest read.
    public var factorCrosstab: [FactorMetricCrosstabRow] {
        (response?.factorCrosstab ?? []).sorted { $0.qValue < $1.qValue }
    }

    /// Whether the rated-factor × metric card has any row to render.
    public var hasFactorCrosstab: Bool {
        !factorCrosstab.isEmpty
    }

    /// Whether the influence card has any row to render.
    public var hasInfluence: Bool {
        !structuredInfluence.isEmpty || !flatInfluence.isEmpty
    }

    /// Whether the better-days card has any factor to render.
    public var hasBetterDays: Bool {
        !betterDays.isEmpty
    }

    /// Whether the whole relations region has anything to show. The call site
    /// keeps the region out of the scroll column entirely when this is `false`.
    public var hasContent: Bool {
        hasInfluence || hasBetterDays || hasFactorCrosstab
    }

    public func load() async {
        isLoading = true
        defer {
            isLoading = false
            hasSettledOnce = true
        }
        // Keep the last good snapshot on a transient failure (graceful
        // degradation) rather than blanking the cards.
        response = await (try? repo.fetch()) ?? response
    }

    public func refresh() async {
        await load()
    }

    public func clearOnLogout() {
        response = nil
        hasSettledOnce = false
    }
}
