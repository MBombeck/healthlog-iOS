import SwiftUI

/// S-1 (A360-3 security) — opaque app-switcher / background privacy cover.
///
/// Painted over the whole shell by `RootView` whenever `scenePhase != .active`
/// so the app-switcher thumbnail and the on-disk SplashBoard snapshot capture
/// this branded, PHI-free surface instead of the live dashboard (medications,
/// doses, mood, measurements). Deliberately minimal: an opaque
/// `HLColor.background` fill plus the app glyph + name — no store reads, no
/// health data, nothing sensitive. Unconditional (does NOT depend on the opt-in
/// biometric-lock setting), so it protects every user — including the default
/// user who never enabled the lock.
struct PrivacyCoverView: View {
    static let accessibilityIdentifier = "privacyCover"

    var body: some View {
        ZStack {
            HLColor.background.ignoresSafeArea()
            VStack(spacing: HLSpace.md) {
                // Cover-scale brand glyph (`HLIconSize.cover`) on a static
                // cover that is never interacted with.
                Image(systemName: "heart.text.square.fill")
                    .font(.hlIcon(HLIconSize.cover, weight: .bold))
                    .foregroundStyle(HLText.primary)
                Text("HealthLog")
                    .font(.hlTitle2)
                    .foregroundStyle(HLText.primary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier(Self.accessibilityIdentifier)
        .accessibilityLabel(Text(verbatim: "HealthLog"))
    }
}
