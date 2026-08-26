import Foundation
@testable import HealthLog
import Testing

/// audit 02 · C-2 — locks the onboarding back-navigation mapping.
///
/// Before this change `OnboardingFlow.step` only ever moved forward: a user who
/// confirmed a wrong server URL or got stuck in the auth step could escape only
/// by force-quitting. `previousStep` now defines a reversible predecessor for
/// every step up to (but never across) the authentication boundary. We test the
/// pure decision, not the SwiftUI view — mirroring `OnboardingStandaloneGateTests`.
@Suite("Onboarding — back navigation")
struct OnboardingBackNavTests {
    @Test("the serverURL ↔ auth pair is reversible (the force-quit trap is gone)")
    func serverURLAuthPairReversible() {
        // The audit's key ask: from auth you can return to serverURL, and from
        // serverURL back to Welcome — both have a predecessor.
        #expect(
            OnboardingFlow.previousStep(from: .auth, chosenMode: .server, standaloneModeAvailable: false)
                == .serverURL
        )
        #expect(
            OnboardingFlow.previousStep(from: .serverURL, chosenMode: .server, standaloneModeAvailable: false)
                == .welcome
        )
    }

    @Test("serverURL returns to the mode fork when standalone selection is available")
    func serverURLBackToModeWhenForkShown() {
        #expect(
            OnboardingFlow.previousStep(from: .serverURL, chosenMode: .server, standaloneModeAvailable: true)
                == .mode
        )
    }

    @Test("legacy demo state uses the ordinary server predecessor")
    func legacyDemoAuthBackToServerURL() {
        #expect(
            OnboardingFlow.previousStep(from: .auth, chosenMode: .demo, standaloneModeAvailable: true)
                == .serverURL
        )
    }

    @Test("welcome and done have no predecessor")
    func terminalsHaveNoBack() {
        #expect(
            OnboardingFlow.previousStep(from: .welcome, chosenMode: nil, standaloneModeAvailable: false) == nil
        )
        #expect(
            OnboardingFlow.previousStep(from: .done, chosenMode: .server, standaloneModeAvailable: false) == nil
        )
    }

    @Test("post-auth boundary: healthKit never walks back across login")
    func healthKitNoBackAcrossLogin() {
        // Server mode is authenticated by the time HealthKit shows; a back tap
        // must NOT return it to the login form. The legacy `.demo` value follows
        // the same post-auth boundary but no longer has an entry path.
        #expect(
            OnboardingFlow.previousStep(from: .healthKit, chosenMode: .server, standaloneModeAvailable: false) == nil
        )
        #expect(
            OnboardingFlow.previousStep(from: .healthKit, chosenMode: .demo, standaloneModeAvailable: false) == nil
        )
    }

    @Test("optional post-auth steps chain backward among themselves")
    func optionalStepsChainBack() {
        #expect(
            OnboardingFlow.previousStep(from: .notifications, chosenMode: .server, standaloneModeAvailable: false)
                == .healthKit
        )
        #expect(
            OnboardingFlow.previousStep(from: .aiSource, chosenMode: .server, standaloneModeAvailable: false)
                == .notifications
        )
        #expect(
            OnboardingFlow.previousStep(from: .anamnesis, chosenMode: .server, standaloneModeAvailable: false)
                == .aiSource
        )
        #expect(
            OnboardingFlow.previousStep(from: .baselineProfile, chosenMode: .server, standaloneModeAvailable: false)
                == .anamnesis
        )
    }

    // MARK: - 08-10: one route, and everything derived from it

    @Test("a standalone install's route omits the steps it never walks")
    func standaloneRouteOmitsServerSteps() {
        let standalone = OnboardingFlow.activeRoute(chosenMode: .standalone, standaloneModeAvailable: true)
        #expect(standalone == [.welcome, .mode, .healthKit, .notifications, .aiSource])
        // Absent, not zero-weighted: this is what makes a skipped step
        // uncounted rather than invisibly counted.
        for absent in [OnboardingFlow.Step.serverURL, .auth, .anamnesis, .baselineProfile] {
            #expect(!standalone.contains(absent), "\(absent) is not on the standalone route")
        }
    }

    @Test("a server-mandatory install's route has no mode fork and eight steps")
    func serverRouteSkipsTheFork() {
        let route = OnboardingFlow.activeRoute(chosenMode: .server, standaloneModeAvailable: false)
        #expect(route == [
            .welcome, .serverURL, .auth, .healthKit, .notifications, .aiSource, .anamnesis, .baselineProfile
        ])
        #expect(!route.contains(.mode))
        // The three transient states are not route positions.
        for transient in [OnboardingFlow.Step.checkingCompletion, .completionUnavailable, .done] {
            #expect(!route.contains(transient))
        }
    }

    @Test("progress counts the route the user is on, not a fixed six")
    func progressDenominatorFollowsTheBranch() {
        let server = OnboardingFlow.progress(for: .auth, chosenMode: .server, standaloneModeAvailable: false)
        #expect(server.total == 8)
        #expect(server.position == 3)
        #expect(abs(server.fraction - 3.0 / 8.0) < 0.0001)

        let standalone = OnboardingFlow.progress(
            for: .healthKit,
            chosenMode: .standalone,
            standaloneModeAvailable: true
        )
        // Five steps, and HealthKit is the third of them — under the old
        // fraction table the same screen reported 0.66 of a six-step route the
        // user was not walking.
        #expect(standalone.total == 5)
        #expect(standalone.position == 3)
    }

    @Test("progress advances strictly along the route it describes")
    func progressIsMonotonicAlongTheRoute() {
        let route = OnboardingFlow.activeRoute(chosenMode: .server, standaloneModeAvailable: false)
        var previous = 0.0
        for (offset, step) in route.enumerated() {
            let progress = OnboardingFlow.progress(
                for: step,
                chosenMode: .server,
                standaloneModeAvailable: false
            )
            #expect(progress.position == offset + 1)
            #expect(progress.fraction > previous, "\(step) must be further along than its predecessor")
            previous = progress.fraction
        }
        #expect(abs(previous - 1.0) < 0.0001, "the last route step must complete the bar")
    }

    @Test("the two lookup surfaces stand where the login left the user")
    func lookupStepsAnchorToAuth() {
        let auth = OnboardingFlow.progress(for: .auth, chosenMode: .server, standaloneModeAvailable: false)
        for step in [OnboardingFlow.Step.checkingCompletion, .completionUnavailable] {
            let progress = OnboardingFlow.progress(for: step, chosenMode: .server, standaloneModeAvailable: false)
            #expect(progress.position == auth.position, "\(step) is not a route position of its own")
            #expect(progress.total == auth.total)
            // The label still names the state — only the position is borrowed.
            #expect(progress.label != auth.label)
        }
    }

    @Test("the terminal handoff completes the route it finished")
    func doneCompletesTheRoute() {
        for (mode, available) in [(OnboardingMode.server, false), (.standalone, true)] {
            let done = OnboardingFlow.progress(for: .done, chosenMode: mode, standaloneModeAvailable: available)
            #expect(done.position == done.total)
            #expect(abs(done.fraction - 1.0) < 0.0001)
        }
    }

    @Test("the spoken value names a position and the label names a step")
    func spokenProgressNamesTheRoute() {
        let progress = OnboardingFlow.progress(for: .healthKit, chosenMode: .server, standaloneModeAvailable: false)
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
    /// produced. Every route's first step is checked, not just the server one.
    @Test("the welcome step is still spoken, and no longer names a count")
    func welcomeStepStillSpeaksWithoutACount() {
        for (mode, available) in [(OnboardingMode.server, false), (.server, true), (.standalone, true)] {
            let welcome = OnboardingFlow.progress(for: .welcome, chosenMode: mode, standaloneModeAvailable: available)
            #expect(!welcome.label.isEmpty)
            #expect(welcome.label.rangeOfCharacter(from: .decimalDigits) == nil)
            #expect(welcome.position == 1)
            #expect(welcome.value.contains("\(welcome.total)"))
        }
    }
}
