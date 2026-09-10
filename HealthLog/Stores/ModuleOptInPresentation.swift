import Foundation

/// **Audit A-7 — how a user-switchable module's OFF surface should read.**
///
/// Labs, Illness and Documents are modules the person owns, so a switched-off
/// surface offers an enable call-to-action rather than the operator-gated
/// ``FeatureDisabledCard`` (which deliberately has no "turn it on" affordance).
/// That is right for exactly one of the off-states.
///
/// `disabled` is the person's own switch: the CTA flips it back and the server
/// agrees. `not_granted`, `unavailable` and any state this build cannot name are
/// somebody else's decision — the grant owner's or the operator's — and the CTA
/// there invites a `PATCH /api/auth/me/modules` the server refuses, leaving the
/// person to interpret a failure instead of a sentence. The server sent the
/// sentence; this is what shows it.
///
/// A `nil` state (server older than v1.38.15, map not loaded, key not in the
/// map, or the two halves disagreeing) keeps the CTA — the absence of a verdict
/// is not a verdict, and A-7 must change nothing where it knows nothing.
public enum ModuleOptInPresentation: Equatable, Sendable {
    /// Render the enable card exactly as before.
    case offerOptIn
    /// Render the server's reason instead, with no switch.
    case explain(String)

    /// Audit A-7 — the whole rule, pure and testable without a view.
    ///
    /// Keyed on ``ModuleAccessState/offersSwitch``, the same predicate the
    /// settings switchboard uses, so the two surfaces cannot drift apart: a
    /// state that may keep its toggle there may keep its CTA here.
    public static func resolve(state: ModuleAccessState?) -> ModuleOptInPresentation {
        guard let state, !state.offersSwitch, let reason = state.offReason else { return .offerOptIn }
        return .explain(reason)
    }
}

public extension ModuleGate {
    /// Audit A-7 — how this module's off surface should read.
    ///
    /// Reads the RECONCILED state (fix round 1), so a stale reason beside a
    /// boolean that contradicts it cannot lock a person out of their own opt-in
    /// either.
    func optInPresentation(_ key: ModuleKey) -> ModuleOptInPresentation {
        ModuleOptInPresentation.resolve(state: reconciledAccessState(key))
    }
}
