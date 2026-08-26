import Foundation

/// Wire-form mirror of `GET /api/insights/correlations` (server v1.10.0,
/// route at `src/app/api/insights/correlations/route.ts`, envelope
/// `CorrelationDiscoveryResponseEnvelope` in `docs/api/openapi.yaml`).
///
/// **What it serves.** FDR-controlled correlation *discovery* over a curated
/// behaviour × outcome matrix: each behaviour-day is lag-joined to the
/// next-day outcome (`lagDays == 1`), Pearson `r` + an exact two-sided
/// Student-t `pValue` are computed per pair, and a Benjamini-Hochberg
/// FDR-adjusted `qValue` is applied across all pairs tested. Only pairs that
/// survive `n ≥ minPairs`, `pValue < 0.05`, AND the BH-FDR control surface.
///
/// **Descriptive, NEVER causal.** Every surfaced pair is a statistical
/// *association*, not a cause/effect claim. The `interpretation` string is the
/// server's own conservative, descriptive framing; iOS mirrors that tone
/// verbatim and adds no causal language of its own.
///
/// **HONEST-ONLY.** The block renders ONLY the pairs the server returns; it
/// never fabricates a correlation. An empty `discovered` array is a valid
/// "nothing statistically defensible yet" state — the block self-suppresses
/// rather than inventing a pair.
///
/// **Operator-gated.** The endpoint sits behind an operator `correlations`
/// assistant surface. A feature-off response (`404`/`422`) maps to `nil` at
/// the repository so the block hides gracefully (not an error, not a crash).
public struct CorrelationDiscoveryResponse: Codable, Sendable, Equatable {
    /// Pairs surviving `n ≥ minPairs`, `pValue < 0.05`, AND the BH-FDR control.
    ///
    /// **CU-33 — dismissed pairs are NOT filtered out here.** The route returns
    /// pairs the person marked as not relevant inline, carrying
    /// `dismissed: true`; suppressing them is the client's job (the web client
    /// does the same). `var` so an optimistic dismissal can be applied — and
    /// rolled back — in place.
    public var discovered: [DiscoveredCorrelation]
    /// Behaviour × outcome pairs assessed (for the honest footer).
    public let pairsTested: Int
    /// The FDR target the surface used (e.g. `0.1`).
    public let fdrQ: Double
    /// Minimum paired-day count enforced per pair.
    public let minPairs: Int

    public init(
        discovered: [DiscoveredCorrelation],
        pairsTested: Int,
        fdrQ: Double,
        minPairs: Int
    ) {
        self.discovered = discovered
        self.pairsTested = pairsTested
        self.fdrQ = fdrQ
        self.minPairs = minPairs
    }
}

