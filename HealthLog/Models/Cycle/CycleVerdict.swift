import Foundation

// The resolved cycle verdict (server v1.35.2, `CycleVerdictDTO` in
// `docs/api/openapi.yaml` @ tag v1.35.2, engine `src/lib/cycle/verdict.ts`).
//
// **The rule this type exists to enforce: the client renders the verdict, it
// does not compute one.** `state`, `phase` and `overdueDays` arrive resolved.
// Everything the ring used to derive from the day series and the cycle length —
// "which phase is today", "how long is this cycle", "is the period late" — is
// now read off the wire. The server resolves `today` from the PROFILE timezone,
// which a client offline does not necessarily have; a day of slip in a forecast
// is a rounding error, a day of slip in "overdue" is a false statement about a
// person's body. That asymmetry is why the judgement half of the on-device
// engine is gone and only the prediction half remains (Z1 / #72).
//
// The grace window that decides `OVERDUE` is deliberately NOT published. Read
// `state` and `overdueDays`; do not reconstruct the threshold.

// MARK: - State

/// `{ IN_CYCLE | OVERDUE | INSUFFICIENT_DATA }` — what the record supports
/// saying about today.
///
/// - ``inCycle``: today sits inside a cycle whose day count is still an observed
///   fact. `dayOfCycle`, `phase` and `cycleStartDate` are all set.
/// - ``overdue``: the open cycle has run past the profile's typical length by
///   more than the server's grace window. `dayOfCycle` and `phase` are `null` on
///   purpose — past that point "day 71" would be a very confident number about
///   something nobody knows. `overdueDays` carries how late it is, measured
///   against the typical length (not typical + grace: someone asking how late
///   they are means their own cycle, not our tolerance).
/// - ``insufficientData``: today carries no phase at all.
public enum CycleVerdictState: String, Codable, Sendable, CaseIterable, Equatable {
    case inCycle = "IN_CYCLE"
    case overdue = "OVERDUE"
    case insufficientData = "INSUFFICIENT_DATA"
}

// MARK: - Phase span

/// One arc of the ring: a phase and its share of the represented cycle.
/// Fractions sum to ~1 — they are cut to the OBSERVED length, not to fixed
/// quarters, so the ring shows this person's cycle rather than a textbook one.
public struct CyclePhaseSpanDTO: Codable, Sendable, Equatable, Hashable {
    /// Raw phase string — see ``phaseValue``.
    public let phase: String
    public let fraction: Double

    public var phaseValue: CyclePhaseValue? {
        CyclePhaseValue(rawValue: phase)
    }

    public init(phase: String, fraction: Double) {
        self.phase = phase
        self.fraction = fraction
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        phase = try c.decodeIfPresent(String.self, forKey: .phase) ?? ""
        fraction = try c.decodeIfPresent(Double.self, forKey: .fraction) ?? 0
    }
}

// MARK: - Fertile window

/// The verdict's fertile-window block — already goal-gated upstream by the
/// server, plus whether today falls inside it.
public struct CycleVerdictFertileWindow: Codable, Sendable, Equatable, Hashable {
    public let start: String?
    public let end: String?
    public let active: Bool

    public init(start: String?, end: String?, active: Bool) {
        self.start = start
        self.end = end
        self.active = active
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        start = try c.decodeIfPresent(String.self, forKey: .start)
        end = try c.decodeIfPresent(String.self, forKey: .end)
        active = try c.decodeIfPresent(Bool.self, forKey: .active) ?? false
    }
}

// MARK: - The verdict

/// `data.verdict` of `GET /api/cycle/calendar` (server ≥ v1.35.2). Tolerant
/// decode like every other cycle DTO, so a server that adds a field later — or
/// one that predates the verdict entirely — never hard-fails the envelope.
public struct CycleVerdictDTO: Codable, Sendable, Equatable, Hashable {
    /// Raw state string — see ``stateValue``.
    public let state: String
    /// 1-based day of the current cycle. **Null in `OVERDUE` and
    /// `INSUFFICIENT_DATA`.**
    public let dayOfCycle: Int?
    /// Days the ring represents: the observed labelled run, or the
    /// profile-derived idealized cycle for a low-data tracker.
    public let cycleLength: Int?
    /// Raw phase string — see ``phaseValue``. **Null in `OVERDUE` and
    /// `INSUFFICIENT_DATA`.**
    public let phase: String?
    public let spans: [CyclePhaseSpanDTO]
    /// First day of the current cycle (`YYYY-MM-DD`). **Still set while
    /// `OVERDUE`** — the last logged period start stays a fact once the count
    /// stops.
    public let cycleStartDate: String?
    /// How many days past the profile's typical cycle length the open cycle has
    /// run. **Set only in `OVERDUE`.**
    public let overdueDays: Int?
    /// Days from today to the predicted next period start. Null when no
    /// prediction ran and null once that start is in the past.
    public let daysUntilNext: Int?
    public let fertileWindow: CycleVerdictFertileWindow

    public var stateValue: CycleVerdictState? {
        CycleVerdictState(rawValue: state)
    }

    public var phaseValue: CyclePhaseValue? {
        phase.flatMap(CyclePhaseValue.init)
    }

