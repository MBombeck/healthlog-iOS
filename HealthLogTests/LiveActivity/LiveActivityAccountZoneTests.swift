#if canImport(ActivityKit)
    import ActivityKit
    import Foundation
    @testable import HealthLog
    import Testing

    /// **1.4 B4 — the Lock Screen grades the dose in the card's zone.**
    ///
    /// Since B4-c the medication card grades its dose window in the account
    /// zone the server keeps (`/me`, `MedicationsStore.profileTimeZone`). The
    /// Live Activity still read the device calendar, so after travel, or with
    /// a zone set on the web, the Lock Screen and the card could disagree about
    /// the same dose: one "due", the other "late" or nothing at all.
    ///
    /// Each case names its instant and zone, so the result does not depend on
    /// the zone the test host runs in (New York and Tokyo are thirteen hours
    /// apart; at most one of them is the host's).
    @Suite("Live Activity — dose verdict in the account zone")
    @MainActor
    struct LiveActivityAccountZoneTests {
        private static let newYork = TimeZone(identifier: "America/New_York") ?? .gmt
        private static let tokyo = TimeZone(identifier: "Asia/Tokyo") ?? .gmt

        /// 2026-05-20 at `hour:minute` on the wall clock of `zone`.
        private static func instant(_ zone: TimeZone, hour: Int, minute: Int) -> Date {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            return calendar.date(from: DateComponents(year: 2026, month: 5, day: 20, hour: hour, minute: minute))
                ?? .distantPast
        }

        /// The card suite's daily 08:00 dose with its 08:00 to 09:00 window,
        /// nothing taken and no server instant: the verdict is the window
        /// arithmetic alone, in whichever zone it is read.
        private static let morningDose = Medication(
            id: "med-account-zone",
            name: "Lisinopril",
            dose: "5 mg",
            schedule: MedicationSchedule(entries: [ScheduleEntry(
                cadence: .daily,
                timesOfDay: [TimeOfDay(hour: 8, minute: 0)],
                windowStart: TimeOfDay(hour: 8, minute: 0),
                windowEnd: TimeOfDay(hour: 9, minute: 0)
            )]),
            todayEventCount: 0,
            active: true
        )

        @Test("The Lock Screen's overdue verdict is the card's, in the same zone")
        func overdueAgreesWithTheCard() {
            let instants = [Self.newYork, Self.tokyo].flatMap { zone in
                [(8, 30), (10, 30), (21, 30)].map { Self.instant(zone, hour: $0.0, minute: $0.1) }
            }
            for now in instants {
                for accountZone in [Self.newYork, Self.tokyo] {
                    let card = MedicationCard.resolveWindowStatus(
                        medication: Self.morningDose, timeZone: accountZone, now: now
                    )
                    let lockScreen = MedicationLiveActivityPlan.isOverdue(
                        medication: Self.morningDose,
                        now: now,
                        calendar: MedicationLiveActivityPlan.calendar(in: accountZone)
                    )
                    #expect(lockScreen == (card == .late || card == .veryLate))
                }
            }
        }

        @Test("10:30 in the account zone is late on both surfaces")
        func lateInTheAccountZone() {
            let now = Self.instant(Self.tokyo, hour: 10, minute: 30)
            #expect(MedicationCard.resolveWindowStatus(
                medication: Self.morningDose, timeZone: Self.tokyo, now: now
            ) == .late)
            #expect(MedicationLiveActivityPlan.isOverdue(
                medication: Self.morningDose, now: now, calendar: MedicationLiveActivityPlan.calendar(in: Self.tokyo)
            ))
        }

        @Test("The reconcile surfaces the dose the account zone has due, and none the device zone would invent")
        func reconcileReadsTheAccountZone() async {
            // 08:30 in New York: inside the window there, past every window in Tokyo.
            let now = Self.instant(Self.newYork, hour: 8, minute: 30)

            let inNewYork = ZoneSpy()
            await AppContainer.reconcileMedicationLiveActivityAwaiting(
                controller: inNewYork,
                medications: [Self.morningDose],
                intakes: [],
                now: now,
                timeZone: Self.newYork
            )
            #expect(inNewYork.started.map(\.fire) == [Self.instant(Self.newYork, hour: 8, minute: 0)])
            #expect(inNewYork.started.map(\.overdue) == [false])

            let inTokyo = ZoneSpy()
            await AppContainer.reconcileMedicationLiveActivityAwaiting(
                controller: inTokyo,
                medications: [Self.morningDose],
                intakes: [],
                now: now,
                timeZone: Self.tokyo
            )
            #expect(inTokyo.started.isEmpty)
            #expect(inTokyo.endedAll == 1)
        }

        @Test("Every reconcile path and the widget read the store's account zone")
        func callSitesPassTheAccountZone() throws {
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent() // LiveActivity
                .deletingLastPathComponent() // HealthLogTests
                .deletingLastPathComponent() // repo root
            let wiring = try String(
                contentsOf: root.appendingPathComponent("HealthLog/Stores/AppContainer+LiveActivity.swift"),
                encoding: .utf8
            )
            // The intake callback, the medication callback and the background hook.
            #expect(wiring.components(separatedBy: "timeZone: medicationsStore.profileTimeZone").count == 4)
            let widgets = try String(
                contentsOf: root.appendingPathComponent("HealthLog/Stores/AppContainer+Widgets.swift"),
                encoding: .utf8
            )
            #expect(widgets.contains("timeZone: medicationsStore.profileTimeZone"))
        }
    }

    /// Records what the reconcile asked the Lock Screen to do.
    @MainActor
    private final class ZoneSpy: MedicationLiveActivityReconciling {
        var areActivitiesEnabled = true
        private(set) var started: [(fire: Date, overdue: Bool)] = []
        private(set) var endedAll = 0

        @discardableResult
        func start(
            medicationId: String,
            medicationName _: String,
            doseText _: String,
            scheduledFireDate: Date,
            isOverdue: Bool,
            now _: Date
        ) async -> String? {
            started.append((scheduledFireDate, isOverdue))
            return medicationId
        }

        func end(
            medicationId _: String,
            finalStatus _: MedicationActivityAttributes.ContentState.Status,
            countdownTarget _: Date,
            dismissalPolicy _: ActivityUIDismissalPolicy
        ) async {}

        func endAll(dismissalPolicy _: ActivityUIDismissalPolicy) async {
            endedAll += 1
        }
    }
#endif
