// Sibling of `LogoutCompletenessTests.swift` (file_length split — pure
// movement of the LOGOUT-NOTIF + Senior-M3 cases off the main suite file).
// App-Target-only, so skipped in the SPM-library build.
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    // MARK: - LOGOUT-NOTIF — delivered/pending notifications + badge cleared

    @MainActor
    extension LogoutCompletenessTests {
        /// On-device finding: delivered notifications, pending scheduled med
        /// reminders, and the app-icon badge survive logout — PHI-adjacent
        /// (a lock-screen med reminder reveals medication use; the badge count
        /// reveals pending doses). The cascade must fire the local
        /// notification-clear seam on EVERY logout path. We assert via a spy
        /// rather than the real `UNUserNotificationCenter` (untestable in unit
        /// scope): the seam is the contract — if it fires, the wired default
        /// (`clearAllNotificationsOnLogout`) runs removeAll* + setBadgeCount(0).
        @Test("logout fires the notification-clear seam (LOGOUT-NOTIF)")
        func logoutClearsNotificationsAndBadge() async throws {
            let container = try makeContainer(
                keychain: InMemoryKeychain(),
                healthKit: MockHealthKitWriter()
            )
            // Default hook must be wired by init (on UserNotifications platforms).
            #expect(container.notificationClearOnLogoutHook != nil)

            let spy = NotificationClearSpy()
            container.notificationClearOnLogoutHook = { @MainActor in spy.calls += 1 }

            await container.performFullLocalLogout(reason: .userInitiated)

            #expect(
                spy.calls == 1,
                "performFullLocalLogout MUST fire notificationClearOnLogoutHook exactly once"
            )
        }

        /// `.tokenExpired` (401) is the network-independent path — the clear
        /// must run there too (a token can expire while offline).
        @Test("logout clears notifications on the 401 path too (LOGOUT-NOTIF)")
        func logoutClearsNotificationsOnTokenExpiry() async throws {
            let container = try makeContainer(
                keychain: InMemoryKeychain(),
                healthKit: MockHealthKitWriter()
            )
            let spy = NotificationClearSpy()
            container.notificationClearOnLogoutHook = { @MainActor in spy.calls += 1 }

            await container.performFullLocalLogout(reason: .tokenExpired)

            #expect(spy.calls == 1)
        }
    }

    /// Tiny MainActor counter for the notification-clear seam.
    @MainActor
    final class NotificationClearSpy {
        var calls = 0
    }

    // MARK: - Senior M3 — compliance-refresh Task cancelled on logout

    @MainActor
    extension LogoutCompletenessTests {
        /// The detached card-compliance refresh `Task` spawned after a
        /// `markIntakeQuick` must be cancelled + dropped on `clearOnLogout()` —
        /// otherwise a stale (previous-user) compliance value can land into the
        /// cleared store and flash for the next user on a shared device.
        @Test("clearOnLogout cancels the in-flight compliance-refresh Task (M3)")
        func clearOnLogoutCancelsComplianceRefreshTask() throws {
            let container = try makeContainer(
                keychain: InMemoryKeychain(),
                healthKit: MockHealthKitWriter()
            )
            let store = container.medicationsStore

            // Seed a long-lived task standing in for an in-flight refresh.
            store.complianceRefreshTask = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
            }
            #expect(store.complianceRefreshTask != nil)

            store.clearOnLogout()

            #expect(
                store.complianceRefreshTask == nil,
                "clearOnLogout MUST cancel + drop the compliance-refresh Task"
            )
        }
    }

#endif // !SWIFT_PACKAGE
