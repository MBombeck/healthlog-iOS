import Foundation

/// **v1.35.0 (GH #83) — the account's own recipe for the Health Score, as
/// `GET`/`PATCH /api/auth/me/health-score-config` speaks it.**
///
/// The score used to be composed for everybody the same way; since v1.35.0 a
/// person can decide which pillars count toward it. This type is the resolved
/// answer the server hands back — **never a config blob**. Both lists arrive in
/// the server's registry order, already reconciled against the catalogue, so
/// iOS renders them and computes nothing.
///
/// Note what is deliberately NOT here: whether the resulting score counts as
/// *configured*. That flag rides with the score itself
/// (``HealthScore/configured``), because it answers a different question — "is
/// this composition narrower than the account's own defaults resolve to today"
/// — and the server is the only place that can answer it.
public struct HealthScoreConfig: Decodable, Sendable, Equatable {
    /// The pillars that count toward the score, registry order.
    public let pillars: [HealthScorePillar]
    /// The pillars the person took out, registry order.
    public let excludedPillars: [HealthScorePillar]
    /// `true` once any selection has been written. Says the person *chose*, not
    /// that their choice differs from the default — an account that opened the
    /// surface and kept everything has a selection.
    public let hasSelection: Bool
    /// Per-account recipe version. `0` while nothing was ever chosen.
    public let version: Int
    /// When the recipe last moved, ISO 8601. `nil` while it never has.
    public let changedAt: String?
    /// **The optimistic-concurrency token — structurally absent, not `null`,
    /// while the person never chose.**
    ///
    /// The server omits the key entirely for an account without a stored
    /// selection, because there is nothing to guard the first write against.
    /// ``OptimisticWriteBody`` mirrors that: a `nil` token omits the key, and a
    /// `null` on the wire would earn a `422 invalid_base_updated_at`.
    public let updatedAt: String?

    public init(
        pillars: [HealthScorePillar],
        excludedPillars: [HealthScorePillar],
        hasSelection: Bool,
        version: Int,
        changedAt: String? = nil,
        updatedAt: String? = nil
    ) {
        self.pillars = pillars
        self.excludedPillars = excludedPillars
        self.hasSelection = hasSelection
        self.version = version
        self.changedAt = changedAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case pillars, excludedPillars, hasSelection, version, changedAt, updatedAt
    }

    /// Tolerant past the two lists: an unfamiliar pillar id degrades to
    /// ``HealthScorePillar/unknown(_:)`` rather than throwing the whole recipe
    /// away, and a missing bookkeeping field degrades to its "never chose"
    /// value instead of failing the read.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pillars = try c.decodeIfPresent([HealthScorePillar].self, forKey: .pillars) ?? []
        excludedPillars = try c.decodeIfPresent([HealthScorePillar].self, forKey: .excludedPillars) ?? []
        hasSelection = (try? c.decodeIfPresent(Bool.self, forKey: .hasSelection)) ?? false
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 0
        changedAt = try? c.decodeIfPresent(String.self, forKey: .changedAt)
        updatedAt = try? c.decodeIfPresent(String.self, forKey: .updatedAt)
    }
}

// MARK: - Write body

/// The `PATCH` body: the **positive** selection, because that is what a person
/// chooses. The server stores its complement, and that inversion happens once,
/// server-side, at the boundary — iOS never sends a deselection list.
public struct HealthScoreConfigPatchDTO: Encodable, Sendable, Equatable {
    public let pillars: [String]

    public init(pillars: [HealthScorePillar]) {
        self.pillars = pillars.map(\.rawValue)
    }
}

// MARK: - Refusal

/// **Why the server refused a selection** (`meta.reason` beside
/// `errorCode: "health_score_config.too_narrow"` on a `422`).
///
/// The lower bound is not a count of pillars but a count of *fields of health*,
/// and which pillar speaks to which field is server knowledge that does not
/// ride any wire. iOS therefore never predicts a refusal — it explains the one
/// it was given.
public enum HealthScoreBreadthReason: Sendable, Equatable, Hashable {
    /// Fewer than three distinct areas of health in the selection.
    case threeDomainsRequired
    /// Nothing in the selection rests on a physical measurement.
    case measuredPhysiologicalDomainRequired
    /// A reason this client does not know yet — explained neutrally rather
    /// than mislabelled as one of the two above.
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "three_domains_required": self = .threeDomainsRequired
        case "measured_physiological_domain_required": self = .measuredPhysiologicalDomainRequired
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .threeDomainsRequired: "three_domains_required"
        case .measuredPhysiologicalDomainRequired: "measured_physiological_domain_required"
        case let .unknown(raw): raw
        }
    }
}

/// The server error codes this surface answers to.
public enum HealthScoreConfigErrorCode {
    /// `422` — the selection cannot produce a score. Paired with a
    /// ``HealthScoreBreadthReason`` in `meta.reason`.
    public static let tooNarrow = "health_score_config.too_narrow"
    /// `422` — the body was malformed. A client bug, not a person's mistake.
    public static let invalid = "health_score_config.invalid"
}
