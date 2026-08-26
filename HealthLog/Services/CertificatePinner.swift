import CryptoKit
import Foundation
import Security

/// Public-Key-Pinning über SHA-256 des SubjectPublicKeyInfo (SPKI).
///
/// # Wie ein Betreiber seine eigenen Pins hinterlegt
///
/// Pins und der zu pinnende Hostname sind **betreiber-eigene Angaben** und
/// stehen deshalb in **keiner** eingecheckten Datei. Das Repository bringt
/// den Mechanismus mit, nicht die Werte.
///
/// 1. Datei `Config/local.yml` anlegen (per `.gitignore` ausgeschlossen —
///    Vorlage: `Config/local.example.yml`).
/// 2. SPKI-Hashes der eigenen Kette ziehen:
///    `scripts/extract-spki.sh health.example.com`
/// 3. In `Config/local.yml` eintragen: `HLPinnedSPKIHashes` (mindestens zwei
///    — Primär plus Backup, sonst sperrt die nächste Zertifikatsrotation
///    alle Nutzer aus), `HLPinnedHosts` (Host-Suffixe, gegen die das Pin-Set
///    durchgesetzt wird) und, falls Passkeys gewünscht sind,
///    `HLPasskeyRelyingPartyHosts` plus die passenden
///    `com.apple.developer.associated-domains`.
/// 4. `HL_LOCAL_CONFIG=1 xcodegen` — nur mit gesetzter Variable zieht
///    XcodeGen das lokale Overlay in `project.yml` hinein.
///    Kein Skript setzt die Variable automatisch — wer das Overlay will,
///    setzt sie selbst in der Build-Umgebung.
///
/// **Ohne lokales Overlay ist kein Pinning konfiguriert — und das ist der
/// Normalzustand.** Ein Selbst-Hoster ohne Pins fällt auf die
/// System-Trust-Validierung zurück (baseline X.509, siehe
/// `APIClient.serverTrustDisposition`); das ist kein Fehler und darf
/// deshalb auch nicht crashen. Kaputt ist nur ein Build, der Pinning
/// *deklariert* und es dann nicht vollständig mitbringt — siehe
/// ``pinConfigurationIsValid``.
///
/// SPKI-Extraktion folgt dem TrustKit-Pattern: pro Key-Typ wird der bekannte ASN.1-Prefix
/// über den Raw-Key geprependet, dann SHA-256 über das Ergebnis. Der Output stimmt
/// mit `scripts/extract-spki.sh` (openssl SPKI dump) bit-genau überein.
///
/// Cert-rotation policy: pin set **must** carry primary (leaf) + at least one backup
/// (intermediate / next-rotation leaf / root). Single-pin sets break the app the moment
/// the leaf rotates — checked by `Self.minimumProductionPinCount`.
public struct CertificatePinner: Sendable {
    /// Minimum number of pins a Release build must ship with. Primary leaf + ≥ 1 backup
    /// so cert rotation does not lock users out. Enforced in `AppContainer.init` for
    /// `!DEBUG` builds and asserted in `CertificatePinnerTests`.
    public static let minimumProductionPinCount: Int = 2

    /// Decoded SPKI hash length: SHA-256 always yields 32 bytes. Used to detect
    /// truncation / encoding mistakes in the Info.plist (e.g. accidentally pasting
    /// a base64 of the *cert* hash instead of the *SPKI* hash).
    public static let spkiHashByteCount: Int = 32

    /// Host suffixes the pin set is enforced against when `HLPinnedHosts` is
    /// missing from the Info.plist: **keine**.
    ///
    /// Früher stand hier die Apex-Domain des Betreibers. Ein eingebauter
    /// Default-Host verrät (a) wer die App betreibt und wäre (b) für jeden
    /// Selbst-Hoster ohnehin das falsche Kriterium gewesen. Wer pinnen will,
    /// nennt seine Hosts in `HLPinnedHosts` (siehe Kopf dieser Datei).
    public static let defaultPinnedHostSuffixes: [String] = []

    public let pinnedSPKIHashes: Set<String> // base64-encoded SHA256

    /// Host suffixes the pin set is enforced for. An entry `example.com` matches the
    /// apex `example.com` exactly **and** any subdomain ending in `.example.com` (the
    /// leading dot enforces a label boundary, so `evilexample.com` does NOT match).
    /// Hosts not covered by any entry fall back to system-trust validation — that is
    /// the documented model for self-hosted / demo backends that ship their own chain.
    public let pinnedHostSuffixes: [String]

    public init(
        pinnedSPKIHashes: Set<String> = [],
        pinnedHostSuffixes: [String] = CertificatePinner.defaultPinnedHostSuffixes
    ) {
        self.pinnedSPKIHashes = pinnedSPKIHashes
        self.pinnedHostSuffixes = pinnedHostSuffixes
    }

