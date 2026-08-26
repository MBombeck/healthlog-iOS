import Foundation

/// Compile-time, client-side UI gates that are NOT operator-controlled.
///
/// Distinct from `FeatureFlagsStore` (server-driven AI/insight surface
/// guards): these are local product decisions baked into the build. Keep
/// this list tiny and well-documented — each flag must fully restore prior
/// behaviour when flipped, so we gate (hide entry points) rather than delete
/// the underlying runtime code.
enum FeatureFlags {
    /// Whether the user may choose the local-only / standalone ("use without
    /// a server") path during onboarding, and whether standalone-related
    /// selection UI is offered.
    ///
    /// **`false` (current product stance):** a server connection is
    /// mandatory. Onboarding skips the mode-selection fork and goes straight
    /// to the server-connect path (`Welcome → ServerURL → Auth`). No
    /// "continue without server" affordance is visible anywhere.
    ///
    /// **`true` (fully reversible):** restores the v0.11 W5 behaviour — the
    /// `ModeSelectionStep` fork is shown and the user may pick the local-only
    /// standalone path.
    ///
    /// The offline / SWR / Outbox / standalone runtime (`HealthLog/Standalone/*`,
    /// `SyncModeStore`, `AuthStore.enterStandaloneMode()`, the adopt-on-pair
    /// upload) is intentionally untouched — only the user-facing ENTRY into
    /// standalone is hidden behind this single flag.
    static let standaloneModeAvailable = false

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
