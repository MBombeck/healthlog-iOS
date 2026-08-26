import Foundation

/// **Phase 09 / plan 09-03 — the configured server, as a value.**
///
/// The audited render surfaces (onboarding auth, Settings → About, Settings →
/// Server, Settings → Security) all needed the same thing from the same place:
/// *which server is this install pointed at?* Each asked the Keychain for it,
/// and each asked from inside a SwiftUI `body`. One `AppEnvironment.resolve`
/// costs up to two `SecItemCopyMatching` round-trips, `SettingsServerScreen`
/// asked three times per evaluation, and SwiftUI evaluates a body as often as
/// it likes — so a scroll or a keystroke turned into a burst of synchronous
/// Keychain queries on the main thread.
///
/// This type is the answer resolved **once**, at an explicit boundary, and
/// rendered from as a plain in-memory value. Every derivation below is pure:
/// given the same `baseURL` it returns the same answer without touching the
/// Keychain, the file system or the network.
///
/// **The Keychain stays the source of truth.** Nothing here caches a secret and
/// nothing here persists. The snapshot carries one URL — the same URL the
/// `APIClient` already routes every request against — and it is re-derived at
/// the two boundaries that can change it (``AppContainer/reloadEnvironment()``,
/// called by onboarding's `ServerURLStep` and by `AppContainer.switchServer`).
struct ConfiguredServerSnapshot: Sendable, Equatable {
    /// The effective server address, or `nil` while no server is configured.
    let baseURL: URL?

    /// No server configured and no bundle default — every link below is `nil`,
    /// which is the honest answer: there is no instance whose policy or account
    /// surface we could point at.
    static let unconfigured = ConfiguredServerSnapshot(baseURL: nil)

    /// The bundle-only answer, for the surfaces that render without a container
    /// (SwiftUI previews, and the `nil`-container branch the four screens keep).
    ///
    /// `Bundle.infoDictionary` is an in-process dictionary rather than a
    /// Keychain query, and it cannot change while the process lives — so it is
    /// resolved once here instead of on every body evaluation.
    static let bundleFallback = ConfiguredServerSnapshot(baseURL: AppEnvironment.loadFromBundle().baseURL)

    /// Resolve from the Keychain. This is the *boundary* form — it performs the
    /// Keychain read that the render paths must not. Retained as the pure,
    /// injectable helper the existing link tests drive.
    static func resolve(keychain: KeychainStoring?) -> ConfiguredServerSnapshot {
        guard let keychain else { return bundleFallback }
        return ConfiguredServerSnapshot(
            baseURL: AppEnvironment.currentBaseURL(keychain: keychain) ?? bundleFallback.baseURL
        )
    }

    /// The host shown on Settings → Server.
    var host: String? {
        baseURL?.host
    }

    /// `nil` while no server is configured — the screen prints an em dash then,
    /// rather than inventing a region for an address that does not exist.
    var region: AppEnvironment.ServerRegion? {
        baseURL.map { AppEnvironment.inferRegion(for: $0) }
    }

    /// `<base>/privacy` — a real server route, so a self-hoster reads *their*
    /// instance's policy rather than somebody else's.
    var privacyPolicyURL: URL? {
        baseURL?.appendingPathComponent("privacy")
    }

    /// `<base>/settings/security` — the one browser destination of this area.
    var accountSecurityURL: URL? {
        baseURL?
            .appendingPathComponent("settings")
            .appendingPathComponent("security")
    }

    /// Does this build carry a `webcredentials:` association for the configured
    /// host? Pure: reads the build's own Info.plist mirror, never the Keychain.
    var supportsPasskeys: Bool {
        AppEnvironment.supportsPasskeys(host: host)
    }

    /// #65 — should sign-in hand off to the browser? Self-hosted **and** not
    /// covered by this build's associated domains.
    var prefersWebHandoff: Bool {
        guard let baseURL else { return false }
        guard AppEnvironment.inferRegion(for: baseURL) == .selfHosted else { return false }
        return !AppEnvironment.supportsPasskeys(host: baseURL.host)
    }
}

extension AppContainer {
    /// **The configured-server value the audited render paths read.**
    ///
    /// `environment` is resolved from the Keychain exactly once per environment
    /// revision — at composition (`HealthLogApp.init` calls
    /// `AppEnvironment.resolve`) and again in ``reloadEnvironment()``, which is
    /// the only thing either write path does after persisting a new address:
    /// onboarding's `ServerURLStep` (line for line, `setCustomBaseURL` then
    /// `reloadEnvironment`) and `AppContainer.switchServer`.
    ///
    /// So this is a stored-property read, and the render paths inherit the
    /// freshness of the same value the `APIClient` routes every request against.
    /// There is no second idea of "the server" that could drift from the one the
    /// requests use — which the previous shape, a parallel Keychain resolve per
    /// body evaluation, could.
    var configuredServer: ConfiguredServerSnapshot {
        ConfiguredServerSnapshot(baseURL: environment.baseURL)
    }
}
