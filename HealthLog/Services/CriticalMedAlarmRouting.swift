import CryptoKit
import Foundation

/// **Pure routing + schedule-mapping for critical med alarms.**
///
/// AlarmKit is iOS 26-only and needs a live OS surface, which makes the
/// `CriticalMedAlarmService` hard to unit-test. This enum holds the **pure**
/// decisions that drive it — which meds the AlarmKit path owns (vs. the
/// existing UNNotification/Spezi path), and how a medication's schedule maps
/// onto AlarmKit's weekly relative-alarm shape. Deliberately
/// `Foundation`-only + free of AlarmKit so it compiles + unit-tests on the
/// host without iOS 26.
///
/// **Coexistence = REPLACE.** A med routed to the AlarmKit channel is
/// REMOVED from the UNNotification/Spezi scheduler set so it can't
/// double-fire. Everything else stays on the existing path unchanged.
enum CriticalMedAlarmRouting {
    /// Generous ceiling on the number of scheduled alarm slots a single med
    /// can hold (one per `MedicationSchedule.times` entry). The cancel sweep
    /// iterates `0 ..< maxScheduledSlots` so a schedule that shrank still has
    /// its stale slots removed.
    static let maxScheduledSlots = 8

    /// Dedicated slot index for a med's pending one-shot snooze alarm. Kept
    /// far outside `0 ..< maxScheduledSlots` so the snooze id can never
    /// collide with a scheduled slot id — the invariant the snooze-survival
    /// reconcile logic depends on.
    static let snoozeSlotIndex = 99

    /// A weekly alarm slot derived from a medication schedule: a wall-clock
    /// time recurring on a weekday set. One slot per `MedicationSchedule
    /// .times` entry. AlarmKit-free so it's unit-testable; the service maps
    /// it onto `Alarm.Schedule.Relative` + `Recurrence.weekly`.
    struct AlarmSlot: Equatable, Hashable {
        let hour: Int
        let minute: Int
        /// Empty means "every day" (no weekday constraint).
        let weekdays: [Weekday]
    }

    /// **A planned alarm slot, either a recurring weekly slot
    /// or a single-shot fixed alarm at a concrete next occurrence.**
    ///
    /// Daily / weekday / weekly(interval==1) cadences map to a recurring
    /// `.weekly` AlarmKit relative alarm (`.weekly`). everyNWeeks(INTERVAL>1) /
    /// monthly / everyNMonths / yearly / rolling / oneShot have no clean
    /// AlarmKit `Recurrence`, so they schedule a single `.fixed` alarm at the
    /// engine's next occurrence and re-arm on each reconcile / intake.
    enum PlannedAlarm: Equatable, Hashable {
        case weekly(AlarmSlot)
        case fixed(at: Date)
    }

    /// Whether a medication is eligible for the AlarmKit critical-alarm
    /// channel, given the per-med opt-in + runtime gates.
    ///
    /// Eligibility requires ALL of:
    /// - `authorized` (AlarmKit granted),
    /// - the medication is `active` + has `notificationsEnabled`,
    /// - the per-med `criticalAlarm` opt-in is ON,
    /// - the schedule has at least one entry with a time-of-day.
    ///
    /// **Generalised from the old "weekly only
    /// (`intervalWeeks == 1`)" gate.** Any cadence the engine can produce a
    /// concrete next occurrence for is now eligible: rolling / monthly /
    /// yearly / biweekly GLP-1 schedule a single-shot `.fixed` alarm at the
    /// next occurrence (re-armed on reconcile / intake) instead of falling
    /// back to the UNNotification path.
    static func isAlarmEligible(
        medication: Medication,
        alarmEnabled: (String) -> Bool,
        authorized: Bool
    ) -> Bool {
        guard authorized else { return false }
        guard medication.active, medication.notificationsEnabled else { return false }
        // v1.42.2 — the server's reminder decision (`remindersActive`) wins: an
        // auto-recorded supplement or an ended course never alarms either.
        guard medication.remindersActive != false else { return false }
        // v1.39.1 — a medication kept as a record never alarms; leaving
        // it out of the alarm set cancels any alarm armed before the switch.
        guard medication.tracksIntake else { return false }
        guard !medication.schedule.entries.isEmpty else { return false }
        guard medication.schedule.entries.contains(where: { !$0.effectiveTimes.isEmpty }) else { return false }
        return alarmEnabled(medication.id)
    }

