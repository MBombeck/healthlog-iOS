import Foundation
import Testing
#if canImport(SpeziScheduler) && canImport(UserNotifications)
    @testable import HealthLog
    import SpeziScheduler

    // swiftlint:disable force_unwrapping

    /// **R1 — local reminders land on the server's days (server 1.39.3, A1).**
    ///
    /// With `clientManaged` on (N1) the app is the only reminder source, so a
    /// local reminder on a day the server lists no dose is a wrong reminder, and
    /// a missing one is a missed dose. These pin the projections the Spezi
    /// reconcile and the AlarmKit planner arm for a course in New York, where
    /// `startsOn`'s UTC midnight is the evening before:
    ///
    /// * a one-shot dose is armed on its own day, not the day before;
    /// * a daily course that has not started yet (or ends soon) is NOT a
    ///   repeating daily trigger — that one fired from tonight on and kept
    ///   firing after `endsOn` — but single occurrences between the start and
    ///   the evening of the last day;
    /// * the update path: the repeating task armed by an older build is an
    ///   orphan on the next reconcile, so it is deleted.
    @Suite("R1 — reminders and alarms honour the course's calendar days")
    @MainActor
    struct MedicationCourseDayReminderTests {
        static let newYork = TimeZone(identifier: "America/New_York")!

        static var calendar: Calendar {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = newYork
            return calendar
        }

        static func localDay(_ date: Date) -> String {
            let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            return String(format: "%04d-%02d-%02d %02d:%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!)
        }

        static func day(_ ymd: String) -> Date {
            ISO8601DateFormatter().date(from: "\(ymd)T00:00:00Z")!
        }

        static func medication(
            _ cadence: Cadence,
            times: [String],
            startsOn: String?,
            endsOn: String?,
            oneShot: Bool = false
        ) -> Medication {
            Medication(
                id: "med-ny",
                name: "Amoxicillin",
                dose: "500 mg",
                schedule: MedicationSchedule(entries: [ScheduleEntry(
                    cadence: cadence,
                    timesOfDay: times.compactMap { TimeOfDay.parse($0) },
                    windowStart: TimeOfDay(hour: 8, minute: 0)
                )]),
                notificationsEnabled: true,
                active: true,
                startsOn: startsOn.map(day),
                endsOn: endsOn.map(day),
                oneShot: oneShot,
                createdAt: ISO8601DateFormatter().date(from: "2026-09-01T12:00:00Z")
            )
        }

        /// 2026-09-13 21:30 in New York = 2026-09-14 01:30Z — already past the
        /// UTC midnight of a course that starts on the 14th.
        static let eveningBefore = ISO8601DateFormatter().date(from: "2026-09-14T01:30:00Z")!

        @Test("a one-shot dose on the 14th is armed on the 14th, not the 13th")
        func oneShotOnItsDay() {
            let med = Self.medication(.oneShot, times: ["08:00"], startsOn: "2026-09-14", endsOn: "2026-09-14", oneShot: true)
            let projections = MedicationsSchedulerModule.projections(for: med, now: Self.eveningBefore, timeZone: Self.newYork)
            #expect(projections.map { Self.localDay($0.schedule.start) } == ["2026-09-14 08:00"])
        }

        @Test("a daily course starting tomorrow arms its own days only, evening of the last day included")
        func boundedDailyCourse() {
            let med = Self.medication(.daily, times: ["08:00", "22:00"], startsOn: "2026-09-14", endsOn: "2026-09-16")
            let projections = MedicationsSchedulerModule.projections(for: med, now: Self.eveningBefore, timeZone: Self.newYork)
            #expect(projections.allSatisfy { $0.schedule.recurrence == nil })
            #expect(projections.map { Self.localDay($0.schedule.start) } == [
                "2026-09-14 08:00", "2026-09-14 22:00",
                "2026-09-15 08:00", "2026-09-15 22:00",
                "2026-09-16 08:00", "2026-09-16 22:00"
            ])
        }

        @Test("a running course far from its end keeps the repeating daily trigger")
        func longCourseStaysRepeating() {
            let med = Self.medication(.daily, times: ["08:00"], startsOn: "2026-09-01", endsOn: "2027-06-30")
            let projections = MedicationsSchedulerModule.projections(for: med, now: Self.eveningBefore, timeZone: Self.newYork)
            #expect(projections.map(\.slotKey) == ["e0-d-t0"])
            #expect(projections.first?.schedule.recurrence != nil)
        }

        @Test("update path: the repeating task an older build armed is purged on the next reconcile")
        func repeatingTaskIsPurged() {
            let med = Self.medication(.daily, times: ["08:00", "22:00"], startsOn: "2026-09-14", endsOn: "2026-09-16")
            let desired = MedicationsSchedulerModule.desiredTaskIDs(
                for: [med], now: Self.eveningBefore, timeZone: Self.newYork
            )
            let olderBuild: Set = [
                MedicationsSchedulerModule.taskID(medicationID: "med-ny", slotKey: "e0-d-t0"),
                MedicationsSchedulerModule.taskID(medicationID: "med-ny", slotKey: "e0-d-t1")
            ]
            let purged = MedicationsSchedulerModule.orphanTaskIDs(existing: olderBuild.union(desired), desired: desired)
            #expect(purged == olderBuild)
            #expect(!desired.isEmpty)
        }

        @Test("a monthly course whose start day has not begun is not lifted to a repeating trigger")
        func monthlyNotYetStarted() {
            // `startsOn` 00:00Z has passed, the 14th in New York has not.
            let med = Self.medication(.monthly(day: 14), times: ["08:00"], startsOn: "2026-09-14", endsOn: nil)
            let context = MedicationRecurrenceEngine.Context(medication: med, timeZone: Self.newYork, now: Self.eveningBefore)
            #expect(!MedicationsSchedulerModule.boundsAllowRepeatingTrigger(context: context, now: Self.eveningBefore))
        }

        @Test("the critical alarm of a course starting tomorrow is its first dose, not a daily alarm from tonight")
        func criticalAlarmBoundedCourse() {
            let med = Self.medication(.daily, times: ["08:00"], startsOn: "2026-09-14", endsOn: "2026-09-16")
            let planned = CriticalMedAlarmRouting.plannedAlarms(for: med, now: Self.eveningBefore, timeZone: Self.newYork)
            #expect(planned.count == 1)
            guard case let .fixed(at) = planned.first else {
                Issue.record("expected a fixed alarm, got \(String(describing: planned.first))")
                return
            }
            #expect(Self.localDay(at) == "2026-09-14 08:00")
        }
    }
#endif
