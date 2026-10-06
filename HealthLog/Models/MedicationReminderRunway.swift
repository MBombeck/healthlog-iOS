import Foundation

/// **R5 — how far ahead the local medication reminders reach.**
///
/// A schedule an OS-repeating trigger can express (an open daily course, plain
/// weekly, monthly on day ≤ 28, a stable yearly day) costs one pending request
/// and never runs dry. Everything else — a course that has not started yet or
/// ends within the horizon, every N weeks, every N months, cyclic, rolling, a
/// one-shot, day 29–31, Feb 29 — is armed as single occurrences, each one
/// pending `UNNotificationRequest`. iOS keeps at most 64 of those per app and
/// SpeziScheduler takes 48 (`LocalNotificationBudget.speziNotificationLimit`).
///
/// Up to R5 every such entry got a fixed eight occurrences. A course with three
/// doses a day therefore ran dry after under three days unless the app ran a
/// reconcile in between, while most of the 48 slots stayed empty. The plan
/// below hands out the whole budget instead: the repeating slots are reserved
/// first, every entry keeps its next dose, and the rest goes to the earliest
/// occurrences across all entries. Taking the earliest first is what makes the
/// split fair — every entry is armed up to one common instant, and no other
/// split of the same number of slots reaches further for the entry that runs
/// out first.
///
/// The plan also says where it was cut short (`continuesAfterLast`). That is
/// the input for two safety nets: the last armed dose of such an entry asks the
/// user to open the app (`HealthLogStandard`), and `clientManaged` is only
/// claimed while every cut-short entry reaches at least
/// ``minimumClaimCoverage`` ahead (``MedicationReminderDeliveryPolicy``).
enum MedicationReminderRunway {
    /// The number of pending requests SpeziScheduler may hold. Mirrors
    /// `LocalNotificationBudget.speziNotificationLimit` (app target only; a test
    /// pins the two together). Planning more tasks than this would let
    /// SpeziScheduler's round robin pick a later occurrence over an earlier one.
    static let notificationBudget = 48

    /// The window SpeziScheduler materializes (`schedulingInterval`, 8 weeks).
    /// An occurrence past it would not become a pending request yet, so only the
    /// immediate next dose of an entry may lie beyond it.
    static let horizon: TimeInterval = 8 * 7 * 24 * 60 * 60

    /// **The X of the `clientManaged` rule: seven days.** The server stays quiet
    /// only while every medication whose runway was cut short is armed at least
    /// this far ahead. Below that the plan is budget-bound — many single-dose
    /// courses at once — and a week without a background wake or an app start is
    /// an ordinary week (holiday, a phone that stays in low-power mode, an app
    /// that iOS stops waking), so a duplicate APNs reminder is the better failure
    /// than a silent one. A course that simply ends within the runway, or any
    /// schedule on a repeating trigger, counts as covered for good.
    static let minimumClaimCoverage: TimeInterval = 7 * 24 * 60 * 60

    struct EntryKey: Hashable, Sendable {
        let medicationID: String
        let entryIndex: Int
    }

    struct Runway: Equatable, Sendable {
        /// The armed occurrence instants, ascending.
        var occurrences: [Date]
        /// `true` when the course has a dose after the last armed one, i.e. the
        /// budget or the horizon cut the runway short.
        var continuesAfterLast: Bool
    }

    struct Plan: Equatable, Sendable {
        var runways: [EntryKey: Runway]
        /// Slots taken by repeating triggers, reserved before any runway.
        var repeatingSlots: Int

        var armedRequestCount: Int {
            repeatingSlots + runways.values.reduce(0) { $0 + $1.occurrences.count }
        }

        /// The instant up to which every planned medication has its doses
        /// armed; `nil` when no runway was cut short.
        var coverageEnd: Date? {
            runways.values
                .filter(\.continuesAfterLast)
                .compactMap(\.occurrences.last)
                .min()
        }
    }

    /// Plans the runways for `medications`, as `MedicationsSchedulerModule`
    /// arms them. Only medications the planner reminds of take part
    /// (``MedicationReminderDeliveryPolicy/plansLocalReminder(for:)``).
    static func plan(
        for medications: [Medication],
        now: Date,
        timeZone: TimeZone = .current,
        budget: Int = notificationBudget
    ) -> Plan {
        var sources: [Source] = []
        var repeatingSlots = 0
        for medication in medications where MedicationReminderDeliveryPolicy.plansLocalReminder(for: medication) {
            let context = MedicationRecurrenceEngine.Context(medication: medication, timeZone: timeZone, now: now)
            let repeats = MedicationRecurrenceEngine.repeatingRuleFits(context: context, now: now, endHorizon: horizon)
            for (entryIndex, entry) in medication.schedule.entries.enumerated() where entry.cadence != .asNeeded {
                if ridesRunway(entry, repeats: repeats, context: context, now: now) {
                    sources.append(Source(
                        key: EntryKey(medicationID: medication.id, entryIndex: entryIndex),
                        entry: entry,
                        context: context
                    ))
                } else {
                    repeatingSlots += repeatingSlotCount(entry)
                }
            }
        }
        return fill(sources: sources, repeatingSlots: repeatingSlots, now: now, budget: budget)
    }

