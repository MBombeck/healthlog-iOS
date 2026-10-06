import Foundation

/// Wire-form mirror of `GET /api/daily/digest` → the **`DailyDigest`** DTO
/// (server `src/lib/daily/digest.ts`, OpenAPI `DailyDigest` /
/// `DailyPriorityItem`).
///
/// **The one data spine of the daily-value system.** The server assembles it
/// from ALREADY-CACHED data (the nightly briefing lifted read-only from
/// `User.insightsCachedText`, the dashboard-snapshot health-score / meds-today /
/// sleep-freshness, plus two light deterministic reads). No AI/provider call is
/// reachable from this path. iOS **renders it verbatim** — it NEVER recomputes
/// the score, band, delta, or the rail, and NEVER warms an AI surface on mount.
///
/// **Tolerant decode (server-drift safe).** Every field decodes through
/// `decodeIfPresent` with a sane floor, and `worthALook` decodes *lossily* — a
/// single malformed rail item is skipped rather than nuking the whole hero — so
/// a newer server that adds a rail `kind` or a field iOS doesn't yet model still
/// paints the read + the items it understands. `kind` / `status` / `tone` /
/// `phase` are carried as raw strings and mapped to closed enums only at render
/// time, so an unknown token degrades to "no icon / no wash" instead of a
/// decode failure.
public struct DailyDigest: Codable, Sendable, Equatable {
    /// ISO-8601 instant the digest was read (carried as a string — the hero
    /// never renders it, so no Date coupling / formatter is introduced).
    public let generatedAt: String
    /// Freshness lifecycle — `"final"` once last night's sleep is in, else
    /// `"provisional"`. Raw string; unknown tokens read as provisional.
    public let phase: String
    /// Honest-degradation flag: sleep tracked but last night not yet recorded.
    public let sleepPending: Bool
    /// Health score + band + week-over-week delta; `nil` when none — zero
    /// available inputs. The hero then renders NO ring at all (25-02,
    /// E-2026-08-29 #2: no provisional face, no explainer), never a zero.
    public let score: Score?
    /// The clinical-priority top signal, lifted from the cached briefing.
    public let topSignal: TopSignal?
    /// First sentence of the cached briefing paragraph; `nil` when absent.
    public let briefingLead: String?
    /// The push / lock-screen line (cached-AI lead with a deterministic floor).
    /// NOT rendered by the hero directly — it is the fallback for `lead`.
    public let line: String
    /// Bounded 0–3 rail items, never padded (defensively re-bounded in `rail`).
    public let worthALook: [DailyPriorityItem]
    /// **#114 / #115 · 0.2 — the three AI capabilities the digest carries text
    /// or a card for** (server v1.39, required there): `briefing` (the lead and
    /// the top signal), `coach` (the Coach check-in card) and `reactionLines`.
    /// `nil` on an older server — then nothing is masked. Everything else in the
    /// digest is data and renders whatever this says.
    public let ai: DigestAI?

    /// The digest's `ai` block. Each member is optional so a partial or
    /// malformed block masks only what it can prove unavailable.
    public struct DigestAI: Codable, Sendable, Equatable {
        public let briefing: AICapabilityState?
        public let coach: AICapabilityState?
        public let reactionLines: AICapabilityState?

        public init(
            briefing: AICapabilityState? = nil,
            coach: AICapabilityState? = nil,
            reactionLines: AICapabilityState? = nil
        ) {
            self.briefing = briefing
            self.coach = coach
            self.reactionLines = reactionLines
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            briefing = try? c.decodeIfPresent(AICapabilityState.self, forKey: .briefing)
            coach = try? c.decodeIfPresent(AICapabilityState.self, forKey: .coach)
            reactionLines = try? c.decodeIfPresent(AICapabilityState.self, forKey: .reactionLines)
        }
    }

    /// The health score envelope. `band` is a `"green" | "yellow" | "red"`
    /// token (server-authoritative) mapped to the monochrome ring's cap-dot
    /// signal at render time; `delta` is the week-over-week numeric delta.
    public struct Score: Codable, Sendable, Equatable {
        public let value: Double
        public let band: String
        public let delta: Double?
        /// **v1.35.0 — the server-resolved "this composition was chosen" flag**,
        /// carried straight through from the snapshot's health-score block. The
        /// hero shows the number on its own, so it is the surface that has to
        /// say where the number's composition came from.
        ///
        /// Optional, and absence is not `false`: an older server or an older
        /// cached digest simply never said, and an untold flag must not be
        /// painted as a claim about the account.
        public let configured: Bool?