    /// Reads `HLPinnedSPKIHashes` (Array of base64-Strings) and `HLPinnedHosts`
    /// (Array of host suffixes) from the bundle's Info.plist.
    ///
    /// No default for `bundle` — callers must opt in explicitly so `CertificatePinner()`
    /// keeps unambiguously meaning "empty pin set" (debug/test default).
    ///
    /// A missing or empty `HLPinnedHosts` key falls back to ``defaultPinnedHostSuffixes``,
    /// which is empty — ein Build ohne lokales Overlay pinnt also gegen
    /// keinen Host und validiert per System-Trust.
    public init(fromBundle bundle: Bundle) {
        let info = bundle.infoDictionary
        let raw = info?["HLPinnedSPKIHashes"] as? [String] ?? []
        pinnedSPKIHashes = Set(raw)
        pinnedHostSuffixes = Self.resolvePinnedHostSuffixes(fromInfoDictionary: info)
    }

    /// Resolves the enforced host-suffix list from a bundle's `infoDictionary`,
    /// applying the missing/empty-key fallback to ``defaultPinnedHostSuffixes``.
    /// Extracted so the fallback semantics can be unit-tested against arbitrary
    /// plist shapes without subclassing `Bundle`.
    static func resolvePinnedHostSuffixes(fromInfoDictionary info: [String: Any]?) -> [String] {
        let hosts = info?["HLPinnedHosts"] as? [String] ?? []
        return hosts.isEmpty ? defaultPinnedHostSuffixes : hosts
    }

    /// Pinned-host predicate. A host is pinned when it equals one of the configured
    /// suffixes exactly, or ends in `.` + the suffix (label-boundary match). Mirrors
    /// the historic `host == <suffix> || host.hasSuffix("." + <suffix>)` semantics
    /// for each configured entry. Case-insensitive (DNS hostnames are case-insensitive).
    public func isPinnedHost(_ host: String) -> Bool {
        let host = host.lowercased()
        for rawSuffix in pinnedHostSuffixes {
            let suffix = rawSuffix.lowercased()
            guard !suffix.isEmpty else { continue }
            if host == suffix || host.hasSuffix("." + suffix) {
                return true
            }
        }
        return false
    }

    public var isEnabled: Bool {
        !pinnedSPKIHashes.isEmpty
    }

    /// `true` iff every pin is a well-formed base64 SHA-256 (decodes to exactly 32 bytes).
    /// Catches paste-mistakes (cert-hash instead of SPKI-hash, line-wrap artifacts,
    /// or accidental whitespace) before they reach Release.
    public var pinsAreWellFormed: Bool {
        guard !pinnedSPKIHashes.isEmpty else { return false }
        for pin in pinnedSPKIHashes {
            guard let decoded = Data(base64Encoded: pin),
                  decoded.count == Self.spkiHashByteCount else
            {
                return false
            }
        }
        return true
    }

    /// Production-readiness gate: ≥ `minimumProductionPinCount` distinct, well-formed pins.
    public var meetsProductionPinPolicy: Bool {
        pinnedSPKIHashes.count >= Self.minimumProductionPinCount && pinsAreWellFormed
    }

    /// Bringt dieses Build Pinning **mit Absicht** mit? Wahr, sobald das
    /// Overlay irgendeine Pinning-Angabe gemacht hat — Hosts oder Hashes.
    ///
    /// Der Unterschied zwischen "nicht konfiguriert" und "falsch
    /// konfiguriert" hängt genau hier: ein Selbst-Hoster, der nichts angibt,
    /// pinnt bewusst nicht. Wer etwas angibt, muss es vollständig angeben.
    public var declaresPinning: Bool {
        !pinnedSPKIHashes.isEmpty || !pinnedHostSuffixes.isEmpty
    }

    /// Release-Gate, das `AppContainer` prüft.
    ///
    /// Früher galt: ein Release **ohne** Pin-Set crasht. Das war richtig,
    /// solange die App genau einen eingebauten Server hatte. Seit sie keinen
    /// mehr hat, ist "keine Pins" der Normalzustand eines Selbst-Hosters und
    /// darf nicht crashen.
    ///
    /// Kaputt ist stattdessen ein Build, der Pinning *mitbringen soll* und es
    /// nicht vollständig tut — beide Halbheiten sind gefährlich, weil sie wie
    /// Pinning aussehen und keines sind:
    /// - Hashes ohne Hosts: ``isPinnedHost`` trifft nie, es wird nie
    ///   durchgesetzt.
    /// - Hosts ohne (oder mit zu wenigen / kaputten) Hashes: entweder gar
    ///   kein Schutz oder ein Set, das die nächste Zertifikatsrotation
    ///   nicht überlebt und alle Nutzer aussperrt.
    public var pinConfigurationIsValid: Bool {
        guard declaresPinning else { return true }
        return !pinnedHostSuffixes.isEmpty && meetsProductionPinPolicy
    }

