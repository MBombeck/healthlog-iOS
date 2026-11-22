import Foundation
@testable import HealthLog
import Testing

/// audit 02 · C-2 — locks the onboarding back-navigation mapping.
///
/// Before this change `OnboardingFlow.step` only ever moved forward: a user who
/// confirmed a wrong server URL or got stuck in the auth step could escape only
/// by force-quitting. `previousStep` now defines a reversible predecessor for
/// every step up to (but never across) the authentication boundary. We test the
/// pure decision, not the SwiftUI view.
@Suite("Onboarding — back navigation")
struct OnboardingBackNavTests {
    @Test("the serverURL ↔ auth pair is reversible (the force-quit trap is gone)")
    func serverURLAuthPairReversible() {
        // The audit's key ask: from auth you can return to serverURL, and from
        // serverURL back to Welcome — both have a predecessor.
        #expect(
            OnboardingFlow.previousStep(from: .auth)
                == .serverURL
        )
        #expect(
            OnboardingFlow.previousStep(from: .serverURL)
                == .welcome
        )
    }

    @Test("welcome and done have no predecessor")
    func terminalsHaveNoBack() {
        #expect(
            OnboardingFlow.previousStep(from: .welcome) == nil
        )
        #expect(
            OnboardingFlow.previousStep(from: .done) == nil
        )
    }

    @Test("post-auth boundary: healthKit never walks back across login")
    func healthKitNoBackAcrossLogin() {
        // The user is authenticated by the time HealthKit shows; a back tap
        // must NOT return them to the login form.
        #expect(
            OnboardingFlow.previousStep(from: .healthKit) == nil
        )
    }

    @Test("optional post-auth steps chain backward among themselves")
    func optionalStepsChainBack() {
        #expect(
            OnboardingFlow.previousStep(from: .notifications)
                == .healthKit
        )
        #expect(
            OnboardingFlow.previousStep(from: .aiSource)
                == .notifications
        )
        #expect(
            OnboardingFlow.previousStep(from: .anamnesis)
                == .aiSource
        )
        #expect(
            OnboardingFlow.previousStep(from: .baselineProfile)
                == .anamnesis
        )
    }

    // MARK: - One route, and everything derived from it

    @Test("the route has eight steps")
    func serverRouteHasEightSteps() {
        let route = OnboardingFlow.activeRoute()
        #expect(route == [
            .welcome, .serverURL, .auth, .healthKit, .notifications, .aiSource, .anamnesis, .baselineProfile
        ])
        // The three transient states are not route positions.
        for transient in [OnboardingFlow.Step.checkingCompletion, .completionUnavailable, .done] {
            #expect(!route.contains(transient))
        }
    }

    @Test("progress counts the route the user is on, not a fixed six")
    func progressDenominatorFollowsTheBranch() {
        let server = OnboardingFlow.progress(for: .auth)
        #expect(server.total == 8)
        #expect(server.position == 3)
        #expect(abs(server.fraction - 3.0 / 8.0) < 0.0001)
    }

    @Test("progress advances strictly along the route it describes")
    func progressIsMonotonicAlongTheRoute() {
        let route = OnboardingFlow.activeRoute()
        var previous = 0.0
        for (offset, step) in route.enumerated() {
            let progress = OnboardingFlow.progress(for: step)
            #expect(progress.position == offset + 1)
            #expect(progress.fraction > previous, "\(step) must be further along than its predecessor")
            previous = progress.fraction
        }
        #expect(abs(previous - 1.0) < 0.0001, "the last route step must complete the bar")
    }

    @Test("the two lookup surfaces stand where the login left the user")
    func lookupStepsAnchorToAuth() {
        let auth = OnboardingFlow.progress(for: .auth)
        for step in [OnboardingFlow.Step.checkingCompletion, .completionUnavailable] {
            let progress = OnboardingFlow.progress(for: step)
            #expect(progress.position == auth.position, "\(step) is not a route position of its own")
            #expect(progress.total == auth.total)
            // The label still names the state — only the position is borrowed.
            #expect(progress.label != auth.label)
        }
    }

    @Test("the terminal handoff completes the route it finished")
    func doneCompletesTheRoute() {
        let done = OnboardingFlow.progress(for: .done)
        #expect(done.position == done.total)
        #expect(abs(done.fraction - 1.0) < 0.0001)
    }

    @Test("the spoken value names a position and the label names a step")
    func spokenProgressNamesTheRoute() {
        let progress = OnboardingFlow.progress(for: .healthKit)
        // The value has to carry two numbers — where, out of how many — and the
        // label has to carry none, because a count baked into a translation
        // cannot follow a branch. "Step 4 of 6: Apple Health" was both wrong and
        // untranslatable per route.
        #expect(progress.value.contains("\(progress.position)"))
        #expect(progress.value.contains("\(progress.total)"))
        #expect(!progress.label.isEmpty)
        #expect(progress.label.rangeOfCharacter(from: .decimalDigits) == nil)
        // And it is not the raw percentage the indicator used to speak.
        #expect(progress.value.range(of: "^[0-9]+ percent$", options: .regularExpression) == nil)
    }

    @Test("the two route-progress copy keys resolve")
    func routeProgressKeysResolve() {
        for key in ["onboarding.progress.welcome", "onboarding.progress.position"] {
            let value = String(localized: String.LocalizationValue(key))
            #expect(!value.isEmpty && value != key, "missing route-progress key: \(key)")
        }
    }

    /// The update path for a deleted key.
    ///
    /// `"Step 1 of 6: Welcome"` was removed from the catalogue in the same
    /// commit that stopped referencing it, and its replacement has to hold the
    /// property the old one broke: the welcome step is still spoken, and what is
    /// spoken no longer contains a count that only one branch could ever have
    /// produced.
    @Test("the welcome step is still spoken, and no longer names a count")
    func welcomeStepStillSpeaksWithoutACount() {
        let welcome = OnboardingFlow.progress(for: .welcome)
        #expect(!welcome.label.isEmpty)
        #expect(welcome.label.rangeOfCharacter(from: .decimalDigits) == nil)
        #expect(welcome.position == 1)
        #expect(welcome.value.contains("\(welcome.total)"))
    }
}
