import CryptoKit
import Foundation

public struct AppEnvironment: Sendable {
    /// Adresse des HealthLog-Servers — oder `nil`, wenn **keiner eingerichtet
    /// ist**.
    ///
    /// Die App bringt bewusst keinen eingebauten Server mit: es gibt keinen
    /// Default-Host, keine Vorbelegung und keinen Rückfall. Wer die App
    /// startet, trägt im Onboarding (`ServerURLStep`) die Adresse der eigenen
    /// Instanz ein; bis dahin — und dauerhaft im Standalone-Modus, der ohne
    /// Server läuft — ist dieser Wert `nil`.
    ///
    /// `nil` ist damit ein legitimer Dauerzustand, kein Fehler. Der Typ macht
    /// ihn sichtbar, damit jeder Aufrufer ihn behandeln muss statt an einer
    /// erfundenen oder leeren URL in einen Netzwerkfehler zu laufen.
    public let baseURL: URL?
    public let cfAccessClientID: String?
    public let cfAccessClientToken: String?
    public let bundleID: String
    public let appVersion: String
    public let buildNumber: String

    /// `true`, sobald eine Serveradresse hinterlegt ist. Lesbarer Name für
    /// `baseURL != nil` an den Stellen, die nur die Ja/Nein-Frage stellen.
    public var isServerConfigured: Bool {
        baseURL != nil
    }

    public init(
        baseURL: URL?,
        cfAccessClientID: String? = nil,
        cfAccessClientToken: String? = nil,
        bundleID: String,
        appVersion: String,
        buildNumber: String
    ) {
        self.baseURL = baseURL
        self.cfAccessClientID = cfAccessClientID?.nilIfEmpty
        self.cfAccessClientToken = cfAccessClientToken?.nilIfEmpty
        self.bundleID = bundleID
        self.appVersion = appVersion
        self.buildNumber = buildNumber
    }
}

public extension AppEnvironment {
    /// SHA-256 fingerprints of server hosts retired from distributed builds.
    /// If a build ever needs to force-retire a previously configured host
    /// (for example after a hosting migration), add the host's fingerprint
    /// here: ``resolve(keychain:bundle:retiredServerHostFingerprints:)``
    /// then refuses to resurrect that host from the Keychain unless the user
    /// explicitly re-confirms it. Empty by default — no host has ever been
    /// retired for public builds.
    static let retiredServerHostFingerprints: Set<String> = []

    /// Loads from `Info.plist`. Keys: `HLBaseURL`, `CFAccess.ClientID`, `CFAccess.ClientToken`.
    ///
    /// **Kein Rückfall.** Fehlt `HLBaseURL` (der Normalfall — die
    /// eingecheckte `project.yml` setzt den Schlüssel nicht), oder ist der
    /// Wert leer bzw. nicht parsbar, dann ist ``baseURL`` `nil`: "noch kein
    /// Server eingerichtet". Die App-Metadaten (Bundle-ID, Version, Build)
    /// gelten unabhängig davon und bleiben immer gefüllt — deshalb liefert
    /// diese Funktion weiterhin ein `AppEnvironment` und nicht `nil`.
    static func loadFromBundle(_ bundle: Bundle = .main) -> AppEnvironment {
        let info = bundle.infoDictionary ?? [:]
        let cfDict = info["CFAccess"] as? [String: String]
        return AppEnvironment(
            baseURL: (info["HLBaseURL"] as? String)?.nilIfEmpty.flatMap { URL(string: $0) },
            cfAccessClientID: cfDict?["ClientID"],
            cfAccessClientToken: cfDict?["ClientToken"],
            bundleID: bundle.bundleIdentifier ?? "dev.healthlog.app",
            appVersion: info["CFBundleShortVersionString"] as? String ?? "0.0.0",
            buildNumber: info["CFBundleVersion"] as? String ?? "0"
        )
    }

    /// Resolves the runtime `AppEnvironment`: App-Metadaten aus dem Bundle,
    /// überlagert von der im Keychain hinterlegten Serveradresse
    /// (`KeychainKey.serverURL`), die der Nutzer im Onboarding
    /// (`ServerURLStep`) einträgt.
    ///
    /// Ist weder ein Keychain-Eintrag noch ein `HLBaseURL` im Bundle
    /// vorhanden, bleibt ``baseURL`` `nil` — "kein Server eingerichtet". Es
    /// wird nichts vorbelegt und nichts erfunden.
    ///
    /// Per-install (not per-user) — the URL routes every request, including
    /// the un-authenticated `/api/auth/registration-status` probe in
    /// `ServerURLStep`. Keychain (not UserDefaults) because the host name is
    /// privacy-sensitive (reveals self-hoster identity).
    static func resolve(
        keychain: KeychainStoring,
        bundle: Bundle = .main,
        retiredServerHostFingerprints: Set<String> = Self.retiredServerHostFingerprints
    ) -> AppEnvironment {
        let bundleEnv = loadFromBundle(bundle)
        guard let overrideString = keychain.getString(forKey: KeychainKey.serverURL),
              let trimmed = overrideString.nilIfEmpty,
              let overrideURL = URL(string: trimmed),
              overrideURL.host?.isEmpty == false else
        {
            return bundleEnv
        }
        if let host = overrideURL.host?.lowercased() {
            let fingerprint = hostFingerprint(host)
            let explicitlyConfirmed = keychain.getString(
                forKey: KeychainKey.serverURLExplicitHostFingerprint
            ) == fingerprint
            if retiredServerHostFingerprints.contains(fingerprint), !explicitlyConfirmed {
                // Fail closed even when the physical Keychain removal fails: the
                // retired identity never becomes the active environment again.
                // Remove provenance first so a partial Keychain failure cannot
                // turn a legacy value into an explicitly-confirmed one later.
                try? keychain.remove(forKey: KeychainKey.serverURLExplicitHostFingerprint)
                try? keychain.remove(forKey: KeychainKey.serverURL)
                return bundleEnv
            }
        }
        return AppEnvironment(
            baseURL: overrideURL,
            cfAccessClientID: bundleEnv.cfAccessClientID,
            cfAccessClientToken: bundleEnv.cfAccessClientToken,
            bundleID: bundleEnv.bundleID,
            appVersion: bundleEnv.appVersion,
            buildNumber: bundleEnv.buildNumber
        )
    }

