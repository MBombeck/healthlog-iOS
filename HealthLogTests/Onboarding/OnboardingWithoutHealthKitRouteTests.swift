import Foundation
@testable import HealthLog
import Testing

/// The iPad reads no HealthKit, so its onboarding walks no HealthKit step. The
/// route is a pure value; these pin it for both devices.
@Suite("Onboarding: the route without the HealthKit step")
struct OnboardingWithoutHealthKitRouteTests {
    @Test("the default route is unchanged for a device that reads HealthKit")
    func phoneRouteUnchanged() {
        let route = OnboardingFlow.activeRoute()
        #expect(route == OnboardingFlow.activeRoute(includesHealthKit: true))
        #expect(route.contains(.healthKit))
        #expect(route == [.welcome, .serverURL, .auth, .healthKit, .notifications, .aiSource, .anamnesis, .baselineProfile])
    }

    @Test("the pad route has no HealthKit step and starts behind the login with notifications")
    func padRoute() {
        let route = OnboardingFlow.activeRoute(includesHealthKit: false)
        #expect(!route.contains(.healthKit))
        #expect(route == [.welcome, .serverURL, .auth, .notifications, .aiSource, .anamnesis, .baselineProfile])
        #expect(OnboardingFlow.firstPostAuthenticationStep(includesHealthKit: false) == .notifications)
        #expect(OnboardingFlow.firstPostAuthenticationStep(includesHealthKit: true) == .healthKit)
    }

    @Test("a device-local-only run on a pad is the notifications step alone")
    func padDeviceLocalRun() {
        #expect(OnboardingFlow.activeRoute(setupScope: .deviceLocalOnly, includesHealthKit: false) == [.notifications])
        #expect(OnboardingFlow.activeRoute(setupScope: .deviceLocalOnly, includesHealthKit: true) == [.healthKit, .notifications])
    }

    @Test("back never crosses the login: on a pad that boundary is the notifications step")
    func padBoundary() {
        #expect(OnboardingFlow.previousStep(from: .notifications, includesHealthKit: false) == nil)
        #expect(OnboardingFlow.previousStep(from: .notifications, includesHealthKit: true) == .healthKit)
        #expect(OnboardingFlow.previousStep(from: .aiSource, includesHealthKit: false) == .notifications)
        #expect(OnboardingFlow.previousStep(from: .healthKit, includesHealthKit: true) == nil)
    }

    @Test("progress counts only the steps the device walks")
    func padProgress() {
        let phone = OnboardingFlow.progress(for: .notifications)
        let pad = OnboardingFlow.progress(for: .notifications, includesHealthKit: false)
        #expect(phone.total == 8)
        #expect(pad.total == 7)
        #expect(phone.position == 5)
        #expect(pad.position == 4)
    }

    @Test("a pad owes the notification permission, read from the system: not determined means open")
    func padSetupFollowsNotificationPermission() {
        func state(_ open: Bool?) -> DeviceLocalSetupState {
            OnboardingFlow.deviceLocalSetupState(
                includesHealthKit: false, healthKitRequested: nil, notificationPermissionOpen: open
            )
        }
        #expect(state(true) == .outstanding)
        #expect(state(false) == .complete)
        #expect(state(nil) == .unknown)
        // A phone still answers from the HealthKit sheet, as before.
        #expect(OnboardingFlow.deviceLocalSetupState(
            includesHealthKit: true, healthKitRequested: true, notificationPermissionOpen: true
        ) == .complete)
        #expect(OnboardingFlow.deviceLocalSetupState(
            includesHealthKit: true, healthKitRequested: false, notificationPermissionOpen: nil
        ) == .outstanding)
        #expect(OnboardingFlow.deviceLocalSetupState(
            includesHealthKit: true, healthKitRequested: nil, notificationPermissionOpen: nil
        ) == .unknown)
        // A finished account on a pad with the permission open walks the notification step alone.
        let scope = PostAuthenticationRouteResolver.setupScope(accountSetupComplete: true, deviceLocalSetup: state(true))
        #expect(scope == .deviceLocalOnly)
        #expect(OnboardingFlow.activeRoute(setupScope: scope, includesHealthKit: false) == [.notifications])
    }
}
