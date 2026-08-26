#if canImport(ActivityKit)
    import ActivityKit
    import Foundation
    @testable import HealthLog
    import Testing

    // swiftlint:disable force_unwrapping

    /// **b181 W-B181 (DOUBLE-DOSE SAFETY)** — pins the remote-intake reconcile.
    ///
    /// Root cause this suite locks down: a dose taken on the WEB / a second
    /// device used to leave the iOS Live Activity + medication widgets showing
    /// "jetzt nehmen" because the reconcile (Live Activity end + widget reload)
    /// only ran on a LOCAL intake mutation — never when a server refresh of
    /// `MedicationsStore` brought a status change (fällig → genommen). That is a
    /// real double-intake hazard.
    ///
    /// These tests drive the REAL `MedicationsStore` through a real
    /// `SWRCoordinator` + in-memory cache + `MockURLProtocol` (no mock-server
    /// shortcut — per PROJECT_GUIDE.md), wire the production reconcile chain onto
    /// `onIntakesDidChange`, and assert that a server `.fresh` carrying a
    /// remote-taken intake:
    ///   (a) ends the Live Activity (recorded on the controller spy), and
    ///   (b) reloads the widget timeline (proxy: the widget snapshot's
    ///       `generatedAt` advances — the writer only writes when data moved).
    /// Plus: an already-taken dose must NOT (re)start a Live Activity.
    @Suite("MedicationsStore — b181 remote-intake reconcile", .serialized)
    @MainActor
    struct MedicationRemoteIntakeReconcileTests {
        // MARK: - Reconcile spy

        /// Records the side-effecting reconcile calls so we can assert the
        /// Live Activity is ended (not left running) when a dose is taken
        /// remotely, and is never (re)started for an already-taken dose.
        /// One reconcile side-effect, in call order, so a test can assert the
        /// FINAL action (the user-visible end state of the banner) — not just
        /// that any start/end ever happened. The bug was that the LAST action
        /// for a remote-taken dose stayed a "start" (stale "jetzt nehmen");
        /// the fix makes the last action an end.
        private enum Event: Equatable { case start(String), end(String), endAll }

        @MainActor
        private final class ReconcileSpy: MedicationLiveActivityReconciling {
            var areActivitiesEnabled = true
            private(set) var events: [Event] = []
            var startCalls: [String] {
                events.compactMap { if case let .start(id) = $0 { id } else { nil } }
            }

            var endCalls: [String] {
                events.compactMap { if case let .end(id) = $0 { id } else { nil } }
            }

            var endAllCount: Int {
                events.filter { $0 == .endAll }.count
            }

            /// The user-visible terminal state of the banner after reconcile.
            var lastEvent: Event? {
                events.last
            }

            /// `true` once the dose's Live Activity has been resolved.
            var didEndDose: Bool {
                !endCalls.isEmpty || endAllCount > 0
            }

            @discardableResult
            func start(
                medicationId: String,
                medicationName _: String,
                doseText _: String,
                scheduledFireDate _: Date,
                isOverdue _: Bool,
                now _: Date
            ) async -> String? {
                events.append(.start(medicationId))
                return medicationId
            }

            func end(
                medicationId: String,
                finalStatus _: MedicationActivityAttributes.ContentState.Status,
                countdownTarget _: Date,
                dismissalPolicy _: ActivityUIDismissalPolicy
            ) async {
                events.append(.end(medicationId))
            }

            func endAll(dismissalPolicy _: ActivityUIDismissalPolicy) async {
                events.append(.endAll)
            }
        }

        // MARK: - Fixtures

        private static var todayKey: CacheKey {
            .medicationsTodayIntakes(day: MedicationDayKey.string(timeZone: .current))
        }

        private final class StubReach: ReachabilityProviding, @unchecked Sendable {
            var isOnlineStream: AsyncStream<Bool> {
                get async { AsyncStream { c in c.yield(true)
                    c.finish()
                } }
            }

            func isCurrentlyOnline() async -> Bool {
                true
            }
        }

        /// A medication due at 09:00 local today (inside the Live-Activity lead
        /// window when "now" is 08:00). The per-med Live-Activity toggle is left
        /// at the test reconcile default (always-enabled) so the gate does not
        /// suppress surfacing.
        private func med(id: String = "med-1") -> Medication {
            Medication(
                id: id,
                name: "Vitamin D",
                dose: "1000 IE",
                schedule: MedicationSchedule(times: [TimeOfDay(hour: 9, minute: 0)]),
                notificationsEnabled: true,
                active: true
            )
        }

        private func makeWidgetWriter() -> (WidgetSnapshotWriter, WidgetSnapshotStore) {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("b181-widget-\(UUID().uuidString).json")
            let store = WidgetSnapshotStore(url: url)
            return (WidgetSnapshotWriter(store: store), store)
        }

        @MainActor
        private func makeAPIClient() -> APIClient {
            let keychain = InMemoryKeychain()
            try? keychain.setString("token", forKey: KeychainKey.authToken)
            let env = AppEnvironment(
                baseURL: URL(string: "https://test.healthlog.local")!,
                bundleID: "dev.healthlog.app",
                appVersion: "0.5.0",
                buildNumber: "1"
            )
            return APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock())
        }

        private nonisolated static func ok(_ request: URLRequest) -> HTTPURLResponse {
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
        }

        /// Wires the production reconcile chain (Live Activity + widget) onto the
        /// store's `onIntakesDidChange` exactly like `AppContainer` does, so the
        /// chain under test is the real one — not a test-only re-implementation.
        private func wireReconcile(
            store: MedicationsStore,
            spy: ReconcileSpy,
            writer: WidgetSnapshotWriter,
            now: @escaping () -> Date
        ) {
            store.onIntakesDidChange = { [weak store, weak spy] in
                guard let store, let spy else { return }
                AppContainer.reconcileMedicationLiveActivity(
                    controller: spy,
                    medications: store.medications,
                    intakes: store.todayIntakes,
                    now: now()
                )
                writer.refresh(
                    medications: store.medications,
                    derivedIntakes: store.derivedTodayIntakes,
                    now: now()
                )
            }
        }

        // MARK: - (a) Remote intake → Live Activity ended + widget reloaded

        @Test("Server .fresh carrying a remote-taken dose ends the Live Activity + reloads the widget")
        func remoteTakenEndsActivityAndReloadsWidget() async throws {
            let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
            let coordinator = SWRCoordinator(cache: cache, reachability: StubReach())

            // Seed the cache with a PENDING 09:00 intake so the first observe
            // emits `.cached` (pending) — the Live Activity / widget see "due".
            let scheduled = try #require(Calendar.current.date(
                bySettingHour: 9, minute: 0, second: 0, of: .now
            ))
            let pending = MedicationIntake(
                id: "intake-1",
                medicationId: "med-1",
                scheduledAt: scheduled,
                takenAt: nil,
                status: .pending
            )
            try await cache.write(Self.todayKey, payload: JSONEncoder.hlDefault.encode([pending]))

            // The server (.fresh) now returns the SAME intake as TAKEN — i.e. a
            // dose marked done on the WEB while the app was backgrounded.
            let scheduledISO = ISO8601DateFormatter().string(from: scheduled)
            let api = makeAPIClient()
            let outbox = try OutboxQueue(inMemory: true)
            MockURLProtocol.handler = { req in
                let path = req.url?.path ?? ""
                let query = req.url?.query ?? ""
                if path == "/api/medications", req.httpMethod == "GET" {
                    return (Self.ok(req), Data(#"{"data":[]}"#.utf8))
                }
                if path == "/api/medications/intake", query.contains("scope=today") {
                    let body = """
                    {"data":[{"id":"intake-1","medicationId":"med-1","scheduledAt":"\(scheduledISO)",\
                    "takenAt":"\(scheduledISO)","status":"taken","snoozedUntil":null}]}
                    """
                    return (Self.ok(req), Data(body.utf8))
                }
                if path == "/api/medications/intake", query.contains("scope=compliance") {
                    return (Self.ok(req), Data(#"{"data":[]}"#.utf8))
                }
                return (
                    HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!,
                    Data()
                )
            }

            let store = MedicationsStore(repo: MedicationsRepository(api: api, outbox: outbox), swr: coordinator)
            // Inject the medication list directly so reconcile/widget see the
            // due 09:00 schedule (the server med list is intentionally empty in
            // this fixture; the bug is about the INTAKE status flip).
            store._testForceSet(medications: [med()])

            let spy = ReconcileSpy()
            let (writer, widgetStore) = makeWidgetWriter()
            // Fixed "now" = 08:00 today → the 09:00 dose is inside the lead window.
            let fixedNow = try #require(Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: .now))
            wireReconcile(store: store, spy: spy, writer: writer, now: { fixedNow })

            // Act — a forced load pulls the server-canonical (TAKEN) intake. This
            // is exactly what the b181 scenePhase / BGTask path now triggers.
            await store.load(force: true)
            // The reconcile dispatches an async MainActor task per intake emit;
            // drain so the .cached(pending) → .fresh(taken) sequence completes.
            await Task.yield()
            try await Task.sleep(nanoseconds: 80_000_000)

            // Assert the store actually saw the remote flip.
            #expect(store.todayIntakes.first?.status == .taken, "Store must pull the remote-taken intake")

            // (a) Live Activity resolved — the TERMINAL reconcile action is an
            // end, not a lingering "start" (the double-dose bug = the banner
            // stayed on "jetzt nehmen"). The seeded .cached(pending) emit may
            // legitimately start the banner first; the .fresh(taken) emit must
            // then clear it. We assert the FINAL state, which is what the user
            // sees on the Lock Screen.
            #expect(spy.didEndDose, "A remote-taken dose must end its Live Activity (double-dose guard)")
            let terminal = spy.lastEvent
            #expect(
                terminal == .endAll || terminal == .end("med-1"),
                "Terminal reconcile action for a remote-taken dose must be an end, was \(String(describing: terminal))"
            )

            // (b) Widget reload triggered — proxy: the snapshot was (re)written
            // (the writer only writes + reloads when the dose/compliance moved).
            // 09-03 — the write is queued off the main actor now, so drain the
            // writer before reading the file it is about to produce.
            await writer.drainPendingWrites()
            #expect(widgetStore.read() != nil, "Widget snapshot must be written so the timeline reloads")
        }

        // MARK: - (c) Already-taken dose never starts a Live Activity

        @Test("An already-taken dose never starts a Live Activity on load")
        func alreadyTakenNeverStarts() async throws {
            let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
            let coordinator = SWRCoordinator(cache: cache, reachability: StubReach())

            let scheduled = try #require(Calendar.current.date(
                bySettingHour: 9, minute: 0, second: 0, of: .now
            ))
            let scheduledISO = ISO8601DateFormatter().string(from: scheduled)
            let api = makeAPIClient()
            let outbox = try OutboxQueue(inMemory: true)
            MockURLProtocol.handler = { req in
                let path = req.url?.path ?? ""
                let query = req.url?.query ?? ""
                if path == "/api/medications", req.httpMethod == "GET" {
                    return (Self.ok(req), Data(#"{"data":[]}"#.utf8))
                }
                if path == "/api/medications/intake", query.contains("scope=today") {
                    let body = """
                    {"data":[{"id":"intake-1","medicationId":"med-1","scheduledAt":"\(scheduledISO)",\
                    "takenAt":"\(scheduledISO)","status":"taken","snoozedUntil":null}]}
                    """
                    return (Self.ok(req), Data(body.utf8))
                }
                if path == "/api/medications/intake", query.contains("scope=compliance") {
                    return (Self.ok(req), Data(#"{"data":[]}"#.utf8))
                }
                return (
                    HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!,
                    Data()
                )
            }

            let store = MedicationsStore(repo: MedicationsRepository(api: api, outbox: outbox), swr: coordinator)
            store._testForceSet(medications: [med()])

            let spy = ReconcileSpy()
            let (writer, _) = makeWidgetWriter()
            let fixedNow = try #require(Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: .now))
            wireReconcile(store: store, spy: spy, writer: writer, now: { fixedNow })

            await store.load(force: true)

            #expect(spy.startCalls.isEmpty, "An already-taken dose must never start a Live Activity")
        }

        // MARK: - Reconcile decision unit (no store) — taken dose clears all

        @Test("reconcile with a taken dose clears every running Live Activity")
        func reconcileTakenClearsAll() async throws {
            let spy = ReconcileSpy()
            let scheduled = try #require(Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: .now))
            let now = try #require(Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: .now))
            let taken = MedicationIntake(
                id: "i1",
                medicationId: "med-1",
                scheduledAt: scheduled,
                takenAt: now,
                status: .taken
            )

            AppContainer.reconcileMedicationLiveActivity(
                controller: spy,
                medications: [med()],
                intakes: [taken],
                now: now
            )
            // The reconcile dispatches an async MainActor task; yield so it runs.
            await Task.yield()
            try await Task.sleep(nanoseconds: 50_000_000)

            #expect(spy.endAllCount >= 1, "A taken-only dose set leaves nothing in-window → endAll clears the banner")
            #expect(spy.startCalls.isEmpty, "No Live Activity may be started for a taken dose")
        }
    }

    // swiftlint:enable force_unwrapping
#endif
