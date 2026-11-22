import SwiftUI

/// S-1 (A360-3 security) — opaque app-switcher / background privacy cover.
///
/// Laid over the mounted shell by `RootView`, and over every sheet by
/// `HLSheetScaffold`, whenever the scene is not active, so the app-switcher
/// thumbnail and the on-disk SplashBoard snapshot capture this branded,
/// PHI-free surface instead of the live dashboard (medications, doses, mood,
/// measurements). It draws the inactive face of ``RootPrivacyShield``: an
/// opaque substrate, the app glyph and name, no store reads, no health data.
/// Unconditional (does NOT depend on the opt-in biometric-lock setting), so it
/// protects every user — including the default user who never enabled the
/// lock.
struct PrivacyCoverView: View {
    static let accessibilityIdentifier = "privacyCover"

    var body: some View {
        RootPrivacyShield(reason: .inactive, onUnlock: {}, onSignOut: {})
    }
}
