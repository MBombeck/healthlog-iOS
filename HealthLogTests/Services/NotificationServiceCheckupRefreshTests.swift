import Foundation
import Testing
#if canImport(UserNotifications) && canImport(UIKit)
    @testable import HealthLog

    // swiftlint:disable force_unwrapping

    /// **Server v1.39.2 — re-read the check-ups after their push.**
    ///
    /// Since v1.39.2 a check-up on a cycle longer than a week keeps `nextDueAt`
    /// after its reminder (a weekly one still rolls on). The app schedules no
    /// local check-up reminder and never predicts either outcome, so after a
    /// `MEASUREMENT_REMINDER` arrives or is tapped it re-reads the list. The
    /// payload shape is the server's APNs `MEASUREMENT_REMINDER` event.
    @Suite("NotificationService — check-up refresh after a push", .serialized, .mockURLSession)
    @MainActor
    struct NotificationServiceCheckupRefreshTests {
        private static let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "1.1.0",
            buildNumber: "1"
        )

        private final class Counter {
            var calls = 0
        }

        private func makeService(counter: Counter) -> NotificationService {
            let keychain = InMemoryKeychain()
            let api = APIClient(environment: Self.env, keychain: keychain, sessionConfiguration: .mock())
            let service = NotificationService(
                api: api,
                environment: Self.env,
                keychain: keychain,
                deepLinks: DeepLinkRouter(router: AppRouter(), isAuthenticated: { true }),
                medicationsRepo: nil
            )
            service.measurementReminderRefresher = { counter.calls += 1 }
            return service
        }

        private func payload(eventType: String) -> APNsPayload {
            APNsPayload(
                title: "Zahnarzt",
                body: "Zahnarzt is due.",
                eventType: eventType,
                metricType: nil,
                deepLink: URL(string: "healthlog://dashboard"),
                reminderId: "rem-dentist"
            )
        }

        @Test("tapping a check-up reminder re-reads the reminders once")
        func bodyTapRefreshes() async {
            MockURLProtocol.install { req in
                (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
            }
            let counter = Counter()
            let service = makeService(counter: counter)

            await service.dispatchAction(
                actionID: "com.apple.UNNotificationDefaultActionIdentifier",
                payload: payload(eventType: NotificationService.categoryMeasurementReminder)
            )

            #expect(counter.calls == 1)
        }

        @Test("an arriving check-up reminder re-reads; any other push does not")
        func onlyCheckupPushesRefresh() async {
            MockURLProtocol.install { req in
                (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
            }
            let counter = Counter()
            let service = makeService(counter: counter)

            await service.refreshRemindersAfterMeasurementReminder(
                payload: payload(eventType: NotificationService.categoryMeasurementReminder)
            )
            await service.refreshRemindersAfterMeasurementReminder(payload: payload(eventType: "MOOD_REMINDER"))
            await service.refreshRemindersAfterMeasurementReminder(payload: nil)

            #expect(counter.calls == 1)
        }
    }
#endif
