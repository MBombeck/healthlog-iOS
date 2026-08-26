import Foundation
@testable import HealthLog
import Testing

/// **Phase 08 Plan 10 — a permission request has three ends, and only one of
/// them may move the flow on.**
///
/// Both onboarding permission steps used to answer every end the same way:
/// `onNext()`. The HealthKit step called it from its own `catch`; the
/// notifications step wrote `_ = await …requestAuthorization()` and advanced
/// regardless. What the fix needs is a value that can *hold* the difference, and
/// that value has to be checkable without a simulator — a system permission
/// sheet is presented out of process and iOS raises it once per install, so a
/// UI test can never drive all three ends.
///
/// The shape follows `LogoutConfirmationState` (08-09): the guarantees live in
/// the value, so they are provable by construction rather than by tapping.
@Suite("Onboarding — permission outcomes")
struct OnboardingPermissionOutcomeTests {
    // MARK: - Classification

    @Test("a refused notification request is a decision, not an error")
    func notificationsRefusalIsDeclined() {
        #expect(OnboardingPermissionOutcome.notifications(granted: false) == .declined)
        #expect(OnboardingPermissionOutcome.notifications(granted: true) == .granted)
    }

    @Test("HealthKit reports completion, never a per-type read grant")
    func healthKitReportsCompletionOnly() {
        // The request returning normally is the strongest claim HealthKit
        // supports — it does not say which read types were allowed, so nothing
        // downstream may read `.granted` as "all reads granted".
        #expect(OnboardingPermissionOutcome.healthKit(requestError: nil) == .granted)
        #expect(OnboardingPermissionOutcome.healthKit(requestError: URLError(.cancelled)) == .failed)
        // And it can never produce a `declined` — HealthKit has no such answer.
        #expect(OnboardingPermissionOutcome.healthKit(requestError: URLError(.timedOut)) != .declined)
    }

    // MARK: - Single flight

    @Test("a second request cannot start while one is in flight")
    func secondRequestIsRefused() {
        var request = OnboardingPermissionRequest()
        let first = request.begin()
        #expect(first != nil)
        #expect(request.isRequesting)
        let second = request.begin()
        #expect(second == nil, "a second tap must not start a second Task")
        // …and the first one still settles.
        let settled = request.settle(.granted, for: first ?? 0)
        #expect(settled)
    }

    @Test("a fresh request is possible once the previous one settled")
    func requestIsRepeatableAfterAnAnswer() {
        var request = OnboardingPermissionRequest()
        let first = request.begin()
        request.settle(.failed, for: first ?? 0)
        #expect(request.outcome == .failed)
        let retry = request.begin()
        #expect(retry != nil)
        #expect(retry != first, "a retry is a new generation, not the old one resumed")
        // Beginning clears the previous answer: the screen is asking again.
        #expect(request.outcome == .idle)
    }

    // MARK: - Nothing lands late

    @Test("a stale token cannot publish an answer")
    func staleTokenIsRefused() {
        var request = OnboardingPermissionRequest()
        let stale = request.begin() ?? 0
        request.invalidate()
        let fresh = request.begin() ?? 0
        let staleLanded = request.settle(.granted, for: stale)
        #expect(staleLanded == false)
        #expect(request.outcome == .idle, "the superseded answer must not be on screen")
        let freshLanded = request.settle(.declined, for: fresh)
        #expect(freshLanded)
        #expect(request.outcome == .declined)
    }

    @Test("invalidating drops both the in-flight request and the last answer")
    func invalidateClearsEverything() {
        var request = OnboardingPermissionRequest()
        let token = request.begin() ?? 0
        request.settle(.declined, for: token)
        #expect(request.needsAnAnswer)

        request.invalidate()
        #expect(request.outcome == .idle)
        #expect(!request.isRequesting)
        #expect(!request.needsAnAnswer)
        // The route or the account moved, so the answer computed for the old one
        // may not land on the new one.
        let landed = request.settle(.granted, for: token)
        #expect(landed == false)
    }

    @Test("settling without a request in flight changes nothing")
    func settleWithoutBeginIsRefused() {
        var request = OnboardingPermissionRequest()
        let landed = request.settle(.granted, for: 1)
        #expect(landed == false)
        #expect(request.outcome == .idle)
        #expect(!request.advancesWithoutTheUser)
    }

    // MARK: - Only one answer advances

    @Test("only a granted request advances the flow by itself")
    func onlyGrantedAdvances() {
        for (answer, advances) in [
            (OnboardingPermissionOutcome.granted, true),
            (.declined, false),
            (.failed, false),
            (.idle, false)
        ] {
            var request = OnboardingPermissionRequest()
            let token = request.begin() ?? 0
            request.settle(answer, for: token)
            #expect(request.advancesWithoutTheUser == advances, "\(answer) must not decide for the user")
        }
    }

    @Test("a refusal and a failure both keep the user on the step")
    func refusalAndFailureBothBlock() {
        for answer in [OnboardingPermissionOutcome.declined, .failed] {
            var request = OnboardingPermissionRequest()
            let token = request.begin() ?? 0
            request.settle(answer, for: token)
            #expect(request.needsAnAnswer)
            #expect(!request.advancesWithoutTheUser)
        }
        for answer in [OnboardingPermissionOutcome.idle, .granted] {
            var request = OnboardingPermissionRequest()
            let token = request.begin() ?? 0
            request.settle(answer, for: token)
            #expect(!request.needsAnAnswer)
        }
    }

    // MARK: - The seam is DEBUG-only and off by default

    @Test("the UI-test outcome override is absent in an ordinary process")
    func overrideIsAbsentWithoutTheArgument() {
        // The gate runs the unit target without `-uitest-permission-outcome`,
        // so the seam must answer `nil` — a production run can never be steered
        // by a flag that is not there, and in Release the literal is not linked
        // at all.
        #expect(OnboardingPermissionOutcome.uiTestOverride == nil)
    }

    // MARK: - Copy

    @Test("the permission-outcome copy keys resolve in the catalogue")
    func outcomeCopyKeysResolve() {
        for key in [
            "onboarding.permission.healthKit.failed",
            "onboarding.permission.notifications.declined",
            "onboarding.permission.notifications.failed",
            "onboarding.permission.openSettings"
        ] {
            let value = String(localized: String.LocalizationValue(key))
            #expect(!value.isEmpty && value != key, "missing permission key: \(key)")
        }
    }

    @Test("no permission copy claims that every read was granted")
    func healthKitCopyClaimsNoReadGrant() {
        let copy = String(localized: "onboarding.permission.healthKit.failed")
        // The one thing this surface must never say. HealthKit does not report
        // per-type read grants, so a message that implies it would be a claim
        // the platform cannot support.
        #expect(!copy.localizedCaseInsensitiveContains("granted"))
        #expect(!copy.localizedCaseInsensitiveContains("erteilt"))
    }
}
