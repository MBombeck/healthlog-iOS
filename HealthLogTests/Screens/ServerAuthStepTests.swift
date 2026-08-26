import Foundation
@testable import HealthLog
import Testing

/// Auth-step routing and configured-server policy contracts.
@Suite("ServerAuthStep configured server", .serialized)
struct ServerAuthStepTests {
    // MARK: - parity 2.9 — pre-login privacy link targets the CONFIGURED server

    // The forgot-password tests that lived here are gone with the affordance
    // itself: `<base>/forgot-password` is not a route the server app serves
    // (`src/app` has no such page), so audit 02 · C-1 had only made the link
    // point its 404 at the right host. The privacy link below is the same
    // configured-base-URL contract applied to a route that DOES exist.

    @Test("privacy link uses the configured server")
    @MainActor
    func privacyLinkUsesConfiguredServer() throws {
        let kc = InMemoryKeychain()
        try kc.setString("https://meinserver.example.com", forKey: KeychainKey.serverURL)
        let url = try #require(ServerAuthStep.privacyPolicyURL(keychain: kc))
        #expect(url.host == "meinserver.example.com")
        #expect(url.path == "/privacy")
    }

    /// Ohne eingerichteten Server gibt es keine Instanz, deren
    /// Datenschutzerklaerung wir zeigen koennten — der Link entfaellt, statt
    /// auf einen erfundenen Host zu zeigen.
    @Test("Ohne Server gibt es keinen Privacy-Link")
    @MainActor
    func privacyLinkAbsentWithoutServer() {
        #expect(ServerAuthStep.privacyPolicyURL(keychain: nil) == nil)
    }

    @Test("Settings → About privacy link also resolves against the configured server")
    @MainActor
    func aboutPrivacyLinkUsesConfiguredServer() throws {
        let kc = InMemoryKeychain()
        try kc.setString("https://meinserver.example.com", forKey: KeychainKey.serverURL)
        let url = try #require(SettingsAboutScreen.privacyPolicyURL(keychain: kc))
        #expect(url.host == "meinserver.example.com")
        #expect(url.path == "/privacy")
    }

    // MARK: - #65 — web-handoff gate

    @Test("prefersWebHandoff — the demo host keeps the native form (scripted review login)")
    @MainActor
    func webHandoffFalseForDemoHost() throws {
        let kc = InMemoryKeychain()
        try kc.setString("https://demo.healthlog.dev", forKey: KeychainKey.serverURL)
        #expect(ServerAuthStep.prefersWebHandoff(keychain: kc) == false)
    }

    /// Der native Weg kann die Passkeys / den Passwortmanager dieses Hosts
    /// nicht binden, solange das Build keine Association dafuer mitbringt —
    /// genau dann ist der Browser auf der eigenen Origin die bessere Tuer.
    @Test("prefersWebHandoff — ein selbst gehosteter Host ohne Association ist der Kandidat")
    @MainActor
    func webHandoffTrueForSelfHosted() throws {
        let kc = InMemoryKeychain()
        try kc.setString("https://meinserver.example.com", forKey: KeychainKey.serverURL)
        // Die Vorbedingung ist, dass GENAU DIESER Host nicht gedeckt ist —
        // nicht, dass das Bundle ueberhaupt keine Associations mitbringt.
        // Die frühere Fassung prüfte Letzteres und war damit auf jeder
        // Maschine mit lokalem Overlay rot, also auch im Ship-Tor.
        #expect(AppEnvironment.supportsPasskeys(host: "meinserver.example.com") == false)
        #expect(ServerAuthStep.prefersWebHandoff(keychain: kc) == true)
    }

    /// Kein stiller Rueckschritt: wer sein Build MIT passender Association
    /// baut, behaelt den nativen Weg samt Passkey-Schaltflaeche und wird
    /// nicht ploetzlich in den Browser geschickt.
    @Test("Ein gedeckter Host behaelt den nativen Weg")
    @MainActor
    func coveredHostKeepsNativeForm() {
        // Reine Regelform, ohne Info.plist-Attrappe: gedeckt ⇒ kein Handoff.
        #expect(AppEnvironment.supportsPasskeys(
            host: "meinserver.example.com",
            relyingPartyHosts: ["meinserver.example.com"]
        ))
    }

    @Test("prefersWebHandoff — a nil keychain is fail-closed to false")
    @MainActor
    func webHandoffFalseForNilKeychain() {
        #expect(ServerAuthStep.prefersWebHandoff(keychain: nil) == false)
    }

    // MARK: - Phase 09 / plan 09-03 — the pure helpers and the value snapshot agree

    /// The four screens render from ``ConfiguredServerSnapshot`` now, while these
    /// `keychain:`-injected helpers are retained for the link tests above. Two
    /// spellings of the same answer is exactly how a refactor drifts, so this
    /// pins them together at every case the screens can be in: a configured
    /// self-hosted host, the demo host, and no server at all.
    @Test("the retained keychain helpers and the rendered snapshot answer alike")
    @MainActor
    func retainedHelpersAgreeWithTheSnapshot() throws {
        for host in ["meinserver.example.com", "demo.healthlog.dev"] {
            let kc = InMemoryKeychain()
            try kc.setString("https://\(host)", forKey: KeychainKey.serverURL)
            let snapshot = ConfiguredServerSnapshot.resolve(keychain: kc)

            #expect(snapshot.host == host)
            #expect(ServerAuthStep.privacyPolicyURL(keychain: kc) == snapshot.privacyPolicyURL)
            #expect(SettingsAboutScreen.privacyPolicyURL(keychain: kc) == snapshot.privacyPolicyURL)
            #expect(AccountSecurityWebLink.url(keychain: kc) == snapshot.accountSecurityURL)
            #expect(ServerAuthStep.prefersWebHandoff(keychain: kc) == snapshot.prefersWebHandoff)
        }

        // No server configured: the links are absent rather than pointed at an
        // invented host, and the web handoff stays fail-closed.
        let empty = InMemoryKeychain()
        let unconfigured = ConfiguredServerSnapshot.resolve(keychain: empty)
        #expect(unconfigured.baseURL == AppEnvironment.loadFromBundle().baseURL)
        #expect(ServerAuthStep.privacyPolicyURL(keychain: empty) == unconfigured.privacyPolicyURL)
        #expect(AccountSecurityWebLink.url(keychain: empty) == unconfigured.accountSecurityURL)
        #expect(ServerAuthStep.prefersWebHandoff(keychain: empty) == unconfigured.prefersWebHandoff)
    }
}
