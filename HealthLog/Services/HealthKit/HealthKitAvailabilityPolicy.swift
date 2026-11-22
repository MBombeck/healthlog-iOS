import Foundation

/// **Which devices read Apple Health.**
///
/// The iPhone and the Duo (a `.phone`) read HealthKit and write back to it.
/// The iPad runs the app as a plain server client: it asks for no HealthKit
/// permission, shows no switch for it and registers no `healthkit-sync`
/// background task. What the iPhone reads reaches Apple Health from there; the
/// iPad shows the data the server already holds. No App Intent reads HealthKit
/// today; one that ever does must ask ``readsHealthKit`` and decline with a
/// plain sentence.
///
/// A pure value over the injected idiom, so each answer is testable without a
/// device.
public struct HealthKitAvailabilityPolicy: Sendable, Equatable {
    public let idiom: DeviceIdiom

    public init(idiom: DeviceIdiom) {
        self.idiom = idiom
    }

    /// Whether this device reads (and writes) Apple Health at all.
    public var readsHealthKit: Bool {
        idiom != .pad
    }

    /// Whether the app asks for HealthKit authorization and offers the switch.
    public var offersAuthorization: Bool {
        readsHealthKit
    }

    /// Whether the guaranteed `healthkit-sync` BGProcessingTask is registered
    /// and submitted. The frequent app-refresh wake stays: it carries reminders
    /// and the outbox, which every device needs.
    public var registersHealthKitBackgroundTask: Bool {
        readsHealthKit
    }

    /// Whether the onboarding walks the HealthKit step.
    public var onboardingIncludesHealthKitStep: Bool {
        readsHealthKit
    }
}