    public init(
        state: String,
        dayOfCycle: Int?,
        cycleLength: Int?,
        phase: String?,
        spans: [CyclePhaseSpanDTO],
        cycleStartDate: String?,
        overdueDays: Int?,
        daysUntilNext: Int?,
        fertileWindow: CycleVerdictFertileWindow
    ) {
        self.state = state
        self.dayOfCycle = dayOfCycle
        self.cycleLength = cycleLength
        self.phase = phase
        self.spans = spans
        self.cycleStartDate = cycleStartDate
        self.overdueDays = overdueDays
        self.daysUntilNext = daysUntilNext
        self.fertileWindow = fertileWindow
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? CycleVerdictState.insufficientData.rawValue
        dayOfCycle = try c.decodeIfPresent(Int.self, forKey: .dayOfCycle)
        cycleLength = try c.decodeIfPresent(Int.self, forKey: .cycleLength)
        phase = try c.decodeIfPresent(String.self, forKey: .phase)
        spans = try c.decodeIfPresent([CyclePhaseSpanDTO].self, forKey: .spans) ?? []
        cycleStartDate = try c.decodeIfPresent(String.self, forKey: .cycleStartDate)
        overdueDays = try c.decodeIfPresent(Int.self, forKey: .overdueDays)
        daysUntilNext = try c.decodeIfPresent(Int.self, forKey: .daysUntilNext)
        fertileWindow = try c.decodeIfPresent(CycleVerdictFertileWindow.self, forKey: .fertileWindow)
            ?? CycleVerdictFertileWindow(start: nil, end: nil, active: false)
    }
}

// MARK: - The stored snapshot (offline)

/// **The last verdict the SERVER sent, with the moment the server computed it.**
///
/// Offline the cycle ring shows this — dated — instead of a freshly invented
/// assessment. A verdict is a statement about one specific day resolved in the
/// user's PROFILE timezone; recomputing it on a device that may sit in another
/// zone, from a cache that may be a day old, produces a number that looks
/// current and can be wrong by a day. "As of yesterday 14:20" is the honest
/// version of the same information.
///
/// ``asOf`` is the server's own `meta.generatedAt`, not the moment we read the
/// row: the calendar can be served from the persistent SWR cache, so "when we
/// received it" would overstate its freshness.
public struct CycleVerdictSnapshot: Codable, Sendable, Equatable {
    public let verdict: CycleVerdictDTO
    /// When the SERVER computed this verdict (`meta.generatedAt`).
    public let asOf: Date

    public init(verdict: CycleVerdictDTO, asOf: Date) {
        self.verdict = verdict
        self.asOf = asOf
    }

    /// **How long this verdict may still be shown, derived from the verdict
    /// itself — no chosen constant.**
    ///
    /// The bound is not "how old feels too old"; it is "when can this sentence
    /// no longer be true". Every number in a verdict is a per-day quantity —
    /// `dayOfCycle` counts up, `daysUntilNext` counts down — so a stored verdict
    /// is a statement about a past day and is shown with its date. The question
    /// is when even the dated statement stops carrying information:
    ///
    /// - ``CycleVerdictState/inCycle`` — the verdict describes a cycle that, by
    ///   its own forecast, ends in `daysUntilNext` days. Once that many days
    ///   have passed, the described cycle is over: the verdict can no longer
    ///   tell whether the period arrived on time or is now late, which is the
    ///   one thing the reader would take from it. This is exactly the failure
    ///   the operator named — a week-old "everything is within range" is worse
    ///   than no statement — and the horizon that catches it is the verdict's
    ///   own, not a round number. When no prediction ran, the remaining days of
    ///   the drawn cycle (`cycleLength − dayOfCycle`) carry the same meaning.
    ///   When neither is known there is nothing to bound it with, so it is valid
    ///   for the day it was made and no longer.
    /// - ``CycleVerdictState/overdue`` — open-ended. "The record holds an open
    ///   cycle that has run past your usual length" does not become false by
    ///   waiting; it only becomes more so. Hiding a late-period statement
    ///   because it aged would fail in the one direction that matters. The
    ///   `overdueDays` count is dated on screen rather than aged forward.
    /// - ``CycleVerdictState/insufficientData`` — open-ended. "Not enough logged
    ///   yet" is not invalidated by the passage of time either.
    public enum Horizon: Equatable, Sendable {
        /// The statement does not expire from age alone.
        case openEnded
        /// Valid for at most this many whole days after ``asOf``.
        case days(Int)
    }

    public var horizon: Horizon {
        switch verdict.stateValue {
        case .overdue, .insufficientData:
            .openEnded
        case .inCycle, nil:
            if let until = verdict.daysUntilNext, until >= 0 {
                .days(until)
            } else if let length = verdict.cycleLength, let day = verdict.dayOfCycle, length > day {
                .days(length - day)
            } else {
                .days(0)
            }
        }
    }

    /// Whole days elapsed since ``asOf``. Measured as a plain duration, not as a
    /// calendar-day difference: a day boundary depends on a timezone, and the
    /// timezone this verdict was resolved in is the profile's, which is the very
    /// thing an offline device may not have. A duration needs no zone.
    public func elapsedDays(now: Date = .now) -> Int {
        max(0, Int(now.timeIntervalSince(asOf) / 86400))
    }

    /// Whether this stored verdict may still be put on screen (always with its
    /// date — see ``horizon``).
    public func isShowable(now: Date = .now) -> Bool {
        switch horizon {
        case .openEnded: true
        case let .days(limit): elapsedDays(now: now) <= limit
        }
    }
}
