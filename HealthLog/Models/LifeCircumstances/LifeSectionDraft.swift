import Foundation

/// **LIFE (1.5.0, #132)** — the editable answers of one section and the
/// writes that turn them into server state.
///
/// One section is one decision about one part of a life, so it saves as a
/// whole (like the web): every kind of the section is compared with its
/// current revision and becomes a POST (first answer), a PATCH (a dated
/// successor) or a DELETE (cleared to "no answer"). Unchanged kinds send
/// nothing.
///
/// Two protections, both on purpose:
/// - An answer this build cannot read in full (``LifeFactValue/unsupported``)
///   is never written over: its kind sends nothing, whatever the form holds.
/// - An unreadable answer (``LifeFactValue/unreadable``) is replaced only
///   when the person enters a new answer for it; an empty form never deletes
///   it.
///
/// Follow-up questions only count where they apply: hidden answers are
/// dropped when the section is saved (cigarettes per day without cigarettes,
/// a quit month for anyone but a former smoker, night work without shift
/// work, the tobacco details of someone who never smoked).
public struct LifeSectionDraft: Equatable, Sendable {
    public let key: LifeSectionKey
    public var smokingStatus: AnamnesisFactValue?
    public var tobacco: LifeTobaccoDetail
    public var activity: LifeActivityHabit
    public var shiftSchedule: AnamnesisFactValue?
    public var work: LifeWorkContext
    public var freeWeekdays: LifeFreeWeekdays
    public var habits: LifeHabits
    public var goals: LifeHealthGoals

    public init(section: LifeSection) {
        key = section.key
        var smoking: AnamnesisFactValue?
        var shift: AnamnesisFactValue?
        var tobacco = LifeTobaccoDetail.empty
        var activity = LifeActivityHabit.empty
        var work = LifeWorkContext.empty
        var free = LifeFreeWeekdays.empty
        var habits = LifeHabits.empty
        var goals = LifeHealthGoals.empty
        for fact in section.facts {
            switch fact.value {
            case let .smokingStatus(value): smoking = value
            case let .shiftSchedule(value): shift = value
            case let .tobacco(value): tobacco = value
            case let .activity(value): activity = value
            case let .work(value): work = value
            case let .freeWeekdays(value): free = value
            case let .habits(value): habits = value
            case let .goals(value): goals = value
            case .unreadable, .unsupported: break
            }
        }
        smokingStatus = smoking
        shiftSchedule = shift
        self.tobacco = tobacco
        self.activity = activity
        self.work = work
        freeWeekdays = free
        self.habits = habits
        self.goals = goals
    }

    // MARK: - Follow-up rules

    /// Products, cigarettes and the start year are asked of everyone but a
    /// never-smoker (an unanswered status still asks them, like the web).
    public var asksTobaccoDetails: Bool {
        smokingStatus != .never
    }

    public var asksCigarettesPerDay: Bool {
        asksTobaccoDetails && tobacco.products.contains(.cigarettes)
    }

    /// The quit month is asked only of a former smoker (Server #1334).
    public var asksQuitMonth: Bool {
        smokingStatus == .former
    }

    public var asksNightWork: Bool {
        shiftSchedule == .fixedShift || shiftSchedule == .rotating
    }

    /// The draft as it is saved: hidden follow-up answers dropped.
    public var normalized: LifeSectionDraft {
        var copy = self
        if !asksTobaccoDetails {
            copy.tobacco.products = []
            copy.tobacco.startYear = nil
        }
        if !copy.asksCigarettesPerDay { copy.tobacco.cigarettesPerDay = nil }
        if !asksQuitMonth { copy.tobacco.quitMonth = nil }
        if !asksNightWork { copy.work.nightWork = nil }
        return copy
    }

    // MARK: - Writes

