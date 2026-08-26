import SwiftUI

// **Phase 08 Wave 1 — the two surfaces a truthful post-authentication route
// needs.**
//
// Both exist because the decision "has this account already finished setup?"
// is answered by a server and can therefore take time or fail. Before Wave 1
// the flow simply assumed the answer was "no", which is why neither surface
// existed: an assumption is instantaneous and never fails.
//
// They live beside `OnboardingFlow` rather than inside it because that file is
// already over the 600-line budget, and a view with no access to the flow's
// state has no reason to share its scope.

/// The lookup is running. A named, visible state rather than a hidden `await`:
/// the alternative is a login form that stops responding for as long as the
/// network takes, which reads as a hang and gets force-quit.
struct CompletionLookupStep: View {
    var body: some View {
        VStack(spacing: HLSpace.md) {
            ProgressView()
                .controlSize(.large)
            Text("onboarding.route.checking")
                .font(.hlSubhead)
                .foregroundStyle(HLText.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, HLSpace.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// The lookup did not resolve.
///
/// The copy states the limit rather than a consequence: the app does not know
/// whether setup is finished, so it says that and offers the only honest action.
/// It deliberately does **not** offer "continue anyway" — continuing is the
/// guess this whole route exists to refuse, and an escape hatch that guesses is
/// the same defect with a confirmation step in front of it. Signing out is
/// always available one level up, from the shell the user never reached.
struct CompletionUnavailableStep: View {
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: HLSpace.md) {
            Image(systemName: "arrow.clockwise.circle")
                .font(.hlTitle1)
                .foregroundStyle(HLText.secondary)
            Text("onboarding.route.unavailable.title")
                .font(.hlTitle3)
                .foregroundStyle(HLText.primary)
                .multilineTextAlignment(.center)
            Text("onboarding.route.unavailable.body")
                .font(.hlSubhead)
                .foregroundStyle(HLText.secondary)
                .multilineTextAlignment(.center)
            Button(action: onRetry) {
                Text("Try again")
                    .font(.hlBody)
                    .foregroundStyle(HLText.primary)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("onboarding.route.retry")
        }
        .padding(.horizontal, HLSpace.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
