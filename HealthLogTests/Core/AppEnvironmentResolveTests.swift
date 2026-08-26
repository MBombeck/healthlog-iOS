import CryptoKit
import Foundation
@testable import HealthLog
import Testing

/// Locks the v0.4.1 server-URL-override mechanism. Before this change
/// `AppEnvironment.baseURL` was `let`-immutable + the `ServerAuthStep`
/// "Eigenen Server verwenden" disclosure was a dead control. The override
/// flow now: ServerURLStep validates → writes Keychain → AppContainer
/// re-resolves → APIClient picks up the new base.
@Suite("AppEnvironment override + validation", .serialized)
struct AppEnvironmentResolveTests {
    @Test("resolve falls back to bundle when Keychain has no override")
    func resolveBundleFallback() {
        let kc = InMemoryKeychain()
        let env = AppEnvironment.resolve(keychain: kc)
        // Kein Default-Server mehr: ohne Keychain-Eintrag gilt, was das
        // Bundle sagt — und das eingecheckte `project.yml` setzt `HLBaseURL`
        // nicht, also `nil`. Der Vertrag bleibt "entspricht loadFromBundle()".
        let bundleEnv = AppEnvironment.loadFromBundle()
        #expect(env.baseURL == bundleEnv.baseURL)
    }

    /// Der neue Vertrag in einem Satz: die App bringt keinen Server mit.
    /// Ohne `HLBaseURL` im Bundle und ohne Keychain-Eintrag ist `baseURL`
    /// `nil` — keine leere, keine erfundene URL.
    @Test("Ohne Konfiguration gibt es keine Serveradresse — nil, kein Platzhalter")
    func unconfiguredIsNil() {
        let empty = Bundle(for: BundleAnchor.self)
        let env = AppEnvironment.loadFromBundle(empty)
        #expect(env.baseURL == nil)
        #expect(env.isServerConfigured == false)
        // Die App-Metadaten gelten unabhaengig vom Server und bleiben gefuellt.
        #expect(!env.appVersion.isEmpty)
        #expect(!env.buildNumber.isEmpty)
    }

    @Test("resolve meldet nicht konfiguriert, wenn weder Keychain noch Bundle eine Adresse hat")
    func resolveUnconfigured() {
        let kc = InMemoryKeychain()
        let env = AppEnvironment.resolve(keychain: kc, bundle: Bundle(for: BundleAnchor.self))
        #expect(env.baseURL == nil)
        #expect(env.isServerConfigured == false)
    }

    @Test("resolve picks up Keychain override when present")
    func resolveOverrideTakesPrecedence() throws {
        let kc = InMemoryKeychain()
        try kc.setString("https://meinserver.example.com", forKey: KeychainKey.serverURL)
        let env = AppEnvironment.resolve(keychain: kc)
        #expect(env.baseURL?.absoluteString == "https://meinserver.example.com")
    }

