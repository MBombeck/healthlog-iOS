import Foundation

/// Compile-time, client-side UI gates that are NOT operator-controlled.
///
/// Distinct from `AICapabilityGate` (server-resolved AI availability): these
/// are local product decisions baked into the build. Keep this list tiny and
/// well-documented.
enum FeatureFlags {
    // Whether the raw-heart-rate upload experiment is visible.
    //
    // Raw upload is an operator experiment with a materially larger data and
    // battery footprint than the public bucketed mode. A server connection is
    // not an authorization boundary: every paired App Store user has one.
    // Keep the control in internal developer builds until product/privacy
    // acceptance deliberately promotes it behind an authenticated server-admin
    // capability or an explicit TestFlight distribution gate.
    #if DEBUG
        static let rawHeartRateExperimentAvailable = true
    #else
        static let rawHeartRateExperimentAvailable = false
    #endif
}