    /// Whether `entry` is armed as single occurrences rather than one repeating
    /// trigger. `repeats` is ``MedicationRecurrenceEngine/repeatingRuleFits``
    /// for the medication. The one decision `MedicationsSchedulerModule` builds
    /// its projections from, so plan and armed tasks cannot disagree.
    static func ridesRunway(
        _ entry: ScheduleEntry,
        repeats: Bool,
        context: MedicationRecurrenceEngine.Context,
        now: Date
    ) -> Bool {
        switch entry.cadence {
        case .daily, .weekdays:
            !repeats
        case let .everyNWeeks(interval, _):
            max(1, interval) > 1 || !repeats
        case let .legacy(days, intervalWeeks):
            !repeats || (intervalWeeks > 1 && (days?.isEmpty ?? true))
        case let .monthly(day):
            !(day <= 28 && boundsAllowRepeatingTrigger(context: context, now: now))
        case let .everyNMonths(interval, day):
            !(max(1, interval) == 1 && day <= 28 && boundsAllowRepeatingTrigger(context: context, now: now))
        case let .yearly(month, day):
            !(isStableYearlyDay(month: month, day: day) && boundsAllowRepeatingTrigger(context: context, now: now))
        case .rolling, .oneShot, .cyclic:
            true
        case .asNeeded:
            false
        }
    }

    /// How many repeating triggers a non-runway entry arms: one per time of day,
    /// times the weekdays for a weekly rule.
    static func repeatingSlotCount(_ entry: ScheduleEntry) -> Int {
        let times = entry.effectiveTimes.count
        switch entry.cadence {
        case let .weekdays(days), let .everyNWeeks(_, days):
            return days.count * times
        case let .legacy(days, _):
            if let days, !days.isEmpty { return days.count * times }
            return times
        case .daily, .monthly, .everyNMonths, .yearly:
            return times
        case .rolling, .oneShot, .cyclic, .asNeeded:
            return 0
        }
    }

    /// A repeating calendar trigger fires indefinitely and cannot express a
    /// start floor or an end cap. So only lift a cadence to one when the
    /// medication has already started (no future `startsOn` day) and never ends
    /// (`endsOn == nil`); bounded schedules ride the runway, which honours both.
    static func boundsAllowRepeatingTrigger(
        context: MedicationRecurrenceEngine.Context,
        now: Date
    ) -> Bool {
        if context.endsOn != nil { return false }
        // R1 — the start DAY on the clock, not `startsOn`'s UTC midnight
        // (which west of UTC is the evening before the course starts).
        if let start = MedicationRecurrenceEngine.startOfCourse(context), start > now { return false }
        return true
    }

    /// Whether `(month, day)` occurs in every common (non-leap) year, so a
    /// yearly repeating calendar trigger fires exactly on it.
    static func isStableYearlyDay(month: Int, day: Int) -> Bool {
        let commonYearDays = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1 ... 12).contains(month), day >= 1 else { return false }
        return day <= commonYearDays[month - 1]
    }

    // MARK: - Fill

    private struct Source {
        let key: EntryKey
        let entry: ScheduleEntry
        let context: MedicationRecurrenceEngine.Context
    }

    /// Every entry keeps its next dose, even past the horizon or the budget —
    /// the guarantee the single pre-armed occurrence always gave. The remaining
    /// slots go to the earliest occurrence across all entries, one at a time,
    /// until the budget or the horizon is reached. Ties go to the entry listed
    /// first, so the plan is deterministic.
    private static func fill(sources: [Source], repeatingSlots: Int, now: Date, budget: Int) -> Plan {
        let horizonEnd = now.addingTimeInterval(horizon)
        var runways: [EntryKey: Runway] = [:]
        var pending: [Date?] = Array(repeating: nil, count: sources.count)
        var armed = repeatingSlots
        for (index, source) in sources.enumerated() {
            guard let first = next(after: now, source) else { continue }
            runways[source.key] = Runway(occurrences: [first], continuesAfterLast: false)
            armed += 1
            pending[index] = next(after: first, source)
        }
        while armed < budget {
            var earliest: (index: Int, at: Date)?
            for (index, candidate) in pending.enumerated() {
                guard let candidate, candidate <= horizonEnd else { continue }
                if let current = earliest, current.at <= candidate { continue }
                earliest = (index, candidate)
            }
            guard let earliest else { break }
            let source = sources[earliest.index]
            runways[source.key]?.occurrences.append(earliest.at)
            armed += 1
            pending[earliest.index] = next(after: earliest.at, source)
        }
        for (index, source) in sources.enumerated() where pending[index] != nil {
            runways[source.key]?.continuesAfterLast = true
        }
        return Plan(runways: runways, repeatingSlots: repeatingSlots)
    }

    private static func next(after instant: Date, _ source: Source) -> Date? {
        MedicationRecurrenceEngine.nextOccurrence(after: instant, entry: source.entry, context: source.context)?.at
    }
}