    @Test("resolve retires a fingerprinted legacy host without naming it in source")
    func resolveRetiresFingerprint() throws {
        let kc = InMemoryKeychain()
        let legacyHost = "retired.example"
        try kc.setString("https://\(legacyHost)", forKey: KeychainKey.serverURL)
        let fingerprint = SHA256.hash(data: Data(legacyHost.utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        let env = AppEnvironment.resolve(
            keychain: kc,
            bundle: Bundle(for: BundleAnchor.self),
            retiredServerHostFingerprints: [fingerprint]
        )

        #expect(env.baseURL == nil)
        #expect(kc.getString(forKey: KeychainKey.serverURL) == nil)
    }

    @Test("fresh explicit confirmation overrides legacy-host retirement")
    func explicitConfirmationPreservesFingerprint() throws {
        let kc = InMemoryKeychain()
        let confirmedHost = "retired.example"
        let confirmedURL = try #require(URL(string: "https://\(confirmedHost)"))
        let fingerprint = SHA256.hash(data: Data(confirmedHost.utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        // Mirrors ServerURLStep after its reachability + trust-boundary UI:
        // explicit user confirmation persists the URL immediately before the
        // AppContainer reload resolves it into the live environment.
        try AppEnvironment.setCustomBaseURL(confirmedURL, keychain: kc)
        let env = AppEnvironment.resolve(
            keychain: kc,
            bundle: Bundle(for: BundleAnchor.self),
            retiredServerHostFingerprints: [fingerprint]
        )

        #expect(env.baseURL == confirmedURL)
        #expect(kc.getString(forKey: KeychainKey.serverURL) == confirmedURL.absoluteString)
    }

    @Test("mismatched confirmation cannot bypass legacy-host retirement")
    func mismatchedConfirmationStillRetiresFingerprint() throws {
        let kc = InMemoryKeychain()
        let legacyHost = "retired.example"
        try kc.setString("https://\(legacyHost)", forKey: KeychainKey.serverURL)
        try kc.setString("unrelated-fingerprint", forKey: KeychainKey.serverURLExplicitHostFingerprint)
        let fingerprint = SHA256.hash(data: Data(legacyHost.utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        let env = AppEnvironment.resolve(
            keychain: kc,
            bundle: Bundle(for: BundleAnchor.self),
            retiredServerHostFingerprints: [fingerprint]
        )

        #expect(env.baseURL == nil)
        #expect(kc.getString(forKey: KeychainKey.serverURL) == nil)
        #expect(kc.getString(forKey: KeychainKey.serverURLExplicitHostFingerprint) == nil)
    }

    @Test("resolve ignores malformed Keychain override + falls back")
    func resolveIgnoresMalformed() throws {
        let kc = InMemoryKeychain()
        try kc.setString("not a url at all", forKey: KeychainKey.serverURL)
        let env = AppEnvironment.resolve(keychain: kc)
        let bundleEnv = AppEnvironment.loadFromBundle()
        // "not a url at all" trims to non-empty, but URL(string:) returns a
        // schemeless URL with nil host → resolve must fall back. The exact
        // failure shape doesn't matter; the host check is the guard.
        #expect(env.baseURL == bundleEnv.baseURL)
    }

    @Test("resolve ignores empty / whitespace override")
    func resolveIgnoresEmpty() throws {
        let kc = InMemoryKeychain()
        try kc.setString("   ", forKey: KeychainKey.serverURL)
        let env = AppEnvironment.resolve(keychain: kc)
        let bundleEnv = AppEnvironment.loadFromBundle()
        #expect(env.baseURL == bundleEnv.baseURL)
    }

    @Test("setCustomBaseURL persists + clears")
    func setCustomURLPersistsClears() throws {
        let kc = InMemoryKeychain()
        let url = try #require(URL(string: "https://acme.example.org"))
        try AppEnvironment.setCustomBaseURL(url, keychain: kc)
        #expect(kc.getString(forKey: KeychainKey.serverURL) == "https://acme.example.org")
        #expect(kc.getString(forKey: KeychainKey.serverURLExplicitHostFingerprint) != nil)
        try AppEnvironment.setCustomBaseURL(nil, keychain: kc)
        #expect(kc.getString(forKey: KeychainKey.serverURL) == nil)
        #expect(kc.getString(forKey: KeychainKey.serverURLExplicitHostFingerprint) == nil)
    }

    @Test("failed provenance write clears the URL and marker")
    func provenanceWriteFailureIsFailClosed() throws {
        let kc = FaultInjectingKeychain(failingSetKey: KeychainKey.serverURLExplicitHostFingerprint)
        let url = try #require(URL(string: "https://retired.example"))

        #expect(throws: KeychainError.self) {
            try AppEnvironment.setCustomBaseURL(url, keychain: kc)
        }
        #expect(kc.getString(forKey: KeychainKey.serverURL) == nil)
        #expect(kc.getString(forKey: KeychainKey.serverURLExplicitHostFingerprint) == nil)
    }

    @Test("failed URL teardown removes provenance so retirement stays fail closed")
    func urlTeardownFailureRemovesProvenance() throws {
        let kc = FaultInjectingKeychain(failingRemoveKey: KeychainKey.serverURL)
        let host = "retired.example"
        let url = try #require(URL(string: "https://\(host)"))
        try AppEnvironment.setCustomBaseURL(url, keychain: kc)

        #expect(throws: KeychainError.self) {
            try AppEnvironment.setCustomBaseURL(nil, keychain: kc)
        }
        #expect(kc.getString(forKey: KeychainKey.serverURL) == url.absoluteString)
        #expect(kc.getString(forKey: KeychainKey.serverURLExplicitHostFingerprint) == nil)

        let fingerprint = SHA256.hash(data: Data(host.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let env = AppEnvironment.resolve(
            keychain: kc,
            bundle: Bundle(for: BundleAnchor.self),
            retiredServerHostFingerprints: [fingerprint]
        )
        #expect(env.baseURL == nil)
    }

    // MARK: - Validation

    @Test("validate empty string throws .empty")
    func validateEmpty() {
        #expect(throws: AppEnvironment.URLValidationError.self) {
            try AppEnvironment.validate(serverURLString: "")
        }
        #expect(throws: AppEnvironment.URLValidationError.self) {
            try AppEnvironment.validate(serverURLString: "   ")
        }
    }

    @Test("validate auto-prepends https:// when no scheme present")
    func validateAutoPrependsHttps() throws {
        let url = try AppEnvironment.validate(serverURLString: "meinserver.example.com")
        #expect(url.scheme == "https")
        #expect(url.host == "meinserver.example.com")
    }

    @Test("validate keeps existing https://")
    func validateKeepsHttps() throws {
        let url = try AppEnvironment.validate(serverURLString: "https://acme.example.org")
        #expect(url.absoluteString == "https://acme.example.org")
    }

    @Test("validate rejects URLs with missing host")
    func validateMissingHost() {
        #expect(throws: AppEnvironment.URLValidationError.self) {
            // `https://` alone parses as a URL but has nil host.
            try AppEnvironment.validate(serverURLString: "https://")
        }
    }

    #if !DEBUG
        @Test("validate rejects http:// in release builds")
        func validateRejectsHttpInRelease() {
            #expect(throws: AppEnvironment.URLValidationError.self) {
                try AppEnvironment.validate(serverURLString: "http://acme.example.org")
            }
        }
    #endif

    #if DEBUG
        @Test("validate accepts http:// in DEBUG (local-dev convenience)")
        func validateAllowsHttpInDebug() throws {
            let url = try AppEnvironment.validate(serverURLString: "http://localhost:3000")
            #expect(url.scheme == "http")
            #expect(url.host == "localhost")
        }
    #endif

    // MARK: - currentBaseURL convenience

    /// v0.5.5.2 W-IMPL-SERVER-EDITOR — Settings → Server reads the
    /// effective host through this accessor. Round-trips through the
    /// Keychain overlay so the user sees the same URL the next request
    /// will hit.
    @Test("currentBaseURL round-trips through Keychain override")
    func currentBaseURLRoundTrip() throws {
        let kc = InMemoryKeychain()
        try kc.setString("https://meinserver.example.com", forKey: KeychainKey.serverURL)
        let url = AppEnvironment.currentBaseURL(keychain: kc)
        #expect(url?.absoluteString == "https://meinserver.example.com")
    }

    @Test("currentBaseURL falls back to bundle when override absent")
    func currentBaseURLBundleFallback() {
        let kc = InMemoryKeychain()
        let url = AppEnvironment.currentBaseURL(keychain: kc)
        #expect(url == AppEnvironment.loadFromBundle().baseURL)
    }

    // MARK: - Region inference

    @Test("inferRegion identifies demo backend")
    func inferRegionDemo() throws {
        let demo = try #require(URL(string: "https://demo.healthlog.dev"))
        #expect(AppEnvironment.inferRegion(for: demo) == .demo)
    }

    @Test("inferRegion treats every other host as self-hosted")
    func inferRegionSelfHosted() throws {
        let other = try #require(URL(string: "https://meinserver.example.com"))
        #expect(AppEnvironment.inferRegion(for: other) == .selfHosted)
    }

    // MARK: - Passkey-Faehigkeit (loest die alte Host-Namen-Schranke ab, GH #65)

    /// Die Schranke fragt, ob DIESES Build eine `webcredentials:`-Domain fuer
    /// den Host mitbringt — nicht, wie der Host heisst. Ohne Association
    /// gibt es ehrlich keine Passkeys.
    @Test("Ohne Relying-Party-Domain sind Passkeys fuer jeden Host aus")
    func passkeysOffWithoutAssociation() {
        #expect(AppEnvironment.supportsPasskeys(host: "healthlog.example.com", relyingPartyHosts: []) == false)
        #expect(AppEnvironment.supportsPasskeys(host: nil, relyingPartyHosts: ["healthlog.example.com"]) == false)
    }

    /// Der Kern von #65: ein Selbst-Hoster, der sein Build mit der eigenen
    /// Domain baut, bekommt die Schaltflaeche — frueher nie.
    @Test("Exakt gedeckter Host schaltet Passkeys frei, fremde Hosts nicht")
    func passkeysExactHostMatch() {
        let rps = ["healthlog.example.com"]
        #expect(AppEnvironment.supportsPasskeys(host: "healthlog.example.com", relyingPartyHosts: rps))
        #expect(AppEnvironment.supportsPasskeys(host: "HEALTHLOG.EXAMPLE.COM", relyingPartyHosts: rps))
        #expect(AppEnvironment.supportsPasskeys(host: "example.com", relyingPartyHosts: rps) == false)
        #expect(AppEnvironment.supportsPasskeys(host: "evil-healthlog.example.com", relyingPartyHosts: rps) == false)
    }

    @Test("Wildcard deckt Subdomains, aber weder Apex noch Label-Nachbarn")
    func passkeysWildcard() {
        let rps = ["*.example.com"]
        #expect(AppEnvironment.supportsPasskeys(host: "healthlog.example.com", relyingPartyHosts: rps))
        #expect(AppEnvironment.supportsPasskeys(host: "example.com", relyingPartyHosts: rps) == false)
        #expect(AppEnvironment.supportsPasskeys(host: "evilexample.com", relyingPartyHosts: rps) == false)
    }
}

/// Anker, um an ein Bundle OHNE `HLBaseURL` zu kommen: das Test-Bundle selbst
/// setzt den Schluessel nicht, also ist es der ehrliche "nicht eingerichtet"-Fall.
private final class BundleAnchor {}

private final class FaultInjectingKeychain: KeychainStoring, @unchecked Sendable {
    private var store: [String: Data] = [:]
    private let lock = NSLock()
    private let failingSetKey: String?
    private let failingRemoveKey: String?

    init(failingSetKey: String? = nil, failingRemoveKey: String? = nil) {
        self.failingSetKey = failingSetKey
        self.failingRemoveKey = failingRemoveKey
    }

    func setString(_ value: String, forKey key: String) throws {
        if key == failingSetKey { throw KeychainError.encoding }
        try setData(Data(value.utf8), forKey: key)
    }

    func getString(forKey key: String) -> String? {
        getData(forKey: key).flatMap { String(data: $0, encoding: .utf8) }
    }

    func setData(_ data: Data, forKey key: String) throws {
        lock.withLock { store[key] = data }
    }

    func getData(forKey key: String) -> Data? {
        lock.withLock { store[key] }
    }

    func remove(forKey key: String) throws {
        if key == failingRemoveKey { throw KeychainError.encoding }
        lock.withLock { _ = store.removeValue(forKey: key) }
    }

    func removeAll() throws {
        lock.withLock { store.removeAll() }
    }
}
