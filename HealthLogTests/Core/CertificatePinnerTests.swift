import Foundation
import Security
import Testing

#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

// swiftlint:disable force_unwrapping line_length

@Suite("CertificatePinner", .serialized)
struct CertificatePinnerTests {
    /// Selbst signiertes EC-P-256-Test-Zertifikat fuer `health.example.com`
    /// (Gueltigkeit 2026-07-31 … 2046-07-26, Serie 1).
    ///
    /// Frueher stand hier ein echtes Leaf-Zertifikat des Betreiber-Hosts —
    /// es traegt CN und SAN im Klartext und war damit ein Hinweis darauf,
    /// wer die App betreibt. Fuer den Zweck dieses Fixtures ist das
    /// gleichgueltig: getestet wird, dass die SPKI-Hash-Bildung bit-genau
    /// dem `scripts/extract-spki.sh`-Pfad (openssl) entspricht. Erzeugt mit:
    ///
    ///     openssl ecparam -name prime256v1 -genkey -noout -out k.pem
    ///     openssl req -new -x509 -key k.pem -days 7300 -set_serial 1 \
    ///       -subj "/CN=health.example.com" \
    ///       -addext "subjectAltName=DNS:health.example.com,DNS:*.health.example.com"
    ///
    /// Kein privates Material im Test-Bundle — nur das oeffentliche Zertifikat.
    private static let leafCertDERBase64: String = """
    MIIBszCCAVmgAwIBAgIBATAKBggqhkjOPQQDAjAdMRswGQYDVQQDDBJoZWFsdGguZXhhbXBsZS5jb20wHhcNMjYwNzMxMjAzMzQyWhcNNDYwNzI2MjAzMzQyWjAdMRswGQYDVQQDDBJoZWFsdGguZXhhbXBsZS5jb20wWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAARZLJn4G0giz2W1cEDEugKKpgcYqe6vmqHAsyAGnWAwTYJsCCDzIk0ng02OSX6n25+irh/VN8sWK3ybB+LlMTLPo4GJMIGGMB0GA1UdDgQWBBSq0B/T8FBmehI4KNCwQyQrjBnddTAfBgNVHSMEGDAWgBSq0B/T8FBmehI4KNCwQyQrjBnddTAPBgNVHRMBAf8EBTADAQH/MDMGA1UdEQQsMCqCEmhlYWx0aC5leGFtcGxlLmNvbYIUKi5oZWFsdGguZXhhbXBsZS5jb20wCgYIKoZIzj0EAwIDSAAwRQIhAKxWIOSHCuHxAduoFyXq5UNmWeSQqvjmak6Vy/RRVezLAiBdA1ReK7tX0gVeyhq7egblozphLGgII6RPQWX5tOOlpA==
    """

    /// SPKI SHA-256 des Fixtures oben — unabhaengig ueber die openssl-Kette
    /// aus `scripts/extract-spki.sh` berechnet, damit der Vergleich die
    /// Swift-Implementierung wirklich prueft und nicht sich selbst.
    private static let leafSPKIHash = "rTah7LIvlKQiVrhA2qT7y5hfKhTpEB+FYSd+c+O6j1E="

