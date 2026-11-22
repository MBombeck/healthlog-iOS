// Sibling of `LogoutCompletenessTests.swift` (file_length split): the push
// relay's logout case (#190, #191). App-Target-only, so skipped in the
// SPM-library build.
#if !SWIFT_PACKAGE && canImport(UserNotifications) && canImport(UIKit)

    import Foundation
    @testable import HealthLog
    import Testing

    @MainActor
    extension LogoutCompletenessTests {
        /// The push relay holds account-bound keys and the domains of the
        /// last opened `DATA_CHANGED`; the next account must not inherit
        /// either (every logout path, through `notificationClearOnLogoutHook`).
        @Test("logout resets the push relay's account state (#190)")
        func logoutResetsPushRelay() async throws {
            let container = try makeContainer(
                keychain: InMemoryKeychain(),
                healthKit: MockHealthKitWriter()
            )
            container.pushRelay.lastDataChange = RelayDataChange(domains: ["medications"])
            container.pushRelay.unverifiedTapNotice = true

            await container.performFullLocalLogout(reason: .userInitiated)

            #expect(container.pushRelay.lastDataChange == nil)
            #expect(!container.pushRelay.unverifiedTapNotice)
            #expect(!container.pushRelay.isOn)
        }
    }
#endif
