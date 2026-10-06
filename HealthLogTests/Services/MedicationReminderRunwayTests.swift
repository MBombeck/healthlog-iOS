import Foundation
import Testing
#if canImport(SpeziScheduler) && canImport(UserNotifications)
    @testable import HealthLog
    import SpeziScheduler
    import UserNotifications

    // swiftlint:disable force_unwrapping

    /// Medications for the R5 runway tests: a course in Berlin, its days given
    /// as the server sends them (`YYYY-MM-DD`, decoded to UTC midnight).
    enum RunwayFixtures {
        static let berlin = TimeZone(identifier: "Europe/Berlin")!

        /// 2026-10-05 08:00 in Berlin.
        static let now = ISO8601DateFormatter().date(from: "2026-10-05T06:00:00Z")!

        static func day(_ ymd: String) -> Date {
            ISO8601DateFormatter().date(from: "\(ymd)T00:00:00Z")!
        }

        /// The UTC-midnight day `offset` days from the real clock — for the
        /// coordinator, which plans against `.now`.
        static func dayFromToday(_ offset: Int) -> Date {
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(identifier: "UTC")!
            let today = utc.startOfDay(for: .now)
            return utc.date(byAdding: .day, value: offset, to: today)!
        }

        static func course(
            id: String,
            times: [String],
            cadence: Cadence = .daily,
            startsOn: Date?,
            endsOn: Date?
        ) -> Medication {
            Medication(
                id: id,
                name: "Course \(id)",
                dose: "1",
                schedule: MedicationSchedule(entries: [ScheduleEntry(
                    cadence: cadence,
                    timesOfDay: times.compactMap { TimeOfDay.parse($0) },
                    windowStart: TimeOfDay(hour: 8, minute: 0)
                )]),
                notificationsEnabled: true,
                active: true,
                startsOn: startsOn,
                endsOn: endsOn,
                createdAt: ISO8601DateFormatter().date(from: "2026-09-01T12:00:00Z")
            )
        }

        /// Three doses a day for 30 days, starting tomorrow.
        static func threeTimesDaily(id: String = "tid") -> Medication {
            course(id: id, times: ["08:00", "14:00", "20:00"], startsOn: day("2026-10-06"), endsOn: day("2026-11-04"))
        }
    }

    // MARK: - Plan

    @Suite("R5 — the runway shares the 48 SpeziScheduler slots")
    @MainActor
    struct MedicationReminderRunwayPlanTests {
        private typealias F = RunwayFixtures

        private func onceInstants(_ projections: [MedicationsSchedulerModule.Projection]) -> [Date] {
            projections.filter { $0.schedule.recurrence == nil }.map(\.schedule.start)
        }

        @Test("a short course with three doses a day is armed far beyond eight doses")
        func shortCourseReachesFurther() throws {
            let projections = MedicationsSchedulerModule.projections(
                for: F.threeTimesDaily(), now: F.now, timeZone: F.berlin
            )
            let instants = onceInstants(projections)
            // Up to R5: eight single occurrences, i.e. under three days.
            #expect(instants.count == MedicationReminderRunway.notificationBudget)
            let reach = try #require(instants.max()?.timeIntervalSince(F.now))
            #expect(reach >= 15 * 24 * 60 * 60)
            #expect(instants == instants.sorted())
        }

        @Test("two courses split the budget so both reach the same instant")
        func budgetIsSharedFairly() throws {
            let often = F.threeTimesDaily(id: "often")
            let once = F.course(id: "once", times: ["09:00"], startsOn: F.day("2026-10-06"), endsOn: F.day("2026-11-04"))
            let plan = MedicationReminderRunway.plan(for: [often, once], now: F.now, timeZone: F.berlin)
            let oftenRunway = try #require(plan.runways[.init(medicationID: "often", entryIndex: 0)])
            let onceRunway = try #require(plan.runways[.init(medicationID: "once", entryIndex: 0)])
            #expect(plan.armedRequestCount == MedicationReminderRunway.notificationBudget)
            #expect(oftenRunway.continuesAfterLast && onceRunway.continuesAfterLast)
            // Earliest-first: neither runs dry more than one dose interval before
            // the other. With a fixed eight each, "often" ended after ~2.7 days
            // and "once" after eight.
            let oftenEnd = try #require(oftenRunway.occurrences.last)
            let onceEnd = try #require(onceRunway.occurrences.last)
            let gap = abs(oftenEnd.timeIntervalSince(onceEnd))
            #expect(gap < 24 * 60 * 60)
            #expect(oftenRunway.occurrences.count > onceRunway.occurrences.count)
        }

        @Test("repeating triggers are reserved before the runway fills the rest")
        func repeatingSlotsAreReserved() {
            let open = F.course(id: "open", times: ["07:00", "19:00"], startsOn: nil, endsOn: nil)
            let desired = MedicationsSchedulerModule.desiredTaskIDs(
                for: [open, F.threeTimesDaily()], now: F.now, timeZone: F.berlin
            )
            #expect(desired.count == MedicationReminderRunway.notificationBudget)
            let openTasks = desired.filter { MedicationsSchedulerModule.medicationId(fromTaskID: $0) == "open" }
            #expect(openTasks.count == 2)
        }

        @Test("every course keeps its next dose, even past the budget")
        func nextDoseAlwaysArmed() {
            let many = (0 ..< 60).map {
                F.course(id: "m\($0)", times: ["09:00"], startsOn: F.day("2026-10-06"), endsOn: F.day("2026-11-04"))
            }
            let planned = MedicationsSchedulerModule.plannedProjections(for: many, now: F.now, timeZone: F.berlin)
            #expect(Set(planned.map(\.medicationID)).count == 60)
            #expect(planned.count == 60)
        }

        @Test("only the last armed dose of a course that goes on carries the tail tag")
        func tailOnlyWhenTheCourseGoesOn() {
            let short = F.course(
                id: "short", times: ["08:00", "20:00"],
                startsOn: F.day("2026-10-06"), endsOn: F.day("2026-10-10")
            )
            let shortProjections = MedicationsSchedulerModule.projections(for: short, now: F.now, timeZone: F.berlin)
            #expect(shortProjections.count == 10)
            #expect(shortProjections.allSatisfy { !$0.isRunwayTail })
            #expect(MedicationReminderRunway.plan(for: [short], now: F.now, timeZone: F.berlin).coverageEnd == nil)

            let long = MedicationsSchedulerModule.projections(for: F.threeTimesDaily(), now: F.now, timeZone: F.berlin)
            #expect(long.filter(\.isRunwayTail).count == 1)
            #expect(long.last?.isRunwayTail == true)
        }

        @Test("the plan reserves exactly the repeating triggers the module arms")
        func repeatingCountMatchesModule() {
            let meds = [
                F.course(id: "d", times: ["07:00", "19:00"], startsOn: nil, endsOn: nil),
                F.course(id: "w", times: ["09:00"], cadence: .weekdays([.mon, .wed, .fri]), startsOn: nil, endsOn: nil),
                F.course(id: "n1", times: ["09:00"], cadence: .everyNWeeks(interval: 1, days: [.tue, .sat]), startsOn: nil, endsOn: nil),
                F.course(id: "m", times: ["09:00"], cadence: .monthly(day: 5), startsOn: nil, endsOn: nil),
                F.course(id: "nm", times: ["09:00"], cadence: .everyNMonths(interval: 1, day: 12), startsOn: nil, endsOn: nil),
                F.course(id: "y", times: ["09:00"], cadence: .yearly(month: 3, day: 20), startsOn: nil, endsOn: nil),
                F.course(id: "lw", times: ["09:00"], cadence: .legacy(days: [.tue, .thu], intervalWeeks: 2), startsOn: nil, endsOn: nil),
                F.course(id: "ld", times: ["09:00", "21:00"], cadence: .legacy(days: nil, intervalWeeks: 1), startsOn: nil, endsOn: nil)
            ]
            let plan = MedicationReminderRunway.plan(for: meds, now: F.now, timeZone: F.berlin)
            let planned = MedicationsSchedulerModule.plannedProjections(for: meds, now: F.now, timeZone: F.berlin)
            #expect(plan.runways.isEmpty)
            #expect(planned.allSatisfy { $0.projection.schedule.recurrence != nil })
            #expect(planned.count == plan.repeatingSlots)
        }

        #if canImport(UIKit) && canImport(Spezi) && canImport(SpeziHealthKit)
            @Test("the plan's budget is the limit SpeziScheduler is configured with")
            func budgetMatchesSpeziLimit() {
                #expect(MedicationReminderRunway.notificationBudget == LocalNotificationBudget.speziNotificationLimit)
                #expect(MedicationsSchedulerModule.preArmHorizon == MedicationReminderRunway.horizon)
            }
        #endif
    }

    // MARK: - Tail banner

    #if canImport(SpeziHealthKit)
        @Suite("R5 — the last armed dose asks the user to open the app")
        @MainActor
        struct MedicationRunwayTailBannerTests {
            private let hint = String(localized: "notif.med.runwayTail.hint")

            @Test("a tail banner gets the open-the-app line under its own text")
            func tailBannerCarriesHint() {
                let taskID = MedicationsSchedulerModule.taskID(medicationID: "med-tail", scheduleSlot: 0)
                let content = UNMutableNotificationContent()
                content.title = "Amoxicillin"
                content.body = "500 mg"
                HealthLogStandard.rewriteMedicationNotificationContent(taskID: taskID, content: content, isRunwayTail: true)
                #expect(!hint.isEmpty)
                #expect(content.body.hasSuffix(hint))
                #expect(content.userInfo["medicationId"] as? String == "med-tail")
            }

            @Test("every other banner stays as it was")
            func otherBannersUnchanged() {
                let taskID = MedicationsSchedulerModule.taskID(medicationID: "med-plain", scheduleSlot: 0)
                let content = UNMutableNotificationContent()
                content.body = "500 mg"
                HealthLogStandard.rewriteMedicationNotificationContent(taskID: taskID, content: content)
                #expect(!content.body.contains(hint))
            }
        }
    #endif

    // MARK: - clientManaged coverage

    @Suite("R5 — clientManaged holds only while local reminders reach seven days ahead")
    struct MedicationReminderCoveragePolicyTests {
        private typealias F = RunwayFixtures

        /// Six courses with four doses a day: 24 doses a day share 48 slots, so
        /// the runway reaches about two days.
        static func crowdedCourses() -> [Medication] {
            (0 ..< 6).map {
                F.course(
                    id: "c\($0)", times: ["06:00", "12:00", "18:00", "23:00"],
                    startsOn: F.dayFromToday(-1), endsOn: F.dayFromToday(30)
                )
            }
        }

        @Test("a crowded plan does not count as local delivery")
        func crowdedPlanDoesNotDeliver() {
            let meds = Self.crowdedCourses()
            #expect(!MedicationReminderDeliveryPolicy.coversMinimum(medications: meds, now: .now))
            #expect(!MedicationReminderDeliveryPolicy.deliversLocally(notificationsAuthorized: true, medications: meds))
        }

        @Test("a course that ends inside the runway, or a repeating trigger, counts as covered")
        func endingCourseIsCovered() {
            let short = F.course(id: "s", times: ["08:00", "20:00"], startsOn: F.dayFromToday(-1), endsOn: F.dayFromToday(5))
            let open = F.course(id: "o", times: ["08:00"], startsOn: nil, endsOn: nil)
            #expect(MedicationReminderDeliveryPolicy.deliversLocally(notificationsAuthorized: true, medications: [short]))
            #expect(MedicationReminderDeliveryPolicy.deliversLocally(notificationsAuthorized: true, medications: [open]))
        }

        @Test("seven days is the line: a single long course reaches past it")
        func singleLongCourseIsCovered() {
            let course = F.course(
                id: "l", times: ["08:00", "14:00", "20:00"],
                startsOn: F.dayFromToday(-1), endsOn: F.dayFromToday(40)
            )
            #expect(MedicationReminderDeliveryPolicy.coversMinimum(medications: [course], now: .now))
        }
    }

    @MainActor
    @Suite("R5 — the coordinator releases clientManaged when coverage runs short")
    struct MedicationReminderCoverageCoordinatorTests {
        private typealias F = MedicationReminderDeliveryFixtures

        private final class Writes: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [Bool] = []
            func append(_ value: Bool) {
                lock.withLock { values.append(value) }
            }

            var all: [Bool] {
                lock.withLock { values }
            }
        }

        private func coordinator(
            defaults: UserDefaults,
            writes: Writes
        ) -> MedicationReminderDeliveryCoordinator {
            MedicationReminderDeliveryCoordinator(
                defaults: defaults,
                notificationsAuthorized: { true },
                writeClaim: { value in
                    writes.append(value)
                    return MedicationReminderServerDelivery(clientManaged: value, deliveryDefault: "server")
                },
                releaseOnSignOut: {}
            )
        }

        @Test("claimed, server quiet, plan reaches two days → PATCH false")
        func shortCoverageReleasesClaim() async throws {
            let defaults = try #require(UserDefaults(suiteName: "hl.tests.r5.\(UUID().uuidString)"))
            let marker = MedicationReminderClaimMarker(defaults: defaults)
            marker.claim(for: F.owner)
            let writes = Writes()
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try #require(registry.activate(ownerID: F.owner))
            let sut = coordinator(defaults: defaults, writes: writes)
            sut.noteServerDelivery(F.serverQuiet, lease: lease)
            sut.noteMedications(MedicationReminderCoveragePolicyTests.crowdedCourses(), ownerID: F.owner)
            await sut.settle()
            #expect(writes.all == [false])
            #expect(!marker.isClaimed(by: F.owner))
        }

        @Test("not claimed, server pushes, plan reaches two days → the server is not silenced")
        func shortCoverageNeverClaims() async throws {
            let defaults = try #require(UserDefaults(suiteName: "hl.tests.r5.\(UUID().uuidString)"))
            let writes = Writes()
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try #require(registry.activate(ownerID: F.owner))
            let sut = coordinator(defaults: defaults, writes: writes)
            sut.noteServerDelivery(F.serverPushes, lease: lease)
            sut.noteMedications(MedicationReminderCoveragePolicyTests.crowdedCourses(), ownerID: F.owner)
            await sut.settle()
            #expect(writes.all.isEmpty)
        }
    }

    // swiftlint:enable force_unwrapping
#endif