        public init(value: Double, band: String, delta: Double?, configured: Bool? = nil) {
            self.value = value
            self.band = band
            self.delta = delta
            self.configured = configured
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            value = try c.decodeIfPresent(Double.self, forKey: .value) ?? 0
            band = try c.decodeIfPresent(String.self, forKey: .band) ?? ""
            delta = try c.decodeIfPresent(Double.self, forKey: .delta)
            configured = try? c.decodeIfPresent(Bool.self, forKey: .configured)
        }

        /// See ``HealthScore/runsOnChosenComposition`` — same gate, same reason.
        public var runsOnChosenComposition: Bool {
            configured == true
        }
    }

    /// The top signal. `delta` is a PRE-FORMATTED string ("+3", "−2 bpm") —
    /// rendered verbatim, never parsed.
    public struct TopSignal: Codable, Sendable, Equatable {
        public let sourceMetric: String
        public let tone: String
        public let headline: String
        public let nudge: String
        public let delta: String?

        public init(sourceMetric: String, tone: String, headline: String, nudge: String, delta: String?) {
            self.sourceMetric = sourceMetric
            self.tone = tone
            self.headline = headline
            self.nudge = nudge
            self.delta = delta
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sourceMetric = try c.decodeIfPresent(String.self, forKey: .sourceMetric) ?? ""
            tone = try c.decodeIfPresent(String.self, forKey: .tone) ?? "info"
            headline = try c.decodeIfPresent(String.self, forKey: .headline) ?? ""
            nudge = try c.decodeIfPresent(String.self, forKey: .nudge) ?? ""
            delta = try c.decodeIfPresent(String.self, forKey: .delta)
        }
    }

    public init(
        generatedAt: String,
        phase: String,
        sleepPending: Bool,
        score: Score?,
        topSignal: TopSignal?,
        briefingLead: String?,
        line: String,
        worthALook: [DailyPriorityItem],
        ai: DigestAI? = nil
    ) {
        self.generatedAt = generatedAt
        self.phase = phase
        self.sleepPending = sleepPending
        self.score = score
        self.topSignal = topSignal
        self.briefingLead = briefingLead
        self.line = line
        self.worthALook = worthALook
        self.ai = ai
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try c.decodeIfPresent(String.self, forKey: .generatedAt) ?? ""
        phase = try c.decodeIfPresent(String.self, forKey: .phase) ?? "provisional"
        sleepPending = try c.decodeIfPresent(Bool.self, forKey: .sleepPending) ?? false
        score = try c.decodeIfPresent(Score.self, forKey: .score)
        topSignal = try c.decodeIfPresent(TopSignal.self, forKey: .topSignal)
        briefingLead = try c.decodeIfPresent(String.self, forKey: .briefingLead)
        line = try c.decodeIfPresent(String.self, forKey: .line) ?? ""
        worthALook = try c.decodeLossyArray(DailyPriorityItem.self, forKey: .worthALook)
        ai = try? c.decodeIfPresent(DigestAI.self, forKey: .ai)
    }
}

// MARK: - Render-time derivations (never mutate the server payload)

public extension DailyDigest {
    /// §2.4 freshness — `true` while the day is still provisional.
    var isProvisional: Bool {
        phase != "final"
    }

    /// #115 · 0.2 — whether model-written briefing text (the lead and the top
    /// signal) may be shown. The server already nulls both while `briefing` is
    /// unavailable; this keeps a body that says otherwise from painting them.
    var showsBriefingText: Bool {
        ai?.briefing?.isAvailable ?? true
    }

    /// The briefing lead is the warmest read; the deterministic `line` is the
    /// floor a keyless self-hoster still gets. Prefer the lead for the hero.
    var lead: String {
        if showsBriefingText, let briefingLead, !briefingLead.isEmpty { return briefingLead }
        return line
    }

    /// True when a cached briefing actually backs the lead (drives the
    /// "read the full briefing" affordance).
    var hasBriefingLead: Bool {
        guard showsBriefingText, let briefingLead else { return false }
        return !briefingLead.isEmpty
    }

    /// The top signal, or `nil` while the `briefing` capability is unavailable
    /// (it is lifted from the briefing).
    var visibleTopSignal: TopSignal? {
        showsBriefingText ? topSignal : nil
    }

    /// Calm degrade (plan §3): a genuinely empty account — no score, no rail
    /// items, no cached briefing lead — surfaces NOTHING. The tile strip below
    /// carries its own "add your first reading" empty state.
    var isEmptyDegrade: Bool {
        score == nil && worthALook.isEmpty && !hasBriefingLead
    }

    /// Defensive re-bound of the rail to the documented 0–3 ceiling — the
    /// server never pads past it, but the hero never renders a fourth card.
    ///
    /// #115 · 0.2 — the Coach check-in card opens the Coach, so it is dropped
    /// while the digest says `coach` is unavailable (the server does not build
    /// it then; this covers a body that still carries one).
    var rail: [DailyPriorityItem] {
        let coachAvailable = ai?.coach?.isAvailable ?? true
        let admitted = worthALook.filter { coachAvailable || $0.kindToken != .coachCheckin }
        return Array(admitted.prefix(3))
    }
}

