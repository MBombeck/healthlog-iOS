import Foundation
@testable import HealthLog
import Testing
#if canImport(UserNotifications) && canImport(UIKit)
    import UserNotifications

    // swiftlint:disable force_unwrapping

    /// **W-B189 (#23) — `MEASUREMENT_REMINDER` (preventive-care / Vorsorge)
    /// category + "Erledigt" action + routing.**
    ///
    /// Pins the contract the server (v1.17.1) welcomed for parity:
    ///   - a dedicated `MEASUREMENT_REMINDER` category carries one
    ///     "Erledigt"/complete action (`measurement.done`)
    ///   - the "Erledigt" action routes to the measurement capture deep-link
    ///     (no confirmed server completion route in the v1.17.1 contract)
    ///   - a body-tap deep-links via the server-supplied `deepLink`, falling
    ///     back to the dashboard when the push carries none
    ///   - the `measurementReminder.clientManaged` opt-in mirror persists
    @Suite("NotificationService — measurement reminder", .serialized)
    @MainActor
    struct NotificationServiceMeasurementReminderTests {
        private static let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.14.1",
            buildNumber: "1"
        )

        private func makeService(appRouter: AppRouter) -> NotificationService {
            let keychain = InMemoryKeychain()
            try? keychain.setString("token", forKey: KeychainKey.authToken)
            let api = APIClient(
                environment: Self.env,
                keychain: keychain,
                sessionConfiguration: .mock()
            )
            let deepLinks = DeepLinkRouter(router: appRouter, isAuthenticated: { true })
            return NotificationService(
                api: api,
                environment: Self.env,
                keychain: keychain,
                deepLinks: deepLinks
            )
        }

        private func payload(deepLink: URL?) -> APNsPayload {
            APNsPayload(
                title: "Vorsorge",
                body: "Blutdruck messen",
                eventType: NotificationService.categoryMeasurementReminder,
                metricType: "BLOOD_PRESSURE",
                deepLink: deepLink
            )
        }

        // MARK: - Identifier contract

        @Test("Category + action identifiers match the server-aligned contract")
        func identifiersMatchContract() {
            #expect(NotificationService.categoryMeasurementReminder == "MEASUREMENT_REMINDER")
            #expect(NotificationService.actionMeasurementDone == "measurement.done")
        }

        // MARK: - Category registration

        @Test("registerCategories installs the MEASUREMENT_REMINDER category with the Erledigt action")
        func categoryRegistersDoneAction() async throws {
            let appRouter = AppRouter()
            _ = makeService(appRouter: appRouter)
            // setNotificationCategories serialises on UNUserNotificationCenter's
            // own queue — yield briefly (mirrors the medication-action test).
            try await Task.sleep(nanoseconds: 50_000_000)
            let categories = await UNUserNotificationCenter.current().notificationCategories()
            guard let cat = categories.first(
                where: { $0.identifier == NotificationService.categoryMeasurementReminder }
            ) else {
                Issue.record("MEASUREMENT_REMINDER category not registered")
                return
            }
            #expect(cat.actions.count == 1)
            #expect(cat.actions.first?.identifier == NotificationService.actionMeasurementDone)
            // Foreground so the tap opens the app onto capture.
            #expect(cat.actions.first?.options.contains(.foreground) == true)
            #expect(cat.options.contains(.customDismissAction))
        }

        // MARK: - Erledigt action routing

        @Test("Erledigt with a server deepLink routes to that capture surface")
        func doneActionFollowsServerDeepLink() async {
            let appRouter = AppRouter()
            let svc = makeService(appRouter: appRouter)
            // Server preventive-care deep-link → the insights/capture surface.
            await svc.dispatchAction(
                actionID: NotificationService.actionMeasurementDone,
                payload: payload(deepLink: URL(string: "healthlog://insights/blood-pressure"))
            )
            // `.insights(metric:)` flips the tab to .insights (see AppRouter).
            #expect(appRouter.selectedTab == .insights)
        }

        @Test("Erledigt without a deepLink falls back to the dashboard — never dead-ends")
        func doneActionFallsBackToDashboard() async {
            let appRouter = AppRouter()
            appRouter.selectedTab = .meds
            let svc = makeService(appRouter: appRouter)
            await svc.dispatchAction(
                actionID: NotificationService.actionMeasurementDone,
                payload: payload(deepLink: nil)
            )
            // `healthlog://dashboard` → .home.
            #expect(appRouter.selectedTab == .home)
        }

        // MARK: - Body-tap routing

        @Test("Body-tap with a server deepLink deep-links to capture")
        func bodyTapFollowsServerDeepLink() async {
            let appRouter = AppRouter()
            let svc = makeService(appRouter: appRouter)
            await svc.dispatchAction(
                actionID: UNNotificationDefaultActionIdentifier,
                payload: payload(deepLink: URL(string: "healthlog://insights/blood-pressure"))
            )
            #expect(appRouter.selectedTab == .insights)
        }

        @Test("Body-tap without a deepLink falls back to the dashboard")
        func bodyTapFallsBackToDashboard() async {
            let appRouter = AppRouter()
            appRouter.selectedTab = .meds
            let svc = makeService(appRouter: appRouter)
            await svc.dispatchAction(
                actionID: UNNotificationDefaultActionIdentifier,
                payload: payload(deepLink: nil)
            )
            #expect(appRouter.selectedTab == .home)
        }

        // MARK: - clientManaged opt-in mirror persistence

        @Test("MeasurementReminderPrefStore persists the opt-in + defaults off")
        func prefStorePersists() throws {
            let suite = try #require(UserDefaults(suiteName: "test.measurementReminder.\(UUID().uuidString)"))
            // Default off when never written.
            #expect(MeasurementReminderPrefStore.clientManaged(defaults: suite) == false)
            MeasurementReminderPrefStore.setClientManaged(true, defaults: suite)
            #expect(MeasurementReminderPrefStore.clientManaged(defaults: suite) == true)
            MeasurementReminderPrefStore.setClientManaged(false, defaults: suite)
            #expect(MeasurementReminderPrefStore.clientManaged(defaults: suite) == false)
        }
    }

    // swiftlint:enable force_unwrapping
#endif

/// **W-B189 (#23)** — decode contract for the preventive-care reminder opt-in
/// block on `GET /api/auth/me/notification-prefs`. Mirrors the medication block
/// shape (forward-compat: unknown siblings ignored, missing block → nil).
@Suite("AuthNotificationPrefsPayload — measurementReminder decode")
struct AuthNotificationPrefsMeasurementReminderTests {
    @Test("decodes measurementReminder.clientManaged when present")
    func decodesClientManaged() throws {
        let json = """
        {
            "medication": { "clientManaged": false },
            "mood": { "reminderHour": 8 },
            "measurementReminder": { "clientManaged": true }
        }
        """
        let data = try #require(json.data(using: .utf8))
        let decoded = try JSONDecoder.hlDefault.decode(AuthNotificationPrefsPayload.self, from: data)
        #expect(decoded.measurementReminderClientManaged == true)
    }

    @Test("missing measurementReminder block yields nil so the local mirror is preserved")
    func missingBlockIsNil() throws {
        let json = """
        { "mood": { "reminderHour": 21 } }
        """
        let data = try #require(json.data(using: .utf8))
        let decoded = try JSONDecoder.hlDefault.decode(AuthNotificationPrefsPayload.self, from: data)
        #expect(decoded.measurementReminder == nil)
        #expect(decoded.measurementReminderClientManaged == nil)
    }
}