    /// Partition the medication set into the AlarmKit-owned meds and the
    /// meds that stay on the UNNotification/Spezi path. The UN set is the
    /// full input MINUS the alarm-owned meds — this is the REPLACE
    /// semantics: an alarm-owned med is excluded from the scheduler reconcile
    /// so the two channels never both fire for the same dose.
    static func route(
        medications: [Medication],
        alarmEnabled: (String) -> Bool,
        authorized: Bool
    ) -> (alarmMeds: [Medication], unMeds: [Medication]) {
        var alarmMeds: [Medication] = []
        var unMeds: [Medication] = []
        for medication in medications {
            if isAlarmEligible(
                medication: medication,
                alarmEnabled: alarmEnabled,
                authorized: authorized
            ) {
                alarmMeds.append(medication)
            } else {
                unMeds.append(medication)
            }
        }
        return (alarmMeds, unMeds)
    }

    /// Map a medication's schedule onto its weekly alarm slots — one per
    /// `times` entry, each carrying the (sorted) weekday set. Returns an
    /// empty array when the schedule has no times.
    ///
    /// **Legacy weekly-only mapper.** Retained for back-compat callers /
    /// tests; the generalised planner is ``plannedAlarms(for:now:timeZone:)``.
    static func alarmSlots(for medication: Medication) -> [AlarmSlot] {
        let weekdays = medication.schedule.weekdays?
            .sorted(by: { $0.rawValue < $1.rawValue }) ?? []
        return medication.schedule.times.map { time in
            AlarmSlot(hour: time.hour, minute: time.minute, weekdays: weekdays)
        }
    }

    /// **Generalised alarm planner.** Map each `ScheduleEntry`
    /// onto the AlarmKit slots it needs:
    /// - `daily` → one recurring `.weekly(everyDay)` slot per time-of-day.
    /// - `weekdays` → one recurring weekly slot per time, carrying the weekday
    ///   set (AlarmKit `.weekly` honours multiple weekdays).
    /// - `everyNWeeks` with `interval == 1` → same as `weekdays`.
    /// - `everyNWeeks` with `interval > 1` / `monthly` / `everyNMonths` /
    ///   `yearly` / `rolling` / `oneShot` → a single `.fixed` alarm at the
    ///   engine's next occurrence (re-armed on reconcile / intake).
    /// - `legacy` → weekly slot when a weekday set is present and
    ///   `intervalWeeks == 1`; otherwise a `.fixed` next-occurrence alarm.
    ///
    /// **#188 (5) — today's occurrence of a resolved dose stays silent.**
    /// `resolvedSlots` are today's taken or skipped slots (the server's today
    /// list). A weekly slot whose occurrence later today is one of them leaves
    /// today's weekday out of its recurrence, so the alarm still fires every
    /// other day without the app being opened; a slot whose only weekday is
    /// today becomes a single alarm a week later. A single `.fixed` alarm on a
    /// resolved occurrence moves to the one after it. The next reconcile after
    /// that time restores the full recurrence. Matching is the reminder
    /// completion's rule (``MedicationReminderCompletion/occurrenceIsResolved``)
    /// until the server publishes the resolved slot itself (#188 (4)).
    ///
    /// `timeZone` is the account zone (the recurrence engine's day); weekly
    /// alarms fire on the device's wall clock (`deviceTimeZone`), the way
    /// AlarmKit's relative schedules do.
    static func plannedAlarms(
        for medication: Medication,
        now: Date = .now,
        timeZone: TimeZone = .current,
        resolvedSlots: [MedicationReminderCompletion.ResolvedSlot] = [],
        deviceTimeZone: TimeZone = .current
    ) -> [PlannedAlarm] {
        let resolved = resolvedSlots.filter { $0.medicationId == medication.id }
        let isResolved: (Date) -> Bool = { start in
            !resolved.isEmpty && MedicationReminderCompletion.occurrenceIsResolved(
                medicationId: medication.id,
                start: start,
                slots: resolved,
                deviceTimeZone: deviceTimeZone,
                accountTimeZone: timeZone
            )
        }
        let context = MedicationRecurrenceEngine.Context(
            medication: medication,
            timeZone: timeZone,
            now: now
        )
        var planned: [PlannedAlarm] = []
        // A weekly-recurring alarm has no first or last day; a course that
        // has not started yet, or ends soon, arms its next occurrence instead.
        let repeats = MedicationRecurrenceEngine.repeatingRuleFits(
            context: context, now: now, endHorizon: repeatingAlarmEndHorizon
        )
        for entry in medication.schedule.entries {
            if !repeats, entry.cadence.armsWeeklyAlarm {
                appendFixed(entry: entry, context: context, now: now, isResolved: isResolved, into: &planned)
            } else {
                appendPlanned(entry: entry, context: context, now: now, isResolved: isResolved, into: &planned)
            }
        }
        guard !resolved.isEmpty else { return planned }
        return planned.flatMap { plan -> [PlannedAlarm] in
            guard case let .weekly(slot) = plan else { return [plan] }
            return suspendingResolved(slot, now: now, deviceTimeZone: deviceTimeZone, isResolved: isResolved)
        }
    }

