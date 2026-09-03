#if canImport(UIKit)
    @testable import HealthLog
    import Testing
    import UIKit
    import UserNotifications

    /// Runtime pin: after the hosted app finished launching, the app's
    /// `NotificationService` must own `UNUserNotificationCenter.current().delegate`.
    ///
    /// Spezi installs its own `SpeziNotificationCenterDelegate` in
    /// `SpeziAppDelegate.application(_:willFinishLaunchingWithOptions:)` whenever
    /// a configured module conforms to `NotificationHandler` — `SchedulerNotifications`
    /// does — and that call runs AFTER `AppContainer.init` installed ours. With
    /// Spezi's delegate in charge every banner action ("Taken", "Skipped",
    /// snooze, mood, measurement "Done") is a silent no-op, because no Spezi
    /// module implements `handleNotificationAction`.
    @MainActor
    @Suite("Notification-center delegate ownership")
    struct NotificationDelegateOwnershipProbeTests {
        @Test("UNUserNotificationCenter delegate is the app's NotificationService")
        func delegateIsNotificationService() {
            let delegate = UNUserNotificationCenter.current().delegate
            let typeName = delegate.map { String(reflecting: type(of: $0)) } ?? "nil"
            #expect(delegate is NotificationService, "delegate is \(typeName)")
        }
    }
#endif
