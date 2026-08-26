import SwiftUI

/// Parity item 2.3 — the forced second-factor enrolment gate that sits in FRONT
/// of the authenticated shell. Split out of `RootView.swift` (file_length
/// discipline — PROJECT_GUIDE.md), mirroring `RootView+DisclaimerGate.swift`.
///
/// **Ordering vs. the disclaimer gate.** The medical-disclaimer gate wins when
/// both are pending. The disclaimer is a legal precondition to showing *any*
/// health content and is satisfiable entirely offline in one tap; enrolling a
/// second factor is a longer detour that may leave the app. Asking the user to
/// enrol before they have even accepted the terms — and then bouncing them to a
/// browser — is the worse first run, and the enrolment gate loses nothing by
/// waiting one screen.
///
/// **Standalone is never gated.** A standalone install has no server, therefore
/// no operator policy and no enrolment endpoint. Gating there would be a dead
/// end with no possible exit.
extension RootView {
    /// Resolve the forced-enrolment requirement on the authentication tick.
    /// Server-phase only; fail-soft inside the store (see
    /// `MfaEnrollmentGateStore.refresh`).
    func refreshMfaEnrollmentIfReady() async {
        switch authStore.phase {
        case .authenticated:
            await mfaEnrollmentGate.refresh()
        case .standalone, .unknown, .unauthenticated, .authenticating:
            break
        }
    }

    /// Whether the enrolment gate must sit in FRONT of the shell.
    ///
    /// Deliberately `false` while `needsDisclaimerGate` is true, so the two
    /// gates cannot both claim the screen — see the ordering note above.
    var needsMfaEnrollmentGate: Bool {
        guard !needsDisclaimerGate else { return false }
        switch authStore.phase {
        case .authenticated:
            return MfaEnrollmentGateStore.shouldGate(
                hasLoaded: mfaEnrollmentGate.hasLoaded,
                isRequired: mfaEnrollmentGate.isRequired
            )
        case .standalone, .unknown, .unauthenticated, .authenticating:
            return false
        }
    }

    /// The enrolment destination for the current server. See
    /// `MfaEnrollmentDestination` for the seam that swaps this to the native
    /// `SettingsSecurityScreen` flow once it exists.
    var mfaEnrollmentDestination: MfaEnrollmentDestination? {
        guard let baseURL = container?.environment.baseURL else { return nil }
        return .current(baseURL: baseURL)
    }
}
