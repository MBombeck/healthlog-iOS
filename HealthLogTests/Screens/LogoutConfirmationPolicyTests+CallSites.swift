import Foundation
@testable import HealthLog
import Testing

/// The call-site half of Plan 08-09's contract: the policy is worth nothing if
/// a surface can still reach the cleanup without it.
///
/// These are source contracts, so they read comment-stripped source over a
/// bounded range — a doc comment naming a symbol is not the symbol, and a
/// tombstone describing what was removed would otherwise keep every removal
/// clause passing forever. The clauses live in a sibling file so the primary
/// suite's body stays well under `type_body_length`.
extension LogoutConfirmationPolicyTests {
    // MARK: - RED closure: no release logout is one tap deep

    @Test("every release-visible logout entry is reached through the shared confirmation")
    func releaseLogoutEntriesRequireConfirmation() throws {
        var violations: [String] = []

        // 1. Settings → Konto → Abmelden.
        let account = try Self.strippedSource("HealthLog/Screens/Settings/Sub/SettingsAccountScreen.swift")
        if let card = Phase8SourceScan.member(named: "private var signOutCard: some View {", in: account) {
            if card.contains("logout(") {
                violations.append("the Settings sign-out row still calls the logout path from its tap handler")
            }
            if !card.contains("logoutConfirmation.request()") {
                violations.append("the Settings sign-out row does not ask before it acts")
            }
        } else {
            violations.append("SettingsAccountScreen no longer declares signOutCard — restate this contract")
        }
        violations += Self.sharedPolicyViolations(
            in: account,
            named: "Settings",
            cleanup: "await authStore.logout()"
        )

        // 2. The forced second-factor gate, whose only escape is signing out.
        let gate = try Self.strippedSource("HealthLog/Screens/Onboarding/MfaEnrollmentGateSheet.swift")
        if let actions = Phase8SourceScan.member(named: "private var actions: some View {", in: gate) {
            if actions.contains("onSignOut(") {
                violations.append("the MFA gate still signs out from its tap handler")
            }
            if !actions.contains("logoutConfirmation.request()") {
                violations.append("the MFA gate does not ask before it acts")
            }
        } else {
            violations.append("MfaEnrollmentGateSheet no longer declares actions — restate this contract")
        }
        violations += Self.sharedPolicyViolations(in: gate, named: "the MFA gate", cleanup: "await onSignOut()")

        // 3. The locked session. Bounded to the protected branch, because the
        //    unprotected one legitimately hands the same cleanup to the gate.
        let root = try Self.strippedSource("HealthLog/App/RootView.swift")
        if let shield = Phase8SourceScan.member(named: "RootPrivacyShield(", in: root, closing: ")") {
            if shield.contains("logout(") {
                violations.append("the locked session still signs out straight from the shield's button")
            }
            if !shield.contains("lockLogoutConfirmation.request()") {
                violations.append("the locked session does not ask before it acts")
            }
        } else {
            violations.append("RootView no longer composes RootPrivacyShield — restate this contract")
        }
        if let protected = Self.region(
            from: "case let .protected(reason):",
            to: "case .unprotected:",
            in: root
        ) {
            violations += Self.sharedPolicyViolations(
                in: protected,
                named: "the locked session",
                cleanup: "await authStore.logout()"
            )
        } else {
            violations.append("RootView no longer branches on the privacy shield — restate this contract")
        }

        #expect(violations.isEmpty, "\(violations)")
    }

    // MARK: - Preservation: the policy layer stays state-agnostic and native

    @Test("the confirmation layer owns presentation only, and it is native")
    func policyLayerOwnsNoAuthState() throws {
        let policy = try Self.strippedSource("HealthLog/DesignSystem/LogoutConfirmationModifier.swift")
        var violations: [String] = []

        // It presents; it does not know who is signed in and it cleans nothing
        // up. Everything destructive stays behind the injected closure.
        for forbidden in ["AuthStore", "AppContainer", "authStore", "@Environment", "URLSession", "UserDefaults"]
            where policy.contains(forbidden)
        {
            violations.append("the confirmation layer reaches \(forbidden); it may only present")
        }

        // Native, destructive, and cancellable — an imitation would lose the
        // platform's own destructive semantics and VoiceOver treatment.
        //
        // **Where that evidence lives moved with R13-A1 (17-08), and the
        // clause moved with it rather than being dropped.** The logout question
        // is no longer built here; it is carried by `hlConfirmDestructive`,
        // which every destructive confirmation in the app now shares. So this
        // asks the modifier for the routing and the carrier for the semantics.
        // `titleVisibility: .visible` has no successor and needs none: it
        // existed to stop a `confirmationDialog` from hiding its own question,
        // and an `alert` always shows its title. Dropping it silently would
        // have been the weakening; saying why is not.
        if !policy.contains(".hlConfirmDestructive(") {
            violations.append("the confirmation no longer routes through the shared destructive carrier")
        }
        let carrier = try Self.strippedSource("HealthLog/DesignSystem/HLConfirmDestructive.swift")
        for required in ["alert(", "role: .destructive", "role: .cancel"] where !carrier.contains(required) {
            violations.append("the shared destructive carrier is no longer \(required)")
        }

        #expect(violations.isEmpty, "\(violations)")
    }

    // MARK: - Helpers

    /// The two clauses every context shares: it applies the one policy, and the
    /// cleanup it always ran is still the thing the answer reaches.
    static func sharedPolicyViolations(in source: String, named context: String, cleanup: String) -> [String] {
        var violations: [String] = []
        if !source.contains(".hlLogoutConfirmation(") {
            violations.append("\(context) does not apply the shared logout confirmation")
        }
        if !source.contains(cleanup) {
            violations.append("\(context) no longer reaches its existing cleanup (\(cleanup))")
        }
        return violations
    }

    /// **Line comments come off first, and the order is load-bearing.** The
    /// shared `Phase8SourceScan.stripped` strips block comments first, which
    /// truncates a whole file when a `/*` sits inside a `//` comment — a live
    /// hazard four Phase-8 REDs share (08-15 wrote it up). Removing `//` lines
    /// first makes such a `/*` disappear with the comment it lives in. The
    /// shared helper is deliberately not changed here: its assertions are
    /// load-bearing for other plans.
    static func strippedSource(_ relativePath: String) throws -> String {
        let text = try String(
            contentsOf: Phase8SourceScan.repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
        return stripBlockComments(from: stripLineComments(from: text))
    }

    /// The text between two landmarks, so a clause about one switch branch can
    /// never read the branch next to it.
    static func region(from start: String, to end: String, in source: String) -> String? {
        guard let lower = source.range(of: start) else { return nil }
        guard let upper = source.range(of: end, range: lower.upperBound ..< source.endIndex) else { return nil }
        return String(source[lower.upperBound ..< upper.lowerBound])
    }

    private static func stripBlockComments(from source: String) -> String {
        var out = ""
        var rest = Substring(source)
        while let open = rest.range(of: "/*") {
            out += rest[..<open.lowerBound]
            guard let close = rest.range(of: "*/", range: open.upperBound ..< rest.endIndex) else { return out }
            rest = rest[close.upperBound...]
        }
        return out + rest
    }

    private static func stripLineComments(from source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var quoted = false
            var previous: Character = " "
            for (offset, character) in line.enumerated() {
                if character == "\"", previous != "\\" { quoted.toggle() }
                if !quoted, character == "/", previous == "/" { return String(line.prefix(max(0, offset - 1))) }
                previous = character
            }
            return String(line)
        }.joined(separator: "\n")
    }
}
