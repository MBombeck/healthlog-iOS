import Foundation

/// What one background wake (BGProcessing or BGAppRefresh) may do.
///
/// The medication, outbox and snapshot work of a wake never needed HealthKit,
/// yet the wakes used to be armed and run only behind the HealthKit grant. A
/// person who uses HealthLog for medications alone therefore got no wake at
/// all. The scope separates the two halves.
enum BackgroundWakeScope: Sendable, Equatable {
    /// Nobody is signed in and HealthKit was never set up: nothing to do, and
    /// no reason to ask the system for the next wake. Only when the session
    /// in memory agrees: a Keychain that could not be read once must not end
    /// the chain of wakes until the next cold start.
    case idle
    /// A signed-in person without a HealthKit setup: reminders, medication
    /// reconcile (which refreshes widgets, watch and Live Activity), mood
    /// reminder and the outbox. No HealthKit pass.
    case withoutHealthKit
    /// Everything, including the orchestrated HealthKit pass.
    case full

    /// The one rule.
    ///
    /// - Parameters:
    ///   - signedIn: a server session is active.
    ///   - healthKitAvailable: the app has a HealthKit writer on this device.
    ///   - healthKitRequested: the HealthKit sheet ran for the current account.
    ///   - sessionSaysSignedOut: the auth state in memory is signed out (not
    ///     merely unresolved yet).
    static func resolve(
        signedIn: Bool,
        healthKitAvailable: Bool,
        healthKitRequested: Bool,
        sessionSaysSignedOut: Bool = true
    ) -> BackgroundWakeScope {
        if healthKitAvailable, healthKitRequested { return .full }
        if signedIn || !sessionSaysSignedOut { return .withoutHealthKit }
        return .idle
    }

    /// Whether the wake runs the HealthKit pass.
    var runsHealthKitPass: Bool {
        self == .full
    }

    /// Whether the wake asks the system for its successor.
    var reschedules: Bool {
        self != .idle
    }
}
