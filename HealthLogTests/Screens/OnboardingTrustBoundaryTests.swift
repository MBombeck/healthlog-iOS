import Foundation
@testable import HealthLog
import Testing

/// Locks the onboarding trust-boundary + host-classification + passkey
/// -gating contracts.
///
/// Background: v0.6.1.16 stripped the host preset and the trust-boundary
/// acknowledgement (v0629 H-2 rec 2) never landed, so a first-time user had
/// no orientation at the Server-URL step and a self-hoster's host was
/// persisted to Keychain after a bare probe with no confirmation. v0.7.0
/// added an explicit confirmation sheet.
///
/// **Privacy-Einheit P1** — der eingebaute Default-Server ist ersatzlos
/// entfallen. Damit gibt es keinen Host mehr, den die App an seinem Namen
/// wiedererkennt: `inferRegion` kennt nur noch die oeffentliche Demo und
/// "selbst gehostet", und die Passkey-Schranke fragt die tatsaechliche
/// Fähigkeit des Builds ab statt einen Hostnamen.
///
/// Diese Tests pinnen die tragenden Invarianten:
/// 1. Jede eingetragene Adresse ist `.selfHosted` — nur die Demo faellt
///    heraus.
/// 2. Die Passkey-Schaltflaeche haengt an den mitgelieferten
///    Relying-Party-Domains, nicht am Namen des Hosts (GH #65).
/// 3. Die `IdentifiableURL.id`-Identitaet fuer `.sheet(item:)` ist der
///    absolute String, damit zwei Proben desselben Hosts keine Sheets
///    stapeln.
@Suite("Onboarding trust boundary + passkey gating", .serialized)
struct OnboardingTrustBoundaryTests {
    // MARK: - Host-Klassifikation ohne eingebauten Server

    @Test("Jede eingetragene Adresse ist selbst gehostet")
    func everyTypedHostIsSelfHosted() throws {
        let a = try AppEnvironment.validate(serverURLString: "https://hl.example.com")
        let b = try AppEnvironment.validate(serverURLString: "https://health.example.org")
        #expect(AppEnvironment.inferRegion(for: a) == .selfHosted)
        #expect(AppEnvironment.inferRegion(for: b) == .selfHosted)
    }

    @Test("Nur die oeffentliche Demo wird eigens erkannt")
    func demoStaysRecognisable() throws {
        let demo = try AppEnvironment.validate(serverURLString: "https://demo.healthlog.dev")
        #expect(AppEnvironment.inferRegion(for: demo) == .demo)
    }

    // MARK: - Passkey-Schranke (GH #65)

    /// `ServerAuthStep.passkeySupportedForHost` zeigt die Schaltflaeche genau
    /// dann, wenn dieses Build eine `webcredentials:`-Domain fuer den
    /// eingerichteten Host mitbringt — iOS laesst eine Assertion sonst gar
    /// nicht zu, und die frueher am Hostnamen haengende Schranke war fuer
    /// jeden Selbst-Hoster falsch.
    @Test("Passkey-Schranke haengt an der Association, nicht am Hostnamen")
    func passkeyGateFollowsAssociation() {
        let rps = ["healthlog.example.com"]
        #expect(AppEnvironment.supportsPasskeys(host: "healthlog.example.com", relyingPartyHosts: rps))
        #expect(AppEnvironment.supportsPasskeys(host: "hl.other.example", relyingPartyHosts: rps) == false)
        #expect(AppEnvironment.supportsPasskeys(host: "demo.healthlog.dev", relyingPartyHosts: rps) == false)
    }

    /// Ein Build ohne lokales Overlay bringt keine Association mit. Dann gibt
    /// es ehrlich keine Passkeys — statt einer Schaltflaeche, die in einen
    /// endlosen Assert laeuft.
    @Test("Build ohne Association bietet nirgends Passkeys an")
    func noAssociationNoPasskeys() {
        #expect(AppEnvironment.supportsPasskeys(host: "healthlog.example.com", relyingPartyHosts: []) == false)
    }

    /// Ein Look-alike darf sich die Association nicht erschleichen: die
    /// Labelgrenze entscheidet, nicht die Zeichenfolge.
    @Test("Look-alike-Host erbt die Association nicht")
    func lookAlikeHostGetsNothing() {
        let rps = ["healthlog.example.com", "*.example.org"]
        #expect(AppEnvironment.supportsPasskeys(host: "healthlog.example.com.attacker.test", relyingPartyHosts: rps) == false)
        #expect(AppEnvironment.supportsPasskeys(host: "evilexample.org", relyingPartyHosts: rps) == false)
    }

    @Test("IdentifiableURL.id identity is the absolute string (no stacked sheets)")
    func urlIdentityIsAbsoluteString() throws {
        let a = try IdentifiableURL(url: #require(URL(string: "https://hl.example.com")))
        let b = try IdentifiableURL(url: #require(URL(string: "https://hl.example.com")))
        let other = try IdentifiableURL(url: #require(URL(string: "https://hl.other.example")))
        // `.sheet(item:)` re-presents only when the item id changes — two
        // probes of the same host must produce the same id so the boundary
        // sheet never stacks on itself. The scoped wrapper keeps this
        // identity off the module-global `URL` type (v0.7.1 H-2).
        #expect(a.id == b.id)
        #expect(a.id == "https://hl.example.com")
        #expect(a.id != other.id)
    }
}
