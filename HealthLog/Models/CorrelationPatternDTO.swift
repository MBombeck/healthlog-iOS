import Foundation

/// Wire-form mirror of one persisted `CorrelationPattern` row from
/// `GET /api/insights/patterns` (server v1.34.0, route at
/// `src/app/api/insights/patterns/route.ts`).
///
/// **What it is.** The server's durable *decision ledger* over discovered
/// behaviour × outcome pairs: one row per `(factorKey, outcomeKey, lagDays)`
/// triple per account, carrying the evidence of the last recomputation plus
/// whether the person has marked the pair as not relevant for them
/// (`dismissedAt != nil`).
///
/// **Closed 13-field shape.** The route serializes a spread over exactly its
/// `select` block, so this mirror is complete: `userId`, `isCurrent`,
/// `dismissedEvidenceHash`, `dismissedEffectSize`, `dismissedSampleSize`,
/// `createdAt` and `updatedAt` exist as columns but are deliberately NOT on the
/// wire.
///
/// **DESCRIPTIVE, NEVER CAUSAL.** A row is a statistical association over one
/// person's own behaviour and measurements — never a cause/effect claim and
/// never advice. iOS renders the server's framing and adds none of its own.
///
/// **No status / direction / strength enum exists on this row.** "Strength" is
/// the signed ``effectSize``; "dismissed" is `dismissedAt != nil`. The
/// `high | moderate | faint` tier lives only on the correlations payload.
public struct CorrelationPattern: Codable, Sendable, Equatable, Identifiable {
    /// Prisma row id (cuid). **Account-bound**, and the ONLY identifier
    /// `PATCH /api/insights/patterns/{id}` accepts — ``canonicalKey`` is not a
    /// valid path parameter.
    public let id: String
    /// `p1:<64 hex>` — a deterministic, *user-independent* sha256 over exactly
    /// `[factorKey, outcomeKey, lagDays]`. Stable across recomputations, across
    /// changes in sample size / effect size / p-value, across a `family` switch
    /// and even across accounts. Use it for local identity, dedup and diffing.
    public let canonicalKey: String
    /// Which discovery family surfaced the pair. Postgres stores a bare string,
    /// so this stays an OPEN string with five known literals — see
    /// ``KnownFamily``. An unknown value must never break decoding.
    public let family: String
    /// Behaviour channel (the lag source), e.g. `TIME_IN_DAYLIGHT`.
    public let factorKey: String
    /// Outcome channel (the lag target), e.g. `SLEEP_DURATION`.
    public let outcomeKey: String
    /// Lag in days applied when joining behaviour-day to outcome-day.
    public let lagDays: Int
    /// Paired-day count behind the current evidence.
    public let sampleSize: Int
    /// Signed effect size — Pearson `r` for the discovery families, a signed
    /// delta for the crosstab families.
    public let effectSize: Double
    /// Two-sided p-value of the current evidence.
    public let pValue: Double
    /// Benjamini-Hochberg adjusted q-value. **Nullable** (`Float?` in the
    /// schema) — the crosstab families do not always carry one.
    public let qValue: Double?
    /// sha256 over the current evidence tuple. Written and returned, but read
    /// by NO server decision — never build client logic on it.
    public let evidenceHash: String
    /// When the evidence was last recomputed (ISO-8601 UTC on the wire).
    public let lastComputedAt: Date
    /// When the person marked the pair as not relevant, or `nil` when they
    /// have not. Server-authoritative — see ``isDismissed``.
    public let dismissedAt: Date?

    /// The five families the server currently mints. Modelled as a *lookup on
    /// an open string* rather than as the stored type, so a sixth family
    /// shipped by the server decodes cleanly instead of failing the row.
    public enum KnownFamily: String, Sendable, CaseIterable {
        case discoveryRetrospective = "DISCOVERY_RETROSPECTIVE"
        case discoveryRecent = "DISCOVERY_RECENT"
        case fixed = "FIXED"
        case moodTagCrosstab = "MOOD_TAG_CROSSTAB"
        case moodFactorCrosstab = "MOOD_FACTOR_CROSSTAB"
    }

    /// The parsed ``family``, or `nil` for a literal this build does not know.
    public var knownFamily: KnownFamily? {
        KnownFamily(rawValue: family)
    }

    /// The person marked this pair as not relevant for them. **Not** a claim
    /// that the pair is wrong, and not a deletion — the row survives.
    public var isDismissed: Bool {
        dismissedAt != nil
    }

    /// Whether this row is the ledger entry for a given discovered pair. The
    /// unique identity of a pattern is the `(factor, outcome, lag)` triple —
    /// `family` is deliberately excluded, so one triple discovered under two
    /// families shares ONE row and ONE dismissal.
    public func matches(factorKey: String, outcomeKey: String, lagDays: Int) -> Bool {
        self.factorKey == factorKey && self.outcomeKey == outcomeKey && self.lagDays == lagDays
    }

    public init(
        id: String,
        canonicalKey: String,
        family: String,
        factorKey: String,
        outcomeKey: String,
        lagDays: Int,
        sampleSize: Int,
        effectSize: Double,
        pValue: Double,
        qValue: Double?,
        evidenceHash: String,
        lastComputedAt: Date,
        dismissedAt: Date?
    ) {
        self.id = id
        self.canonicalKey = canonicalKey
        self.family = family
        self.factorKey = factorKey
        self.outcomeKey = outcomeKey
        self.lagDays = lagDays
        self.sampleSize = sampleSize
        self.effectSize = effectSize
        self.pValue = pValue
        self.qValue = qValue
        self.evidenceHash = evidenceHash
        self.lastComputedAt = lastComputedAt
        self.dismissedAt = dismissedAt
    }
}

/// Envelope payload of `GET /api/insights/patterns` — the wrapper key is
/// `data.patterns`.
///
/// The route takes NO input: no query parameters, no pagination, no limit. It
/// filters to `isCurrent = true` and sorts `lastComputedAt DESC, canonicalKey
/// ASC`. **Dismissed rows are included** — there is no `dismissedAt` filter, so
/// the client distinguishes on ``CorrelationPattern/isDismissed``.
public struct CorrelationPatternsResponse: Codable, Sendable, Equatable {
    public let patterns: [CorrelationPattern]

    public init(patterns: [CorrelationPattern]) {
        self.patterns = patterns
    }
}

/// The 200 body of `PATCH /api/insights/patterns/{id}` — a five-field delta,
/// NOT the full pattern row. Whoever needs the updated row re-reads
/// `GET /api/insights/patterns`.
public struct CorrelationPatternDismissal: Codable, Sendable, Equatable {
    public let id: String
    public let canonicalKey: String
    /// The state the server actually settled on. Authoritative — the optimistic
    /// UI reconciles against this value rather than against what it sent.
    public let dismissed: Bool
    public let dismissedAt: Date?
    public let evidenceHash: String

    public init(
        id: String,
        canonicalKey: String,
        dismissed: Bool,
        dismissedAt: Date?,
        evidenceHash: String
    ) {
        self.id = id
        self.canonicalKey = canonicalKey
        self.dismissed = dismissed
        self.dismissedAt = dismissedAt
        self.evidenceHash = evidenceHash
    }
}
