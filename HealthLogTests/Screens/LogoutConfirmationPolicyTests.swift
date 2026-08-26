import Foundation
@testable import HealthLog
import SwiftUI
import Testing

/// **Phase 08 Plan 09 — the logout confirmation contract, without a view tree.**
///
/// `Phase8AccessibilityUITests.testLogoutConfirmationPreservesSessionOnCancel`
/// asks the product question on a rendered German screen: does a sign-out tap
/// raise anything a user could answer? These ask the three questions a tap
/// coordinate cannot answer deterministically — that presenting is not
/// signing out, that cancelling changes nothing, and that a confirmed logout
/// reaches the existing cleanup exactly once.
///
/// The subject is deliberately a value type plus one static entry point, so
/// every clause below is a direct call rather than a simulated gesture. The
/// call-site half of the contract lives in
/// `LogoutConfirmationPolicyTests+CallSites.swift`.
@MainActor
@Suite("Phase 08 logout confirmation policy")
struct LogoutConfirmationPolicyTests {
    /// A `Binding` the test owns, so the exact entry point the destructive
    /// button calls can be driven directly.
    @MainActor
    final class StateBox {
        var value = LogoutConfirmationState()
        var binding: Binding<LogoutConfirmationState> {
            Binding(get: { self.value }, set: { self.value = $0 })
        }
    }

    /// Counts how often the injected logout path actually ran.
    @MainActor
    final class LogoutSpy {
        private(set) var runs = 0
        var perform: @MainActor () async -> Void {
            { self.runs += 1 }
        }
    }

    // MARK: - RED closure: presenting is not signing out

    @Test("presenting the confirmation never reaches the logout path")
    func presentationHasNoDestructiveSideEffect() {
        let box = StateBox()
        let spy = LogoutSpy()

        // Nothing has been asked, so nothing may be confirmed. This is the
        // clause that makes the dialog a gate rather than a decoration: the
        // destructive branch is unreachable from a surface that never put the
        // consequence on screen.
        #expect(LogoutConfirmation.confirm(box.binding, perform: spy.perform) == nil)
        #expect(spy.runs == 0)
        #expect(box.value.stage == .idle)

        box.value.request()
        #expect(box.value.isAsking, "the dialog must be presented by a request")
        #expect(!box.value.isSigningOut)
        #expect(spy.runs == 0, "presentation alone must not run the cleanup")
    }

    // MARK: - RED closure: cancel is non-destructive

    @Test("cancelling leaves the session and the state exactly as they were")
    func cancelIsNonDestructive() {
        let box = StateBox()
        let spy = LogoutSpy()

        box.value.request()
        // SwiftUI lowers the dialog before it runs the tapped button's action,
        // so the real sequence is always "lowered, then answered".
        box.value.dialogWasLowered()
        box.value.cancel()

        #expect(box.value.stage == .idle)
        #expect(!box.value.isAsking)
        #expect(!box.value.isSigningOut)
        #expect(spy.runs == 0, "a cancelled dialog must not have run the cleanup")
        #expect(
            LogoutConfirmation.confirm(box.binding, perform: spy.perform) == nil,
            "a cancelled dialog must not stay answerable"
        )
        #expect(spy.runs == 0)
    }

    // MARK: - RED closure: one confirmed answer, one cleanup

    @Test("the destructive answer runs the injected logout exactly once")
    func confirmationRunsTheSingleLogoutPathOnce() async {
        let box = StateBox()
        let spy = LogoutSpy()

        box.value.request()
        box.value.dialogWasLowered()
        let first = LogoutConfirmation.confirm(box.binding, perform: spy.perform)
        #expect(first != nil, "the destructive answer must start the cleanup")
        #expect(box.value.isSigningOut)

        // A second answer while the first is in flight — a double tap, or a
        // second surface reached through the same state — is refused rather
        // than queued behind it.
        #expect(LogoutConfirmation.confirm(box.binding, perform: spy.perform) == nil)
        // And nothing may re-open the question underneath a running cleanup.
        box.value.request()
        #expect(box.value.isSigningOut, "a re-request must not interrupt a logout in flight")

        await first?.value
        #expect(spy.runs == 1, "the cleanup ran \(spy.runs) times")
        #expect(box.value.stage == .idle, "the surface must be answerable again afterwards")
    }

    // MARK: - Preservation: one localized consequence for all three contexts

    @Test("the confirmation copy is one localized contract in de and en")
    func copyIsLocalizedAndNamesTheConsequence() throws {
        let catalog = try ParityCatalog.load()
        var violations: [String] = []

        let keys = [
            "Sign out?",
            "You will need to sign in again with your HealthLog account afterwards.",
            "Sign out",
            "Cancel"
        ]
        for key in keys {
            guard let entry = catalog.strings[key] else {
                violations.append("the catalogue has no key for \(key)")
                continue
            }
            for language in ["de", "en"] where ParityCatalog.value(entry, language: language) == nil {
                violations.append("\(key) has no \(language) value")
            }
        }

        // The consequence has to be a sentence about signing in again, not a
        // restatement of the question — otherwise the dialog is a speed bump
        // that says the same thing twice.
        if let consequence = catalog.strings[
            "You will need to sign in again with your HealthLog account afterwards."
        ] {
            for (language, expected) in [("de", "anmelden"), ("en", "sign in again")]
                where ParityCatalog.value(consequence, language: language)?
                .localizedCaseInsensitiveContains(expected) != true
            {
                violations.append("the \(language) consequence does not say what happens next")
            }
        }

        #expect(violations.isEmpty, "\(violations)")
    }
}