    /// Fixed verify date for the fixture trust evaluation — mitten im
    /// Gueltigkeitsfenster des Fixtures (2026-07-31 … 2046-07-26). Haelt die
    /// Pin-Logik-Tests unabhaengig von der Wanduhr.
    private static let fixtureVerifyDate: Date = {
        var components = DateComponents()
        components.year = 2027
        components.month = 1
        components.day = 1
        components.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: components)!
    }()

    private static func makeTrust(forDER der: Data, anchorToSelf: Bool) -> SecTrust? {
        guard let cert = SecCertificateCreateWithData(nil, der as CFData) else { return nil }
        var trust: SecTrust?
        let policy = SecPolicyCreateBasicX509()
        let status = SecTrustCreateWithCertificates([cert] as CFArray, policy, &trust)
        guard status == errSecSuccess, let trust else { return nil }
        // Pin the trust evaluation to a FIXED verify date inside the fixture
        // leaf's validity window (notBefore 2026-07-31; notAfter
        // 2026-06-26). Without this the baseline `SecTrustEvaluateWithError`
        // rejects the leaf once the wall clock passes its expiry, turning these
        // pin-logic tests into a time bomb that fails the suite every day after
        // 2026-06-26. The PRODUCTION pinning is unaffected (CA-level GTS pins to
        // 2028/2029, leaf renewals need no build) — this only stabilises the
        // TEST fixture. Re-capture a fresh long-lived leaf to move the window.
        SecTrustSetVerifyDate(trust, Self.fixtureVerifyDate as CFDate)
        if anchorToSelf {
            // v0.12 W1 — `validate(trust:)` now runs `SecTrustEvaluateWithError`
            // BEFORE the SPKI-match loop (security finding W1-3). Das Fixture
            // ist selbst signiert und kettet damit gegen keinen System-Anker,
            // so a bare single-leaf trust would never evaluate.
            // To keep the SPKI-match tests testing the pin logic (not the
            // system trust store), we anchor the leaf to itself + disable
            // network revocation fetch so baseline eval passes deterministically
            // offline. The eval-FIRST ordering is proven separately by
            // `evalFailureRejectsEvenWithMatchingPin`, which leaves the trust
            // un-anchored on purpose.
            SecTrustSetAnchorCertificates(trust, [cert] as CFArray)
            SecTrustSetNetworkFetchAllowed(trust, false)
        }
        return trust
    }

    private static func leafTrust() -> SecTrust {
        let der = Data(base64Encoded: leafCertDERBase64.replacingOccurrences(of: "\n", with: ""))!
        return makeTrust(forDER: der, anchorToSelf: true)!
    }

    /// Same leaf, but NOT anchored — baseline `SecTrustEvaluateWithError`
    /// fails (untrusted chain). Used to prove the eval gate rejects a chain
    /// even when a pin matches.
    private static func unanchoredLeafTrust() -> SecTrust {
        let der = Data(base64Encoded: leafCertDERBase64.replacingOccurrences(of: "\n", with: ""))!
        return makeTrust(forDER: der, anchorToSelf: false)!
    }

    @Test("Empty pin set disables pinning (validate returns true)")
    func emptyPinSetDisablesPinning() {
        let pinner = CertificatePinner()
        #expect(!pinner.isEnabled)
        #expect(pinner.validate(trust: Self.leafTrust()))
    }

    @Test("Matching SPKI hash validates the trust chain")
    func matchingPinValidates() {
        let pinner = CertificatePinner(pinnedSPKIHashes: [Self.leafSPKIHash])
        #expect(pinner.isEnabled)
        #expect(pinner.validate(trust: Self.leafTrust()))
    }

    @Test("Non-matching SPKI hash rejects the trust chain")
    func nonMatchingPinRejects() {
        let bogus = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
        let pinner = CertificatePinner(pinnedSPKIHashes: [bogus])
        #expect(pinner.isEnabled)
        #expect(!pinner.validate(trust: Self.leafTrust()))
    }

    @Test("Baseline trust eval runs FIRST — a matching pin on an untrusted chain is rejected")
    func evalFailureRejectsEvenWithMatchingPin() {
        // v0.12 W1 (security finding W1-3). The pin matches the leaf's SPKI
        // exactly, so the SPKI-match loop alone would accept. But the trust is
        // un-anchored → `SecTrustEvaluateWithError` fails (untrusted chain),
        // standing in for the real-world expired / revoked / name-mismatched
        // chain that carries a pinned key. `validate` must reject because the
        // baseline eval runs BEFORE the pin loop. If the ordering regressed
        // (pin-match first / eval skipped) this would wrongly return true.
        let pinner = CertificatePinner(pinnedSPKIHashes: [Self.leafSPKIHash])
        #expect(pinner.isEnabled)
        // Sanity: the SAME leaf, when properly anchored (baseline eval passes),
        // IS accepted — proving the only difference is the eval gate, not the pin.
        #expect(pinner.validate(trust: Self.leafTrust()))
        // Un-anchored: baseline eval fails, so the matching pin must NOT rescue it.
        #expect(!pinner.validate(trust: Self.unanchoredLeafTrust()))
    }

    @Test("Backup pin still validates if the primary pin would not match")
    func backupPinSurvivesLeafRotation() {
        // Simulates the post-rotation scenario: the leaf SPKI hash in the pin set is stale,
        // but the backup pin (here: the actual leaf hash standing in for the intermediate)
        // still allows the connection to succeed.
        let stalePrimary = "ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ="
        let pinner = CertificatePinner(pinnedSPKIHashes: [stalePrimary, Self.leafSPKIHash])
        #expect(pinner.validate(trust: Self.leafTrust()))
    }

    // MARK: - Build-Zeit-Vertrag: Pinning ist optional, Halbheiten sind es nicht

    /// Der Build-Zeit-Vertrag, und zwar in BEIDEN Welten.
    ///
    /// Die konkreten Hashes und Hosts sind betreiber-eigen und leben im
    /// lokalen, nicht eingecheckten Overlay (`Config/local.yml`). Ein
    /// frischer Clone hat es nicht und pinnt deshalb gar nicht — gueltig,
    /// System-Trust traegt. Die Maschine des Betreibers hat es immer, sonst
    /// koennte sie nicht ausliefern.
    ///
    /// Dieser Test hat urspruenglich schlicht „kein Pin-Set" behauptet. Das
    /// war ein Vertrag ueber die Umgebung, nicht ueber den Code: auf der
    /// Maschine des Betreibers war er unerfuellbar — und da laeuft die Suite
    /// als Tor vor jedem TestFlight-Upload. Er haette jede Auslieferung
    /// blockiert. Geprueft wird jetzt die tatsaechliche Zusage: **entweder
    /// gar nichts, oder vollstaendig — Halbheiten nie.**
    @Test("Pinning ist optional, Halbheiten sind es nicht — mit und ohne Overlay")
    func bundlePinConfigurationIsEitherAbsentOrComplete() {
        let pinner = CertificatePinner(fromBundle: .main)
        // Die eine Zusage, die immer gilt: der Release-Guard laeuft nicht an.
        #expect(pinner.pinConfigurationIsValid)

        if pinner.declaresPinning {
            // Overlay aktiv (Betreiber-Maschine, Ship-Lauf): dann muss es
            // vollstaendig sein, sonst sperrt die naechste Rotation alle aus.
            #expect(pinner.pinnedSPKIHashes.count >= CertificatePinner.minimumProductionPinCount)
            #expect(pinner.pinsAreWellFormed)
            #expect(!pinner.pinnedHostSuffixes.isEmpty)
            #expect(pinner.isEnabled)
        } else {
            // Frischer Clone: nichts deklariert, nichts erzwungen.
            #expect(pinner.pinnedSPKIHashes.isEmpty)
            #expect(pinner.pinnedHostSuffixes.isEmpty)
            #expect(!pinner.isEnabled)
        }
    }

    /// Und der eingecheckte Stand fuer sich genommen bringt weiterhin nichts
    /// mit — das prueft der Katalog-Stand des Repositories, nicht das Bundle
    /// der gerade laufenden Maschine.
    @Test("Der eingecheckte Stand deklariert keine Hosts")
    func repositoryDefaultsDeclareNoHosts() {
        #expect(CertificatePinner.defaultPinnedHostSuffixes.isEmpty)
    }

    /// Falls doch Pins im Bundle liegen (lokales Overlay aktiv), muessen sie
    /// wohlgeformt und vollstaendig sein — sonst crasht der Release-Build.
    @Test("Sind Pins im Bundle, muessen sie vollstaendig und wohlgeformt sein")
    func bundledPinsMustBeCompleteWhenPresent() {
        let pinner = CertificatePinner(fromBundle: .main)
        guard pinner.declaresPinning else { return }
        let raw = Bundle.main.infoDictionary?["HLPinnedSPKIHashes"] as? [String] ?? []
        #expect(raw.count == Set(raw).count, "Doppelte SPKI-Hashes — der Backup-Pin ist eine Illusion.")
        #expect(pinner.pinsAreWellFormed)
        #expect(pinner.meetsProductionPinPolicy)
        #expect(!pinner.pinnedHostSuffixes.isEmpty)
        #expect(pinner.pinConfigurationIsValid)
    }

    @Test("Ein Build ohne jede Pinning-Angabe ist gueltig und crasht nicht")
    func noPinningIsAValidConfiguration() {
        let pinner = CertificatePinner()
        #expect(!pinner.isEnabled)
        #expect(!pinner.declaresPinning)
        #expect(pinner.pinConfigurationIsValid)
    }

    /// Hashes ohne Hosts: `isPinnedHost` trifft nie, das Pin-Set waere
    /// dekorativ. Das ist die gefaehrlichere Haelfte — es sieht nach Pinning
    /// aus und ist keines.
    @Test("Pins ohne Hosts sind eine kaputte Konfiguration")
    func pinsWithoutHostsAreInvalid() {
        let a = Data(repeating: 0x01, count: CertificatePinner.spkiHashByteCount).base64EncodedString()
        let b = Data(repeating: 0x02, count: CertificatePinner.spkiHashByteCount).base64EncodedString()
        let pinner = CertificatePinner(pinnedSPKIHashes: [a, b], pinnedHostSuffixes: [])
        #expect(pinner.declaresPinning)
        #expect(pinner.meetsProductionPinPolicy)
        #expect(!pinner.pinConfigurationIsValid)
    }

    /// Hosts ohne (genug) Hashes: entweder gar kein Schutz oder ein Set, das
    /// die naechste Zertifikatsrotation nicht ueberlebt.
    @Test("Hosts ohne vollstaendiges Pin-Set sind eine kaputte Konfiguration")
    func hostsWithoutUsablePinsAreInvalid() {
        let noPins = CertificatePinner(pinnedSPKIHashes: [], pinnedHostSuffixes: ["example.com"])
        #expect(noPins.declaresPinning)
        #expect(!noPins.pinConfigurationIsValid)

        let single = Data(repeating: 0xAB, count: CertificatePinner.spkiHashByteCount).base64EncodedString()
        let onePin = CertificatePinner(pinnedSPKIHashes: [single], pinnedHostSuffixes: ["example.com"])
        #expect(!onePin.pinConfigurationIsValid)

        let short = Data(repeating: 0x02, count: 20).base64EncodedString()
        let malformed = CertificatePinner(pinnedSPKIHashes: [single, short], pinnedHostSuffixes: ["example.com"])
        #expect(!malformed.pinConfigurationIsValid)
    }

    /// Vollstaendige Konfiguration — der Zustand, den ein Betreiber mit
    /// eigenem Overlay herstellt.
    @Test("Hosts plus zwei wohlgeformte Pins sind eine gueltige Konfiguration")
    func completeConfigurationIsValid() {
        let a = Data(repeating: 0x01, count: CertificatePinner.spkiHashByteCount).base64EncodedString()
        let b = Data(repeating: 0x02, count: CertificatePinner.spkiHashByteCount).base64EncodedString()
        let pinner = CertificatePinner(pinnedSPKIHashes: [a, b], pinnedHostSuffixes: ["example.com"])
        #expect(pinner.pinConfigurationIsValid)
    }

    // MARK: - Pinned-host resolution (WPIN)

    /// Ohne Angabe pinnt die App gegen NICHTS. Frueher stand hier die
    /// Apex-Domain des Betreibers fest im Quelltext.
    @Test("Default-Konfiguration pinnt keinen Host")
    func defaultConfigPinsNothing() {
        let pinner = CertificatePinner()
        #expect(pinner.pinnedHostSuffixes.isEmpty)
        #expect(!pinner.isPinnedHost("health.example.com"))
        #expect(!pinner.isPinnedHost("demo.healthlog.dev"))
    }

    @Test("Konfigurierte HLPinnedHosts pinnen Apex plus Subdomains")
    func customHostListPinsConfiguredHost() {
        let pinner = CertificatePinner(pinnedHostSuffixes: ["example.com"])
        #expect(pinner.isPinnedHost("example.com"))
        #expect(pinner.isPinnedHost("health.example.com"))
        // Case-insensitive (DNS-Hostnamen sind es auch).
        #expect(pinner.isPinnedHost("Health.Example.COM"))
        // Labelgrenze: blosses Enthalten reicht nicht.
        #expect(!pinner.isPinnedHost("notexample.com"))
        #expect(!pinner.isPinnedHost("example.com.attacker.test"))
        #expect(!pinner.isPinnedHost("demo.healthlog.dev"))
    }

    @Test("Multiple HLPinnedHosts entries each pin independently")
    func multipleHostEntriesEachPin() {
        let pinner = CertificatePinner(pinnedHostSuffixes: ["example.org", "example.com"])
        #expect(pinner.isPinnedHost("health.example.org"))
        #expect(pinner.isPinnedHost("health.example.com"))
        #expect(!pinner.isPinnedHost("other.dev"))
    }

    @Test("Leere HLPinnedHosts (aus Info.plist) faellt auf die leere Vorgabe zurueck")
    func emptyHostListResolvesToNoHosts() {
        let resolved = CertificatePinner.resolvePinnedHostSuffixes(fromInfoDictionary: [
            "HLPinnedSPKIHashes": [Self.leafSPKIHash],
            "HLPinnedHosts": [String]()
        ])
        #expect(resolved == CertificatePinner.defaultPinnedHostSuffixes)
        #expect(resolved.isEmpty)
        #expect(!CertificatePinner(pinnedHostSuffixes: resolved).isPinnedHost("example.com"))
    }

    @Test("Fehlender HLPinnedHosts-Schluessel faellt auf die leere Vorgabe zurueck")
    func missingHostKeyResolvesToNoHosts() {
        let resolved = CertificatePinner.resolvePinnedHostSuffixes(fromInfoDictionary: [
            "HLPinnedSPKIHashes": [Self.leafSPKIHash]
        ])
        #expect(resolved == CertificatePinner.defaultPinnedHostSuffixes)
        #expect(resolved.isEmpty)
    }

    @Test("nil Info.plist resolves to the empty default")
    func nilInfoDictionaryResolvesToNoHosts() {
        let resolved = CertificatePinner.resolvePinnedHostSuffixes(fromInfoDictionary: nil)
        #expect(resolved == CertificatePinner.defaultPinnedHostSuffixes)
        #expect(resolved.isEmpty)
    }

    @Test("Custom HLPinnedHosts (from Info.plist) is honoured")
    func customHostListResolvesFromInfoDictionary() {
        let resolved = CertificatePinner.resolvePinnedHostSuffixes(fromInfoDictionary: [
            "HLPinnedSPKIHashes": [Self.leafSPKIHash],
            "HLPinnedHosts": ["example.com"]
        ])
        #expect(resolved == ["example.com"])
        let pinner = CertificatePinner(pinnedHostSuffixes: resolved)
        #expect(pinner.isPinnedHost("health.example.com"))
        #expect(!pinner.isPinnedHost("example.org"))
    }
}

// swiftlint:enable force_unwrapping line_length
