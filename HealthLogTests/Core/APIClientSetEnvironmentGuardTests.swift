import Foundation

// swiftlint:disable force_unwrapping
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// Locks the M-2 guard around `APIClient.setEnvironment`. Live-swapping the
/// environment mid-session would invalidate whatever Cert-Pin SPKI set the
/// build carries — die gepinnten Hosts kommen aus dem lokalen Betreiber-Overlay
/// und gelten fuer den EINEN Host, gegen den die Session laeuft. The runtime
/// check refuses any swap that fires while an auth token is present in the
/// Keychain, so a future Settings "switch server" affordance fails closed
/// instead of silently breaking the trust chain.
@Suite("APIClient.setEnvironment post-auth guard (M-2)", .serialized)
struct APIClientSetEnvironmentGuardTests {
    private static func makeEnvironment(host: String) -> AppEnvironment {
        AppEnvironment(
            baseURL: URL(string: "https://\(host)"),
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
    }

    private func makeClient(env: AppEnvironment, keychain: InMemoryKeychain) -> APIClient {
        APIClient(
            environment: env,
            keychain: keychain,
            sessionConfiguration: .mock()
        )
    }

    @Test("Pre-auth swap succeeds — current onboarding path")
    func preAuthSwapSucceeds() async {
        let original = Self.makeEnvironment(host: "old.healthlog.local")
        let next = Self.makeEnvironment(host: "new.healthlog.local")
        let kc = InMemoryKeychain()
        // No auth token in keychain → swap must take effect.
        let api = makeClient(env: original, keychain: kc)
        await api.setEnvironment(next)

        let envAfter = await api.environment
        #expect(envAfter.baseURL?.host == "new.healthlog.local")
    }

    @Test("Post-auth swap is rejected — Keychain auth-token present blocks the rotation")
    func postAuthSwapRejected() async {
        let original = Self.makeEnvironment(host: "old.healthlog.local")
        let next = Self.makeEnvironment(host: "attacker.example.com")
        let kc = InMemoryKeychain()
        try? kc.setString("hlk_active_session", forKey: KeychainKey.authToken)
        let api = makeClient(env: original, keychain: kc)

        // Suppress the Debug `assertionFailure` so the test runner can verify
        // the Release branch (early-return) instead of aborting.
        _HLAPIClientTestHook.suppressAssertion = true
        defer { _HLAPIClientTestHook.suppressAssertion = false }

        await api.setEnvironment(next)

        let envAfter = await api.environment
        #expect(
            envAfter.baseURL?.host == "old.healthlog.local",
            "setEnvironment must refuse the swap once an auth-token is in the Keychain — the live session must continue against the previously-pinned host."
        )
    }

    /// **R1 — die Ersteinrichtung ist kein Hostwechsel.**
    ///
    /// Der Waechter oben schuetzt eine laufende Sitzung gegen einen
    /// Host-WECHSEL. Ohne bisherige Adresse gibt es keinen vorherigen Host —
    /// und genau dort hat er den Betreiber ausgesperrt: das Onboarding schrieb
    /// die eingetippte Adresse in den Schluesselbund, `setEnvironment` verweigerte
    /// den Uebergang wegen des noch vorhandenen Tokens, der laufende APIClient
    /// behielt `baseURL == nil` — und jeder Anmeldeversuch danach warf
    /// `serverNotConfigured`, beliebig oft, ohne dass Zurueckgehen etwas
    /// geaendert haette.
    @Test("Ersteinrichtung wird trotz vorhandenem Token uebernommen (R1)")
    func initialConfigurationAcceptedDespiteToken() async {
        let unconfigured = AppEnvironment(
            baseURL: nil,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        let next = Self.makeEnvironment(host: "meinserver.example.com")
        let kc = InMemoryKeychain()
        try? kc.setString("hlk_session_from_previous_build", forKey: KeychainKey.authToken)
        let api = makeClient(env: unconfigured, keychain: kc)

        _HLAPIClientTestHook.suppressAssertion = true
        defer { _HLAPIClientTestHook.suppressAssertion = false }

        await api.setEnvironment(next)

        let envAfter = await api.environment
        #expect(
            envAfter.baseURL?.host == "meinserver.example.com",
            "Ohne bisherige Adresse ist der Uebergang eine Ersteinrichtung, kein Wechsel — ihn zu verweigern sperrt den Nutzer aus."
        )
    }

    @Test("Logout-then-swap is permitted again — token absence re-enables the rotation")
    func swapAfterLogoutPermitted() async {
        let original = Self.makeEnvironment(host: "old.healthlog.local")
        let next = Self.makeEnvironment(host: "self-hosted.example.com")
        let kc = InMemoryKeychain()
        try? kc.setString("hlk_session", forKey: KeychainKey.authToken)
        let api = makeClient(env: original, keychain: kc)

        // First call: guard fires (token present) → no swap.
        _HLAPIClientTestHook.suppressAssertion = true
        defer { _HLAPIClientTestHook.suppressAssertion = false }
        await api.setEnvironment(next)

        // Simulate logout — token cleared.
        try? kc.remove(forKey: KeychainKey.authToken)

        // Second call: no token → swap takes effect.
        await api.setEnvironment(next)

        let envAfter = await api.environment
        #expect(envAfter.baseURL?.host == "self-hosted.example.com")
    }
}