    /// The writes that bring `section` to this draft, in the section's kind
    /// order. `validFrom` (a calendar day, `YYYY-MM-DD`) dates every write
    /// back; `nil` means "from now".
    public func writes(against section: LifeSection, validFrom: String?) -> [LifeFactWrite] {
        let draft = normalized
        return key.kinds.compactMap { kind in
            draft.write(for: kind, current: section.fact(kind), validFrom: validFrom)
        }
    }

    /// `true` when saving would send at least one write.
    public func hasChanges(against section: LifeSection) -> Bool {
        !writes(against: section, validFrom: nil).isEmpty
    }

    private func write(for kind: LifeFactKind, current: LifeFact?, validFrom: String?) -> LifeFactWrite? {
        if current?.value == .unsupported { return nil }
        let next = wireValue(for: kind)
        guard let current else {
            return next.map { .create(kind: kind, value: $0, validFrom: validFrom) }
        }
        guard let next else {
            // Cleared to "no answer". An unreadable answer is not deleted by
            // an empty form: the person never saw it.
            return current.value == .unreadable ? nil : .remove(revisionID: current.id)
        }
        if current.isReadable, LifeFactWireValue(current.value) == next { return nil }
        return .correct(revisionID: current.id, kind: kind, value: next, validFrom: validFrom)
    }

    /// The wire value of one kind, or `nil` for "no answer".
    func wireValue(for kind: LifeFactKind) -> LifeFactWireValue? {
        switch kind {
        case .smokingStatus: smokingStatus.map { .string($0.rawValue) }
        case .shiftSchedule: shiftSchedule.map { .string($0.rawValue) }
        case .tobaccoDetail: tobacco.isEmpty ? nil : .tobacco(tobacco)
        case .activityHabit: activity.isEmpty ? nil : .activity(activity)
        case .workContext: work.isEmpty ? nil : .work(work)
        case .freeWeekdays:
            freeWeekdays.isEmpty ? nil : .freeWeekdays(LifeFreeWeekdays(days: freeWeekdays.days.sorted { $0.rawValue < $1.rawValue }))
        case .habits: habits.isEmpty ? nil : .habits(habits)
        case .healthGoals: goals.isEmpty ? nil : .goals(goals)
        }
    }
}

/// One write of a section save.
public enum LifeFactWrite: Equatable, Sendable {
    case create(kind: LifeFactKind, value: LifeFactWireValue, validFrom: String?)
    case correct(revisionID: String, kind: LifeFactKind, value: LifeFactWireValue, validFrom: String?)
    case remove(revisionID: String)
}

/// The `value` of a fact write: a string for the two closed kinds, an object
/// with `schema: 1` for the others.
public enum LifeFactWireValue: Equatable, Sendable, Encodable {
    case string(String)
    case tobacco(LifeTobaccoDetail)
    case activity(LifeActivityHabit)
    case work(LifeWorkContext)
    case freeWeekdays(LifeFreeWeekdays)
    case habits(LifeHabits)
    case goals(LifeHealthGoals)

    /// The wire form of a decoded answer, for comparison with the draft.
    init?(_ value: LifeFactValue) {
        switch value {
        case let .smokingStatus(v), let .shiftSchedule(v): self = .string(v.rawValue)
        case let .tobacco(v): self = .tobacco(v)
        case let .activity(v): self = .activity(v)
        case let .work(v): self = .work(v)
        case let .freeWeekdays(v): self = .freeWeekdays(LifeFreeWeekdays(days: v.days.sorted { $0.rawValue < $1.rawValue }))
        case let .habits(v): self = .habits(v)
        case let .goals(v): self = .goals(v)
        case .unreadable, .unsupported: return nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case let .string(value):
            var c = encoder.singleValueContainer()
            try c.encode(value)
        case let .tobacco(value): try value.encode(to: encoder)
        case let .activity(value): try value.encode(to: encoder)
        case let .work(value): try value.encode(to: encoder)
        case let .freeWeekdays(value): try value.encode(to: encoder)
        case let .habits(value): try value.encode(to: encoder)
        case let .goals(value): try value.encode(to: encoder)
        }
    }
}
