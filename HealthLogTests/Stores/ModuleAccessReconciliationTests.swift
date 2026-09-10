import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **Audit A-7, fix round 1 — the disagreement fallback has to cover the
/// switchboard, and the PATCH echo must not leave a reason behind.**
///
/// `ModuleGate.offReason(_:)` already refuses to explain a module whose two
/// halves disagree: the boolean wins and no sentence is shown, because a wrong
/// explanation is worse than none. The switchboard did not go through it — it
/// read the RAW `accessState(_:)` and fed that straight into
/// `rowPresentation(for:)`, so the one surface that turns a reason into a
/// LOCKED SWITCH was the one surface without the guard.
///
/// That is reachable, not theoretical. `setEnabled` replaces `modules` wholesale
/// from the PATCH echo but mirrors `moduleAccess` for the toggled key only. A
/// sibling key whose boolean moved server-side in the same round-trip therefore
/// kept its old access entry — and the row for that sibling could show a reason
/// with its switch disabled while `isOn` said the opposite.
///
/// The two switchboard cases go through `rowPresentation(gate:key:)` — the same
/// call `moduleToggleRow` makes — rather than resolving the state themselves and
/// handing the answer to `rowPresentation(for:)`. Resolving it here is what let
/// an earlier round of this suite stay green over a screen that read the raw
/// map: the assertion pinned the RULE and left the WIRING unwatched.
@MainActor
@Suite("Audit A-7 — reconciled access state (fix round 1)", .serialized)
struct ModuleAccessReconciliationTests {
    private func makeGate(modules: [String: Bool], access: [String: ModuleAccessState]) -> ModuleGate {
        ModuleGate(modules: modules, moduleAccess: access)
    }

    // MARK: - The reconciled accessor

    @Test("A key whose two halves disagree has no reconciled state, in both directions")
    func disagreementYieldsNoState() {
        // ON, but the map says the grant does not cover it.
        let onButNotGranted = makeGate(modules: ["labs": true], access: ["labs": .notGranted])
        #expect(onButNotGranted.accessState(.labs) == .notGranted, "the raw map is unchanged")
        #expect(onButNotGranted.reconciledAccessState(.labs) == nil)
        // OFF, but the map claims enabled.
        let offButEnabled = makeGate(modules: ["labs": false], access: ["labs": .enabled])
        #expect(offButEnabled.reconciledAccessState(.labs) == nil)
    }

    @Test("An agreeing key reconciles to exactly what the server said")
    func agreementPassesThrough() {
        let gate = makeGate(
            modules: ["labs": true, "illness": false, "nutrients": false],
            access: ["labs": .enabled, "illness": .disabled, "nutrients": .notGranted]
        )
        #expect(gate.reconciledAccessState(.labs) == .enabled)
        #expect(gate.reconciledAccessState(.illness) == .disabled)
        #expect(gate.reconciledAccessState(.nutrients) == .notGranted)
        // Absent map / absent key stay `nil` — the absence of a state, as before.
        #expect(ModuleGate(modules: ["labs": false]).reconciledAccessState(.labs) == nil)
        #expect(makeGate(modules: ["labs": false], access: ["mood": .enabled]).reconciledAccessState(.labs) == nil)
    }

    @Test("offReason routes through the same reconciliation")
    func offReasonUsesTheReconciledState() {
        #expect(makeGate(modules: ["labs": true], access: ["labs": .notGranted]).offReason(.labs) == nil)
        #expect(makeGate(modules: ["labs": false], access: ["labs": .notGranted]).offReason(.labs) != nil)
    }

    // MARK: - The switchboard row, end to end

    @Test("A sibling row carrying disagreeing data is interactive and shows no reason")
    func switchboardRowFallsBackOnDisagreement() {
        // The Critical case: the server moved `labs` ON in the echo, the stale
        // access entry still says `not_granted`. The row must read as the
        // boolean does — on, and the person's own switch — never as a locked
        // switch beside a sentence that contradicts it.
        let gate = makeGate(modules: ["labs": true], access: ["labs": .notGranted])

        let row = SettingsModulesScreen.rowPresentation(gate: gate, key: .labs)

        #expect(row.isSwitchOffered == true, "the switch must not be locked by a reason the boolean contradicts")
        #expect(row.reasonKey == nil, "a wrong explanation is worse than none")
        #expect(gate.isEnabled(.labs) == true)
    }

    @Test("An agreeing not_granted row is still locked and still explains itself")
    func switchboardRowStillLocksOnAgreement() {
        let gate = makeGate(modules: ["nutrients": false], access: ["nutrients": .notGranted])

        let row = SettingsModulesScreen.rowPresentation(gate: gate, key: .nutrients)

        #expect(row.isSwitchOffered == false)
        #expect(row.reasonKey == ModuleAccessState.notGranted.offReasonKey)
    }

    // MARK: - The PATCH echo

    @Test("The PATCH echo drops every access entry its booleans no longer agree with")
    func patchEchoClearsStaleSiblings() async {
        // `illness` was `not_granted` (off). The echo of a `labs` toggle reports
        // it ON — the grant changed server-side between the two hops. The
        // sibling's stale reason must not survive that.
        MockURLProtocol.handler = { req in
            let body = Data(#"{"data":{"modules":{"labs":true,"illness":true,"nutrients":false}},"error":null}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let env = AppEnvironment(
            // `baseURL` is `URL?` — no unwrap, and nothing for a formatter to
            // rewrite into a redundant `#require`.
            baseURL: URL(string: "https://test.healthlog.local"),
            bundleID: "dev.healthlog.app",
            appVersion: "1.38.15",
            buildNumber: "1"
        )
        let keychain = InMemoryKeychain()
        try? keychain.setString("token", forKey: KeychainKey.authToken)
        let gate = ModuleGate(
            repo: ModuleGateRepository(
                api: APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock())
            ),
            modules: ["labs": false, "illness": false, "nutrients": false],
            moduleAccess: ["labs": .disabled, "illness": .notGranted, "nutrients": .notGranted]
        )

        let ok = await gate.setEnabled(.labs, enabled: true)

        #expect(ok)
        #expect(gate.isEnabled(.illness) == true)
        #expect(gate.accessState(.illness) == nil, "a reason the echoed boolean contradicts is dropped, not kept")
        // The toggled key is mirrored, and an untouched agreeing sibling stands.
        #expect(gate.accessState(.labs) == .enabled)
        #expect(gate.accessState(.nutrients) == .notGranted)
    }
}

// swiftlint:enable force_unwrapping
