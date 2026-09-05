import Foundation
import Testing
#if canImport(UserNotifications) && canImport(UIKit)
    @testable import HealthLog
    import UserNotifications

    /// Build 274 (public #3) — four TestFlight crashes on iOS 26/27: opening the
    /// app from a medication reminder aborted inside UIKit's completion of
    /// `userNotificationCenter(_:didReceive:)` (`_performBlockAfterCATransactionCommitSynchronizes:`
    /// assertion, on a concurrency worker thread). Both delegate methods were
    /// `nonisolated async`; the compiler-synthesised ObjC thunk then invoked UIKit's
    /// completion handler on whatever executor the Task ended on — never the main
    /// thread. The methods are main-actor isolated now, so the completion lands on
    /// the main thread. Two pins: the ObjC entry point at runtime, and the source.
    @Suite("Notification delegate — completion on the main thread", .serialized)
    @MainActor
    struct NotificationDelegateMainThreadCompletionTests {
        private static let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "1.0.0",
            buildNumber: "274"
        )

        private func makeService() -> NotificationService {
            let keychain = InMemoryKeychain()
            let api = APIClient(environment: Self.env, keychain: keychain, sessionConfiguration: .mock())
            let deepLinks = DeepLinkRouter(router: AppRouter(), isAuthenticated: { true })
            return NotificationService(
                api: api,
                environment: Self.env,
                keychain: keychain,
                deepLinks: deepLinks,
                medicationsRepo: nil
            )
        }

        // MARK: - Building a response with public API only

        /// Encodes exactly the keys `UNNotification` decodes, archived under
        /// UNNotification's class name (`NSKeyedArchiver.setClassName(_:for:)`).
        @objc(HLB274NotificationShape)
        private final class NotificationShape: NSObject, NSSecureCoding {
            static var supportsSecureCoding: Bool {
                true
            }

            let request: UNNotificationRequest
            let date: Date
            init(request: UNNotificationRequest, date: Date) {
                self.request = request
                self.date = date
            }

            required init?(coder _: NSCoder) {
                nil
            }

            func encode(with coder: NSCoder) {
                coder.encode(request, forKey: "request")
                coder.encode(date, forKey: "date")
            }
        }

        @objc(HLB274ResponseShape)
        private final class ResponseShape: NSObject, NSSecureCoding {
            static var supportsSecureCoding: Bool {
                true
            }

            let notification: UNNotification
            let actionIdentifier: String
            init(notification: UNNotification, actionIdentifier: String) {
                self.notification = notification
                self.actionIdentifier = actionIdentifier
            }

            required init?(coder _: NSCoder) {
                nil
            }

            func encode(with coder: NSCoder) {
                coder.encode(notification, forKey: "notification")
                coder.encode(actionIdentifier, forKey: "actionIdentifier")
            }
        }

        private static func archive(_ object: NSObject & NSSecureCoding, as cls: AnyClass) -> Data {
            let archiver = NSKeyedArchiver(requiringSecureCoding: true)
            archiver.setClassName(NSStringFromClass(cls), for: type(of: object))
            archiver.encode(object, forKey: NSKeyedArchiveRootObjectKey)
            archiver.finishEncoding()
            return archiver.encodedData
        }

        /// A default-action tap on a medication reminder, the exact shape the
        /// four crash reports describe.
        static func makeReminderResponse() throws -> UNNotificationResponse {
            let content = UNMutableNotificationContent()
            content.title = "Reminder"
            content.userInfo = ["eventType": "MEDICATION_REMINDER"]
            let request = UNNotificationRequest(identifier: "b274-reminder", content: content, trigger: nil)
            let notification = try #require(
                try NSKeyedUnarchiver.unarchivedObject(
                    ofClass: UNNotification.self,
                    from: archive(NotificationShape(request: request, date: Date()), as: UNNotification.self)
                )
            )
            return try #require(
                try NSKeyedUnarchiver.unarchivedObject(
                    ofClass: UNNotificationResponse.self,
                    from: archive(
                        ResponseShape(notification: notification, actionIdentifier: UNNotificationDefaultActionIdentifier),
                        as: UNNotificationResponse.self
                    )
                )
            )
        }

        // MARK: - Pins

        @Test("the ObjC completion handler of didReceive runs on the main thread")
        func didReceiveCompletesOnMain() async throws {
            // Build 274 (public #3) — `NotificationService.init` claims the center's
            // (weak) delegate, but the host app's service owns it and
            // `NotificationDelegateOwnershipProbeTests` pins that; hand it back so this
            // suite's throwaway service does not leave the center delegate-less for the
            // suites that sort after it.
            let previousDelegate = UNUserNotificationCenter.current().delegate
            defer { UNUserNotificationCenter.current().delegate = previousDelegate }
            let service = makeService()
            let response = try Self.makeReminderResponse()
            #expect(response.notification.request.identifier == "b274-reminder")
            let delegate: any UNUserNotificationCenterDelegate = service
            let onMain = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                delegate.userNotificationCenter?(UNUserNotificationCenter.current(), didReceive: response) {
                    continuation.resume(returning: Thread.isMainThread)
                }
            }
            #expect(onMain, "UIKit's completion must be invoked on the main thread (iOS 26 asserts it)")
        }

        @Test("the ObjC completion handler of willPresent runs on the main thread")
        func willPresentCompletesOnMain() async throws {
            // Build 274 (public #3) — same delegate hand-back as above.
            let previousDelegate = UNUserNotificationCenter.current().delegate
            defer { UNUserNotificationCenter.current().delegate = previousDelegate }
            let service = makeService()
            let response = try Self.makeReminderResponse()
            let delegate: any UNUserNotificationCenterDelegate = service
            let onMain = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                delegate.userNotificationCenter?(UNUserNotificationCenter.current(), willPresent: response.notification) { _ in
                    continuation.resume(returning: Thread.isMainThread)
                }
            }
            #expect(onMain)
        }

        /// The structural pin: neither delegate method may opt out of the main
        /// actor again, on any simulator OS — including one that does not assert.
        @Test("neither delegate method is declared nonisolated")
        func delegateMethodsAreMainActorIsolated() throws {
            let file = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent() // Services
                .deletingLastPathComponent() // HealthLogTests
                .deletingLastPathComponent() // repo root
                .appendingPathComponent("HealthLog/Services/NotificationService+Handler.swift")
            let source = try String(contentsOf: file, encoding: .utf8)
            let declarations = source
                .components(separatedBy: "\n")
                .filter { $0.contains("func userNotificationCenter(") }
            #expect(declarations.count == 2, "expected exactly the willPresent and didReceive witnesses")
            for declaration in declarations {
                #expect(
                    !declaration.contains("nonisolated"),
                    Comment(rawValue: declaration.trimmingCharacters(in: .whitespaces))
                )
            }
        }
    }
#endif