/// One discovered behaviour → next-day-outcome association. Descriptive only.
public struct DiscoveredCorrelation: Codable, Sendable, Equatable, Identifiable {
    /// Behaviour channel (lag source), e.g. `TIME_IN_DAYLIGHT`, `MOOD`.
    public let behaviour: String
    /// Outcome channel (lag target), e.g. `SLEEP_DURATION`,
    /// `HEART_RATE_VARIABILITY`.
    public let outcome: String
    /// Paired-day count after the day+1 lag join (`≥ minPairs`).
    public let n: Int
    /// Pearson `r` over the lag-joined daily series (`-1…1`).
    public let r: Double
    /// Two-sided exact Student-t p-value (`< 0.05`).
    public let pValue: Double
    /// Benjamini-Hochberg FDR-adjusted q-value (`≤` the surface threshold).
    public let qValue: Double
    /// Conservative, descriptive interpretation — never causal (server prose).
    public let interpretation: String
    /// Lag in days applied (currently always `1`).
    public let lagDays: Int
    /// **CU-33 (server v1.34.0)** — the behaviour channel's user-facing name,
    /// already resolved and localized BY THE SERVER (it is the source of a
    /// custom metric's own name, and it is what the server's `interpretation`
    /// prose uses). Present only for channels the server can name; the view
    /// RENDERS it rather than re-deriving a label of its own, and falls back to
    /// the local curated table only when it is absent.
    public let behaviourLabel: String?
    /// **CU-33** — the outcome channel's server-resolved, server-localized
    /// name. Same contract as ``behaviourLabel``.
    public let outcomeLabel: String?
    /// **CU-33** — the persisted pattern row's id (cuid), the ONLY identifier
    /// `PATCH /api/insights/patterns/{id}` accepts. Optional on the wire: the
    /// server attaches it only when a stored decision exists for the evidence,
    /// and an older server omits it entirely. No `patternId` → no dismiss
    /// affordance (the app never invents a handle).
    public let patternId: String?
    /// **CU-33** — `p1:<64 hex>`, the user-independent identity of the
    /// `(behaviour, outcome, lagDays)` triple. Stable across recomputations and
    /// across surfaces (correlations, analytics and mood crosstabs mint the
    /// same key for the same triple), so it is the right local identity.
    public let canonicalKey: String?
    /// **CU-33** — whether the person has marked this pair as not relevant for
    /// them. **Server-authoritative and re-read on every fetch**: the GET that
    /// returns it is also the recomputation that may clear a dismissal, so the
    /// app never treats a local dismissal as durable truth. `var` so an
    /// optimistic toggle can be applied and rolled back in place.
    public var dismissed: Bool?

    /// Stable identity for `ForEach`. Prefers the server's ``canonicalKey``
    /// (the authoritative, recomputation-stable identity); falls back to the
    /// locally-derived triple when the server did not attach a decision, which
    /// yields the same identity for the same pair either way.
    public var id: String {
        canonicalKey ?? "\(behaviour)→\(outcome)@\(lagDays)"
    }

    /// The person marked this pair as not relevant for them. Absent field →
    /// not dismissed (an older server simply never dismisses anything).
    ///
    /// This is a statement about relevance, **not** a claim that the pair is
    /// wrong, and **not** a deletion — the server keeps the row and the person
    /// can take it back.
    public var isDismissed: Bool {
        dismissed == true
    }

    /// Whether the pair can be marked not-relevant / relevant-again at all —
    /// i.e. whether the server handed over a pattern handle.
    public var isDismissable: Bool {
        patternId != nil
    }

    public init(
        behaviour: String,
        outcome: String,
        n: Int,
        r: Double,
        pValue: Double,
        qValue: Double,
        interpretation: String,
        lagDays: Int,
        behaviourLabel: String? = nil,
        outcomeLabel: String? = nil,
        patternId: String? = nil,
        canonicalKey: String? = nil,
        dismissed: Bool? = nil
    ) {
        self.behaviour = behaviour
        self.outcome = outcome
        self.n = n
        self.r = r
        self.pValue = pValue
        self.qValue = qValue
        self.interpretation = interpretation
        self.lagDays = lagDays
        self.behaviourLabel = behaviourLabel
        self.outcomeLabel = outcomeLabel
        self.patternId = patternId
        self.canonicalKey = canonicalKey
        self.dismissed = dismissed
    }
}

public extension DiscoveredCorrelation {
    /// Direction of the association, derived from the sign of `r` only — a
    /// descriptive framing ("…goes with more / less…"), never causal.
    enum Direction: Sendable {
        case positive
        case negative
    }

    /// `r ≥ 0` → positive (the two move together), else negative (inverse).
    var direction: Direction {
        r >= 0 ? .positive : .negative
    }

    /// |r| magnitude bucket for the descriptive strength word. Conservative
    /// thresholds (web parity): weak < 0.3 ≤ moderate < 0.5 ≤ strong.
    enum Strength: Sendable {
        case weak
        case moderate
        case strong
    }

    var strength: Strength {
        let magnitude = abs(r)
        if magnitude < 0.3 { return .weak }
        if magnitude < 0.5 { return .moderate }
        return .strong
    }
}
