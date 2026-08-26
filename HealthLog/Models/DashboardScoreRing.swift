import Foundation

/// **v1.27.7 — the closed set of hero score-ring ids.**
///
/// Mirrors the server `SCORE_RING_IDS` (`src/lib/dashboard-layout.ts`) — the
/// only ids a user may feature as a dashboard hero ring. `selectedScoreRings`
/// persists a subset (max ``maxSelected``) of these via the widgets PUT; the
/// snapshot resolves them into ``DashboardScoreRing`` rows for TODAY.
///
/// Codable via the raw value: an unknown raw (a future server ring id) THROWS,
/// which the tolerant ``DashboardScoreRing`` array decode skips — so a new
/// server ring never poisons the whole array.
public enum ScoreRingID: String, Codable, Sendable, CaseIterable, Hashable {
    case readiness = "READINESS"
    case recovery = "RECOVERY_SCORE"
    case sleepScore = "SLEEP_SCORE"
    case medCompliance = "MED_COMPLIANCE"

    /// Server `MAX_SELECTED_SCORE_RINGS` — at most three rings on the hero.
    public static let maxSelected = 3

    /// Server `DEFAULT_SELECTED_SCORE_RINGS` — the resolver's default when the
    /// user has never chosen (medication progress is the one ring that needs no
    /// wearable). Used to pre-select the picker when the layout carries none.
    public static let defaultSelection: [ScoreRingID] = [.medCompliance]

    /// Localized short label under the hero ring + in the selection UI. Reuses
    /// the existing derived-score title keys where they exist so the hero and
    /// the Insights score cards read the same names.
    public var label: String {
        switch self {
        case .readiness: String(localized: "Daily condition")
        case .recovery: String(localized: "Recovery")
        case .sleepScore: String(localized: "Sleep score")
        case .medCompliance: String(localized: "Medication")
        }
    }
}

/// **v1.27.27 / parity Build 4 · 4.8 — a member of the hero ring ORDER.**
///
/// Mirrors the server `HERO_RING_IDS` (`src/lib/dashboard-layout.ts:414`): the
/// health-score anchor plus the selectable ``ScoreRingID`` set. The anchor has
/// no on/off toggle — it is always present — but it IS positionable, which is
/// the whole point of `heroRingOrder`: "always start with the health score by
/// default, but let the user reorder" (server comment, `:420-426`).
public enum HeroRingID: String, Codable, Sendable, CaseIterable, Hashable {
    /// Server `HEALTH_SCORE_RING_ID` — the anchor ring, always in the order.
    case healthScore = "HEALTH_SCORE"
    case readiness = "READINESS"
    case recovery = "RECOVERY_SCORE"
    case sleepScore = "SLEEP_SCORE"
    case medCompliance = "MED_COMPLIANCE"

    /// Server `MAX_HERO_RING_ORDER` — the anchor plus up to three score rings.
    public static let maxOrderLength = ScoreRingID.maxSelected + 1

    /// The hero-order member for a selectable score ring.
    public init(_ ring: ScoreRingID) {
        switch ring {
        case .readiness: self = .readiness
        case .recovery: self = .recovery
        case .sleepScore: self = .sleepScore
        case .medCompliance: self = .medCompliance
        }
    }

    /// The selectable score ring behind this member, or `nil` for the anchor.
    public var scoreRing: ScoreRingID? {
        ScoreRingID(rawValue: rawValue)
    }

    /// Localized label — the anchor's own name, else the score ring's.
    public var label: String {
        scoreRing?.label ?? String(localized: "Health score", comment: "Hero anchor ring label")
    }

    /// Server `resolveHeroRingOrder` (`dashboard-layout.ts:457-478`) mirrored
    /// client-side: keep the entries that are actually available (the anchor
    /// plus the CURRENT selection), dedupe, then append any available id the
    /// stored order never mentioned. A stale or over-long array is clamped, not
    /// rejected — exactly what the server does on read.
    public static func resolved(
        order: [HeroRingID]?,
        selected: [ScoreRingID]
    ) -> [HeroRingID] {
        let available = [HeroRingID.healthScore] + selected.map(HeroRingID.init)
        let availableSet = Set(available)
        var seen = Set<HeroRingID>()
        var out = (order ?? []).filter { availableSet.contains($0) && seen.insert($0).inserted }
        out += available.filter { !seen.contains($0) }
        return Array(out.prefix(maxOrderLength))
    }
}

/// **v1.27.7 — one resolved hero score ring off `GET /api/dashboard/snapshot`.**
///
/// Wire-mirror of a `scoreRings[]` element (server `DashboardSnapshotResponse`,
/// `docs/api/openapi.yaml`). The server resolves each user-selected ring for
/// TODAY and returns ONLY the rings that have data, in selection order — a
/// missing entry means "no data or a disabled module", NEVER zero.
///
/// iOS **renders only**. READINESS / RECOVERY_SCORE / SLEEP_SCORE ride the
/// derived engines; MED_COMPLIANCE is today's dose progress off the
/// server-ledger `medsToday` tally (`score` = rounded 0..100 progress, `doses`
/// = the taken/scheduled pair, band green/yellow only — never red). Never
/// recompute client-side (PROJECT_GUIDE.md Med-Compliance rule).
public struct DashboardScoreRing: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let id: ScoreRingID
    /// Server-rounded 0..100 score (dose progress for MED_COMPLIANCE).
    public let score: Int
    /// Server band token — `green` / `yellow` / `red`. Rendered as-is via the
    /// signal-dot mapping; MED_COMPLIANCE never emits `red`.
    public let band: String
    /// MED_COMPLIANCE only — today's dose tally behind the progress score, for a
    /// "taken/scheduled" ring label (e.g. 1/3). `nil` on the derived rings.
    public let doses: Doses?

    public struct Doses: Codable, Sendable, Equatable, Hashable {
        public let taken: Int
        public let scheduled: Int

        public init(taken: Int, scheduled: Int) {
            self.taken = taken
            self.scheduled = scheduled
        }
    }

    public init(id: ScoreRingID, score: Int, band: String, doses: Doses? = nil) {
        self.id = id
        self.score = score
        self.band = band
        self.doses = doses
    }

    /// 0…1 ring fill (`score ÷ 100`, clamped). Never extrapolated.
    public var fraction: Double {
        max(0, min(1, Double(score) / 100))
    }

    /// The short label under the ring.
    public var label: String {
        id.label
    }

    /// MED_COMPLIANCE "taken/scheduled" caption (e.g. "1/3"), or `nil` for the
    /// derived rings (their caption is the band word, resolved by the view).
    public var dosesCaption: String? {
        guard let doses else { return nil }
        return "\(doses.taken)/\(doses.scheduled)"
    }
}

// MARK: - Tolerant array decode

public extension DashboardScoreRing {
    /// Lossy per-element wrapper: a ring whose `id` is outside this client's
    /// closed ``ScoreRingID`` set (a future server ring) decodes to `nil` and is
    /// dropped, so one unknown id never throws away the whole `scoreRings`
    /// array. Selection order is preserved for the survivors.
    struct SkipUnknown: Decodable, Sendable {
        public let ring: DashboardScoreRing?

        public init(from decoder: Decoder) throws {
            ring = try? DashboardScoreRing(from: decoder)
        }
    }
}
