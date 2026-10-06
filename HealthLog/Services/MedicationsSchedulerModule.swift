#if canImport(SpeziScheduler) && canImport(UserNotifications)
    import Foundation
    import Spezi

    // Module-qualified — SpeziScheduler.Task collides with
    // Swift's _Concurrency.Task. References to the scheduler's Task
    // below spell out `SpeziScheduler.Task`; bare `Task { ... }` blocks
    // in this file refer to the Swift-concurrency Task.
    import SpeziScheduler
    import UserNotifications

    /// v0.6.0.7 Spezi Phase E — Spezi `Module` that owns the
    /// medication-reminder reconcile path.
    ///
    /// **What it does:** given a snapshot of `Medication` rows, it
    /// projects each active medication × `(time-of-day × scheduled-
    /// recurrence)` into a SpeziScheduler `Task`. `Scheduler.create-
    /// OrUpdateTask` is idempotent — re-running with the same input
    /// is a no-op; a changed schedule appends a new task version.
    /// Inactive / archived medications get their existing tasks
    /// purged via `deleteAllVersions(ofTask:)`.
    ///
    /// **What replaces what:**
    /// - The legacy `MedicationReminderScheduler` orchestrator turned
    ///   `MedicationsStore.todayIntakes` into `UNTimeIntervalNoti-
    ///   ficationTrigger` requests under `med-local-backup-…` ids. It
    ///   was never wired into the live `AppContainer`, so it never ran
    ///   in production. This module replaces it with the Spezi-driven
    ///   path that **does** get wired — see
    ///   `AppContainer+MedicationsScheduler.swift`.
    /// - `NotificationService+LocalBackups.scheduleLocalBackups(for:)`
    ///   stays available as a builder for ad-hoc test-only requests
    ///   but is no longer invoked at runtime.
    ///
    /// **What stays custom:**
    /// - The 3-action category (`MEDICATION_REMINDER`) +
    ///   `dispatchAction` server-mark-intake roundtrip. Preserved by
    ///   the `HealthLogStandard: SchedulerNotificationsConstraint`
    ///   override which rewrites the Spezi-derived category id back
    ///   to `NotificationService.categoryMedication` on every banner.
    /// - The server-driven APNs cron + the `apns-collapse-id`
    ///   coalescing. Spezi only owns local reminders.
    ///
    /// **Task id shape:**
    /// `med-<medicationId>-<scheduleSlot>` where `scheduleSlot`
    /// encodes the time-of-day index (one schedule slot per
    /// `MedicationSchedule.times` entry). The constraint hook reads
    /// `medicationId` back out of the id via
    /// `Self.medicationId(fromTaskID:)` because Spezi's `Task.Context`
    /// `@Property(coding:)` macro path requires a SpeziScheduler-
    /// macros build step (not currently set up); the encoded-id
    /// approach keeps the implementation self-contained.
    @MainActor
    final class MedicationsSchedulerModule: Module, DefaultInitializable {
        @Dependency(Scheduler.self) private var scheduler

        /// Tasks created by this module carry an id with this prefix so
        /// `Self.medicationId(fromTaskID:)` can sniff them apart from any
        /// future non-medication scheduler clients.
        static let taskIDPrefix = "med-"

        /// Separator between the medication id + schedule-slot index in
        /// the task id. Picked to avoid collision with the medication-
        /// id's allowed character set (server uses Cuid / nanoid for
        /// medication ids, both URL-safe with no `__`).
        static let taskIDSlotSeparator = "__slot-"

        required nonisolated init() {}

        /// Reconcile the Spezi `Task` set against the provided
        /// medication snapshot. Idempotent — safe to invoke on every
        /// `MedicationsStore.load()` completion.
        ///
        /// **Reconcile algorithm:**
        /// 1. For each active medication × `(time × weekdays ×
        ///    intervalWeeks)`, call `createOrUpdateTask` with a
        ///    deterministic id. Spezi's flow-sensitive version
        ///    check ensures no duplicate task is appended when the
        ///    schedule has not changed.
        /// 2. Collect the desired-id set. Query every existing task
        ///    with the `med-` prefix; any id NOT in the desired set
        ///    belongs to a medication that was archived or whose
        ///    schedule was deleted — `deleteAllVersions(ofTask:)`
        ///    purges it (notifications cancelled on next save tick).
        ///
        /// All thrown errors are logged + swallowed — a reconcile
        /// failure must not block the calling `MedicationsStore.load`
        /// path because Spezi-side state is purely a local-fallback
        /// layer. The server schedule is the canonical source of
        /// truth.
        func reconcile(medications: [Medication], now: Date = .now) {
            var desiredTaskIDs: Set<String> = []
            for planned in Self.plannedProjections(for: medications, now: now) {
                let medication = medications.first { $0.id == planned.medicationID }
                guard let medication else { continue }
                let projection = planned.projection
                let taskID = Self.taskID(medicationID: medication.id, slotKey: projection.slotKey)
                desiredTaskIDs.insert(taskID)
                var tags = ["medication", "schedule:\(projection.slotKey)"]
                if projection.isRunwayTail { tags.append(Self.runwayTailTag) }
                do {
                    try scheduler.createOrUpdateTask(
                        id: taskID,
                        title: Self.localizedTitle(for: medication),
                        instructions: Self.localizedInstructions(for: medication),
                        category: .medication,
                        schedule: projection.schedule,
                        completionPolicy: .sameDay,
                        scheduleNotifications: true,
                        notificationThread: .task,
                        tags: tags,
                        shadowedOutcomesHandling: .delete
                    )
                } catch {
                    HLLog.notifications.error(
                        "MedicationsSchedulerModule: createOrUpdateTask failed id=\(taskID, privacy: .private) err=\(LogSanitizer.redact(String(describing: error)), privacy: .private)"
                    )
                }
            }
            // v0.14.1 notifications-bug H4 — budget telemetry. R5 fills the
            // runways up to the SpeziScheduler budget on purpose, so a full set
            // is the normal case. Only a set ABOVE the budget is a signal: the
            // repeating triggers plus one next dose per runway entry no longer
            // fit, and SpeziScheduler's round robin may skip a task.
            if desiredTaskIDs.count > MedicationReminderRunway.notificationBudget {
                // Slot count is not PII — public is intentional (operator-grade).
                // swiftlint:disable:next hllog_public_privacy_interpolation
                HLLog.notifications.warning(
                    "MedicationsSchedulerModule: \(desiredTaskIDs.count, privacy: .public) reminder slots projected — above the SpeziScheduler budget"
                )
            }
            purgeOrphanedTasks(keeping: desiredTaskIDs)
        }

        /// Whether `reconcile` arms any reminder task for `medication`.
        ///
        /// **v1.39.1 (#1033)** — a medication kept as a record (`trackIntake:
        /// false`) never reminds, whatever its schedule says. Leaving it out of
        /// the desired set is also what REMOVES reminders armed before the
        /// switch: `purgeOrphanedTasks` drops every `med-` task this set does
        /// not name.
        ///
        /// **N1** — one predicate with ``MedicationReminderDeliveryPolicy``, so
        /// the `clientManaged` claim never asserts a reminder this pass skips.
        static func plansReminders(for medication: Medication) -> Bool {
            MedicationReminderDeliveryPolicy.plansLocalReminder(for: medication)
        }

        /// The task ids one reconcile pass wants to exist — the pure half of
        /// `reconcile`, so the set can be asserted without a live `Scheduler`.
        static func desiredTaskIDs(
            for medications: [Medication],
            now: Date,
            timeZone: TimeZone = .current
        ) -> Set<String> {
            Set(plannedProjections(for: medications, now: now, timeZone: timeZone).map {
                taskID(medicationID: $0.medicationID, slotKey: $0.projection.slotKey)
            })
        }

        /// The stored `med-` tasks a reconcile pass deletes: every medication
        /// task the desired set does not name.
        static func orphanTaskIDs(existing: Set<String>, desired: Set<String>) -> Set<String> {
            existing.filter { $0.hasPrefix(taskIDPrefix) }.subtracting(desired)
        }

        /// One projected SpeziScheduler task for a medication. `slotKey`
        /// uniquely identifies the (entry × weekday × time) slot within the
        /// medication; `reconcile` prefixes the medication id to form the full
        /// task id.
        struct Projection {
            let slotKey: String
            let schedule: Schedule
            /// R5 — the last armed occurrence of a runway whose course goes on.
            var isRunwayTail = false
        }

        /// **v0.10 R1 §3.4 — project a medication's `ScheduleEntry` rows onto
        /// SpeziScheduler tasks.** The single-medication view of
        /// ``plannedProjections(for:now:timeZone:)`` — the medication planned as
        /// if it were the only one, so it may use the whole budget.
        static func projections(for medication: Medication, now: Date, timeZone: TimeZone = .current) -> [Projection] {
            plannedProjections(for: [medication], now: now, timeZone: timeZone).map(\.projection)
        }

        /// One projection together with the medication it belongs to.
        struct PlannedProjection {
            let medicationID: String
            let projection: Projection
        }

        /// **All tasks one reconcile arms, across every medication.**
        ///
        /// Per entry, by cadence:
        /// - `daily` → one repeating `.daily` task per time-of-day.
        /// - `weekdays` / `everyNWeeks(interval == 1)` → one repeating `.weekly`
        ///   task per (weekday × time) — the single-weekday Spezi `.weekly`
        ///   factory limitation is resolved by fanning out a task per weekday.
        /// - `monthly` / `everyNMonths(interval == 1)` (day ≤ 28, unbounded) /
        ///   `yearly` (stable month/day, unbounded) → an OS-delivered REPEATING
        ///   calendar trigger (`.monthly` / `.yearly`, `repeats: true`) that
        ///   survives background / force-quit with zero re-arm (v0.14.1 H1).
        /// - everything else (`everyNWeeks(interval > 1)`, `everyNMonths(interval
        ///   > 1)`, `rolling`, `oneShot`, `cyclic`, day-29–31 monthly, Feb-29
        ///   yearly, and — R1 — a daily/weekly course that has not started or
        ///   ends within the horizon) → single occurrences as one-off `.once`
        ///   tasks, re-armed and extended on every reconcile (v0.14.1 H3).
        ///
        /// **R5 — the runway depth is the budget, not a constant.** Which
        /// occurrences are armed comes from ``MedicationReminderRunway/plan(for:now:timeZone:budget:)``:
        /// the repeating triggers are reserved first, every entry keeps its next
        /// dose, and the rest of the 48 SpeziScheduler slots go to the earliest
        /// occurrences across all medications. Up to R5 each entry got a fixed
        /// eight, which for three doses a day is under three days of reminders.
        /// The last armed occurrence of an entry whose course goes on is tagged
        /// ``runwayTailTag``; its banner asks the user to open the app.
        static func plannedProjections(
            for medications: [Medication],
            now: Date,
            timeZone: TimeZone = .current
        ) -> [PlannedProjection] {
            let plan = MedicationReminderRunway.plan(for: medications, now: now, timeZone: timeZone)
            var result: [PlannedProjection] = []
            for medication in medications where plansReminders(for: medication) {
                let context = MedicationRecurrenceEngine.Context(medication: medication, timeZone: timeZone, now: now)
                // R1 — a repeating daily/weekly trigger knows neither a first nor
                // a last day: it fired before `startsOn` and kept firing after
                // `endsOn`, on days the server lists no dose. Such a course rides
                // the engine runway instead, which honours both calendar days.
                let repeats = MedicationRecurrenceEngine.repeatingRuleFits(
                    context: context, now: now, endHorizon: preArmHorizon
                )
                var projections: [Projection] = []
                for (entryIndex, entry) in medication.schedule.entries.enumerated() where entry.cadence != .asNeeded {
                    if MedicationReminderRunway.ridesRunway(entry, repeats: repeats, context: context, now: now) {
                        let key = MedicationReminderRunway.EntryKey(medicationID: medication.id, entryIndex: entryIndex)
                        appendRunway(plan.runways[key], entryIndex: entryIndex, into: &projections)
                    } else {
                        appendRepeating(entry: entry, entryIndex: entryIndex, now: now, into: &projections)
                    }
                }
                result += projections.map { PlannedProjection(medicationID: medication.id, projection: $0) }
            }
            return result
        }

        /// The repeating trigger(s) of an entry that does not ride the runway.
        private static func appendRepeating(
            entry: ScheduleEntry,
            entryIndex: Int,
            now: Date,
            into result: inout [Projection]
        ) {
            switch entry.cadence {
            case .daily:
                appendDaily(entry: entry, entryIndex: entryIndex, into: &result)
            case let .weekdays(days), let .everyNWeeks(_, days):
                // `everyNWeeks` only gets here with interval 1 — a recurring
                // Spezi `.weekly(interval: N)` would anchor the N-week phase on
                // reconcile time, so interval > 1 rides the runway (H3).
                appendWeekly(entry: entry, entryIndex: entryIndex, days: days, interval: 1, into: &result)
            case let .legacy(days, intervalWeeks):
                if let days, !days.isEmpty {
                    appendWeekly(entry: entry, entryIndex: entryIndex, days: days, interval: max(1, intervalWeeks), into: &result)
                } else {
                    appendDaily(entry: entry, entryIndex: entryIndex, into: &result)
                }
            case let .monthly(day), let .everyNMonths(_, day):
                for (timeIndex, time) in entry.effectiveTimes.enumerated() {
                    result.append(Projection(
                        slotKey: "e\(entryIndex)-m-t\(timeIndex)",
                        schedule: .monthly(interval: 1, day: day, hour: time.hour, minute: time.minute, startingAt: now)
                    ))
                }
            case let .yearly(month, day):
                for (timeIndex, time) in entry.effectiveTimes.enumerated() {
                    result.append(Projection(
                        slotKey: "e\(entryIndex)-y-t\(timeIndex)",
                        schedule: .yearly(
                            interval: 1, month: month, day: day,
                            hour: time.hour, minute: time.minute, startingAt: now
                        )
                    ))
                }
            case .rolling, .oneShot, .cyclic, .asNeeded:
                // Always a runway (or nothing) — `ridesRunway` never sends these here.
                break
            }
        }

        private static func appendDaily(
            entry: ScheduleEntry,
            entryIndex: Int,
            into result: inout [Projection]
        ) {
            for (timeIndex, time) in entry.effectiveTimes.enumerated() {
                result.append(Projection(
                    slotKey: "e\(entryIndex)-d-t\(timeIndex)",
                    schedule: .daily(interval: 1, hour: time.hour, minute: time.minute, startingAt: .now)
                ))
            }
        }

        private static func appendWeekly(
            entry: ScheduleEntry,
            entryIndex: Int,
            days: Set<Weekday>,
            interval: Int,
            into result: inout [Projection]
        ) {
            let sortedDays = days.sorted { $0.rawValue < $1.rawValue }
            for weekday in sortedDays {
                for (timeIndex, time) in entry.effectiveTimes.enumerated() {
                    result.append(Projection(
                        slotKey: "e\(entryIndex)-w\(weekday.rawValue)-t\(timeIndex)",
                        schedule: .weekly(
                            interval: interval,
                            weekday: localeWeekday(from: weekday),
                            hour: time.hour,
                            minute: time.minute,
                            startingAt: .now
                        )
                    ))
                }
            }
        }

        /// Tag on the last armed occurrence of a runway whose course goes on.
        /// `HealthLogStandard` adds the "open the app" line to that banner.
        static let runwayTailTag = "runway-tail"

        /// The forward window over which single occurrences are materialized.
        /// Kept in lock-step with `SchedulerNotifications.schedulingInterval`
        /// (8 weeks, `HealthLogSpeziDelegate`) so every armed `.once` task falls
        /// inside the window SpeziScheduler turns into a pending
        /// `UNNotificationRequest`. The immediate next occurrence is always
        /// armed even if it lies past the horizon (the pre-H3 "next dose is
        /// always queued" guarantee); only the additional runway is capped.
        static let preArmHorizon: TimeInterval = MedicationReminderRunway.horizon

        /// The armed occurrences of one runway entry as `.once` tasks.
        private static func appendRunway(
            _ runway: MedicationReminderRunway.Runway?,
            entryIndex: Int,
            into result: inout [Projection]
        ) {
            guard let runway else { return }
            let lastIndex = runway.occurrences.count - 1
            for (index, instant) in runway.occurrences.enumerated() {
                result.append(Projection(
                    slotKey: "e\(entryIndex)-once-\(index)",
                    schedule: Schedule(startingAt: instant, recurrence: nil),
                    isRunwayTail: runway.continuesAfterLast && index == lastIndex
                ))
            }
        }

        /// Drop every existing `med-` task whose id is NOT in
        /// `desiredTaskIDs`. Mirrors the legacy `scheduleLocalBackups`
        /// "cancel-then-re-add" sweep but at the SwiftData persistence
        /// layer — `Scheduler.deleteAllVersions` cancels pending
        /// notifications for that task automatically when the save
        /// tick runs.
        private func purgeOrphanedTasks(keeping desiredTaskIDs: Set<String>) {
            do {
                // `queryAllTasks` is `@_spi(TestingSupport)` upstream;
                // the public surface is `queryTasks(for: Range<Date>)`,
                // so we query a wide effective range that comfortably
                // covers every task version Spezi has stored
                // (`distantPast ..< distantFuture` works but is over-
                // wide; the practical range is 5 years backward + 5
                // years forward, which covers every plausible
                // medication-schedule effectiveFrom we will encounter).
                let calendar = Calendar.current
                let now = Date()
                let lowerBound = calendar.date(byAdding: .year, value: -5, to: now) ?? .distantPast
                let upperBound = calendar.date(byAdding: .year, value: 5, to: now) ?? .distantFuture
                let allTasks = try scheduler.queryTasks(for: lowerBound ..< upperBound)
                let toPurge = Self.orphanTaskIDs(
                    existing: Set(allTasks.map { (task: SpeziScheduler.Task) -> String in task.id }),
                    desired: desiredTaskIDs
                )
                for staleID in toPurge {
                    do {
                        try scheduler.deleteAllVersions(ofTask: staleID)
                        HLLog.notifications.debug(
                            "MedicationsSchedulerModule: purged orphan task id=\(staleID, privacy: .private)"
                        )
                    } catch {
                        HLLog.notifications.error(
                            "MedicationsSchedulerModule: deleteAllVersions failed id=\(staleID, privacy: .private) err=\(LogSanitizer.redact(String(describing: error)), privacy: .private)"
                        )
                    }
                }
            } catch {
                HLLog.notifications.error(
                    "MedicationsSchedulerModule: queryAllTasks failed err=\(LogSanitizer.redact(String(describing: error)), privacy: .public)"
                )
            }
        }

        // MARK: - Task ID helpers

        /// Build a deterministic task id from a `(medicationId,
        /// scheduleSlot)` pair. Stable across launches so the same
        /// medication-time-of-day always projects to the same
        /// SpeziScheduler `Task` — that's what makes `createOrUpdate-
        /// Task` idempotent.
        static func taskID(medicationID: String, scheduleSlot: Int) -> String {
            "\(taskIDPrefix)\(medicationID)\(taskIDSlotSeparator)\(scheduleSlot)"
        }

        /// v0.10 R1 §3.4 — task id from a string slot key (`e0-w1-t0`,
        /// `e0-once`, …). The slot key never contains `taskIDSlotSeparator`
        /// (`__slot-`), so `medicationId(fromTaskID:)` still round-trips the
        /// medication id back out cleanly.
        static func taskID(medicationID: String, slotKey: String) -> String {
            "\(taskIDPrefix)\(medicationID)\(taskIDSlotSeparator)\(slotKey)"
        }

        /// Reverse of `taskID(medicationID:scheduleSlot:)`. Returns
        /// `nil` if the id is malformed or doesn't carry the medication-
        /// prefix — defensive against future scheduler clients writing
        /// non-medication tasks the constraint hook should ignore.
        static func medicationId(fromTaskID taskID: String) -> String? {
            guard taskID.hasPrefix(taskIDPrefix) else { return nil }
            let withoutPrefix = taskID.dropFirst(taskIDPrefix.count)
            guard let slotRange = withoutPrefix.range(of: taskIDSlotSeparator) else {
                return nil
            }
            return String(withoutPrefix[..<slotRange.lowerBound])
        }

        /// Returns a synthetic schedule-slot id derived from the task
        /// id. Used by the notification constraint to populate the
        /// `scheduleId` field on the userInfo dict so the server
        /// mark-intake POST carries a coherent `scheduleId` value for
        /// observability, even though the slot index is not what the
        /// server-side schedule row id would be. Server tolerates any
        /// string (it only matches by medicationId + scheduledFor).
        static func scheduleId(fromTaskID taskID: String) -> String? {
            guard taskID.hasPrefix(taskIDPrefix),
                  let slotRange = taskID.range(of: taskIDSlotSeparator) else
            {
                return nil
            }
            let slotIndexSlice = taskID[slotRange.upperBound...]
            return slotIndexSlice.isEmpty ? nil : String(slotIndexSlice)
        }

        // MARK: - Schedule construction

        /// Project a HealthLog `(time, weekdays, intervalWeeks)` triple
        /// onto a Spezi `Schedule`. The mapping:
        /// - `intervalWeeks > 1` + weekdays present → `.weekly(interval:N,
        ///   weekday:first, ...)`. Spezi's `.weekly` factory accepts only
        ///   a single weekday in its convenience form — for `weekdays
        ///   .count > 1` we currently project to the **first** weekday
        ///   (sorted ascending) because Spezi 1.2.x's notification
        ///   matching hint logic is only sound for single-weekday
        ///   recurrences. Multi-weekday biweekly schedules are rare in
        ///   the operator's medication set; if they surface we widen the
        ///   adapter to multiple Spezi tasks per weekday.
        /// - `intervalWeeks == 1` + weekdays present → `.weekly(interval:1,
        ///   weekday:first, ...)` for the same reason. Multi-weekday
        ///   weekly schedules require splitting into N tasks; deferred to
        ///   a follow-up.
        /// - `intervalWeeks == 1` + no weekdays → `.daily(hour:minute:
        ///   startingAt:)`. The default.
        ///
        /// **`startingAt: now` rationale:** Spezi snaps the start date
        /// to the wall-clock time-of-day in the factory call; the actual
        /// first banner fires at the **next** matching moment, which is
        /// what the operator expects (a med-reminder created at 14:00
        /// for 09:00 should fire tomorrow at 09:00, not today at 09:00).
        static func buildSchedule(
            time: TimeOfDay,
            weekdays: Set<Weekday>?,
            intervalWeeks: Int,
            now: Date
        ) -> Schedule {
            let interval = max(1, min(4, intervalWeeks))
            if let weekdays, let firstWeekday = weekdays.sorted(by: { $0.rawValue < $1.rawValue }).first {
                let localeWeekday = Self.localeWeekday(from: firstWeekday)
                return .weekly(
                    interval: interval,
                    weekday: localeWeekday,
                    hour: time.hour,
                    minute: time.minute,
                    startingAt: now
                )
            }
            return .daily(
                interval: 1,
                hour: time.hour,
                minute: time.minute,
                startingAt: now
            )
        }

        /// Map our `Weekday` (server-aligned: `sun = 0 … sat = 6`) onto
        /// Foundation's `Locale.Weekday`. Apple's enum starts at
        /// `monday`; we route via the explicit case-mapping to keep the
        /// projection table grep-able.
        static func localeWeekday(from weekday: Weekday) -> Locale.Weekday {
            switch weekday {
            case .sun: .sunday
            case .mon: .monday
            case .tue: .tuesday
            case .wed: .wednesday
            case .thu: .thursday
            case .fri: .friday
            case .sat: .saturday
            }
        }

        // MARK: - Localized strings

        /// Title shown on the banner. The medication name is fed
        /// through the `String.LocalizationValue` initialiser as a
        /// substituted argument so the German / English copy stays in
        /// `Localizable.xcstrings`.
        static func localizedTitle(for medication: Medication) -> String.LocalizationValue {
            // The medication name itself is user data, not a localized
            // string — we splice it into the localized template. The
            // template lives under the `medication.reminder.title`
            // xcstrings key.
            String.LocalizationValue(stringLiteral: medication.name)
        }

        /// Body shown on the banner. Mirrors the legacy `scheduleLocal-
        /// Backups` "Erinnerung — bitte einnehmen." copy, dose-aware:
        /// "Lisinopril 5 mg — bitte einnehmen." renders cleanly inside the
        /// 4-line banner budget.
        static func localizedInstructions(for medication: Medication) -> String.LocalizationValue {
            // Same xcstrings strategy as the title — the dose is user
            // data interpolated into a localized template, but for the
            // first ship we splice in plain-language to avoid breaking
            // the strings catalog mid-marathon. The follow-up ticket
            // moves both title + body to dedicated xcstrings keys.
            String.LocalizationValue(stringLiteral: medication.dose)
        }
    }

    /// Course-bound checks of the projection, outside the module's type body
    /// (type_body_length discipline).
    extension MedicationsSchedulerModule {
        /// A repeating calendar trigger cannot fence a course; see
        /// ``MedicationReminderRunway/boundsAllowRepeatingTrigger(context:now:)``.
        static func boundsAllowRepeatingTrigger(
            context: MedicationRecurrenceEngine.Context,
            now: Date
        ) -> Bool {
            MedicationReminderRunway.boundsAllowRepeatingTrigger(context: context, now: now)
        }

        /// See ``MedicationReminderRunway/isStableYearlyDay(month:day:)``.
        static func isStableYearlyDay(month: Int, day: Int) -> Bool {
            MedicationReminderRunway.isStableYearlyDay(month: month, day: day)
        }
    }
#endif
