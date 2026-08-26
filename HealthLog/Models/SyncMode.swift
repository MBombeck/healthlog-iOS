import Foundation

/// Runtime sync mode of the app. Either we are paired with a HealthLog server
/// (`paired`), in which case all server-derived surfaces are live, or we run
/// fully offline on this device (`standalone`), in which case server-derived
/// tiles fall back to local-only data with a "Mit Server verbinden" CTA.
///
/// Mirrors the server-side handoff doc `22-standalone-and-server-pairing.md`.
/// Set by the onboarding flow on first install, can be flipped later via
/// Settings → "Mit Server verbinden". Persisted in UserDefaults under
/// `hl.syncMode`.
public enum SyncMode: String, Codable, Sendable, CaseIterable, Equatable {
    /// Local-only mode: HK + Outbox, no server account, no AI insights.
    case standalone
    /// Server-paired mode: full feature set, Bearer token in Keychain.
    case paired
}

/// User's initial onboarding choice. Stored in UserDefaults under
/// `hl.onboarding.mode` for analytics/debug purposes; the canonical runtime
/// signal is `SyncMode`.
public enum OnboardingMode: String, Codable, Sendable, CaseIterable, Equatable {
    /// User chose to connect to their own HealthLog server (default or custom URL).
    case server
    /// User chose local-only mode — no server, no account.
    case standalone
    /// Legacy persisted value from builds that offered an embedded demo path.
    /// It is retained only so old UserDefaults remain decodable; current UI
    /// never writes it and it grants no credential or server-address bypass.
    case demo
}