    /// Validates that the trust chain (a) passes baseline X.509 trust
    /// evaluation AND (b) contains at least one matching SPKI pin.
    public func validate(trust: SecTrust) -> Bool {
        guard isEnabled else { return true }

        // v0.12 W1 (security finding W1-3) — baseline trust evaluation MUST
        // run BEFORE the SPKI-match loop. Public-key pinning on its own only
        // proves "this chain contains a key I expect"; it says nothing about
        // whether the chain is otherwise valid. Without this gate an expired,
        // revoked, or name-mismatched chain that still happens to carry a
        // pinned key (e.g. an attacker replaying a captured-but-expired leaf,
        // or a mis-issued cert sharing the pinned intermediate's key) would be
        // accepted. `SecTrustEvaluateWithError` applies the policy the trust
        // object was created with (hostname + validity + revocation per the
        // system trust store), so pinning becomes "valid chain AND pinned key"
        // rather than "pinned key alone".
        var evalError: CFError?
        guard SecTrustEvaluateWithError(trust, &evalError) else {
            return false
        }

        // `SecTrustGetCertificateAtIndex(_:_:)` was deprecated in iOS 15 in favour
        // of `SecTrustCopyCertificateChain(_:)` which returns the whole chain at once.
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] else {
            return false
        }
        for cert in chain {
            guard let spki = subjectPublicKeyInfo(of: cert) else { continue }
            let hash = SHA256.hash(data: spki)
            let b64 = Data(hash).base64EncodedString()
            if pinnedSPKIHashes.contains(b64) {
                return true
            }
        }
        return false
    }

    /// Reconstructs the full SubjectPublicKeyInfo (SPKI) blob from a certificate.
    /// Strategy: extract the raw public-key data via `SecKeyCopyExternalRepresentation`,
    /// determine the algorithm + parameters, then prepend the canonical ASN.1 SPKI
    /// header for that key type. Result equals `openssl x509 -pubkey | openssl pkey -outform DER`.
    private func subjectPublicKeyInfo(of cert: SecCertificate) -> Data? {
        guard let key = SecCertificateCopyKey(cert),
              let attrs = SecKeyCopyAttributes(key) as? [String: Any],
              let raw = SecKeyCopyExternalRepresentation(key, nil) as Data?,
              let kType = attrs[kSecAttrKeyType as String] as? String,
              let kSize = attrs[kSecAttrKeySizeInBits as String] as? Int else { return nil }

        guard let prefix = SPKIHeader.lookup(keyType: kType, sizeInBits: kSize) else {
            return nil
        }
        return prefix + raw
    }
}

/// Canonical ASN.1 SubjectPublicKeyInfo headers per (key type, key size).
/// Source: TrustKit `TSKSPKIHashCache.m`. Only the variants used by Cloudflare Edge are needed
/// in the default set; extend as new key shapes appear server-side.
private enum SPKIHeader {
    // Bridge the CoreFoundation key-type constants to plain Swift `String` once,
    // so they can appear directly in `case` patterns (a `case (CFString as String, _)`
    // pattern doesn't compile because Swift can't equate the bridged values at
    // pattern-match time).
    private static let rsaKeyType = kSecAttrKeyTypeRSA as String
    private static let ecKeyType = kSecAttrKeyTypeECSECPrimeRandom as String

    static func lookup(keyType: String, sizeInBits: Int) -> Data? {
        switch (keyType, sizeInBits) {
        case (rsaKeyType, 2048):
            Data([
                0x30, 0x82, 0x01, 0x22, 0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86,
                0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00, 0x03,
                0x82, 0x01, 0x0F, 0x00
            ])
        case (rsaKeyType, 4096):
            Data([
                0x30, 0x82, 0x02, 0x22, 0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86,
                0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00, 0x03,
                0x82, 0x02, 0x0F, 0x00
            ])
        case (ecKeyType, 256):
            // ECDSA P-256
            Data([
                0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE,
                0x3D, 0x02, 0x01, 0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D,
                0x03, 0x01, 0x07, 0x03, 0x42, 0x00
            ])
        case (ecKeyType, 384):
            // ECDSA P-384
            Data([
                0x30, 0x76, 0x30, 0x10, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE,
                0x3D, 0x02, 0x01, 0x06, 0x05, 0x2B, 0x81, 0x04, 0x00, 0x22,
                0x03, 0x62, 0x00
            ])
        default:
            nil
        }
    }
}
