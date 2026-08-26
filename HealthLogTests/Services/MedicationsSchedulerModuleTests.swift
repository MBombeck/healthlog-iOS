import Foundation
import Testing
#if canImport(SpeziScheduler) && canImport(UserNotifications)
    @testable import HealthLog
    import SpeziScheduler
    import UserNotifications

    /// v0.6.0.7 Spezi Phase E — unit coverage for the
    /// `MedicationsSchedulerModule` reconcile path + the
    /// `HealthLogStandard: SchedulerNotificationsConstraint` rewrite
    /// hook.
    ///
    /// The full reconcile path runs against a live `Scheduler` module,
    /// which Spezi only mounts inside a configured `SpeziAppDelegate`.
    /// We exercise the pieces that don't require the module graph here:
    ///
    /// 1. **Task ID round-trip** — `taskID(medicationID:scheduleSlot:)`
    ///    → `medicationId(fromTaskID:)` reverses cleanly for every
    ///    medication-id shape the server emits (Cuid, nanoid).
    /// 2. **Schedule construction** — `buildSchedule(time:weekdays:
    ///    intervalWeeks:now:)` projects daily / weekly / biweekly
    ///    HealthLog schedules onto the matching Spezi `.daily` /
    ///    `.weekly(interval:N)` factory.
    /// 3. **`SchedulerNotificationsConstraint` rewrite** — given a
    ///    Spezi-built `UNMutableNotificationContent` for a medication
    ///    task, the constraint hook rewrites `categoryIdentifier` back
    ///    to `MEDICATION_REMINDER` and injects a `medicationId` +
    ///    `eventType` userInfo so `dispatchAction` can drive the
    ///    server mark-intake.
    @Suite("MedicationsSchedulerModule — pure helpers + projection")
    @MainActor
    struct MedicationsSchedulerModuleTests {
        // MARK: - Task ID round-trip

        @Test("taskID + medicationId roundtrip for cuid-shaped ids")
        func taskIDRoundTripCuid() {
            let medID = "clx7y4k1p0000abcd"
            let taskID = MedicationsSchedulerModule.taskID(medicationID: medID, scheduleSlot: 0)
            #expect(taskID.hasPrefix(MedicationsSchedulerModule.taskIDPrefix))
            #expect(MedicationsSchedulerModule.medicationId(fromTaskID: taskID) == medID)
            #expect(MedicationsSchedulerModule.scheduleId(fromTaskID: taskID) == "0")
        }

        @Test("taskID encodes the schedule slot index")
        func taskIDRoundTripSlots() {
            let medID = "test-med"
            let zero = MedicationsSchedulerModule.taskID(medicationID: medID, scheduleSlot: 0)
            let one = MedicationsSchedulerModule.taskID(medicationID: medID, scheduleSlot: 1)
            let two = MedicationsSchedulerModule.taskID(medicationID: medID, scheduleSlot: 2)
            #expect(zero != one)
            #expect(one != two)
            // medicationId returns the same id regardless of slot
            #expect(MedicationsSchedulerModule.medicationId(fromTaskID: zero) == medID)
            #expect(MedicationsSchedulerModule.medicationId(fromTaskID: one) == medID)
            #expect(MedicationsSchedulerModule.medicationId(fromTaskID: two) == medID)
            // scheduleId reads back the slot index
            #expect(MedicationsSchedulerModule.scheduleId(fromTaskID: zero) == "0")
            #expect(MedicationsSchedulerModule.scheduleId(fromTaskID: one) == "1")
            #expect(MedicationsSchedulerModule.scheduleId(fromTaskID: two) == "2")
        }

        @Test("medicationId returns nil for non-medication task ids")
        func medicationIdRejectsForeignPrefix() {
            #expect(MedicationsSchedulerModule.medicationId(fromTaskID: "questionnaire-daily") == nil)
            #expect(MedicationsSchedulerModule.medicationId(fromTaskID: "") == nil)
            #expect(MedicationsSchedulerModule.medicationId(fromTaskID: "med-no-slot-separator") == nil)
        }

        // MARK: - Schedule projection

        @Test("daily schedule with no weekdays produces a daily Spezi schedule")
        func dailyScheduleNoWeekdays() {
            let time = TimeOfDay(hour: 9, minute: 0)
            let schedule = MedicationsSchedulerModule.buildSchedule(
                time: time,
                weekdays: nil,
                intervalWeeks: 1,
                now: Date()
            )
            // The recurrence rule must be present + must be a daily one.
            // Spezi's RecurrenceRule wraps `Calendar.RecurrenceRule`
            // whose `frequency` field is the public surface.
            let recurrence = schedule.recurrence
            #expect(recurrence != nil)
            #expect(recurrence?.frequency == .daily)
        }

        @Test("weekly schedule with weekdays produces a weekly Spezi schedule")
        func weeklyScheduleWithWeekdays() {
            let time = TimeOfDay(hour: 21, minute: 0)
            let schedule = MedicationsSchedulerModule.buildSchedule(
                time: time,
                weekdays: [.mon, .wed, .fri],
                intervalWeeks: 1,
                now: Date()
            )
            let recurrence = schedule.recurrence
            #expect(recurrence != nil)
            #expect(recurrence?.frequency == .weekly)
            #expect(recurrence?.interval == 1)
        }

        @Test("biweekly schedule projects intervalWeeks onto Spezi interval")
        func biweeklyScheduleProjection() {
            // GLP-1 typical: weekly intervalWeeks=2 ("every other week")
            // with a single weekday entry.
            let time = TimeOfDay(hour: 8, minute: 30)
            let schedule = MedicationsSchedulerModule.buildSchedule(
                time: time,
                weekdays: [.tue],
                intervalWeeks: 2,
                now: Date()
            )
            let recurrence = schedule.recurrence
            #expect(recurrence != nil)
            #expect(recurrence?.frequency == .weekly)
            #expect(recurrence?.interval == 2)
        }

        @Test("intervalWeeks clamps to the 1...4 range")
        func intervalClamps() {
            let time = TimeOfDay(hour: 10, minute: 0)
            // Above the cap — must clamp to 4
            let above = MedicationsSchedulerModule.buildSchedule(
                time: time,
                weekdays: [.wed],
                intervalWeeks: 99,
                now: Date()
            )
            #expect(above.recurrence?.interval == 4)
            // Below the floor — must clamp to 1
            let below = MedicationsSchedulerModule.buildSchedule(
                time: time,
                weekdays: [.wed],
                intervalWeeks: 0,
                now: Date()
            )
            #expect(below.recurrence?.interval == 1)
        }

        // MARK: - Locale.Weekday mapping

        @Test("Weekday maps to the corresponding Locale.Weekday")
        func weekdayMappingCovered() {
            // Sample-test the case-mapping for every weekday case; the
            // mapping table is exhaustive in code but we pin the
            // sun = 0 / mon = 1 / … convention by walking each.
            #expect(MedicationsSchedulerModule.localeWeekday(from: .sun) == .sunday)
            #expect(MedicationsSchedulerModule.localeWeekday(from: .mon) == .monday)
            #expect(MedicationsSchedulerModule.localeWeekday(from: .tue) == .tuesday)
            #expect(MedicationsSchedulerModule.localeWeekday(from: .wed) == .wednesday)
            #expect(MedicationsSchedulerModule.localeWeekday(from: .thu) == .thursday)
            #expect(MedicationsSchedulerModule.localeWeekday(from: .fri) == .friday)
            #expect(MedicationsSchedulerModule.localeWeekday(from: .sat) == .saturday)
        }

        // MARK: - v0.10 R1 §3.4 — per-entry cadence projection

        private static func med(
            id: String = "med-x",
            cadence: Cadence,
            time: TimeOfDay = TimeOfDay(hour: 9, minute: 0),
            lastTakenAt: Date? = nil,
            startsOn: Date? = nil,
            endsOn: Date? = nil,
            oneShot: Bool = false
        ) -> Medication {
            let entry = ScheduleEntry(cadence: cadence, timesOfDay: [time], windowStart: time)
            return Medication(
                id: id,
                name: "Test",
                dose: "1",
                schedule: MedicationSchedule(entries: [entry]),
                lastTakenAt: lastTakenAt,
                notificationsEnabled: true,
                active: true,
                startsOn: startsOn,
                endsOn: endsOn,
                oneShot: oneShot
            )
        }

        @Test("multi-weekday cadence fans out one Spezi task per (weekday × time)")
        func multiWeekdayFanOut() {
            let medication = Self.med(cadence: .weekdays([.mon, .wed, .fri]))
            let projections = MedicationsSchedulerModule.projections(for: medication, now: .now)
            // 3 weekdays × 1 time → 3 tasks (was 1 before the fix).
            #expect(projections.count == 3)
            let keys = Set(projections.map(\.slotKey))
            #expect(keys.count == 3)
        }

        @Test("daily cadence projects one task per time-of-day")
        func dailyPerTime() {
            let entry = ScheduleEntry(
                cadence: .daily,
                timesOfDay: [TimeOfDay(hour: 8, minute: 0), TimeOfDay(hour: 20, minute: 0)],
                windowStart: TimeOfDay(hour: 8, minute: 0)
            )
            let medication = Medication(
                id: "med-d",
                name: "Test",
                dose: "1",
                schedule: MedicationSchedule(entries: [entry]),
                notificationsEnabled: true,
                active: true
            )
            let projections = MedicationsSchedulerModule.projections(for: medication, now: .now)
            #expect(projections.count == 2)
        }

        @Test("rolling cadence projects a single one-off task (not recurring)")
        func rollingOneOff() {
            let lastTaken = Date().addingTimeInterval(-2 * 86400)
            let medication = Self.med(cadence: .rolling(intervalDays: 30), lastTakenAt: lastTaken)
            let projections = MedicationsSchedulerModule.projections(for: medication, now: .now)
            // Rolling re-anchors on each intake → only ONE forward slot exists,
            // even under the H3 pre-arm loop.
            #expect(projections.count == 1)
            #expect(projections.first?.schedule.recurrence == nil)
            #expect(projections.first?.slotKey == "e0-once-0")
        }

        // MARK: - v0.14.1 notifications-bug H1 — OS-repeating conversion

        @Test("H1 — monthly cadence (day ≤ 28, unbounded) converts to a REPEATING monthly trigger")
        func monthlyConvertsToRepeating() {
            let medication = Self.med(cadence: .monthly(day: 1))
            let projections = MedicationsSchedulerModule.projections(for: medication, now: .now)
            #expect(projections.count == 1)
            // Was a one-off `.once` (recurrence nil) that the app had to re-arm;
            // now an OS-delivered repeating `.monthly` rule that survives
            // background / force-quit.
            #expect(projections.first?.schedule.recurrence != nil)
            #expect(projections.first?.schedule.recurrence?.frequency == .monthly)
            #expect(projections.first?.slotKey == "e0-m-t0")
        }

        @Test("H1 — yearly cadence (stable month/day, unbounded) converts to a REPEATING yearly trigger")
        func yearlyConvertsToRepeating() {
            let medication = Self.med(cadence: .yearly(month: 6, day: 15))
            let projections = MedicationsSchedulerModule.projections(for: medication, now: .now)
            #expect(projections.count == 1)
            #expect(projections.first?.schedule.recurrence != nil)
            #expect(projections.first?.schedule.recurrence?.frequency == .yearly)
            #expect(projections.first?.slotKey == "e0-y-t0")
        }

        @Test("H1 — monthly day 31 stays a pre-armed runway (preserves the short-month clamp, no repeating trigger)")
        func monthlyDay31PreArmsNotRepeating() {
            // A repeating `day: 31` calendar trigger would SKIP short months
            // (Feb/Apr/…), diverging from the server-parity clamp. Day 29–31 must
            // fall back to the engine runway instead.
            let medication = Self.med(cadence: .monthly(day: 31))
            let projections = MedicationsSchedulerModule.projections(for: medication, now: .now)
            #expect(projections.count >= 1)
            #expect(projections.allSatisfy { $0.schedule.recurrence == nil })
            #expect(projections.first?.slotKey == "e0-once-0")
        }

        @Test("H1 — Feb-29 yearly stays a pre-armed runway (can't repeat exactly every year)")
        func yearlyFeb29PreArmsNotRepeating() {
            let medication = Self.med(cadence: .yearly(month: 2, day: 29))
            let projections = MedicationsSchedulerModule.projections(for: medication, now: .now)
            #expect(projections.count >= 1)
            #expect(projections.allSatisfy { $0.schedule.recurrence == nil })
        }

        @Test("H1 — a bounded (endsOn) monthly cadence pre-arms instead of a repeating trigger")
        func boundedMonthlyPreArms() {
            // A repeating trigger fires indefinitely and can't honour `endsOn` —
            // bounded schedules must ride the bounds-aware engine runway.
            let ends = Date().addingTimeInterval(400 * 86400)
            let medication = Self.med(cadence: .monthly(day: 1), endsOn: ends)
            let projections = MedicationsSchedulerModule.projections(for: medication, now: .now)
            #expect(projections.count >= 1)
            #expect(projections.allSatisfy { $0.schedule.recurrence == nil })
            #expect(projections.first?.slotKey == "e0-once-0")
        }

        // MARK: - v0.14.1 notifications-bug H3 — pre-armed runway

        @Test("H3 — everyNWeeks(interval>1) pre-arms a RUNWAY of phase-correct one-offs")
        func biweeklyPreArmsRunway() {
            // A biweekly med reconciled at an arbitrary `now` must NOT be armed
            // as a recurring `.weekly(interval:2, startingAt:.now)` (that anchors
            // the 2-week phase on reconcile-time). It routes through the engine's
            // phase-correct `nextOccurrence` — now as a RUNWAY of several future
            // one-offs (was a single one-off) so a backgrounded app keeps a queue.
            let medication = Self.med(cadence: .everyNWeeks(interval: 2, days: [.wed]))
            let projections = MedicationsSchedulerModule.projections(for: medication, now: .now)
            // Biweekly over the 8-week pre-arm horizon → at least 2 occurrences.
            #expect(projections.count >= 2)
            #expect(projections.count <= MedicationsSchedulerModule.maxPreArmedOccurrences)
            #expect(projections.allSatisfy { $0.schedule.recurrence == nil })
            #expect(projections.first?.slotKey == "e0-once-0")
            // Slot keys are unique (distinct pending-notification ids).
            #expect(Set(projections.map(\.slotKey)).count == projections.count)
        }

        @Test("H3 — everyNMonths(interval>1) pre-arms a runway (no Spezi factory for it)")
        func everyNMonthsPreArmsRunway() {
            let medication = Self.med(cadence: .everyNMonths(interval: 3, day: 10))
            let projections = MedicationsSchedulerModule.projections(for: medication, now: .now)
            #expect(projections.count >= 1)
            #expect(projections.allSatisfy { $0.schedule.recurrence == nil })
            #expect(projections.first?.slotKey == "e0-once-0")
        }

        @Test("H3 — cyclic on/off-weeks pre-arms a runway of on-week one-offs")
        func cyclicPreArmsRunway() {
            let medication = Self.med(cadence: .cyclic(weeksOn: 3, weeksOff: 1))
            let projections = MedicationsSchedulerModule.projections(for: medication, now: .now)
            #expect(projections.count >= 2)
            #expect(projections.count <= MedicationsSchedulerModule.maxPreArmedOccurrences)
            #expect(projections.allSatisfy { $0.schedule.recurrence == nil })
        }

        // MARK: - Budget — the projection set stays within the shared cap

        @Test("Budget — a realistic mixed-cadence med set stays within the Spezi 48 cap")
        func projectionBudgetWithinCap() {
            let meds: [Medication] = [
                Self.med(id: "m-daily", cadence: .daily),
                Self.med(id: "m-weekly", cadence: .weekdays([.mon, .wed, .fri])),
                Self.med(id: "m-monthly", cadence: .monthly(day: 5)),
                Self.med(id: "m-yearly", cadence: .yearly(month: 3, day: 20)),
                Self.med(id: "m-biweekly", cadence: .everyNWeeks(interval: 2, days: [.tue])),
                Self.med(id: "m-nmonths", cadence: .everyNMonths(interval: 2, day: 12)),
                Self.med(id: "m-rolling", cadence: .rolling(intervalDays: 14), lastTakenAt: Date()),
                Self.med(id: "m-cyclic", cadence: .cyclic(weeksOn: 2, weeksOff: 2))
            ]
            let total = meds.reduce(0) { acc, med in
                acc + MedicationsSchedulerModule.projections(for: med, now: .now).count
            }
            // Every pre-armed slot is one prospective pending request; the whole
            // set must fit under the SpeziScheduler budget so the tail is never
            // silently dropped.
            #expect(total <= 48)
            // Sanity: the set is non-trivial (repeating + pre-armed slots present).
            #expect(total >= meds.count)
        }

        @Test("weekly (everyNWeeks interval==1) stays a recurring weekly rule")
        func weeklyIntervalOneStaysRecurring() {
            // The interval==1 case must NOT regress to a one-off — it stays a
            // recurring `.weekly` rule (one task per weekday).
            let medication = Self.med(cadence: .everyNWeeks(interval: 1, days: [.wed]))
            let projections = MedicationsSchedulerModule.projections(for: medication, now: .now)
            #expect(projections.count == 1)
            #expect(projections.first?.schedule.recurrence != nil)
            #expect(projections.first?.schedule.recurrence?.frequency == .weekly)
            #expect(projections.first?.slotKey == "e0-w3-t0")
        }

        @Test("string-slot task id round-trips the medication id")
        func stringSlotTaskID() {
            let taskID = MedicationsSchedulerModule.taskID(medicationID: "clx7y4k1p0000abcd", slotKey: "e0-w1-t0")
            #expect(MedicationsSchedulerModule.medicationId(fromTaskID: taskID) == "clx7y4k1p0000abcd")
        }

        // MARK: - Legacy local-backup purge gate

        @Test("legacy local-backup purge marks defaults flag after run")
        func purgeMarksUserDefaultsFlag() async throws {
            // Stand up an isolated UserDefaults so we don't touch the
            // bundle default + don't pollute parallel test runs.
            let suite = "MedicationsSchedulerModuleTests.purge-\(UUID().uuidString)"
            // swiftlint:disable:next force_unwrapping
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            #expect(!defaults.bool(forKey: NotificationService.legacyLocalBackupPurgeDefaultsKey))
            await NotificationService.purgeLegacyLocalBackupsIfNeeded(defaults: defaults)
            #expect(defaults.bool(forKey: NotificationService.legacyLocalBackupPurgeDefaultsKey))
        }

        @Test("legacy local-backup purge is a no-op when flag already set")
        func purgeNoopWhenFlagSet() async throws {
            let suite = "MedicationsSchedulerModuleTests.purge-noop-\(UUID().uuidString)"
            // swiftlint:disable:next force_unwrapping
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(true, forKey: NotificationService.legacyLocalBackupPurgeDefaultsKey)
            await NotificationService.purgeLegacyLocalBackupsIfNeeded(defaults: defaults)
            #expect(defaults.bool(forKey: NotificationService.legacyLocalBackupPurgeDefaultsKey))
        }
    }
#endif