    private static func hostFingerprint(_ host: String) -> String {
        SHA256.hash(data: Data(host.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Validation result for a user-typed server URL. Returned by
    /// `validate(serverURLString:)` so the `ServerURLStep` UI can render
    /// scheme/host errors before issuing the inline health-probe.
    enum URLValidationError: Error, Equatable, Sendable {
        /// Empty input or whitespace-only.
        case empty
        /// `URL(string:)` returned nil.
        case malformed
        /// Host component missing or empty.
        case missingHost
        /// Scheme other than `https`. In DEBUG builds we still accept `http`
        /// for local-dev convenience; release builds reject.
        case insecureScheme
    }

    /// Validates a typed server URL string. Pure function — no Keychain side
    /// effects. Auto-prepends `https://` if no scheme is present so users
    /// can type `meinserver.example.com` and have it Just Work.
    ///
    /// - Returns: A canonicalised URL on success (always with scheme).
    /// - Throws: `URLValidationError` describing the first failure.
    static func validate(serverURLString raw: String) throws -> URL {
        guard let trimmed = raw.nilIfEmpty else { throw URLValidationError.empty }
        let canonical: String = if trimmed.hasPrefix("https://") || trimmed.hasPrefix("http://") {
            trimmed
        } else {
            "https://\(trimmed)"
        }
        guard let url = URL(string: canonical) else { throw URLValidationError.malformed }
        guard let host = url.host, !host.isEmpty else { throw URLValidationError.missingHost }
        // Refuse `http://` in release builds — passwords and Bearer tokens
        // would cross the wire in clear text. DEBUG keeps the affordance for
        // self-hosters running on `http://localhost:3000` during dev work.
        #if !DEBUG
            guard url.scheme?.lowercased() == "https" else {
                throw URLValidationError.insecureScheme
            }
        #endif
        return url
    }

    /// Resolves the current effective server URL by replaying the same
    /// bundle-default + Keychain overlay logic ``resolve(keychain:bundle:)``
    /// uses, but returns only the URL. Convenience for read-only UI
    /// surfaces (Settings → Server) that need to display the host without
    /// pulling the entire ``AppEnvironment`` graph.
    ///
    /// Pure — no side effects, no env mutation. Cheap enough to call once
    /// per render tick; the Keychain read is a single SecItem lookup.
    static func currentBaseURL(
        keychain: KeychainStoring,
        bundle: Bundle = .main
    ) -> URL? {
        resolve(keychain: keychain, bundle: bundle).baseURL
    }

    /// Coarse classification of an effective server URL. Used by
    /// Settings → Server for the human-readable label and by
    /// `ServerAuthStep.prefersWebHandoff` (#65).
    ///
    /// Es gibt **keinen** `.managedCloud`-Fall mehr: die App kennt keinen
    /// eingebauten Server, also gibt es keine Instanz, die sie an ihrem
    /// Namen wiedererkennen könnte. Jede Adresse, die der Nutzer einträgt,
    /// ist selbst gehostet — bis auf die öffentliche Demo, die eine
    /// Fremd-Domain ist und deshalb weiter benannt wird.
    ///
    /// **Wichtig:** diese Klassifikation beschriftet nur. Sie schaltet
    /// nichts mehr frei — die Passkey-Schranke hängt seit dem Wegfall des
    /// Default-Servers an ``supportsPasskeys(host:bundle:)``, also an einer
    /// tatsächlichen Fähigkeit des Builds statt am Namen des Hosts.
    enum ServerRegion: String, Sendable, Equatable {
        case demo
        case selfHosted
    }

    /// Best-effort region inference from the resolved server host.
    /// `demo.healthlog.dev` (die öffentliche Demo, Fremd-Domain) → `.demo`,
    /// alles andere → `.selfHosted`.
    static func inferRegion(for url: URL) -> ServerRegion {
        guard let host = url.host?.lowercased() else { return .selfHosted }
        if host == "demo.healthlog.dev" || host.hasSuffix(".healthlog.dev") {
            return .demo
        }
        return .selfHosted
    }

    // MARK: - Passkey-Fähigkeit

    /// Die `webcredentials:`-Domains, die dieses Build im
    /// Associated-Domains-Entitlement mitbringt — gespiegelt in den
    /// Info.plist-Schlüssel `HLPasskeyRelyingPartyHosts`, weil das
    /// Entitlement selbst zur Laufzeit nicht lesbar ist.
    ///
    /// Beide Seiten kommen aus derselben Quelle (`Config/local.yml`, siehe
    /// `CertificatePinner`-Kopf), damit sie nicht auseinanderlaufen können.
    /// Ein Build ohne lokales Overlay hat weder Entitlement noch Schlüssel —
    /// und damit ehrlich keine Passkey-Fähigkeit.
    ///
    /// Einträge sind exakte Hosts; ein führendes `*.` erlaubt zusätzlich
    /// direkte Subdomains (Apples AASA-Wildcard-Schreibweise).
    static func passkeyRelyingPartyHosts(bundle: Bundle = .main) -> [String] {
        bundle.infoDictionary?["HLPasskeyRelyingPartyHosts"] as? [String] ?? []
    }

    /// Prüft, ob dieses Build für `host` überhaupt einen Passkey
    /// registrieren oder abfragen **kann**.
    ///
    /// Hintergrund (GH #65): Passkeys sind an die `rpId` des Servers
    /// gebunden, und iOS lässt eine Assertion nur zu, wenn diese `rpId` von
    /// einer `webcredentials:`-Domain des Builds gedeckt ist. Die frühere
    /// Schranke prüfte stattdessen den Namen des Hosts gegen eine
    /// fest eingebaute Domain — für jeden Selbst-Hoster war sie damit
    /// grundsätzlich falsch: er bekam die Schaltfläche nie zu sehen, auch
    /// wenn er die App mit seiner eigenen Domain neu gebaut hatte.
    ///
    /// Jetzt entscheidet die tatsächlich mitgelieferte Association.
    static func supportsPasskeys(host: String?, bundle: Bundle = .main) -> Bool {
        supportsPasskeys(host: host, relyingPartyHosts: passkeyRelyingPartyHosts(bundle: bundle))
    }

    /// Reine Form von ``supportsPasskeys(host:bundle:)`` — ohne Bundle,
    /// damit die Regel ohne Info.plist-Attrappe testbar ist.
    static func supportsPasskeys(host: String?, relyingPartyHosts: [String]) -> Bool {
        guard let host = host?.lowercased().nilIfEmpty else { return false }
        for raw in relyingPartyHosts {
            guard let entry = raw.lowercased().nilIfEmpty else { continue }
            if entry.hasPrefix("*.") {
                let suffix = String(entry.dropFirst(2))
                // `*.example.com` deckt `a.example.com`, nicht den Apex und
                // nicht `evilexample.com` — der Punkt erzwingt die Labelgrenze.
                if !suffix.isEmpty, host.hasSuffix("." + suffix) { return true }
            } else if host == entry {
                return true
            }
        }
        return false
    }

    /// Writes (or clears) the custom server URL in Keychain. Pure setter — the
    /// caller is responsible for re-creating `AppEnvironment` + the dependent
    /// `APIClient` afterwards (currently only happens at onboarding before any
    /// authenticated request fires, so a process-level `AppEnvironment.resolve`
    /// on next launch is sufficient).
    ///
    /// - Parameters:
    ///   - url: Neue Basis-URL, oder `nil`, um den Eintrag zu löschen. Danach
    ///     gilt wieder "kein Server eingerichtet" (es sei denn, ein Build
    ///     setzt `HLBaseURL` im Bundle).
    ///   - keychain: Storage backend.
    /// - Throws: Underlying KeychainError on write failure.
    static func setCustomBaseURL(_ url: URL?, keychain: KeychainStoring) throws {
        if let url {
            do {
                try keychain.setString(url.absoluteString, forKey: KeychainKey.serverURL)
                if let host = url.host?.lowercased() {
                    try keychain.setString(
                        hostFingerprint(host),
                        forKey: KeychainKey.serverURLExplicitHostFingerprint
                    )
                } else {
                    try keychain.remove(forKey: KeychainKey.serverURLExplicitHostFingerprint)
                }
            } catch {
                // A URL without its matching provenance is safer than stale,
                // mismatched state, but the caller must still see the failure.
                // Clear both best-effort so the next resolve fails closed.
                try? keychain.remove(forKey: KeychainKey.serverURLExplicitHostFingerprint)
                try? keychain.remove(forKey: KeychainKey.serverURL)
                throw error
            }
        } else {
            do {
                // Provenance goes first: if URL removal then fails, a retired
                // host can no longer bypass migration on the next resolve.
                try keychain.remove(forKey: KeychainKey.serverURLExplicitHostFingerprint)
                try keychain.remove(forKey: KeychainKey.serverURL)
            } catch {
                try? keychain.remove(forKey: KeychainKey.serverURLExplicitHostFingerprint)
                throw error
            }
        }
    }
}

extension String {
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
