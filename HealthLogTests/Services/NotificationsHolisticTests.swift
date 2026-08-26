import Foundation
import SwiftUI
import Testing
#if canImport(UserNotifications) && canImport(UIKit)
    @testable import HealthLog
    import UserNotifications

    // swiftlint:disable force_unwrapping

    /// v0.5.4.3 HP5 — holistic notification-surface assertions.
    ///
    /// Pins five cross-cutting contracts that the operator's "denk
    /// ganzheitlich" feedback called out:
    ///
    /// 1. The `MOOD_REMINDER` category is registered with exactly the
    ///    three operator-mandated actions (mood.log.now / mood.snooze.1h
    ///    / mood.dismiss) — without this, the lock-screen banner would
    ///    render with no action chrome.
    ///
    /// 2. Each action identifier dispatches to the correct downstream
    ///    surface: mood.log.now opens the central-CTA sheet via the
    ///    router, mood.snooze.1h enqueues a UNTimeIntervalNotification\
    ///    Trigger one hour out with the MOOD_REMINDER category carried
    ///    through, mood.dismiss is a client-only no-op.
    ///
    /// 3. The settings toggle PATCHes `/api/user/profile` with the
    ///    `moodReminderEnabled` field — without this the server's cron
    ///    never fires for the user even if they tap the switch.
    ///
    /// 4. The local-fallback scheduler creates UNTimeIntervalNotification\
    ///    Triggers with the correct metadata shape + identifier prefix,
    ///    skips past-stamps + non-pending intakes, and cancels stale
    ///    backup identifiers before re-scheduling.
    @Suite(
        "Notifications — holistic surface (v0.5.4.3 HP5)",
        .serialized
    )
    @MainActor
    struct NotificationsHolisticTests {
        // MARK: - Scaffolding

        private static let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.5.4.3",
            buildNumber: "1"
        )

        private func makeAPI() -> APIClient {
            let keychain = InMemoryKeychain()
            try? keychain.setString("token", forKey: KeychainKey.authToken)
            return APIClient(
                environment: Self.env,
                keychain: keychain,
                sessionConfiguration: .mock()
            )
        }

        private func makeService(appRouter: AppRouter) -> NotificationService {
            let keychain = InMemoryKeychain()
            let deepLinks = DeepLinkRouter(router: appRouter, isAuthenticated: { true })
            return NotificationService(
                api: makeAPI(),
                environment: Self.env,
                keychain: keychain,
                deepLinks: deepLinks
            )
        }

        nonisolated static func okResponse(_ req: URLRequest) -> HTTPURLResponse {
            HTTPURLResponse(
                url: req.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
        }

        // MARK: - 1. MOOD_REMINDER category registration

        @Test("MOOD_REMINDER category registers with the operator-mandated 3 actions")
        func moodCategoryRegistration() async throws {
            let appRouter = AppRouter()
            _ = makeService(appRouter: appRouter)
            try await Task.sleep(nanoseconds: 50_000_000)
            let categories = await UNUserNotificationCenter.current().notificationCategories()
            guard let mood = categories.first(where: { $0.identifier == NotificationService.categoryMood }) else {
                Issue.record("MOOD_REMINDER category not registered")
                return
            }
            #expect(mood.actions.count == 3)
            let ids = mood.actions.map(\.identifier)
            #expect(ids.contains(NotificationService.actionMoodLogNow))
            #expect(ids.contains(NotificationService.actionMoodSnooze))
            #expect(ids.contains(NotificationService.actionMoodDismiss))
        }

        @Test("Mood action identifiers match the server's apns.category contract")
        func moodActionIdentifiersAreStable() {
            // Server payload contract: aps.category == "MOOD_REMINDER".
            // Action identifiers are iOS-only but stable so a future
            // server-side hint (e.g. background-only snooze cancel) can
            // assume these strings.
            #expect(NotificationService.categoryMood == "MOOD_REMINDER")
            #expect(NotificationService.actionMoodLogNow == "mood.log.now")
            #expect(NotificationService.actionMoodSnooze == "mood.snooze.1h")
            #expect(NotificationService.actionMoodDismiss == "mood.dismiss")
            #expect(NotificationService.moodSnoozeIntervalSeconds == 60 * 60)
        }

        @Test("Three categories are all registered together")
        func allCategoriesRegistered() async throws {
            let appRouter = AppRouter()
            _ = makeService(appRouter: appRouter)
            try await Task.sleep(nanoseconds: 50_000_000)
            let categories = await UNUserNotificationCenter.current().notificationCategories()
            let identifiers = Set(categories.map(\.identifier))
            #expect(identifiers.contains(NotificationService.categoryMedication))
            #expect(identifiers.contains(NotificationService.categoryBriefing))
            #expect(identifiers.contains(NotificationService.categoryMood))
        }

        // MARK: - 2. Action-handler dispatch

        @Test("mood.log.now bumps moodQuickEntryRequestCount on the router")
        func moodLogNowRoutesToQuickEntry() async {
            let appRouter = AppRouter()
            let svc = makeService(appRouter: appRouter)
            #expect(appRouter.moodQuickEntryRequestCount == 0)

            await svc.dispatchAction(actionID: NotificationService.actionMoodLogNow, payload: nil)

            #expect(appRouter.moodQuickEntryRequestCount == 1)
            // The router flips the tab back to .home so the sheet covers
            // the dashboard surface — not whichever tab happened to be
            // selected when the user tapped the lock-screen banner.
            #expect(appRouter.selectedTab == .home)
        }

        @Test("Two mood.log.now invocations re-bump the counter so the sheet re-presents")
        func moodLogNowReBumpsCounter() async {
            let appRouter = AppRouter()
            let svc = makeService(appRouter: appRouter)
            await svc.dispatchAction(actionID: NotificationService.actionMoodLogNow, payload: nil)
            await svc.dispatchAction(actionID: NotificationService.actionMoodLogNow, payload: nil)
            #expect(appRouter.moodQuickEntryRequestCount == 2)
        }

        @Test("Mood-snooze request builder produces a one-hour trigger with the MOOD_REMINDER category")
        func moodSnoozeBuilderShape() {
            let payload = APNsPayload(
                title: "Wie geht's dir gerade?",
                body: "Logge kurz deine Stimmung.",
                eventType: "MOOD_REMINDER",
                metricType: nil,
                deepLink: nil
            )
            let req = NotificationService.buildMoodSnoozeRequest(payload: payload)
            #expect(req.identifier.hasPrefix("mood-snooze-"))
            #expect(req.content.categoryIdentifier == NotificationService.categoryMood)
            #expect(req.content.userInfo["eventType"] as? String == "MOOD_REMINDER")
            if let trigger = req.trigger as? UNTimeIntervalNotificationTrigger {
                #expect(trigger.timeInterval == NotificationService.moodSnoozeIntervalSeconds)
                #expect(!trigger.repeats)
            } else {
                Issue.record("Expected UNTimeIntervalNotificationTrigger")
            }
        }

        @Test("Mood-snooze builder falls back to MOOD_REMINDER eventType when payload has none")
        func moodSnoozeBuilderEventTypeFallback() {
            let req = NotificationService.buildMoodSnoozeRequest(payload: nil)
            #expect(req.content.userInfo["eventType"] as? String == NotificationService.categoryMood)
            #expect(req.content.categoryIdentifier == NotificationService.categoryMood)
            // Default copy is the static MoodQuickEntry fallback so the
            // snoozed banner reads coherently even when the original
            // payload had no title/body.
            #expect(!req.content.title.isEmpty)
            #expect(!req.content.body.isEmpty)
        }

        @Test("mood.dismiss is a client-only no-op — no router state change, no pending request")
        func moodDismissIsClientOnly() async throws {
            let appRouter = AppRouter()
            let svc = makeService(appRouter: appRouter)
            let center = UNUserNotificationCenter.current()
            center.removeAllPendingNotificationRequests()

            let payload = APNsPayload(
                title: "Stimmung?",
                body: "Bitte loggen.",
                eventType: "MOOD_REMINDER",
                metricType: nil,
                deepLink: nil
            )
            await svc.dispatchAction(actionID: NotificationService.actionMoodDismiss, payload: payload)

            try await Task.sleep(nanoseconds: 50_000_000)
            #expect(appRouter.moodQuickEntryRequestCount == 0)
            #expect(appRouter.selectedTab == .home)
            let pending = await center.pendingNotificationRequests()
            #expect(pending.contains { $0.identifier.hasPrefix("mood-snooze-") } == false)
        }

        @Test("Body-tap on MOOD_REMINDER push routes to the mood quick-entry sheet")
        func moodBodyTapRoutesToQuickEntry() async {
            let appRouter = AppRouter()
            let svc = makeService(appRouter: appRouter)
            let payload = APNsPayload(
                title: "Stimmung?",
                body: "Bitte loggen.",
                eventType: "MOOD_REMINDER",
                metricType: nil,
                deepLink: nil
            )
            await svc.dispatchAction(actionID: UNNotificationDefaultActionIdentifier, payload: payload)

            #expect(appRouter.moodQuickEntryRequestCount == 1)
            #expect(appRouter.selectedTab == .home)
        }

        // MARK: - 3. Settings toggle PATCHes the server

        @Test("SettingsStore.updateMoodReminderEnabled PATCHes /api/user/profile with the flag")
        func moodToggleHitsServerPATCH() async throws {
            let api = makeAPI()
            let repo = SettingsRepository(api: api)
            let store = try SettingsStore(
                repo: repo,
                defaults: #require(UserDefaults(suiteName: "moodToggleTest-\(UUID().uuidString)"))
            )

            nonisolated(unsafe) var capturedPath: String?
            nonisolated(unsafe) var capturedBody: Data?
            MockURLProtocol.handler = { req in
                // CU-07: the handler is process-global — record only OUR route so
                // a parallel suite's request cannot overwrite the capture.
                if req.targets("/api/user/profile") {
                    capturedPath = req.url?.path
                    capturedBody = req.httpBody ?? Self.drainBody(req)
                }
                // Server reply mirrors the request — moodReminderEnabled=true.
                let body = #"""
                {"data":{"username":"u","displayName":null,"email":null,"dateOfBirth":null,"gender":null,"heightCm":null,"locale":null,"timezone":null,"moodReminderEnabled":true}}
                """#
                return (Self.okResponse(req), Data(body.utf8))
            }

            let ok = await store.updateMoodReminderEnabled(true)
            #expect(ok)
            #expect(capturedPath == "/api/user/profile")
            guard let body = capturedBody,
                  let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else
            {
                Issue.record("Could not decode PATCH body")
                return
            }
            #expect(json["moodReminderEnabled"] as? Bool == true)
            #expect(store.profile?.moodReminderEnabled == true)
        }

        @Test("Toggle skips network when the desired value already matches")
        func moodToggleSkipsNoOp() async throws {
            let api = makeAPI()
            let repo = SettingsRepository(api: api)
            let store = try SettingsStore(
                repo: repo,
                defaults: #require(UserDefaults(suiteName: "moodToggleNoOp-\(UUID().uuidString)"))
            )
            // Pre-seed in-memory profile so the toggle finds a matching
            // value and short-circuits before touching the network.
            await Self.seedProfile(store: store, enabled: true)

            nonisolated(unsafe) var hits = 0
            MockURLProtocol.handler = { req in
                // CU-07: `hits == 0` only means "the toggle skipped the PATCH" if
                // a parallel suite's request cannot raise it.
                // Path only, no method pin: a regression that reached the profile
                // route with a different verb must still trip this.
                if req.targets("/api/user/profile") { hits &+= 1 }
                return (
                    Self.okResponse(req),
                    Data(
                        #"{"data":{"username":"u","displayName":null,"email":null,"dateOfBirth":null,"gender":null,"heightCm":null,"locale":null,"timezone":null,"moodReminderEnabled":true}}"#
                            .utf8
                    )
                )
            }
            let ok = await store.updateMoodReminderEnabled(true)
            #expect(ok)
            #expect(hits == 0, "PATCH should be skipped when no diff")
        }

        @Test("NotificationEventLocalization knows MOOD_REMINDER")
        func moodEventLocalized() {
            #expect(NotificationEventLocalization.title(for: "MOOD_REMINDER") == "Stimmungs-Erinnerung")
            // UI-Standard R3/R7 (U6) — die Unterzeile ist entfallen: sie nannte
            // eine harte „22:00", obwohl die Uhrzeit im DatePicker der
            // Stimmungs-Karte gesetzt wird, und die Karte ist die Heimat der
            // Aussage.
            #expect(NotificationEventLocalization.hint(for: "MOOD_REMINDER") == nil)
        }

        @Test("MOOD_REMINDER slots into the priority ranking just under DAILY_BRIEFING")
        func moodPriorityRank() {
            let mood = NotificationEventPriority.rank(of: "MOOD_REMINDER")
            let briefing = NotificationEventPriority.rank(of: "DAILY_BRIEFING")
            let meds = NotificationEventPriority.rank(of: "MEDICATION_REMINDER")
            #expect(briefing < mood)
            #expect(mood < meds)
        }

        // MARK: - 5. Local-fallback scheduling

        @Test("Local-backup builder produces a request only for future-pending intakes")
        func localBackupsBuilderRules() {
            let now = Date(timeIntervalSince1970: 1_779_710_400)
            let future = MedicationIntake(
                id: "intake-1",
                medicationId: "med-A",
                scheduledAt: now.addingTimeInterval(3600),
                status: .pending
            )
            let past = MedicationIntake(
                id: "intake-past",
                medicationId: "med-C",
                scheduledAt: now.addingTimeInterval(-600),
                status: .pending
            )
            let taken = MedicationIntake(
                id: "intake-taken",
                medicationId: "med-D",
                scheduledAt: now.addingTimeInterval(1800),
                status: .taken
            )
            #expect(NotificationService.buildLocalBackupRequest(for: future, now: now) != nil)
            #expect(NotificationService.buildLocalBackupRequest(for: past, now: now) == nil)
            #expect(NotificationService.buildLocalBackupRequest(for: taken, now: now) == nil)
        }

        @Test("Local-backup builder carries medicationId + scheduleId + localBackup marker")
        func localBackupBuilderUserInfo() {
            let now = Date(timeIntervalSince1970: 1_779_710_400)
            let intake = MedicationIntake(
                id: "intake-x",
                medicationId: "med-X",
                scheduledAt: now.addingTimeInterval(3600),
                status: .pending
            )
            guard let req = NotificationService.buildLocalBackupRequest(for: intake, now: now) else {
                Issue.record("Builder returned nil for a valid future-pending intake")
                return
            }
            #expect(req.identifier == "med-local-backup-med-X-intake-x")
            #expect(req.content.categoryIdentifier == NotificationService.categoryMedication)
            #expect(req.content.userInfo["medicationId"] as? String == "med-X")
            #expect(req.content.userInfo["scheduleId"] as? String == "intake-x")
            #expect(req.content.userInfo["eventType"] as? String == NotificationService.categoryMedication)
            #expect(req.content.userInfo["localBackup"] as? Bool == true)
            if let trigger = req.trigger as? UNTimeIntervalNotificationTrigger {
                // Trigger interval mirrors the future delta (~3600s).
                #expect(trigger.timeInterval == 3600)
                #expect(!trigger.repeats)
            } else {
                Issue.record("Expected UNTimeIntervalNotificationTrigger")
            }
        }

        @Test("Local-backup builder clamps non-positive intervals to a minimum of 1 second")
        func localBackupBuilderClampsInterval() {
            let now = Date(timeIntervalSince1970: 1_779_710_400)
            // Exactly +0.5s into the future — production code clamps the
            // trigger to >=1s so UN doesn't reject a sub-second window.
            let nearFuture = MedicationIntake(
                id: "intake-near",
                medicationId: "med-near",
                scheduledAt: now.addingTimeInterval(0.5),
                status: .pending
            )
            guard let req = NotificationService.buildLocalBackupRequest(for: nearFuture, now: now) else {
                Issue.record("Builder returned nil for a 0.5s-future intake")
                return
            }
            if let trigger = req.trigger as? UNTimeIntervalNotificationTrigger {
                #expect(trigger.timeInterval >= 1)
            } else {
                Issue.record("Expected UNTimeIntervalNotificationTrigger")
            }
        }

        @Test("Local-backup identifier shape is stable across releases")
        func localBackupIdentifierShape() {
            let intake = MedicationIntake(
                id: "intake-Z",
                medicationId: "med-Z",
                scheduledAt: Date(),
                status: .pending
            )
            let id = NotificationService.localBackupIdentifier(for: intake)
            #expect(id == "med-local-backup-med-Z-intake-Z")
        }

        // MARK: - 6. Profile encode/decode shape

        @Test("UserProfile decodes moodReminderEnabled from /api/user/profile reply")
        func userProfileDecodesMoodFlag() throws {
            let json = #"""
            {"username":"u","displayName":null,"email":null,"dateOfBirth":null,"gender":null,"heightCm":null,"locale":null,"timezone":"Europe/Berlin","moodReminderEnabled":true}
            """#
            let decoded = try JSONDecoder().decode(UserProfile.self, from: Data(json.utf8))
            #expect(decoded.moodReminderEnabled == true)
        }

        @Test("UserProfile tolerates legacy server omitting moodReminderEnabled")
        func userProfileToleratesMissingMoodFlag() throws {
            let json = #"""
            {"username":"u","displayName":null,"email":null,"dateOfBirth":null,"gender":null,"heightCm":null,"locale":null,"timezone":"Europe/Berlin"}
            """#
            let decoded = try JSONDecoder().decode(UserProfile.self, from: Data(json.utf8))
            #expect(decoded.moodReminderEnabled == nil)
        }

        @Test("ProfilePatch encodes only the keys whose value was set")
        func profilePatchEncodesOnlySetFields() throws {
            let patch = ProfilePatch(moodReminderEnabled: true)
            #expect(patch.isEmpty == false)
            let data = try JSONEncoder().encode(patch)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            #expect(json["moodReminderEnabled"] as? Bool == true)
            #expect(json["displayName"] == nil)
            #expect(json["heightCm"] == nil)
            // Empty patch is empty.
            let empty = ProfilePatch()
            #expect(empty.isEmpty)
        }

        // MARK: - Helpers

        nonisolated static func drainBody(_ req: URLRequest) -> Data? {
            guard let stream = req.httpBodyStream else { return nil }
            stream.open()
            defer { stream.close() }
            var data = Data()
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { buf.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buf, maxLength: 4096)
                if read <= 0 { break }
                data.append(buf, count: read)
            }
            return data.isEmpty ? nil : data
        }

        /// Seed the SettingsStore.profile to a known value by stubbing
        /// the /profile GET + calling `load()`.
        @MainActor
        static func seedProfile(store: SettingsStore, enabled: Bool) async {
            MockURLProtocol.handler = { req in
                let path = req.url?.path ?? ""
                if path == "/api/user/profile" {
                    let body = #"""
                    {"data":{"username":"seed","displayName":null,"email":null,"dateOfBirth":null,"gender":null,"heightCm":null,"locale":null,"timezone":"Europe/Berlin","moodReminderEnabled":\#(
                        enabled ?
                            "true" : "false"
                    )}}
                    """#
                    return (Self.okResponse(req), Data(body.utf8))
                }
                // HK config GET — minimal valid body.
                let body = #"{"data":{"entries":[],"lastSyncedAt":null}}"#
                return (Self.okResponse(req), Data(body.utf8))
            }
            await store.load()
        }
    }

    // swiftlint:enable force_unwrapping
#endif
