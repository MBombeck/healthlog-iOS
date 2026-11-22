// swiftlint:disable file_length force_unwrapping
#if !SWIFT_PACKAGE
    import Foundation
    @testable import HealthLog
    import Synchronization
    import Testing
    #if canImport(UserNotifications)
        import UserNotifications
    #endif
    #if canImport(AuthenticationServices)
        import AuthenticationServices
    #endif

    // D3 — the medication-safety review: double doses and missed reminders.
    // Each suite names the finding it pins; every test fails on the code before
    // the fix.

    /// Answers by path suffix with canned JSON and records every request.
    private final class D3ScriptedAPI: APIClientProtocol, @unchecked Sendable {
        struct Call: Sendable {
            let method: String
            let path: String
            let bodyData: Data?

            var body: [String: Any]? {
                bodyData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            }
        }

        private let lock = Mutex<[Call]>([])
        private let answers: [String: String]

        init(_ answers: [String: String]) {
            self.answers = answers
        }

        var calls: [Call] {
            lock.withLock { $0 }
        }

        func send<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> T {
            lock.withLock { $0.append(Call(method: request.method.rawValue, path: request.path, bodyData: request.body)) }
            guard let key = answers.keys.first(where: { request.path.hasSuffix($0) }), let json = answers[key] else {
                throw HLError.unknown("not stubbed: \(request.path)")
            }
            return try JSONDecoder.hlDefault.decode(T.self, from: Data(json.utf8))
        }

        func sendVoid(_ request: APIRequest<EmptyPayload>) async throws {
            _ = try await send(request)
        }

        func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
            throw HLError.unknown("not stubbed")
        }
    }

    private enum D3Clock {
        static let berlin = TimeZone(identifier: "Europe/Berlin")!
        static let baseURL = URL(string: "https://test.healthlog.local")!

        /// `day.11.2026 hour:minute` in `zone`.
        static func at(_ day: Int, _ hour: Int, _ minute: Int = 0, in zone: TimeZone = berlin) -> Date {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            return calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
        }

        static func med(_ cadence: Cadence, id: String = "m1", hour: Int = 8) -> Medication {
            let time = TimeOfDay(hour: hour, minute: 0)
            return Medication(
                id: id,
                name: "Med",
                dose: "5 mg",
                schedule: MedicationSchedule(entries: [ScheduleEntry(cadence: cadence, timesOfDay: [time], windowStart: time)]),
                notificationsEnabled: true,
                active: true
            )
        }
    }

    // MARK: - #1 snoozed critical alarm

    @Suite("D3 #1 — a snoozed critical alarm ends once its dose is resolved")
    struct D3SnoozedAlarmTests {
        @Test("a resolved snooze is no longer protected from the reconcile")
        func resolvedSnoozeIsCancelled() {
            let snooze = CriticalMedAlarmRouting.snoozeAlarmID(medicationID: "m1")
            let slot = CriticalMedAlarmRouting.alarmID(medicationID: "m1", slotIndex: 0)
            let kept = CriticalMedAlarmRouting.orphanIDs(existing: [snooze, slot], desiredScheduledIDs: [slot], activeMedIDs: ["m1"])
            #expect(kept.isEmpty, "update path: an open snooze still survives a routine reconcile")
            let cancelled = CriticalMedAlarmRouting.orphanIDs(
                existing: [snooze, slot],
                desiredScheduledIDs: [slot],
                activeMedIDs: ["m1"],
                resolvedSnoozeMedIDs: ["m1"]
            )
            #expect(cancelled == [snooze])
        }

        @Test("only the snoozed slot's own take resolves the snooze")
        func matchesOwnSlotOnly() {
            let snoozed = [CriticalMedAlarmRouting.SnoozedDose(medicationId: "m1", occurrence: D3Clock.at(23, 8))]
            let resolve: ([MedicationReminderCompletion.ResolvedSlot]) -> Set<String> = {
                CriticalMedAlarmRouting.resolvedSnoozes(
                    snoozed, resolvedSlots: $0, deviceTimeZone: D3Clock.berlin, accountTimeZone: D3Clock.berlin
                )
            }
            #expect(resolve([.init(medicationId: "m1", scheduledAt: D3Clock.at(23, 8))]) == ["m1"])
            #expect(resolve([.init(medicationId: "m1", scheduledAt: D3Clock.at(23, 14))]).isEmpty)
            #expect(resolve([.init(medicationId: "m2", scheduledAt: D3Clock.at(23, 8))]).isEmpty)
        }

        @Test("the occurrence is the dose that rang, also from a weekly alarm armed days before")
        func occurrence() {
            let armedFor = D3Clock.at(23, 8) // Monday, the next fire when the alarm was armed
            let wednesday = CriticalMedAlarmRouting.occurrence(of: armedFor, now: D3Clock.at(25, 8, 1), deviceTimeZone: D3Clock.berlin)
            #expect(wednesday == D3Clock.at(25, 8))
            let fixed = CriticalMedAlarmRouting.occurrence(of: armedFor, now: D3Clock.at(23, 8, 2), deviceTimeZone: D3Clock.berlin)
            #expect(fixed == armedFor)
            let snoozeAgain = CriticalMedAlarmRouting.occurrence(of: armedFor, now: D3Clock.at(23, 8, 35), deviceTimeZone: D3Clock.berlin)
            #expect(snoozeAgain == armedFor)
        }

        @Test("the ledger keeps one record per medication and drops the ones without an alarm")
        func ledger() throws {
            let defaults = try #require(UserDefaults(suiteName: "test.d3.snooze.\(UUID().uuidString)"))
            let ledger = CriticalAlarmSnoozeLedger(defaults: defaults)
            ledger.note(.init(medicationId: "m1", occurrence: D3Clock.at(23, 8)))
            ledger.note(.init(medicationId: "m1", occurrence: D3Clock.at(23, 14)))
            ledger.note(.init(medicationId: "m2", occurrence: D3Clock.at(23, 8)))
            #expect(ledger.read().count == 2)
            #expect(ledger.read().first { $0.medicationId == "m1" }?.occurrence == D3Clock.at(23, 14))
            ledger.keep(["m2"])
            #expect(ledger.read().map(\.medicationId) == ["m2"])
            ledger.clear()
            #expect(ledger.read().isEmpty)
        }
    }

    // MARK: - #8 / #4 suspended alarm weekdays

    @Suite("D3 #8 / #4 — a resolved occurrence keeps the next week armed")
    struct D3AlarmWeekdayTests {
        private func plan(
            _ cadence: Cadence,
            now: Date,
            slots: [MedicationReminderCompletion.ResolvedSlot]
        ) -> [CriticalMedAlarmRouting.PlannedAlarm] {
            CriticalMedAlarmRouting.plannedAlarms(
                for: D3Clock.med(cadence), now: now, timeZone: D3Clock.berlin, resolvedSlots: slots, deviceTimeZone: D3Clock.berlin
            )
        }

        @Test("Mon and Thu, Monday's dose taken early: Thursday stays weekly, next Monday is armed on its own")
        func twoWeekdays() {
            let planned = plan(
                .weekdays([.mon, .thu]),
                now: D3Clock.at(23, 7, 50),
                slots: [.init(medicationId: "m1", scheduledAt: D3Clock.at(23, 8))]
            )
            #expect(planned == [
                .weekly(.init(hour: 8, minute: 0, weekdays: [.thu])),
                .fixed(at: D3Clock.at(30, 8))
            ])
        }

        @Test("a Saturday take the server binds to Sunday's slot moves Sunday's alarm to next week (#4)")
        func saturdayTakeForSunday() {
            // 21.11.2026 is a Saturday.
            let planned = plan(
                .weekdays([.sun]),
                now: D3Clock.at(21, 10),
                slots: [.init(medicationId: "m1", scheduledAt: D3Clock.at(22, 8))]
            )
            #expect(planned == [.fixed(at: D3Clock.at(29, 8))])
        }

        @Test("update path: nothing resolved leaves the weekly alarm as it was")
        func unchanged() {
            #expect(plan(.weekdays([.sun]), now: D3Clock.at(21, 10), slots: []) == [.weekly(.init(hour: 8, minute: 0, weekdays: [.sun]))])
        }
    }

    // MARK: - #4 resolved slots beyond today

    @Suite("D3 #4 — slots resolved for other days reach completion and alarms", .serialized)
    @MainActor
    struct D3ResolvedBeyondTodayTests {
        private static let ledger = """
        {"from":"2026-11-19T00:00:00.000Z","to":"2026-11-29T00:00:00.000Z","rows":[\
        {"kind":"slot","at":"2026-11-15T07:00:00.000Z","timeOfDay":"08:00","status":"taken_on_time","state":"taken"},\
        {"kind":"slot","at":"2026-11-22T07:00:00.000Z","timeOfDay":"08:00","status":"taken_on_time","state":"taken"},\
        {"kind":"slot","at":"2026-11-29T07:00:00.000Z","timeOfDay":"08:00","status":"upcoming","state":"upcoming"},\
        {"kind":"ad_hoc","at":"2026-11-21T09:00:00.000Z","timeOfDay":null,"status":"ad_hoc","state":null}]}
        """

        @Test("the window's taken and skipped slot rows are the resolved slots")
        func ledgerRows() throws {
            let envelope = try JSONDecoder.hlDefault.decode(MedicationDoseHistoryEnvelope.self, from: Data(Self.ledger.utf8))
            let slots = MedicationsStore.resolvedSlots(inLedger: envelope.rows, medicationId: "m1")
            #expect(slots.map(\.scheduledAt) == [
                ISO8601DateFormatter().date(from: "2026-11-15T07:00:00Z"),
                ISO8601DateFormatter().date(from: "2026-11-22T07:00:00Z")
            ])
        }

        @Test("a weekly medication reads the window, a daily one does not")
        func whichMedications() {
            #expect(MedicationsStore.needsResolvedWindow(D3Clock.med(.weekdays([.sun]))))
            #expect(!MedicationsStore.needsResolvedWindow(D3Clock.med(.daily)))
        }

        @Test("the read feeds allResolvedSlots, runs the intake hook once, and is throttled")
        func refreshFeedsAndThrottles() async throws {
            let api = D3ScriptedAPI(["/dose-history": Self.ledger])
            let store = try MedicationsStore(repo: MedicationsRepository(api: api, outbox: OutboxQueue(inMemory: true)), swr: nil)
            nonisolated(unsafe) var hooks = 0
            store.onIntakesDidChange = { hooks += 1 }
            let now = D3Clock.at(21, 10)
            await store.refreshResolvedSlotsBeyondToday(for: ["m1"], force: true, now: now)
            #expect(store.allResolvedSlots.contains(.init(medicationId: "m1", scheduledAt: D3Clock.at(22, 8))))
            #expect(hooks == 1)
            await store.refreshResolvedSlotsBeyondToday(for: ["m1"], now: now.addingTimeInterval(60))
            #expect(api.calls.count == 1, "throttled within five minutes")
            await store.refreshResolvedSlotsBeyondToday(for: ["m1"], force: true, now: now.addingTimeInterval(60))
            #expect(hooks == 1, "an unchanged window does not run the hook again")
        }

        @Test("a single-route write that named a slot notes the slot it answered with")
        func noteFromWrite() throws {
            let store = try MedicationsStore(
                repo: MedicationsRepository(api: D3ScriptedAPI([:]), outbox: OutboxQueue(inMemory: true)),
                swr: nil
            )
            store.noteResolvedSlot(medicationId: "m1", slotAt: D3Clock.at(22, 8))
            store.noteResolvedSlot(medicationId: "m1", slotAt: D3Clock.at(22, 8))
            #expect(store.allResolvedSlots == [.init(medicationId: "m1", scheduledAt: D3Clock.at(22, 8))])
        }
    }

    // MARK: - #3 ad-hoc take on an off day

    @Suite("D3 #3 — an off-day take books now, today's slot comes from the server")
    struct D3AdHocTests {
        @Test("the server's open slot today is booked; no slot today books now")
        func serverSlots() {
            let med = D3Clock.med(.weekdays([.sun]))
            let now = D3Clock.at(22, 9)
            let today = [IntakeSlotAttribution.DaySlot(instant: D3Clock.at(22, 8), time: TimeOfDay(hour: 8, minute: 0))]
            #expect(ActiveMedicationsSection.resolveAdHocScheduledFor(
                medication: med, now: now, timeZone: D3Clock.berlin, daySlots: today
            ) == D3Clock.at(22, 8))
            #expect(ActiveMedicationsSection.resolveAdHocScheduledFor(
                medication: med, now: D3Clock.at(21, 10), timeZone: D3Clock.berlin, daySlots: []
            ) == D3Clock.at(21, 10))
        }
    }

    // MARK: - #6 one zone

    @Suite("D3 #6 — away from the account zone a take is pinned onto the account slot")
    struct D3ZoneTests {
        private let bangkok = TimeZone(identifier: "Asia/Bangkok")!
        private let newYork = TimeZone(identifier: "America/New_York")!

        @Test("east: Bangkok 08:00 pins Berlin's 08:00 ahead, takenAt stays the moment of the take")
        func east() {
            let rang = D3Clock.at(22, 8, in: bangkok)
            let booking = MedicationReminderSlot.booking(deliveredAt: rang, deviceTimeZone: bangkok, accountTimeZone: D3Clock.berlin)
            #expect(booking.pin == D3Clock.at(22, 8))
            #expect(booking.scheduledFor == D3Clock.at(22, 8))
            #expect(booking.takenAt(now: rang) == rang)
        }

        @Test("west: New York 08:00 pins Berlin's 08:00 behind")
        func west() {
            let rang = D3Clock.at(22, 8, in: newYork)
            let booking = MedicationReminderSlot.booking(deliveredAt: rang, deviceTimeZone: newYork, accountTimeZone: D3Clock.berlin)
            #expect(booking.pin == D3Clock.at(22, 8))
            #expect(booking.takenAt(now: rang) == rang)
        }

        @Test("update path: at home nothing is pinned and the clamp stays")
        func home() {
            let rang = D3Clock.at(22, 8)
            let booking = MedicationReminderSlot.booking(deliveredAt: rang, deviceTimeZone: D3Clock.berlin, accountTimeZone: D3Clock.berlin)
            #expect(booking.pin == nil)
            #expect(booking.scheduledFor == rang)
            #expect(booking.takenAt(now: rang.addingTimeInterval(600)) == rang)
        }

        @Test("the bulk entry carries the pin on a take, not on a skip")
        func wire() async throws {
            let answer = #"{"processed":1,"inserted":1,"entries":[{"index":0,"status":"inserted","id":"r1"}]}"#
            let api = D3ScriptedAPI(["/intake/bulk": answer])
            let repo = try MedicationsRepository(api: api, outbox: OutboxQueue(inMemory: true))
            _ = try await repo.recordFromReminder(
                medicationId: "m1",
                scheduledFor: D3Clock.at(22, 8),
                status: .taken,
                forceSlotInstant: D3Clock.at(22, 8)
            )
            _ = try await repo.recordFromReminder(
                medicationId: "m1",
                scheduledFor: D3Clock.at(22, 8),
                status: .skipped,
                forceSlotInstant: D3Clock.at(22, 8)
            )
            _ = try await repo.recordFromReminder(medicationId: "m1", scheduledFor: D3Clock.at(22, 8), status: .taken)
            let entries = api.calls.map { ($0.body?["entries"] as? [[String: Any]])?.first }
            #expect(entries[0]?["forceSlotInstant"] != nil)
            #expect(entries[1]?["forceSlotInstant"] == nil)
            #expect(entries[2]?["forceSlotInstant"] == nil, "update path: an unpinned take keeps its old body")
        }

        @Test("a pin onto a slot another dose holds reads as already taken")
        func occupied() async throws {
            let answer = #"{"processed":1,"inserted":0,"entries":[{"index":0,"status":"skipped","reason":"force_slot_occupied"}]}"#
            let repo = try MedicationsRepository(api: D3ScriptedAPI(["/intake/bulk": answer]), outbox: OutboxQueue(inMemory: true))
            await #expect(throws: MedicationAlreadyTaken.self) {
                _ = try await repo.recordFromReminder(medicationId: "m1", scheduledFor: .now, status: .taken, forceSlotInstant: .now)
            }
        }

        @Test("update path: an outbox entry written before the pin existed still replays")
        func oldOutboxEntry() throws {
            let old = #"{"medicationId":"m1","scheduledFor":"2026-11-22T07:00:00Z","takenAt":"2026-11-22T07:00:00Z","skipped":false,"idempotencyKey":"k1"}"#
            let entry = try JSONDecoder.hlDefault.decode(MedicationsRepository.BulkIntakeEntry.self, from: Data(old.utf8))
            #expect(entry.forceSlotInstant == nil)
            #expect(entry.idempotencyKey == "k1")
        }
    }

    // MARK: - #9 budget

    @Suite("D3 #9 — the runway plans against the budget Spezi really has")
    struct D3BudgetTests {
        @Test("Spezi's limit: min(48, 64 − foreign requests)")
        func budget() {
            #expect(MedicationReminderRunway.budget(foreignPending: 0) == 48)
            #expect(MedicationReminderRunway.budget(foreignPending: 16) == 48)
            #expect(MedicationReminderRunway.budget(foreignPending: 28) == 36)
            #expect(MedicationReminderRunway.budget(foreignPending: 80) == 0)
        }

        @Test("Spezi's own requests are not foreign")
        func foreignCount() {
            let ids = [
                "edu.stanford.spezi.scheduler.notification.event.a",
                "edu.stanford.spezi.scheduler.notification.event.b",
                "snooze-m1-1790000000",
                "mood-reminder-local"
            ]
            #expect(MedicationReminderRunway.foreignCount(in: ids) == 2)
        }

        @Test("a smaller budget cuts the runway short, so the claim rule sees it")
        func planHonoursBudget() {
            let course = Medication(
                id: "c1",
                name: "Course",
                dose: "1",
                schedule: MedicationSchedule(entries: [ScheduleEntry(
                    cadence: .everyNWeeks(interval: 2, days: [.mon]),
                    timesOfDay: [TimeOfDay(hour: 8, minute: 0), TimeOfDay(hour: 20, minute: 0)],
                    windowStart: TimeOfDay(hour: 8, minute: 0)
                )]),
                notificationsEnabled: true,
                active: true
            )
            let wide = MedicationReminderRunway.plan(for: [course], now: D3Clock.at(22, 9), timeZone: D3Clock.berlin, budget: 48)
            let narrow = MedicationReminderRunway.plan(for: [course], now: D3Clock.at(22, 9), timeZone: D3Clock.berlin, budget: 2)
            #expect(narrow.armedRequestCount == 2)
            #expect(narrow.armedRequestCount < wide.armedRequestCount)
            #expect(narrow.coverageEnd != nil)
        }
    }

    // MARK: - #12 hidden medication

    @Suite("D3 #12 — a hidden medication's reminder opens its page")
    @MainActor
    struct D3HiddenLandingTests {
        @Test("hidden: the detail page, no landing; visible: the list as before")
        func landing() {
            let router = AppRouter()
            router.isHiddenFromMedicationsList = { $0 == "hidden" }
            router.apply(.medicationDue(id: "hidden", slot: nil), isAuthenticated: true)
            #expect(router.selectedTab == .meds)
            #expect(router.medsPath.count == 1)
            #expect(router.consumeMedicationLanding() == nil)
            router.apply(.medicationDue(id: "shown", slot: nil), isAuthenticated: true)
            #expect(router.medsPath.isEmpty)
            #expect(router.consumeMedicationLanding()?.medicationId == "shown")
        }
    }

    // MARK: - #13 already taken at the alarm

    #if canImport(UserNotifications)
        @Suite("D3 #13 — the alarm's Take says when the dose was already taken")
        struct D3AlarmAlreadyTakenTests {
            @Test("a quiet notice with the first take's time")
            func notice() {
                let already = MedicationAlreadyTaken(takenAt: D3Clock.at(22, 7, 12), source: "INTEGRATION")
                let request = MedicationAlarmActions.alreadyTakenRequest(already)
                #expect(request.trigger == nil)
                #expect(request.content.interruptionLevel == .passive)
                #expect(request.content.body == already.message)
                #expect(!request.content.title.isEmpty)
            }
        }
    #endif

    // MARK: - #2 sign-out and the device row

    #if canImport(AuthenticationServices)
        @Suite("D3 #2 — signing out deletes this device's row before the revoke", .serialized, .mockURLSession)
        struct D3LogoutDeviceRowTests {
            private final class NoopPasskey: PasskeyServiceProtocol, @unchecked Sendable {
                @MainActor func register(
                    challenge _: String, rpId _: String, rpName _: String,
                    userID _: String, userName _: String, displayName _: String,
                    anchor _: ASPresentationAnchorProvider
                ) async throws -> PasskeyRegistration {
                    throw HLError.unknown("noop")
                }

                @MainActor func assert(
                    challenge _: String, rpId _: String, allowCredentialIDs _: [String],
                    anchor _: ASPresentationAnchorProvider
                ) async throws -> PasskeyAssertion {
                    throw HLError.unknown("noop")
                }
            }

            @Test("GET the devices, DELETE the current one, then revoke")
            func order() async throws {
                let keychain = InMemoryKeychain()
                try keychain.setString("access", forKey: KeychainKey.authToken)
                try keychain.setString("refresh", forKey: KeychainKey.refreshToken)
                try keychain.setString("usr_a", forKey: KeychainKey.userID)
                let env = AppEnvironment(
                    baseURL: D3Clock.baseURL,
                    bundleID: "dev.healthlog.app",
                    appVersion: "1.7.0",
                    buildNumber: "1"
                )
                let api = APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock())
                let service = AuthService(api: api, keychain: keychain, passkey: NoopPasskey())
                let seen = Mutex<[String]>([])
                let devices = #"{"data":{"devices":[{"id":"dev_other","label":"iPad","lastSeenAt":"2026-11-22T07:00:00.000Z","isCurrent":false},"#
                    + #"{"id":"dev_1","label":"iPhone","lastSeenAt":"2026-11-22T07:00:00.000Z","isCurrent":true}]},"error":null}"#
                MockURLProtocol.install { req in
                    let line = "\(req.httpMethod ?? "") \(req.url?.path ?? "")"
                    seen.withLock { $0.append(line) }
                    let body = req.url?.path == "/api/auth/me/devices" ? devices : #"{"data":{},"error":null}"#
                    return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
                }
                try await service.logout()
                #expect(seen.withLock { $0 } == [
                    "GET /api/auth/me/devices",
                    "DELETE /api/auth/me/devices/dev_1",
                    "POST /api/auth/refresh"
                ])
            }
        }
    #endif

    #if canImport(UserNotifications) && canImport(UIKit)
        @Suite("D3 #2 — a 409 on POST /api/devices is not remembered as sent", .serialized, .mockURLSession)
        @MainActor
        struct D3RegistrationConflictTests {
            @Test("the next token callback posts again")
            func conflictRetries() async throws {
                let env = AppEnvironment(
                    baseURL: D3Clock.baseURL,
                    bundleID: "dev.healthlog.app",
                    appVersion: "1.7.0",
                    buildNumber: "1"
                )
                let keychain = InMemoryKeychain()
                try keychain.setString("token", forKey: KeychainKey.authToken)
                let owner = InMemoryKeychain()
                try owner.setString("usr_b", forKey: KeychainKey.userID)
                let posts = Mutex(0)
                MockURLProtocol.install { req in
                    if req.targets("/api/devices") { posts.withLock { $0 += 1 } }
                    let body = Data(#"{"data":null,"error":{"message":"token belongs to another user"}}"#.utf8)
                    return (HTTPURLResponse(url: req.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!, body)
                }
                let service = try NotificationService(
                    api: APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock()),
                    environment: env,
                    keychain: owner,
                    deepLinks: DeepLinkRouter(router: AppRouter(), isAuthenticated: { true }),
                    backgroundSync: nil,
                    defaults: #require(UserDefaults(suiteName: "test.d3.reg.\(UUID().uuidString)"))
                )
                await service.didRegister(deviceToken: Data(repeating: 0x0A, count: 32))
                await service.didRegister(deviceToken: Data(repeating: 0x0A, count: 32))
                #expect(posts.withLock { $0 } == 2)
                #expect(service.lastRegistrationSnapshot?.lastRegistrationServerStatus == 409)
            }
        }
    #endif
#endif
