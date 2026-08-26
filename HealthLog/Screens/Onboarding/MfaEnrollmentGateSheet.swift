import SwiftUI

/// The seam between this gate and the actual TOTP-enrolment flow.
///
/// **Coordination note (parity Build 2).** A sibling agent is building
/// `SettingsSecurityScreen`, which will own the native TOTP enrolment
/// (QR/secret → confirm code → recovery codes). At the time this gate was
/// written that screen did not exist in the tree, so the gate must not
/// duplicate the enrolment UI — it would be thrown away on contact.
///
/// This enum is the single switch point. `.web` is the honest behaviour today:
/// hand off to the server's own `/settings/security`, which is the same surface
/// the web interstitial embeds, and which works right now. When the native
/// screen lands, add a `.native` case and route `MfaEnrollmentGateSheet`'s
/// primary action to it — no other file needs to change.
enum MfaEnrollmentDestination {
    /// Open the server's security hub in the browser. Works today; the user
    /// returns to a lifted gate because the server clears the enrolment hint the
    /// moment a factor is confirmed and `/me` re-reads it on the next tick.
    case web(URL)

    /// The destination in force. Kept as a single computed entry point so the
    /// swap to the native flow is one edit in one place.
    static func current(baseURL: URL) -> MfaEnrollmentDestination {
        .web(baseURL.appendingPathComponent("/settings/security"))
    }
}

/// Forced second-factor enrolment interstitial (parity item 2.3). Modal gate in
/// FRONT of the authenticated shell, mirroring `src/app/enroll-mfa/page.tsx`.
///
/// **Why a gate and not a banner.** The operator has made a second factor a
/// condition of use. A dismissible nudge would misrepresent that, and — the
/// actual bug being fixed — leaves the user with no path at all: before this
/// existed, an MFA-mandating instance rendered the iOS app unusable, with the
/// user stuck in a loop they could not exit.
///
/// **Nobody is trapped.** Web's interstitial keeps exactly one escape, a
/// sign-out button, and so does this. The gate is not swipe-dismissible (that
/// would defeat it), but signing out is always one tap away — the same contract,
/// and the reason this is a gate rather than a trap.
struct MfaEnrollmentGateSheet: View {
    let destination: MfaEnrollmentDestination
    let onSignOut: () async -> Void

    @Environment(\.openURL) private var openURL

    /// 08-09 — the escape is one tap away, and it is now one *answered* tap.
    /// Signing out of the gate drops the session exactly as it always did; what
    /// changed is that the button no longer does it on contact. This is the
    /// surface where a mis-tap costs the most, because the user is here because
    /// they cannot use the app until they enrol — losing the session as well
    /// means starting from the login screen.
    @State private var logoutConfirmation = LogoutConfirmationState()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HLSpace.lg) {
                header
                bodyCopy
                actions
            }
            .padding(HLSpace.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(HLColor.background)
        .hlScrollEdgeSoft()
        // The gate must not be swipeable away — that is the whole point.
        .interactiveDismissDisabled(true)
        // 08-09 — the shared destructive confirmation. `onSignOut` is unchanged
        // and still the only cleanup path; it is now reached from an answer.
        .hlLogoutConfirmation($logoutConfirmation) {
            await onSignOut()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            Image(systemName: "lock.shield.fill")
                .font(.hlIcon(HLIconSize.display, weight: .bold))
                .foregroundStyle(HLAccent.userBrandTint)
            Text("mfaEnroll.title")
                .font(.hlTitle2)
                .foregroundStyle(HLText.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var bodyCopy: some View {
        VStack(alignment: .leading, spacing: HLSpace.md) {
            Text("mfaEnroll.body")
                .font(.hlBody)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // Says where the requirement comes from. Without this the demand
            // reads as an app defect rather than an operator policy.
            Text("mfaEnroll.policyNote")
                .font(.hlCaption)
                .foregroundStyle(HLText.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var actions: some View {
        VStack(spacing: HLSpace.sm) {
            HLButton(
                String(localized: "mfaEnroll.enrollButton"),
                icon: enrollButtonIcon,
                variant: .primary,
                size: .compact
            ) {
                switch destination {
                case let .web(url):
                    openURL(url)
                }
            }
            .accessibilityIdentifier(Self.enrollButtonIdentifier)

            // Only shown for the web hand-off: it sets the expectation that the
            // gate lifts on return rather than instantly.
            if case .web = destination {
                Text("mfaEnroll.web.returnHint")
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HLButton(
                String(localized: "mfaEnroll.signOutButton"),
                variant: .ghost,
                size: .regular,
                isLoading: logoutConfirmation.isSigningOut
            ) {
                logoutConfirmation.request()
            }
            .disabled(logoutConfirmation.isSigningOut)
            .accessibilityIdentifier(Self.signOutButtonIdentifier)
        }
    }

    private var enrollButtonIcon: String {
        switch destination {
        case .web: "safari"
        }
    }

    static let enrollButtonIdentifier = "mfaEnroll.enrollButton"
    static let signOutButtonIdentifier = "mfaEnroll.signOutButton"
}
