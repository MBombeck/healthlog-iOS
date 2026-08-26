import SwiftUI

/// **Phase 08 Plan 10 — what a permission request actually answered.**
///
/// A permission request has three distinguishable ends and both onboarding
/// permission steps used to collapse all of them into one call to `onNext()`:
/// the HealthKit step advanced out of its own `catch` block, and the
/// notifications step discarded the `Bool` it awaited (`_ = await …`). A user
/// who refused, and a user whose request failed outright, saw exactly what a
/// user who granted saw — the next screen — so "setup succeeded" was painted
/// over work that had not happened.
///
/// The vocabulary is deliberately three-valued rather than a `Bool`, because a
/// refusal and a failure are not the same event and do not deserve the same
/// affordance: a refusal is the user's decision and needs a way to change it
/// (Settings) plus a deliberate way past it, while a failure is the app's
/// problem and needs a retry.
enum OnboardingPermissionOutcome: Equatable, Sendable {
    /// Nothing has been asked yet, or a previous answer was invalidated.
    case idle
    /// The request completed and the permission was granted.
    case granted
    /// The request completed and the user (or a device restriction) refused.
    case declined
    /// The request did not complete. Not an answer — an operational failure.
    case failed
}

extension OnboardingPermissionOutcome {
    /// Notifications answer with a `Bool`, and `false` is the user's refusal
    /// rather than an error: the request itself worked.
    static func notifications(granted: Bool) -> Self {
        granted ? .granted : .declined
    }

    /// HealthKit cannot report a per-type read grant — `requestAuthorization`
    /// returns normally whether the user allowed everything, nothing, or closed
    /// the sheet — so the only two answers it can honestly produce are "the
    /// request completed" and "it did not". Nothing here may be read as "all
    /// reads granted"; the copy this drives says so too.
    static func healthKit(requestError: Error?) -> Self {
        requestError == nil ? .granted : .failed
    }

    /// **UI-test seam (`-uitest-permission-outcome <granted|declined|failed>`).**
    ///
    /// A hermetic UI test cannot drive a real permission answer: the system
    /// sheet is presented out of process, it swallows taps, and iOS shows it
    /// once per install. Without a seam the only checkable claim left is "some
    /// element with a denial identifier exists", which a step can satisfy by
    /// rendering a denial message at a user who denied nothing.
    ///
    /// So the outcome — and only the outcome — is injectable, in DEBUG only:
    /// the argument replaces the *answer*, never the rendering, never the
    /// routing and never the classification above. Mirrors the existing
    /// `-uitest-auth-journey` seam in ``OnboardingFlow/initialStep`` and the
    /// `-uitest-ack-disclaimer` seam in `DisclaimerAckStore`; the literal is
    /// inside `#if DEBUG`, so no Release binary carries it.
    static var uiTestOverride: OnboardingPermissionOutcome? {
        #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            guard let index = arguments.firstIndex(of: "-uitest-permission-outcome"),
                  arguments.index(after: index) < arguments.endIndex else { return nil }
            switch arguments[arguments.index(after: index)] {
            case "granted": return .granted
            case "declined": return .declined
            case "failed": return .failed
            default: return nil
            }
        #else
            nil
        #endif
    }
}

/// A single-flight, generation-fenced permission request.
///
/// Two properties, both of which the steps used to lack and neither of which is
/// provable from a view tree:
///
/// * **Single flight.** ``begin()`` hands out a token only when nothing is in
///   flight, so a second tap on a button whose spinner has not appeared yet
///   cannot start a second `Task` against the same system service.
/// * **Nothing lands late.** ``settle(_:for:)`` refuses a token that is no
///   longer current, and ``invalidate()`` makes every outstanding token stale
///   in one move — which is what a route or account change needs, because an
///   answer computed for the session that just ended may not decide what the
///   session that just started sees.
///
/// The shape follows `LogoutConfirmationState` (08-09): the state is a value
/// type with the guarantee inside it, so the guarantee is testable without a
/// simulator.
struct OnboardingPermissionRequest: Equatable, Sendable {
    private(set) var outcome: OnboardingPermissionOutcome = .idle
    private(set) var isRequesting = false
    private var generation: UInt64 = 0

    /// The token the caller must hand back to publish an answer, or `nil` when
    /// a request is already in flight.
    mutating func begin() -> UInt64? {
        guard !isRequesting else { return nil }
        isRequesting = true
        outcome = .idle
        generation &+= 1
        return generation
    }

    /// Publishes an answer. Returns `false` — and changes nothing — when the
    /// token is stale, which is every request that was superseded or cancelled.
    @discardableResult
    mutating func settle(_ answer: OnboardingPermissionOutcome, for token: UInt64) -> Bool {
        guard isRequesting, token == generation else { return false }
        isRequesting = false
        outcome = answer
        return true
    }

    /// The route or the account moved: nothing in flight may publish, and the
    /// last answer no longer describes anything on screen.
    mutating func invalidate() {
        generation &+= 1
        isRequesting = false
        outcome = .idle
    }

    /// Only a granted request may move the flow on by itself. A refusal or a
    /// failure needs the user to say so.
    var advancesWithoutTheUser: Bool {
        outcome == .granted
    }

    /// True while the step must keep the user where they are and say why.
    var needsAnAnswer: Bool {
        outcome == .declined || outcome == .failed
    }
}

/// The message a refused or failed permission request leaves on screen.
///
/// Only the message: each step composes its own affordances, so the identifier
/// of every button stays next to the step it belongs to instead of being
/// assembled from three parameters one file away.
struct OnboardingPermissionNotice: View {
    let outcome: OnboardingPermissionOutcome
    /// The identifier the message carries — the surface a test can find.
    let identifier: String
    let declined: LocalizedStringKey
    let failed: LocalizedStringKey

    var body: some View {
        switch outcome {
        case .idle, .granted:
            EmptyView()
        case .declined:
            message(declined)
        case .failed:
            message(failed)
        }
    }

    private func message(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.hlCaption)
            .foregroundStyle(HLColor.statusBad)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(identifier)
    }
}
