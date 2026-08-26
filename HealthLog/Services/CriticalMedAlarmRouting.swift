import CryptoKit
import Foundation

/// **v0.9.0 W2 — pure routing + schedule-mapping for critical med alarms.**
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

    /// **v0.10 R1 §3.5 — a planned alarm slot, either a recurring weekly slot
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
    /// - `osAvailable` (iOS ≥ 26) and `authorized` (AlarmKit granted),
    /// - the medication is `active` + has `notificationsEnabled`,
    /// - the per-med `criticalAlarm` opt-in is ON,
    /// - the schedule has at least one entry with a time-of-day.
    ///
    /// **v0.10 R1 §3.5 — generalised from the old "weekly only
    /// (`intervalWeeks == 1`)" gate.** Any cadence the engine can produce a
    /// concrete next occurrence for is now eligible: rolling / monthly /
    /// yearly / biweekly GLP-1 schedule a single-shot `.fixed` alarm at the
    /// next occurrence (re-armed on reconcile / intake) instead of falling
    /// back to the UNNotification path.
    static func isAlarmEligible(
        medication: Medication,
        alarmEnabled: (String) -> Bool,
        authorized: Bool,
        osAvailable: Bool
    ) -> Bool {
        guard osAvailable, authorized else { return false }
        guard medication.active, medication.notificationsEnabled else { return false }
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
        authorized: Bool,
        osAvailable: Bool
    ) -> (alarmMeds: [Medication], unMeds: [Medication]) {
        var alarmMeds: [Medication] = []
        var unMeds: [Medication] = []
        for medication in medications {
            if isAlarmEligible(
                medication: medication,
                alarmEnabled: alarmEnabled,
                authorized: authorized,
                osAvailable: osAvailable
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

    /// **v0.10 R1 §3.5 — generalised alarm planner.** Map each `ScheduleEntry`
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
    static func plannedAlarms(
        for medication: Medication,
        now: Date = .now,
        timeZone: TimeZone = .current
    ) -> [PlannedAlarm] {
        let context = MedicationRecurrenceEngine.Context(
            medication: medication,
            timeZone: timeZone,
            now: now
        )
        var planned: [PlannedAlarm] = []
        for entry in medication.schedule.entries {
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
                    appendFixed(entry: entry, context: context, now: now, into: &planned)
                }
            case let .legacy(days, intervalWeeks):
                if let days, !days.isEmpty, intervalWeeks <= 1 {
                    appendWeeklySlots(entry: entry, days: days, into: &planned)
                } else if days?.isEmpty ?? true, intervalWeeks <= 1 {
                    for time in entry.effectiveTimes {
                        planned.append(.weekly(AlarmSlot(hour: time.hour, minute: time.minute, weekdays: [])))
                    }
                } else {
                    appendFixed(entry: entry, context: context, now: now, into: &planned)
                }
            case .monthly, .everyNMonths, .yearly, .rolling, .oneShot, .cyclic:
                // Cyclic on/off-weeks has no clean AlarmKit Recurrence → arm a
                // single `.fixed` alarm at the next on-week occurrence,
                // re-armed on reconcile / intake. Off-weeks yield no alarm.
                appendFixed(entry: entry, context: context, now: now, into: &planned)
            case .asNeeded:
                // PRN / as-needed — never arms a critical alarm.
                continue
            }
        }
        return planned
    }

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

    private static func appendFixed(
        entry: ScheduleEntry,
        context: MedicationRecurrenceEngine.Context,
        now: Date,
        into planned: inout [PlannedAlarm]
    ) {
        guard let next = MedicationRecurrenceEngine.nextOccurrence(
            after: now,
            entry: entry,
            context: context
        ) else { return }
        planned.append(.fixed(at: next.at))
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
    /// reconcile (HIGH-1). An alarm is orphaned — and so cancelled — only when
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
    static func orphanIDs(
        existing: [UUID],
        desiredScheduledIDs: Set<UUID>,
        activeMedIDs: [String]
    ) -> [UUID] {
        var protectedIDs = desiredScheduledIDs
        for medID in activeMedIDs {
            protectedIDs.insert(snoozeAlarmID(medicationID: medID))
        }
        return existing.filter { !protectedIDs.contains($0) }
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
