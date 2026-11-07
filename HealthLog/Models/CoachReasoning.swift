import Foundation

/// **1.5 COACH-R (server v1.41)** — how hard the Coach thinks before it answers.
public enum CoachReasoningLevel: String, Sendable, Equatable, CaseIterable, Codable {
    case off
    case low
    case medium
    case high

    /// The order the settings offer and the ceiling compares against.
    var rank: Int {
        Self.allCases.firstIndex(of: self) ?? 0
    }
}

/// `coachReasoning` on `GET /api/auth/me`: the Coach's thinking depth for the
/// signed-in person, resolved on the server from their choice, the operator's
/// switch and cap, who pays for the provider and what the provider can do.
///
/// Absent on a server older than v1.41: then the app offers no choice at all.
/// A level this build does not know makes the whole block unreadable (`nil`),
/// so the app never offers a choice it cannot represent.
public struct CoachReasoningState: Decodable, Sendable, Equatable {
    /// What a turn runs at right now, every cap applied.
    public let level: CoachReasoningLevel
    /// What the person picked (`medium` when never chosen). The picker binds here.
    public let preference: CoachReasoningLevel
    /// The highest level the settings may offer; `off` when switched off.
    public let maxLevel: CoachReasoningLevel
    /// `false`: the operator switched reasoning off or the provider cannot
    /// reason. The setting is then locked.
    public let available: Bool
    /// `false`: the provider cannot switch thinking off, so the lowest option
    /// is called "Minimal" instead of "Off".
    public let offIsReal: Bool
    /// Which layer decided `level` (`user`, `admin_off`, `admin_cap`,
    /// `cost_cap`, `unsupported`). Unknown values read as `nil`.
    public let source: String?

    public init(
        level: CoachReasoningLevel,
        preference: CoachReasoningLevel,
        maxLevel: CoachReasoningLevel,
        available: Bool,
        offIsReal: Bool,
        source: String? = nil
    ) {
        self.level = level
        self.preference = preference
        self.maxLevel = maxLevel
        self.available = available
        self.offIsReal = offIsReal
        self.source = source
    }

    /// The setting is locked: nothing can be chosen.
    public var isLocked: Bool {
        !available || maxLevel == .off
    }

    /// A level the picker may send: unlocked, and not above the ceiling.
    public func canChoose(_ candidate: CoachReasoningLevel) -> Bool {
        !isLocked && candidate.rank <= maxLevel.rank
    }

    /// The operator's ceiling or funding cap holds the level below the choice.
    public var isCapped: Bool {
        level != preference && (source == "admin_cap" || source == "cost_cap")
    }
}

/// Projection of `GET /api/auth/me` for the one field. An unreadable block is
/// `nil` and never fails the read.
struct AuthMeCoachReasoning: Decodable, Sendable {
    let coachReasoning: CoachReasoningState?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        coachReasoning = try? container.decodeIfPresent(CoachReasoningState.self, forKey: .coachReasoning)
    }

    private enum CodingKeys: String, CodingKey {
        case coachReasoning
    }
}