    /// A weekly slot with every weekday left out whose next occurrence (within
    /// the coming week) is already resolved, plus a single `.fixed` alarm one
    /// week after each such occurrence.
    ///
    /// **D3 #8.** AlarmKit cannot skip one occurrence of a weekly alarm, so the
    /// resolved weekday leaves the recurrence. Before, nothing put it back
    /// until the app reconciled again: someone who then only used the alarm's
    /// own buttons lost that weekday for good, and a once-a-week dose (GLP-1)
    /// rang once more and then never again. The `.fixed` alarm keeps the
    /// following week's dose armed without any app run; the alarm intents
    /// reconcile after every action, which turns it back into the weekly slot.
    ///
    /// **D3 #4.** Not only today: a dose taken on Saturday that the server binds
    /// to Sunday's slot resolves Sunday's occurrence too.
    static func suspendingResolved(
        _ slot: AlarmSlot,
        now: Date,
        deviceTimeZone: TimeZone,
        isResolved: (Date) -> Bool
    ) -> [PlannedAlarm] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = deviceTimeZone
        let allDays = (0 ... 6).compactMap(Weekday.init(rawValue:))
        var remaining = slot.weekdays.isEmpty ? allDays : slot.weekdays
        var nextWeek: [PlannedAlarm] = []
        for offset in 0 ... 6 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: now),
                  let occurrence = calendar.date(bySettingHour: slot.hour, minute: slot.minute, second: 0, of: day),
                  occurrence > now,
                  let weekday = Weekday(rawValue: calendar.component(.weekday, from: occurrence) - 1),
                  remaining.contains(weekday),
                  isResolved(occurrence) else { continue }
            remaining.removeAll { $0 == weekday }
            nextWeek.append(.fixed(at: calendar.date(byAdding: .day, value: 7, to: occurrence) ?? occurrence))
        }
        guard !nextWeek.isEmpty else { return [.weekly(slot)] }
        guard remaining.isEmpty else {
            return [.weekly(AlarmSlot(hour: slot.hour, minute: slot.minute, weekdays: remaining))] + nextWeek
        }
        return nextWeek
    }

    /// One entry's alarms when the course allows a weekly-recurring slot (the
    /// pre-R1 mapping, unchanged).
    private static func appendPlanned(
        entry: ScheduleEntry,
        context: MedicationRecurrenceEngine.Context,
        now: Date,
        isResolved: (Date) -> Bool,
        into planned: inout [PlannedAlarm]
    ) {
        switch entry.cadence {
        case .daily:
            for time in entry.effectiveTimes {
                planned.append(.weekly(AlarmSlot(hour: time.hour, minute: time.minute, weekdays: [])))
            }
        case let .weekdays(days):
            appendWeeklySlots(entry: entry, days: days, into: &planned)
        case let .everyNWeeks(interval, days):
            if interval <= 1 {
                appendWeeklySlots(entry: entry, days: days, into: &planned)
            } else {
                appendFixed(entry: entry, context: context, now: now, isResolved: isResolved, into: &planned)
            }
        case let .legacy(days, intervalWeeks):
            if let days, !days.isEmpty, intervalWeeks <= 1 {
                appendWeeklySlots(entry: entry, days: days, into: &planned)
            } else if days?.isEmpty ?? true, intervalWeeks <= 1 {
                for time in entry.effectiveTimes {
                    planned.append(.weekly(AlarmSlot(hour: time.hour, minute: time.minute, weekdays: [])))
                }
            } else {
                appendFixed(entry: entry, context: context, now: now, isResolved: isResolved, into: &planned)
            }
        case .monthly, .everyNMonths, .yearly, .rolling, .oneShot, .cyclic:
            // Cyclic on/off-weeks has no clean AlarmKit Recurrence → arm a
            // single `.fixed` alarm at the next on-week occurrence,
            // re-armed on reconcile / intake. Off-weeks yield no alarm.
            appendFixed(entry: entry, context: context, now: now, isResolved: isResolved, into: &planned)
        case .asNeeded:
            // PRN / as-needed — never arms a critical alarm.
            break
        }
    }

    /// How far ahead a course end must lie for a weekly-recurring alarm to
    /// stand in for it (the Spezi pre-arm horizon, eight weeks).
    static let repeatingAlarmEndHorizon: TimeInterval = 8 * 7 * 24 * 60 * 60

    private static func appendWeeklySlots(
        entry: ScheduleEntry,
        days: Set<Weekday>,
        into planned: inout [PlannedAlarm]
    ) {
        let sorted = days.sorted { $0.rawValue < $1.rawValue }
        for time in entry.effectiveTimes {
            planned.append(.weekly(AlarmSlot(hour: time.hour, minute: time.minute, weekdays: sorted)))
        }
    }

    /// One `.fixed` alarm at the entry's next occurrence. A resolved
    /// occurrence (#188 (5)) is passed over for the one after it; bounded, a
    /// cadence cannot have more resolved occurrences ahead than today's few.
    private static func appendFixed(
        entry: ScheduleEntry,
        context: MedicationRecurrenceEngine.Context,
        now: Date,
        isResolved: (Date) -> Bool,
        into planned: inout [PlannedAlarm]
    ) {
        var after = now
        for _ in 0 ..< 4 {
            guard let next = MedicationRecurrenceEngine.nextOccurrence(
                after: after,
                entry: entry,
                context: context
            ) else { return }
            guard isResolved(next.at) else {
                planned.append(.fixed(at: next.at))
                return
            }
            after = next.at
        }
    }

    /// Deterministic, stable UUID for a med's alarm slot so reconcile is a
    /// no-op when unchanged and `cancel` can find the prior alarm. Derived
    /// from `medicationId + slot index` via a UUIDv5-style namespaced hash
    /// so the same `(med, slot)` always maps to the same `Alarm.ID`.
    static func alarmID(medicationID: String, slotIndex: Int) -> UUID {
        UUIDv5.named("\(medicationID)#alarm#\(slotIndex)")
    }

    /// Deterministic id for a med's pending one-shot snooze alarm
    /// (`snoozeSlotIndex`). Stable per med so the snooze can be found + kept
    /// across reconciles and cancelled holistically on med removal.
    static func snoozeAlarmID(medicationID: String) -> UUID {
        alarmID(medicationID: medicationID, slotIndex: snoozeSlotIndex)
    }

    /// Decide which existing AlarmKit alarm ids to purge on a routine
    /// reconcile. An alarm is orphaned — and so cancelled — only when
    /// it is neither a currently-desired scheduled slot NOR a snooze alarm of
    /// a med that is still alarm-owned. This protects a *pending snooze*
    /// (slot ``snoozeSlotIndex``) of an active med from being silently
    /// dropped on every load/foreground/intake reconcile, while still purging
    /// the snooze + scheduled slots of a med that is genuinely gone
    /// (toggle-off / archived / deleted / no longer eligible).
    ///
    /// - Parameters:
    ///   - existing: every HealthLog-owned `Alarm.ID` currently scheduled.
    ///   - desiredScheduledIDs: the scheduled-slot ids the reconcile just
    ///     (re-)scheduled for the still-alarm-owned meds.
    ///   - activeMedIDs: the ids of the meds the AlarmKit channel still owns —
    ///     used to protect each one's pending snooze id.
    /// - Returns: the subset of `existing` that should be cancelled.
    ///   - resolvedSnoozeMedIDs: **D3 #1** — meds whose snoozed dose is
    ///     resolved by now (``resolvedSnoozes(_:resolvedSlots:deviceTimeZone:accountTimeZone:)``);
    ///     their snooze is no longer protected and is cancelled.
    static func orphanIDs(
        existing: [UUID],
        desiredScheduledIDs: Set<UUID>,
        activeMedIDs: [String],
        resolvedSnoozeMedIDs: Set<String> = []
    ) -> [UUID] {
        var protectedIDs = desiredScheduledIDs
        for medID in activeMedIDs where !resolvedSnoozeMedIDs.contains(medID) {
            protectedIDs.insert(snoozeAlarmID(medicationID: medID))
        }
        return existing.filter { !protectedIDs.contains($0) }
    }

    // MARK: - Snoozed doses (D3 #1)

    /// The dose a snooze defers, kept until its alarm is gone or the dose is
    /// resolved.
    struct SnoozedDose: Codable, Equatable, Sendable {
        let medicationId: String
        /// The occurrence the alarm fired for, an instant on the device clock.
        let occurrence: Date
    }

    /// The occurrence an alarm action stands for: the latest instant at or
    /// before `now` with the wall-clock time of the alarm's `scheduledFor`.
    ///
    /// A weekly alarm's `scheduledFor` is the next fire instant at the time it
    /// was armed, so its date may be days old; its time of day is the slot's.
    /// A fixed alarm's `scheduledFor` is its fire instant, and a snooze alarm
    /// carries the snoozed alarm's, so both resolve to the dose that rang.
    static func occurrence(of scheduledFor: Date, now: Date, deviceTimeZone: TimeZone = .current) -> Date {
        if scheduledFor <= now, now.timeIntervalSince(scheduledFor) < 24 * 60 * 60 { return scheduledFor }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = deviceTimeZone
        let clock = calendar.dateComponents([.hour, .minute], from: scheduledFor)
        for offset in [0, -1] {
            guard let day = calendar.date(byAdding: .day, value: offset, to: now),
                  let candidate = calendar.date(
                      bySettingHour: clock.hour ?? 0,
                      minute: clock.minute ?? 0,
                      second: 0,
                      of: day
                  ) else { continue }
            if candidate <= now { return candidate }
        }
        return scheduledFor
    }

    /// The meds whose snoozed dose is now taken or skipped, by the reminder
    /// completion's rule (same wall clock across zones, or ±5 minutes).
    static func resolvedSnoozes(
        _ snoozes: [SnoozedDose],
        resolvedSlots: [MedicationReminderCompletion.ResolvedSlot],
        deviceTimeZone: TimeZone,
        accountTimeZone: TimeZone
    ) -> Set<String> {
        Set(snoozes.filter { snooze in
            MedicationReminderCompletion.occurrenceIsResolved(
                medicationId: snooze.medicationId,
                start: snooze.occurrence,
                slots: resolvedSlots,
                deviceTimeZone: deviceTimeZone,
                accountTimeZone: accountTimeZone
            )
        }.map(\.medicationId))
    }
}

