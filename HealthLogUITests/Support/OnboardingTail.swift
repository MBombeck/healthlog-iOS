import UIKit
import XCTest

/// The post-authentication setup steps, as the device owes them. The pad has
/// no HealthKit (`HealthKitAvailabilityPolicy`), so its route starts at the
/// notifications step; the phone starts at the HealthKit step. Release UI
/// cases walk the route through this one list instead of assuming a phone.
@MainActor
enum OnboardingTail {
    /// Whether this device is offered the HealthKit step.
    static var offersHealthKitStep: Bool {
        UIDevice.current.userInterfaceIdiom != .pad
    }

    /// The skip button of the first step this device owes.
    static var firstSkip: String {
        offersHealthKitStep ? "onboarding.healthKit.skip" : "onboarding.notifications.skip"
    }

    /// `identifiers` without the HealthKit step where the device has none.
    static func owed(_ identifiers: [String]) -> [String] {
        offersHealthKitStep ? identifiers : identifiers.filter { $0 != "onboarding.healthKit.skip" }
    }
}
