// swiftlint:disable force_unwrapping

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing
    import UserNotifications

    // MARK: - Fixtures

    private enum Devices {
        static let now = Date(timeIntervalSince1970: 1_800_000_000)
        static let day: TimeInterval = 24 * 60 * 60

        static func phone(seenDaysAgo days: Double, label: String = "iPhone", isCurrent: Bool = false) -> ReminderDevice {
            ReminderDevice(label: label, lastSeenAt: now.addingTimeInterval(-days * day), isCurrent: isCurrent)
        }

        static func pad(seenDaysAgo days: Double = 0, isCurrent: Bool = true) -> ReminderDevice {
            ReminderDevice(label: "iPad", lastSeenAt: now.addingTimeInterval(-days * day), isCurrent: isCurrent)
        }
    }

    // MARK: - The rule

    @Suite("ReminderDevicePolicy: which device plans the local reminders")
    struct ReminderDevicePolicyTests {
        private func plans(
            _ idiom: DeviceIdiom,
            _ devices: [ReminderDevice]?,
            override: Bool = false
        ) -> Bool {
            ReminderDevicePolicy.plansLocally(idiom: idiom, devices: devices, override: override, now: Devices.now)
        }

        @Test("iPhone and Duo (both `.phone`) plan, whatever the device list says")
        func phoneAlwaysPlans() {
            let lists: [[ReminderDevice]?] = [
                nil, [], [Devices.phone(seenDaysAgo: 0, isCurrent: true)],
                [Devices.phone(seenDaysAgo: 0), Devices.pad(isCurrent: false)],
                [Devices.pad(isCurrent: false)]
            ]
            for list in lists {
                #expect(plans(.phone, list))
                #expect(plans(.phone, list, override: true))
            }
        }

        @Test("only an iPad on the account: it plans")
        func padAlonePlans() {
            #expect(plans(.pad, [Devices.pad()]))
            #expect(plans(.pad, []))
        }

        @Test("an active iPhone next to the iPad: the iPad does not plan")
        func padWaitsForActivePhone() {
            #expect(!plans(.pad, [Devices.pad(), Devices.phone(seenDaysAgo: 1)]))
            #expect(!plans(.pad, [Devices.pad(), Devices.phone(seenDaysAgo: 6.9)]))
        }

        @Test("the switch is additive: the iPad plans next to an active iPhone")
        func overrideAddsPlanning() {
            #expect(plans(.pad, [Devices.pad(), Devices.phone(seenDaysAgo: 1)], override: true))
        }

        @Test("an iPhone not seen for seven days or more no longer counts: the iPad takes over")
        func staleIPhoneIsIgnored() {
            #expect(plans(.pad, [Devices.pad(), Devices.phone(seenDaysAgo: 7)]))
            #expect(plans(.pad, [Devices.pad(), Devices.phone(seenDaysAgo: 30)]))
        }

        @Test("the device query failed: the iPad plans, better twice than never")
        func failedQueryPlans() {
            #expect(plans(.pad, nil))
        }

        @Test("only devices labelled iPhone count; the asking device never does")
        func labelsAndCurrent() {
            #expect(plans(.pad, [Devices.pad(), Devices.phone(seenDaysAgo: 0, label: "iPad", isCurrent: false)]))
            #expect(plans(.pad, [Devices.phone(seenDaysAgo: 0, isCurrent: true)]))
            #expect(plans(.pad, [Devices.phone(seenDaysAgo: 0, label: "ios")]))
            #expect(!plans(.pad, [Devices.phone(seenDaysAgo: 0, label: "iPhone 17 Pro")]))
        }

        @Test("an active phone is reported on its own, for the screen that explains the rule")
        func hasActivePhone() {
            #expect(ReminderDevicePolicy.hasActivePhone([Devices.phone(seenDaysAgo: 2)], now: Devices.now))
            #expect(!ReminderDevicePolicy.hasActivePhone([Devices.phone(seenDaysAgo: 9)], now: Devices.now))
            #expect(!ReminderDevicePolicy.hasActivePhone([], now: Devices.now))
        }
    }

    // MARK: - Wire shape

    @Suite("GET /api/auth/me/devices: decoding")
    struct DeviceListDecodingTests {
        @Test("the server's envelope shape decodes into the rule's input")
        func decodesServerShape() throws {
            let json = """
            {"data":{"devices":[
              {"id":"d1","label":"iPhone","platform":"ios","appVersion":"1.6.0","locale":"de-DE",
               "channels":["apns"],"lastSeenAt":"2026-11-10T08:30:15.123Z",
               "createdAt":"2026-01-01T00:00:00.000Z","isCurrent":false},
              {"id":"d2","label":"iPad","platform":"ios","appVersion":null,"locale":null,
               "channels":["web_push","apns"],"lastSeenAt":"2026-11-16T07:00:00.000Z",
               "createdAt":"2026-11-01T00:00:00.000Z","isCurrent":true}
            ]},"error":null}
            """
            let envelope = try JSONDecoder.hlDefault.decode(APIEnvelope<DeviceListResponse>.self, from: Data(json.utf8))
            let devices = try #require(envelope.data).devices.map(\.reminderDevice)
            #expect(devices.map(\.label) == ["iPhone", "iPad"])
            #expect(devices.map(\.isCurrent) == [false, true])
            #expect(devices[0].lastSeenAt < devices[1].lastSeenAt)
        }

        @Test("a row without isCurrent reads as not current")
        func missingIsCurrent() throws {
            let json = #"{"devices":[{"id":"d","label":"iPhone","lastSeenAt":"2026-11-10T08:30:15.000Z"}]}"#
            let list = try JSONDecoder.hlDefault.decode(DeviceListResponse.self, from: Data(json.utf8))
            #expect(list.devices.first?.reminderDevice.isCurrent == false)
        }
    }

    // MARK: - The coordinator that holds the answer

    @MainActor
    @Suite("ReminderPlanningCoordinator: the answer, its memory and its switch")
    struct ReminderPlanningCoordinatorTests {
        private final class Clock: @unchecked Sendable {
            private let lock = NSLock()
            private var current = Devices.now
            var now: Date {
                lock.lock()
                defer { lock.unlock() }
                return current
            }

            func advance(_ seconds: TimeInterval) {
                lock.lock()
                current = current.addingTimeInterval(seconds)
                lock.unlock()
            }
        }

        private final class Loader: @unchecked Sendable {
            private let lock = NSLock()
            private var _calls = 0
            var result: Result<[ReminderDevice], Error> = .success([])
            var calls: Int {
                lock.lock()
                defer { lock.unlock() }
                return _calls
            }

            func load() throws -> [ReminderDevice] {
                lock.lock()
                _calls += 1
                let outcome = result
                lock.unlock()
                return try outcome.get()
            }
        }

        private func makeDefaults() throws -> UserDefaults {
            try #require(UserDefaults(suiteName: "hl.tests.reminderplanning.\(UUID().uuidString)"))
        }

        private func make(
            _ idiom: DeviceIdiom,
            defaults: UserDefaults,
            clock: Clock = Clock(),
            loader: Loader
        ) -> ReminderPlanningCoordinator {
            ReminderPlanningCoordinator(
                idiom: idiom,
                defaults: defaults,
                clock: { clock.now },
                loadDevices: { try loader.load() }
            )
        }

        @Test("a phone plans, never asks the server and never changes its mind")
        func phoneNeverAsks() async throws {
            let loader = Loader()
            loader.result = .success([Devices.phone(seenDaysAgo: 0)])
            let planning = try make(.phone, defaults: makeDefaults(), loader: loader)
            await planning.refresh(force: true)
            #expect(planning.plansLocally)
            #expect(!planning.isPad)
            #expect(loader.calls == 0)
        }

        @Test("an iPad next to an active iPhone stops planning and says so once")
        func padStopsNextToPhone() async throws {
            let loader = Loader()
            loader.result = .success([Devices.pad(), Devices.phone(seenDaysAgo: 1)])
            let planning = try make(.pad, defaults: makeDefaults(), loader: loader)
            #expect(planning.plansLocally) // until the first answer
            var changes = 0
            planning.onPlanningChanged = { changes += 1 }
            await planning.refresh(force: true)
            #expect(!planning.plansLocally)
            #expect(planning.otherPhoneIsActive)
            await planning.refresh(force: true)
            #expect(changes == 1)
        }

        @Test("the switch makes the iPad plan as well, and off falls back to the list")
        func switchIsAdditive() async throws {
            let loader = Loader()
            loader.result = .success([Devices.pad(), Devices.phone(seenDaysAgo: 1)])
            let planning = try make(.pad, defaults: makeDefaults(), loader: loader)
            await planning.refresh(force: true)
            #expect(!planning.plansLocally)
            planning.alsoOnThisDevice = true
            #expect(planning.plansLocally)
            planning.alsoOnThisDevice = false
            #expect(!planning.plansLocally)
        }

        @Test("an iPhone gone for seven days hands the reminders to the iPad")
        func iPadTakesOver() async throws {
            let loader = Loader()
            loader.result = .success([Devices.pad(), Devices.phone(seenDaysAgo: 8)])
            let planning = try make(.pad, defaults: makeDefaults(), loader: loader)
            await planning.refresh(force: true)
            #expect(planning.plansLocally)
            #expect(!planning.otherPhoneIsActive)
        }

        @Test("a failed query makes the iPad plan, even after it had stopped")
        func failedQueryFlipsToPlanning() async throws {
            let loader = Loader()
            loader.result = .success([Devices.phone(seenDaysAgo: 0)])
            let planning = try make(.pad, defaults: makeDefaults(), loader: loader)
            await planning.refresh(force: true)
            #expect(!planning.plansLocally)
            loader.result = .failure(HLError.offline)
            await planning.refresh(force: true)
            #expect(planning.plansLocally)
        }

        @Test("a cold start (a background wake) decides like the last foreground did")
        func remembersTheLastAnswer() async throws {
            let defaults = try makeDefaults()
            let loader = Loader()
            loader.result = .success([Devices.phone(seenDaysAgo: 0)])
            let first = make(.pad, defaults: defaults, loader: loader)
            await first.refresh(force: true)
            #expect(!first.plansLocally)

            let second = make(.pad, defaults: defaults, loader: Loader())
            #expect(!second.plansLocally)

            // The override is remembered too, and wins over the remembered answer.
            first.alsoOnThisDevice = true
            let third = make(.pad, defaults: defaults, loader: Loader())
            #expect(third.plansLocally)
            #expect(third.alsoOnThisDevice)
        }

        @Test("sign-out forgets the account: list, answer and switch; the next account decides afresh")
        func resetOnAccountChange() async throws {
            let defaults = try makeDefaults()
            let loader = Loader()
            loader.result = .success([Devices.pad(), Devices.phone(seenDaysAgo: 1)])
            let planning = make(.pad, defaults: defaults, loader: loader)
            await planning.refresh(force: true)
            planning.alsoOnThisDevice = true
            planning.alsoOnThisDevice = false
            #expect(!planning.plansLocally)

            var changes = 0
            planning.onPlanningChanged = { changes += 1 }
            planning.reset()
            #expect(planning.plansLocally)
            #expect(!planning.otherPhoneIsActive)
            #expect(!planning.alsoOnThisDevice)
            #expect(defaults.object(forKey: ReminderPlanningCoordinator.lastDecisionKey) == nil)
            #expect(changes == 0)
            // A cold start after the sign-out does not inherit the old answer.
            #expect(make(.pad, defaults: defaults, loader: Loader()).plansLocally)

            // The next account has no iPhone: it plans, and the throttle was cleared.
            loader.result = .success([Devices.pad()])
            await planning.refresh()
            #expect(loader.calls == 2)
            #expect(planning.plansLocally)
        }

        @Test("the device list is read at most every fifteen minutes unless forced")
        func throttle() async throws {
            let clock = Clock()
            let loader = Loader()
            let planning = try make(.pad, defaults: makeDefaults(), clock: clock, loader: loader)
            await planning.refresh()
            await planning.refresh()
            #expect(loader.calls == 1)
            clock.advance(ReminderPlanningCoordinator.refreshInterval + 1)
            await planning.refresh()
            #expect(loader.calls == 2)
            await planning.refresh(force: true)
            #expect(loader.calls == 3)
        }
    }

    // MARK: - The claim follows the decision

    @MainActor
    @Suite("clientManaged follows the device decision")
    struct ReminderPlanningClaimTests {
        private final class Gate {
            var plans: Bool
            init(_ plans: Bool) {
                self.plans = plans
            }
        }

        private final class Writes: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [Bool] = []
            var all: [Bool] {
                lock.lock()
                defer { lock.unlock() }
                return values
            }

            func append(_ value: Bool) {
                lock.lock()
                values.append(value)
                lock.unlock()
            }
        }

        private struct Harness {
            let coordinator: MedicationReminderDeliveryCoordinator
            let writes: Writes
            let registry: AuthenticatedSessionLeaseRegistry
            let lease: AuthenticatedSessionLease
            let marker: MedicationReminderClaimMarker
        }

        private func makeHarness(gate: Gate, phoneActive: Gate = Gate(false)) throws -> Harness {
            let owner = MedicationReminderDeliveryFixtures.owner
            let defaults = try #require(UserDefaults(suiteName: "hl.tests.reminderclaim.\(UUID().uuidString)"))
            let writes = Writes()
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try #require(registry.activate(ownerID: owner))
            let coordinator = MedicationReminderDeliveryCoordinator(
                defaults: defaults,
                notificationsAuthorized: { true },
                writeClaim: { value in
                    writes.append(value)
                    return MedicationReminderServerDelivery(clientManaged: value, deliveryDefault: "server")
                },
                releaseOnSignOut: {},
                plansLocally: { gate.plans },
                otherPhoneIsActive: { phoneActive.plans }
            )
            return Harness(
                coordinator: coordinator, writes: writes, registry: registry, lease: lease,
                marker: MedicationReminderClaimMarker(defaults: defaults)
            )
        }

        private func feed(_ h: Harness) throws {
            let owner = MedicationReminderDeliveryFixtures.owner
            h.coordinator.noteServerDelivery(MedicationReminderDeliveryFixtures.serverPushes, lease: h.lease)
            try h.coordinator.noteMedications(
                [MedicationReminderDeliveryFixtures.remindedMedication()], ownerID: owner
            )
        }

        @Test("a device that plans sets the mark, exactly as an iPhone does")
        func planningDeviceClaims() async throws {
            let h = try makeHarness(gate: Gate(true))
            try feed(h)
            await h.coordinator.settle()
            #expect(h.writes.all == [true])
            #expect(h.marker.isClaimed(by: MedicationReminderDeliveryFixtures.owner))
        }

        @Test("an iPad next to an active iPhone sets no mark and writes nothing")
        func waitingPadStaysQuiet() async throws {
            let h = try makeHarness(gate: Gate(false))
            try feed(h)
            await h.coordinator.settle()
            #expect(h.writes.all.isEmpty)
            #expect(!h.marker.isClaimed(by: MedicationReminderDeliveryFixtures.owner))
        }

        @Test("an iPad that yields to an active iPhone forgets its claim but never writes false")
        func yieldingPadKeepsTheFlag() async throws {
            let gate = Gate(true)
            let phone = Gate(false)
            let h = try makeHarness(gate: gate, phoneActive: phone)
            try feed(h)
            await h.coordinator.settle()
            #expect(h.writes.all == [true])

            gate.plans = false
            phone.plans = true
            h.coordinator.noteLocalPlanningChanged()
            await h.coordinator.settle()
            #expect(h.writes.all == [true])
            #expect(!h.marker.isClaimed(by: MedicationReminderDeliveryFixtures.owner))
        }

        @Test("an iPad that stops planning with no iPhone active gives its claim back")
        func lonePadReleases() async throws {
            let gate = Gate(true)
            let h = try makeHarness(gate: gate)
            try feed(h)
            await h.coordinator.settle()
            gate.plans = false
            h.coordinator.noteLocalPlanningChanged()
            await h.coordinator.settle()
            #expect(h.writes.all == [true, false])
            #expect(!h.marker.isClaimed(by: MedicationReminderDeliveryFixtures.owner))
        }
    }

    // MARK: - Composition

    @MainActor
    @Suite("The container carries the device profile into the platform policies", .serialized)
    struct DeviceProfileCompositionTests {
        private func makeContainer(_ profile: DeviceProfile) -> AppContainer {
            AppContainer(
                environment: AppEnvironment(
                    baseURL: URL(string: "https://example.invalid"),
                    bundleID: "dev.healthlog.app.tests",
                    appVersion: "0.0.0-test",
                    buildNumber: "0"
                ),
                keychain: InMemoryKeychain(),
                passkey: TestPasskeyService(),
                healthKit: nil,
                deviceProfile: profile
            )
        }

        @Test("an iPad registers no healthkit-sync task and decides the reminders; a phone keeps both as before")
        func padAndPhone() {
            let pad = makeContainer(DeviceProfile(idiom: .pad, model: "iPad"))
            #expect(!pad.backgroundSync.registersHealthKitTask)
            #expect(pad.reminderPlanning.isPad)
            #expect(pad.deviceProfile.model == "iPad")

            let phone = makeContainer(.phone)
            #expect(phone.backgroundSync.registersHealthKitTask)
            #expect(!phone.reminderPlanning.isPad)
            #expect(phone.reminderPlanning.plansLocally)
        }

        @Test("on a pad nothing collects HealthKit: no sample collection installed, no sync pass runs")
        func padCollectsNothing() async throws {
            AppOwnedHealthCollection.removeSampleCollectionForTesting()
            let pad = makeContainer(DeviceProfile(idiom: .pad, model: "iPad"))
            try await Task.sleep(for: .milliseconds(300))
            #expect(!AppOwnedHealthCollection.hasSampleCollection)
            let named = await pad.runHealthSyncPass(.foreground)
            #expect(named.isEmpty)
        }
    }

    // MARK: - A device that does not plan only removes reopened reminders

    @MainActor
    @Suite("MedicationReminderReopen follows the planning gate")
    struct ReopenPlanningGateTests {
        private let slot = MedicationReminderReopen.Slot(
            medicationId: "med-gate", scheduledAt: Date().addingTimeInterval(3 * 60 * 60)
        )

        @Test("the plan of a device that does not plan keeps its removals and drops its schedule")
        func restrictedPlan() {
            let plan = MedicationReminderReopen.Plan(schedule: [slot], remove: [slot], silenced: [slot], armed: [slot])
            let restricted = plan.restricted(plansLocally: false)
            #expect(restricted.schedule.isEmpty)
            #expect(restricted.remove == [slot])
            #expect(restricted.silenced == [slot])
            #expect(plan.restricted(plansLocally: true) == plan)
        }

        @Test("apply with plansLocally false arms nothing")
        func applyArmsNothing() async throws {
            let medication = try MedicationReminderDeliveryFixtures.remindedMedication(id: "med-gate")
            let plan = MedicationReminderReopen.Plan(schedule: [slot])
            MedicationReminderReopen.apply(plan, medications: [medication], plansLocally: false)
            try await Task.sleep(for: .milliseconds(200))
            let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
            #expect(!pending.contains { $0.identifier == MedicationReminderReopen.identifier(for: slot) })
        }
    }

#endif
