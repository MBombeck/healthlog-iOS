// App-Target-Symbole (`BackgroundSyncCoordinator`, `NotificationService`) — in
// der SPM-Library nicht enthalten, der SPM-Test-Build überspringt die Datei.
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    // swiftlint:disable force_unwrapping

    /// Records the order in which the hooks of one wake ran.
    private final class WakeLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []

        func record(_ entry: String) {
            lock.withLock { entries.append(entry) }
        }

        var all: [String] {
            lock.withLock { entries }
        }
    }

    /// **R5 — background wakes extend the local medication reminders.**
    ///
    /// Up to R5 only the BGProcessing wake (HealthKit users only, after the
    /// HealthKit pass, if the grant had not expired) and the intake-sync push
    /// reached the medication reconcile. The AppRefresh wake, every other silent
    /// push and the actions on a reminder never did, so a course armed with
    /// single occurrences ran dry unless the app was opened.
    @Suite("R5 — every background wake tops up the local reminders", .serialized, .mockURLSession)
    @MainActor
    struct MedicationReminderWakeTopUpTests {
        private static let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "1.1.0",
            buildNumber: "1"
        )

        private func makeAPI() -> APIClient {
            let keychain = InMemoryKeychain()
            try? keychain.setString("token", forKey: KeychainKey.authToken)
            return APIClient(environment: Self.env, keychain: keychain, sessionConfiguration: .mock())
        }

        private func coordinator(_ log: WakeLog, healthKit: AnyHealthKitWriter? = nil) -> BackgroundSyncCoordinator {
            let coordinator = BackgroundSyncCoordinator(healthKit: healthKit)
            coordinator.attachReminderTopUpHook { log.record("topUp") }
            coordinator.attachHealthSyncRoute { _, _ in
                log.record("healthPass")
                return []
            }
            return coordinator
        }

        @Test("BGAppRefresh wake: top-up runs, before the HealthKit pass")
        func appRefreshTopsUp() async {
            let log = WakeLog()
            let spy = BGTaskCompletionSpy()
            await coordinator(log).runBGRefresh(on: spy)
            #expect(log.all == ["topUp", "healthPass"])
            #expect(spy.completionCount == 1)
        }

        @Test("BGProcessing wake: top-up runs first, so an expiring HealthKit pass cannot skip it")
        func processingTopsUpFirst() async {
            let log = WakeLog()
            let spy = BGTaskCompletionSpy()
            await coordinator(log, healthKit: MockHealthKitWriter()).runBGSync(on: spy)
            #expect(log.all.first == "topUp")
            #expect(log.all.contains("healthPass"))
        }

        private func makeService(backgroundSync: BackgroundSyncCoordinator) throws -> NotificationService {
            let deepLinks = DeepLinkRouter(router: AppRouter(), isAuthenticated: { true })
            return try NotificationService(
                api: makeAPI(),
                environment: Self.env,
                keychain: InMemoryKeychain(),
                deepLinks: deepLinks,
                backgroundSync: backgroundSync,
                defaults: #require(UserDefaults(suiteName: "test.r5.\(UUID().uuidString)"))
            )
        }

        @Test("any silent push tops up, not only the intake-sync push")
        func silentPushTopsUp() async throws {
            MockURLProtocol.install { req in
                (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!, Data("{}".utf8))
            }
            let log = WakeLog()
            let service = try makeService(backgroundSync: coordinator(log))
            _ = await service.didReceiveSilentNotification(
                userInfo: RemoteNotificationUserInfo(["aps": ["content-available": 1]])
            )
            #expect(log.all.contains("topUp"))
        }

        @Test("an action on a medication reminder tops up: Genommen, Überspringen, Verschieben")
        func reminderActionTopsUp() async throws {
            let log = WakeLog()
            let service = try makeService(backgroundSync: coordinator(log))
            let payload = APNsPayload(
                title: "Amoxicillin",
                body: "500 mg",
                eventType: "MEDICATION_REMINDER",
                metricType: nil,
                deepLink: nil,
                medicationId: "med-1",
                scheduleId: "sched-1",
                scheduledFor: Date(timeIntervalSince1970: 1_779_710_400)
            )
            for action in [
                NotificationService.actionMedicationTaken,
                NotificationService.actionMedicationSkipped,
                NotificationService.actionMedicationSnooze
            ] {
                await service.dispatchAction(actionID: action, payload: payload)
            }
            #expect(log.all == ["topUp", "topUp", "topUp"])

            // Any other action leaves the reminders alone.
            await service.dispatchAction(actionID: NotificationService.actionMoodDismiss, payload: nil)
            #expect(log.all.count == 3)
        }
    }

    /// **R5 — the top-up reads the cached list, never the network.**
    @Suite("R5 — MedicationsStore tops up from the cache", .serialized, .mockURLSession)
    @MainActor
    struct MedicationsStoreReminderTopUpTests {
        private static let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "1.1.0",
            buildNumber: "1"
        )

        private final class StubReach: ReachabilityProviding, @unchecked Sendable {
            var isOnlineStream: AsyncStream<Bool> {
                get async { AsyncStream { continuation in
                    continuation.yield(true)
                    continuation.finish()
                } }
            }

            func isCurrentlyOnline() async -> Bool {
                true
            }
        }

        private final class RequestCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            func hit() {
                lock.withLock { count += 1 }
            }

            var value: Int {
                lock.withLock { count }
            }
        }

        private static let cachedMedication = Medication(
            id: "med-cached",
            name: "Amoxicillin",
            dose: "500 mg",
            schedule: MedicationSchedule(entries: [ScheduleEntry(
                cadence: .daily,
                timesOfDay: [TimeOfDay(hour: 8, minute: 0)],
                windowStart: TimeOfDay(hour: 8, minute: 0)
            )]),
            notificationsEnabled: true,
            active: true
        )

        private func makeStore(counter: RequestCounter) async throws -> MedicationsStore {
            let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
            try await cache.write(.medicationsList, payload: JSONEncoder.hlDefault.encode([Self.cachedMedication]))
            let swr = SWRCoordinator(cache: cache, reachability: StubReach())
            MockURLProtocol.install { req in
                counter.hit()
                return (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: "HTTP/1.1", headerFields: nil)!, Data())
            }
            let keychain = InMemoryKeychain()
            try? keychain.setString("token", forKey: KeychainKey.authToken)
            let api = APIClient(environment: Self.env, keychain: keychain, sessionConfiguration: .mock())
            let repo = try MedicationsRepository(api: api, outbox: OutboxQueue(inMemory: true))
            return MedicationsStore(repo: repo, swr: swr)
        }

        @Test("a store the wake just launched reconciles from the cached list, without a request")
        func coldStoreReconcilesFromCache() async throws {
            let counter = RequestCounter()
            let store = try await makeStore(counter: counter)
            var reconciled: [[Medication]] = []
            store.onMedicationsDidChange = { reconciled.append($0) }

            #expect(await store.topUpRemindersFromCache())
            #expect(store.medications.map(\.id) == ["med-cached"])
            #expect(reconciled.map { $0.map(\.id) } == [["med-cached"]])
            #expect(counter.value == 0)
        }

        @Test("a list the store already holds is reconciled as it is, never replaced by the cache")
        func loadedStoreKeepsItsList() async throws {
            let counter = RequestCounter()
            let store = try await makeStore(counter: counter)
            let live = Medication(
                id: "med-live", name: "Lisinopril", dose: "5 mg",
                schedule: Self.cachedMedication.schedule, notificationsEnabled: true, active: true
            )
            store._testForceSet(medications: [live])
            var reconciled: [[Medication]] = []
            store.onMedicationsDidChange = { reconciled.append($0) }

            #expect(await store.topUpRemindersFromCache())
            #expect(reconciled.map { $0.map(\.id) } == [["med-live"]])
            #expect(counter.value == 0)
        }

        @Test("without a session lease nothing is read and nothing reconciled")
        func noLeaseNoTopUp() async throws {
            let counter = RequestCounter()
            let store = try await makeStore(counter: counter)
            store.bindAuthenticatedSessionRegistry(AuthenticatedSessionLeaseRegistry(), ownerIDProvider: { nil })
            var reconciled = 0
            store.onMedicationsDidChange = { _ in reconciled += 1 }

            #expect(await !store.topUpRemindersFromCache())
            #expect(store.medications.isEmpty)
            #expect(reconciled == 0)
        }
    }

    // swiftlint:enable force_unwrapping

#endif