// MARK: - Priority item

/// One "worth a look" rail item — the single model every daily-value consumer
/// renders through the priority card. `title` / `body` arrive ALREADY LOCALIZED
/// from the server; only the action `labelKey`s resolve client-side.
public struct DailyPriorityItem: Codable, Sendable, Equatable {
    /// Closed rail-item kind, carried raw (mapped to `Kind` at render time).
    public let kind: String
    /// Stable dismiss identity, namespaced `<kind>:…`. Present ONLY on the
    /// observational kinds (milestone / ecg_new_recording / tension_window /
    /// same_time_baseline — the OpenAPI note that lists only the first three is
    /// stale, `priority-item.ts:60-65` carries four).
    public let itemKey: String?
    /// Localized headline (resolved server-side).
    public let title: String
    /// Grounded one-liner, plain text (resolved server-side).
    public let body: String?
    /// Semantic status wash — meaning, not decoration.
    public let status: String?
    /// 1–3 one-tap actions.
    public let actions: [Action]
    /// Provenance of the gate that admitted the item.
    public let moduleKey: String?

    /// One tappable action. `href` is the web deep-link (mapped to a native
    /// route by intent); `labelKey` resolves against the iOS string catalog.
    public struct Action: Codable, Sendable, Equatable {
        public let labelKey: String
        public let intent: String
        public let href: String?

        public init(labelKey: String, intent: String, href: String?) {
            self.labelKey = labelKey
            self.intent = intent
            self.href = href
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            labelKey = try c.decodeIfPresent(String.self, forKey: .labelKey) ?? ""
            intent = try c.decodeIfPresent(String.self, forKey: .intent) ?? ""
            href = try c.decodeIfPresent(String.self, forKey: .href)
        }
    }

    public init(
        kind: String,
        itemKey: String?,
        title: String,
        body: String?,
        status: String?,
        actions: [Action],
        moduleKey: String?
    ) {
        self.kind = kind
        self.itemKey = itemKey
        self.title = title
        self.body = body
        self.status = status
        self.actions = actions
        self.moduleKey = moduleKey
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        itemKey = try c.decodeIfPresent(String.self, forKey: .itemKey)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        body = try c.decodeIfPresent(String.self, forKey: .body)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        actions = try c.decodeLossyArray(Action.self, forKey: .actions)
        moduleKey = try c.decodeIfPresent(String.self, forKey: .moduleKey)
    }
}

public extension DailyPriorityItem {
    /// The closed rail-item kind — `nil` for a token iOS doesn't yet model
    /// (renders without a leading icon rather than failing).
    enum Kind: String, Sendable {
        case coachCheckin = "coach_checkin"
        case doseWindow = "dose_window"
        case preventiveCare = "preventive_care"
        case syncIssue = "sync_issue"
        case milestone
        case ecgNewRecording = "ecg_new_recording"
        case tensionWindow = "tension_window"
        /// CU-30 / C5 (server v1.34.0) — today's cumulative total against the
        /// operator's own typical standing at the SAME hour of day. Emitted for
        /// steps only, and only when the day is OUTSIDE the typical band
        /// (`digest.ts:581-606`). **No number crosses the wire on this card** —
        /// `title`/`body` arrive with the figures already baked in and
        /// localized; the derived endpoint is where the numbers live.
        case sameTimeBaseline = "same_time_baseline"
    }

    /// The semantic status wash — `nil` for an unknown token (no wash).
    enum Status: String, Sendable {
        case success, warning, info, destructive
    }

    var kindToken: Kind? {
        Kind(rawValue: kind)
    }

    var statusToken: Status? {
        status.flatMap(Status.init(rawValue:))
    }

    /// Dismiss is offered ONLY on the observational kinds, and only once the
    /// server has stamped an `itemKey` — the actionable kinds never carry one.
    ///
    /// CU-30 — `same_time_baseline` is the fourth dismissible kind
    /// (`priority-item.ts:60-65`). Its key is
    /// `same_time_baseline:<YYYY-MM-DD>:<MeasurementType>` and deliberately
    /// carries NO hour: the card's figures move through the day, and an hourly
    /// key would undo a dismissal every hour. Dismissing it means "not today".
    var isDismissible: Bool {
        guard let itemKey, !itemKey.isEmpty else { return false }
        switch kindToken {
        case .milestone, .ecgNewRecording, .tensionWindow, .sameTimeBaseline: return true
        default: return false
        }
    }

    /// Bounded to 3 (defence-in-depth; the server already caps at 3).
    var boundedActions: [Action] {
        Array(actions.prefix(3))
    }
}
