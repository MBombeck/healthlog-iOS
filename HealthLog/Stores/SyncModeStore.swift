import Foundation
import Observation

/// Persisted runtime sync-mode store. Lives in `AppContainer` next to `AuthStore`.
///
/// **State semantics:**
/// - On first launch ever (no Keychain token, no UserDefaults key): `mode == nil`.
///   `OnboardingFlow.ModeSelectionStep` writes the user's choice.
/// - On every subsequent launch the stored value is loaded synchronously in `init`.
/// - Existing v0.4.0 upgraders are detected by `AuthStore.bootstrap`: if the
///   Keychain has a token but `mode == nil`, the bootstrap defaults to `.paired`
///   (covered in `AuthStore.bootstrap` — they were already pre-onboarding paired).
///
/// **Why UserDefaults, not Keychain:** the sync-mode is a UI-routing decision, not
/// a secret. Bundle-ID-scoped UserDefaults is per-install; no iCloud sync (the
/// `.suite(named:)` overload is not used). Keychain is reserved for credentials.
@MainActor
@Observable
public final class SyncModeStore {
    /// Canonical UserDefaults key. Public to allow Test seeding (Mocks layer
    /// writes the value before the store inits). `nonisolated` so the standalone
    /// read-union gate (`AppContainer.makeStandaloneGate`) can read the persisted
    /// mode from a `@Sendable` closure off the main actor (v0.11 W2).
    public nonisolated static let storageKey = "hl.syncMode"
    /// Onboarding-choice key — separate so we can keep the historical choice
    /// alongside the current runtime mode (analytics + debug).
    public static let onboardingModeKey = "hl.onboarding.mode"

    public private(set) var mode: SyncMode?
    public private(set) var onboardingMode: OnboardingMode?

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let raw = defaults.string(forKey: Self.storageKey),
           let parsed = SyncMode(rawValue: raw)
        {
            mode = parsed
        }
        if let raw = defaults.string(forKey: Self.onboardingModeKey),
           let parsed = OnboardingMode(rawValue: raw)
        {
            onboardingMode = parsed
        }
    }

    /// Onboarding-mode choice — also derives a default `SyncMode`.
    public func setOnboardingChoice(_ choice: OnboardingMode) {
        onboardingMode = choice
        defaults.set(choice.rawValue, forKey: Self.onboardingModeKey)
        // Derive the runtime mode. `.demo` is a decode-only legacy value from
        // old builds; treating it as paired preserves existing sessions but
        // does not provide a server address or credential.
        switch choice {
        case .server, .demo:
            setMode(.paired)
        case .standalone:
            setMode(.standalone)
        }
    }

    /// Direct mode setter. Used by `AuthStore.bootstrap` (existing v0.4.0
    /// upgraders → `.paired` from token presence) and by "Mit Server verbinden"
    /// in Settings (standalone → paired flip).
    public func setMode(_ newMode: SyncMode) {
        mode = newMode
        defaults.set(newMode.rawValue, forKey: Self.storageKey)
    }

    /// Reset both keys — invoked on logout from a paired session so the user
    /// re-enters the onboarding picker on next launch (vs being silently
    /// re-paired against the previous server). Note: AuthStore-driven logout
    /// already wipes the Keychain token; this just clears the soft prefs.
    public func clearOnLogout() {
        // Intentionally only clear runtime mode — keep `onboardingMode` so
        // analytics can still reflect the user's historical choice. The bootstrap
        // flow re-derives mode from token presence on next launch.
        mode = nil
        defaults.removeObject(forKey: Self.storageKey)
    }

    /// True iff the app is running fully local (no server token expected).
    public var isStandalone: Bool {
        mode == .standalone
    }

    /// True iff the app should surface server-derived features.
    public var isPaired: Bool {
        mode == .paired
    }
}
