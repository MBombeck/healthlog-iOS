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
            for medication in medications where medication.active && medication.notificationsEnabled {
                let projections = Self.projections(for: medication, now: now)
                for projection in projections {
                    let taskID = Self.taskID(medicationID: medication.id, slotKey: projection.slotKey)
                    desiredTaskIDs.insert(taskID)
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
                            tags: ["medication", "schedule:\(projection.slotKey)"],
                            shadowedOutcomesHandling: .delete
                        )
                    } catch {
                        HLLog.notifications.error(
                            "MedicationsSchedulerModule: createOrUpdateTask failed id=\(taskID, privacy: .private) err=\(LogSanitizer.redact(String(describing: error)), privacy: .private)"
                        )
                    }
                }
            }
            // v0.14.1 notifications-bug H4 — budget telemetry. Each desired task
            // is one prospective pending local notification drawing from the
            // shared 64-request cap (SpeziScheduler capped at 48). When the
            // projected set approaches the cap, log it: SpeziScheduler schedules
            // earliest-first up to its limit and registers a background top-up for
            // the tail, so the overflow is DEFERRED, not silently dropped — but a
            // persistently high count is the operator-visible signal that the H3
            // pre-arm depth / horizon may need trimming.
            if desiredTaskIDs.count >= Self.budgetTelemetryThreshold {
                // Slot count is not PII — public is intentional (operator-grade).
                // swiftlint:disable:next hllog_public_privacy_interpolation
                HLLog.notifications.warning(
                    "MedicationsSchedulerModule: \(desiredTaskIDs.count, privacy: .public) reminder slots projected — approaching the shared local-notification budget (SpeziScheduler cap 48); tail is background-topped-up, not dropped"
                )
            }
            purgeOrphanedTasks(keeping: desiredTaskIDs)
        }

        /// Threshold at which `reconcile` emits the budget-telemetry warning.
        /// Set below the SpeziScheduler cap (48) so the operator log surfaces a
        /// crowding trend before the tail actually spills to the background
        /// top-up path.
        static let budgetTelemetryThreshold = 40

        /// One projected SpeziScheduler task for a medication. `slotKey`
        /// uniquely identifies the (entry × weekday × time) slot within the
        /// medication; `reconcile` prefixes the medication id to form the full
        /// task id.
        struct Projection {
            let slotKey: String
            let schedule: Schedule
        }

        /// **v0.10 R1 §3.4 — project a medication's `ScheduleEntry` rows onto
        /// SpeziScheduler tasks.**
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
        /// - `everyNWeeks(interval > 1)` / `everyNMonths(interval > 1)` /
        ///   `rolling` / `oneShot` / `cyclic` / day-29–31 monthly / Feb-29 yearly
        ///   / bounded (`startsOn`/`endsOn`) schedules → cannot be a single
        ///   repeating trigger, so PRE-ARM a runway of the next occurrences
        ///   (`engine.nextOccurrence`) as one-off `.once` tasks (v0.14.1 H3),
        ///   re-armed + extended on every reconcile. Honours `startsOn`/`endsOn`.
        static func projections(for medication: Medication, now: Date) -> [Projection] {
            let context = MedicationRecurrenceEngine.Context(
                medication: medication,
                timeZone: .current,
                now: now
            )
            var result: [Projection] = []
            for (entryIndex, entry) in medication.schedule.entries.enumerated() {
                switch entry.cadence {
                case .daily:
                    appendDaily(entry: entry, entryIndex: entryIndex, into: &result)
                case let .weekdays(days):
                    appendWeekly(entry: entry, entryIndex: entryIndex, days: days, interval: 1, into: &result)
                case let .everyNWeeks(interval, days):
                    // v0.14.1 notifications-bug H3 — interval > 1 is a single-slot
                    // cadence (`isSingleSlotCadence` agrees). A recurring Spezi
                    // `.weekly(interval:N, startingAt: .now)` would anchor the
                    // N-week phase on reconcile-time, NOT the server's Sunday-
                    // rooted schedule phase — firing a week out of sync from
                    // `nextDueAt` + the compliance grid. Pre-arm a RUNWAY of the
                    // next phase-correct occurrences (was a single next occurrence)
                    // via the engine instead, so a backgrounded / force-quit app
                    // keeps iOS-delivered notifications queued. Plain weekly
                    // (interval == 1) stays a recurring `.weekly` rule.
                    if max(1, interval) > 1 {
                        appendPreArmedOccurrences(entry: entry, entryIndex: entryIndex, context: context, now: now, into: &result)
                    } else {
                        appendWeekly(
                            entry: entry, entryIndex: entryIndex,
                            days: days, interval: 1, into: &result
                        )
                    }
                case let .legacy(days, intervalWeeks):
                    if let days, !days.isEmpty {
                        appendWeekly(
                            entry: entry, entryIndex: entryIndex,
                            days: days, interval: max(1, intervalWeeks), into: &result
                        )
                    } else if intervalWeeks > 1 {
                        appendPreArmedOccurrences(entry: entry, entryIndex: entryIndex, context: context, now: now, into: &result)
                    } else {
                        appendDaily(entry: entry, entryIndex: entryIndex, into: &result)
                    }
                case .monthly, .everyNMonths, .yearly, .rolling, .oneShot, .cyclic:
                    // v0.14.1 notifications-bug H1/H3 — monthly/yearly may lift to
                    // an OS-repeating trigger; the rest pre-arm an engine runway.
                    // Dispatched in a dedicated helper so this switch stays within
                    // the cyclomatic-complexity budget.
                    appendLowFrequencyProjections(entry: entry, entryIndex: entryIndex, context: context, now: now, into: &result)
                case .asNeeded:
                    // PRN / as-needed — no reminder task is ever armed.
                    continue
                }
            }
            return result
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

        /// **v0.14.1 notifications-bug H3 — pre-arm depth.** How many future
        /// occurrences to pre-schedule for a cadence that cannot be expressed as
        /// a single OS-repeating trigger (everyNWeeks > 1, everyNMonths > 1,
        /// rolling, cyclic, day-29–31 monthly, Feb-29 yearly, bounded schedules).
        /// Each becomes one `.once` Spezi task, so a backgrounded / force-quit
        /// app keeps a runway of iOS-delivered notifications instead of a single
        /// next occurrence that fires once and then goes silent (the operator
        /// bug). Bounded to protect the shared 64-pending budget — SpeziScheduler
        /// is capped at 48 (`LocalNotificationBudget.speziNotificationLimit`) and
        /// round-robins the slots across tasks earliest-first, so a heavy runway
        /// never starves the daily/weekly repeating triggers.
        static let maxPreArmedOccurrences = 8

        /// The forward window over which pre-armed occurrences are materialized.
        /// Kept in lock-step with `SchedulerNotifications.schedulingInterval`
        /// (8 weeks, `HealthLogSpeziDelegate`) so every pre-armed `.once` task
        /// falls inside the window SpeziScheduler turns into a pending
        /// `UNNotificationRequest` — a horizon deeper than the scheduling window
        /// would just leave the tail unscheduled until the next background
        /// refresh. The immediate next occurrence is always armed even if it is
        /// past the horizon (preserving the pre-H3 "next dose is always queued"
        /// guarantee); only the ADDITIONAL runway is horizon-capped.
        static let preArmHorizon: TimeInterval = 8 * 7 * 24 * 60 * 60

        /// Dispatch the low-frequency cadences (`monthly` / `everyNMonths` /
        /// `yearly` / `rolling` / `oneShot` / `cyclic`) onto their projection.
        /// Monthly + yearly may lift to an OS-repeating trigger (H1); rolling /
        /// one-shot / cyclic always pre-arm an engine runway (H3). Extracted from
        /// the `projections` switch to keep that switch within the
        /// cyclomatic-complexity budget. Only invoked for those six cadences —
        /// the `default` arm is the pre-arm runway shared by rolling/oneShot/cyclic.
        private static func appendLowFrequencyProjections(
            entry: ScheduleEntry,
            entryIndex: Int,
            context: MedicationRecurrenceEngine.Context,
            now: Date,
            into result: inout [Projection]
        ) {
            switch entry.cadence {
            case let .monthly(day):
                appendMonthlyOrPreArm(
                    entry: entry, entryIndex: entryIndex,
                    day: day, interval: 1, context: context, now: now, into: &result
                )
            case let .everyNMonths(interval, day):
                appendMonthlyOrPreArm(
                    entry: entry, entryIndex: entryIndex,
                    day: day, interval: max(1, interval), context: context, now: now, into: &result
                )
            case let .yearly(month, day):
                appendYearlyOrPreArm(
                    entry: entry, entryIndex: entryIndex,
                    month: month, day: day, context: context, now: now, into: &result
                )
            default:
                // rolling / oneShot / cyclic — no single OS-repeating trigger can
                // express these (rolling re-anchors on each intake; cyclic on/off
                // -weeks + one-shot have no calendar-trigger form). Off-weeks / a
                // past one-shot emit no occurrence → no slot.
                appendPreArmedOccurrences(entry: entry, entryIndex: entryIndex, context: context, now: now, into: &result)
            }
        }

        /// Monthly / every-N-months projection. **H1:** an interval-1 cadence
        /// whose day-of-month exists in every month (≤ 28) on an unbounded,
        /// already-started schedule is lifted to an OS-delivered REPEATING
        /// `.monthly` calendar trigger (`repeats: true`) — no re-arm, survives
        /// background / force-quit / Background-App-Refresh-off. Everything else
        /// (interval > 1, day 29–31 where the server-parity clamp must be
        /// preserved rather than skipping short months, or a bounded schedule a
        /// repeating trigger can't fence) falls back to the H3 engine runway.
        private static func appendMonthlyOrPreArm(
            entry: ScheduleEntry,
            entryIndex: Int,
            day: Int,
            interval: Int,
            context: MedicationRecurrenceEngine.Context,
            now: Date,
            into result: inout [Projection]
        ) {
            guard interval == 1, day <= 28, boundsAllowRepeatingTrigger(context: context, now: now) else {
                appendPreArmedOccurrences(entry: entry, entryIndex: entryIndex, context: context, now: now, into: &result)
                return
            }
            for (timeIndex, time) in entry.effectiveTimes.enumerated() {
                result.append(Projection(
                    slotKey: "e\(entryIndex)-m-t\(timeIndex)",
                    schedule: .monthly(
                        interval: 1,
                        day: day,
                        hour: time.hour,
                        minute: time.minute,
                        startingAt: now
                    )
                ))
            }
        }

        /// Yearly projection. **H1:** an annual cadence on a `(month, day)` that
        /// exists every year, on an unbounded already-started schedule, is lifted
        /// to an OS-delivered REPEATING `.yearly` calendar trigger. Feb-29 (and
        /// any day beyond the month's common-year length) or a bounded schedule
        /// falls back to the H3 engine runway.
        private static func appendYearlyOrPreArm(
            entry: ScheduleEntry,
            entryIndex: Int,
            month: Int,
            day: Int,
            context: MedicationRecurrenceEngine.Context,
            now: Date,
            into result: inout [Projection]
        ) {
            guard isStableYearlyDay(month: month, day: day),
                  boundsAllowRepeatingTrigger(context: context, now: now) else
            {
                appendPreArmedOccurrences(entry: entry, entryIndex: entryIndex, context: context, now: now, into: &result)
                return
            }
            for (timeIndex, time) in entry.effectiveTimes.enumerated() {
                result.append(Projection(
                    slotKey: "e\(entryIndex)-y-t\(timeIndex)",
                    schedule: .yearly(
                        interval: 1,
                        month: month,
                        day: day,
                        hour: time.hour,
                        minute: time.minute,
                        startingAt: now
                    )
                ))
            }
        }

        /// A repeating `UNCalendarNotificationTrigger` fires indefinitely and
        /// cannot express a start floor or an end cap. So only lift a cadence to
        /// a repeating trigger when the medication has already started (no future
        /// `startsOn`) and never ends (`endsOn == nil`); bounded schedules ride
        /// the engine pre-arm, which honours `startsOn` / `endsOn`.
        static func boundsAllowRepeatingTrigger(
            context: MedicationRecurrenceEngine.Context,
            now: Date
        ) -> Bool {
            if context.endsOn != nil { return false }
            if let startsOn = context.startsOn, startsOn > now { return false }
            return true
        }

        /// Whether `(month, day)` occurs in every common (non-leap) year, so a
        /// yearly repeating calendar trigger fires exactly on it. Feb-29 and any
        /// day beyond the month's common-year length are excluded (they'd skip
        /// years, diverging from the server-parity clamp).
        static func isStableYearlyDay(month: Int, day: Int) -> Bool {
            let commonYearDays = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
            guard (1 ... 12).contains(month), day >= 1 else { return false }
            return day <= commonYearDays[month - 1]
        }

        /// **v0.14.1 notifications-bug H3 — pre-arm the next occurrences as a
        /// runway.** Walks the server-parity `MedicationRecurrenceEngine` forward
        /// (phase-, DST-, clamp-, `startsOn`/`endsOn`-, `serverNextDueAt`-correct),
        /// feeding each occurrence's instant back as the floor for the next, and
        /// emits up to `maxPreArmedOccurrences` one-off `.once` tasks. The
        /// immediate next occurrence is ALWAYS armed (matching the pre-H3
        /// guarantee); additional runway occurrences are capped at `preArmHorizon`
        /// so the tail can't outrun SpeziScheduler's materialization window.
        /// Rolling / one-shot naturally yield a single slot (a rolling anchor only
        /// projects one forward slot; a one-shot has exactly one occurrence).
        private static func appendPreArmedOccurrences(
            entry: ScheduleEntry,
            entryIndex: Int,
            context: MedicationRecurrenceEngine.Context,
            now: Date,
            into result: inout [Projection]
        ) {
            let horizonEnd = now.addingTimeInterval(preArmHorizon)
            var cursor = now
            var count = 0
            while count < maxPreArmedOccurrences {
                guard let next = MedicationRecurrenceEngine.nextOccurrence(
                    after: cursor,
                    entry: entry,
                    context: context
                ) else { break }
                // Always arm the immediate next occurrence; horizon-cap the rest.
                if count > 0, next.at > horizonEnd { break }
                result.append(Projection(
                    slotKey: "e\(entryIndex)-once-\(count)",
                    schedule: Schedule(startingAt: next.at, recurrence: nil)
                ))
                cursor = next.at
                count += 1
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
                let medicationTaskIDs = Set(
                    allTasks
                        .map { (task: SpeziScheduler.Task) -> String in task.id }
                        .filter { (id: String) -> Bool in id.hasPrefix(Self.taskIDPrefix) }
                )
                let toPurge = medicationTaskIDs.subtracting(desiredTaskIDs)
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
#endif
