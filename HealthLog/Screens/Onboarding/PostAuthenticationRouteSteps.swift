import SwiftUI

// **The two surfaces a truthful post-authentication route
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