/// **D3 #1 — which dose each pending snooze alarm defers.**
///
/// The snooze alarm is protected from the routine reconcile so a load does
/// not drop it, and nothing cancelled it when its dose was then taken in the
/// app, on the web or by the pill box: it rang half an hour later, loud and
/// through Focus, for a dose already taken. The snooze intent notes the dose
/// here; the reconcile cancels the snooze once that dose is resolved.
/// One record per medication, as there is one snooze alarm per medication.
struct CriticalAlarmSnoozeLedger {
    static let defaultsKey = "hl.criticalAlarm.snoozedDoses"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func read() -> [CriticalMedAlarmRouting.SnoozedDose] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let doses = try? JSONDecoder().decode([CriticalMedAlarmRouting.SnoozedDose].self, from: data) else { return [] }
        return doses
    }

    func note(_ dose: CriticalMedAlarmRouting.SnoozedDose) {
        write(read().filter { $0.medicationId != dose.medicationId } + [dose])
    }

    /// Keeps only the records of `medicationIDs`.
    func keep(_ medicationIDs: Set<String>) {
        let current = read()
        let kept = current.filter { medicationIDs.contains($0.medicationId) }
        if kept != current { write(kept) }
    }

    func clear() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }

    private func write(_ doses: [CriticalMedAlarmRouting.SnoozedDose]) {
        guard let data = try? JSONEncoder().encode(doses) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

/// Minimal deterministic UUIDv5 (SHA-1, name-based) so an `(medId, slot)`
/// pair always projects to the same `Alarm.ID`. Uses a fixed HealthLog
/// namespace UUID. Kept local + tiny — we only need stability, not RFC-4122
/// interop. Foundation-only so it's testable on the host.
enum UUIDv5 {
    /// Fixed namespace for HealthLog critical-med alarm ids
    /// (`8B5E1C7A-9D2F-4E6B-A1C3-7F0D2E4B6A89`). Constructed from the raw
    /// byte tuple — the non-failable `UUID(uuid:)` initializer — so the
    /// alarm-delivery path carries no force-unwrap.
    private static let namespace = UUID(uuid: (
        0x8B, 0x5E, 0x1C, 0x7A, 0x9D, 0x2F, 0x4E, 0x6B,
        0xA1, 0xC3, 0x7F, 0x0D, 0x2E, 0x4B, 0x6A, 0x89
    ))

    static func named(_ name: String) -> UUID {
        var bytes = [UInt8]()
        withUnsafeBytes(of: namespace.uuid) { bytes.append(contentsOf: $0) }
        bytes.append(contentsOf: Array(name.utf8))
        let digest = Insecure.SHA1.hash(data: Data(bytes))
        var uuidBytes = Array(digest.prefix(16))
        // Set version (5) + variant bits per RFC 4122.
        uuidBytes[6] = (uuidBytes[6] & 0x0F) | 0x50
        uuidBytes[8] = (uuidBytes[8] & 0x3F) | 0x80
        let tuple = (
            uuidBytes[0], uuidBytes[1], uuidBytes[2], uuidBytes[3],
            uuidBytes[4], uuidBytes[5], uuidBytes[6], uuidBytes[7],
            uuidBytes[8], uuidBytes[9], uuidBytes[10], uuidBytes[11],
            uuidBytes[12], uuidBytes[13], uuidBytes[14], uuidBytes[15]
        )
        return UUID(uuid: tuple)
    }
}

private extension Cadence {
    /// The cadences ``CriticalMedAlarmRouting/plannedAlarms(for:now:timeZone:)``
    /// arms as a weekly-recurring AlarmKit slot when the course allows it.
    var armsWeeklyAlarm: Bool {
        switch self {
        case .daily, .weekdays, .legacy: true
        case let .everyNWeeks(interval, _): interval <= 1
        case .monthly, .everyNMonths, .yearly, .rolling, .oneShot, .asNeeded, .cyclic: false
        }
    }
}
