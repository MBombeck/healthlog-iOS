import SwiftUI
#if canImport(LocalAuthentication)
    import LocalAuthentication
#endif

enum RootPrivacyShieldReason: Equatable, Sendable {
    case inactive
    case biometricLocked
}

/// What the window root shows. Only the biometric lock decides it: the locked
/// session unmounts the whole tree behind the shield. An inactive or
/// backgrounded scene keeps its tree; the scene's cover window
/// (``PrivacyCoverPolicy``) hides it from the app switcher instead, so a
/// fold, a resize or a trip to the switcher loses no screen, sheet or input.
enum RootPrivacyShieldPolicy {
    enum Resolution: Equatable, Sendable {
        /// The shield is the only view at the window root; the content is
        /// unmounted.
        case protected(RootPrivacyShieldReason)
        /// The content is mounted.
        case unprotected
    }

    /// `RootView` branches on exactly this. While locked, an inactive scene
    /// (the Face ID sheet itself) shows the plain brand face.
    static func resolve(sceneIsActive: Bool, biometricLocked: Bool) -> Resolution {
        guard biometricLocked else { return .unprotected }
        return .protected(sceneIsActive ? .biometricLocked : .inactive)
    }
}

/// When the cover window of a scene hides the app.
///
/// The system snapshots a scene for the app switcher as it leaves the
/// foreground. On the phone (the Duo included) the switcher and the Control
/// Centre show it inactive first, so the cover comes at `.inactive`. An iPad
/// scene is also inactive while it merely lost focus to another window in
/// Stage Manager and stays fully visible; a cover there would lie
/// permanently over a window the user is looking at. So the iPad covers at
/// `.background`, and at `.inactive` when no other scene of the app is active
/// and the scene is not a window that stays on screen beside others: a scene
/// filling the screen that goes inactive is on its way into the app switcher
/// (``PrivacyCoverController/staysOnScreen(phase:sceneSize:screenSize:)``).
enum PrivacyCoverPolicy {
    enum Idiom: Equatable, Sendable {
        case phone
        case pad
    }

    enum Phase: Equatable, Sendable {
        case active
        case inactive
        case background
    }

    /// - Parameters:
    ///   - idiom: the scene's device idiom; injected, so the rule is testable.
    ///   - phase: the scene's phase.
    ///   - anotherSceneActive: some other scene of the app is foreground active.
    ///   - visibleInForeground: the scene is still on screen.
    static func covers(
        idiom: Idiom,
        phase: Phase,
        anotherSceneActive: Bool,
        visibleInForeground: Bool
    ) -> Bool {
        switch (idiom, phase) {
        case (_, .active): false
        case (_, .background): true
        case (.phone, .inactive): true
        case (.pad, .inactive): !anotherSceneActive && !visibleInForeground
        }
    }
}

/// The window root's one branch: the shield while the biometric lock holds,
/// the content otherwise. The content keeps its identity, and so its state,
/// through every scene phase; only the lock unmounts it.
struct RootPrivacyComposition<Shield: View, Content: View>: View {
    let resolution: RootPrivacyShieldPolicy.Resolution
    @ViewBuilder let shield: (RootPrivacyShieldReason) -> Shield
    @ViewBuilder let content: () -> Content

    var body: some View {
        switch resolution {
        case let .protected(reason):
            shield(reason)
        case .unprotected:
            content()
        }
    }
}

/// The only view mounted at the window root while a privacy boundary is active.
/// Its first paint is an opaque, non-PHI substrate; no authenticated environment
/// value or presentation state is read while the protected branch is mounted.
struct RootPrivacyShield: View {
    let reason: RootPrivacyShieldReason
    let onUnlock: () -> Void
    let onSignOut: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var unavailabilityHint: String?

    var body: some View {
        ZStack {
            opaqueSubstrate
            HLColor.background
            switch reason {
            case .inactive:
                brandContent
            case .biometricLocked:
                lockContent
            }
        }
        .ignoresSafeArea()
        .accessibilityElement(children: reason == .inactive ? .ignore : .contain)
        .accessibilityIdentifier(reason == .inactive ? PrivacyCoverView.accessibilityIdentifier : "rootPrivacyShield.locked")
        .accessibilityLabel(reason == .inactive ? Text(verbatim: "HealthLog") : Text("HealthLog is locked"))
        .task(id: reason) {
            guard reason == .biometricLocked else { return }
            await refreshUnavailabilityHint()
        }
    }

    private var opaqueSubstrate: Color {
        colorScheme == .dark ? .black : .white
    }

    private var brandContent: some View {
        VStack(spacing: HLSpace.md) {
            Image(systemName: "heart.text.square.fill")
                .font(.hlIcon(HLIconSize.cover, weight: .bold))
                .foregroundStyle(HLText.primary)
            Text("HealthLog")
                .font(.hlTitle2)
                .foregroundStyle(HLText.primary)
        }
    }

    private var lockContent: some View {
        VStack(spacing: HLSpace.lg) {
            Image(systemName: "lock.shield.fill")
                .font(.hlIcon(HLIconSize.cover, weight: .bold))
                .foregroundStyle(HLText.primary)
            Text("HealthLog is locked")
                .font(.hlTitle2)
                .foregroundStyle(HLText.primary)
            Text(bodyText)
                .font(.hlBody)
                .foregroundStyle(HLText.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, HLSpace.xxl)
            VStack(spacing: HLSpace.sm) {
                HLButton("Unlock", icon: "faceid", variant: .primary, size: .large, action: onUnlock)
                    .accessibilityIdentifier(LockOverlay.unlockButtonIdentifier)
                HLButton(
                    "Sign out",
                    systemImage: "rectangle.portrait.and.arrow.right",
                    variant: .secondary,
                    action: onSignOut
                )
                .accessibilityIdentifier(LockOverlay.signOutButtonIdentifier)
            }
            .padding(.horizontal, HLSpace.xxl)
        }
    }

    private var bodyText: LocalizedStringKey {
        if let unavailabilityHint, !unavailabilityHint.isEmpty {
            return LocalizedStringKey(unavailabilityHint)
        }
        return "Unlock with Face ID, Touch ID or device passcode."
    }

    @MainActor
    private func refreshUnavailabilityHint() async {
        #if canImport(LocalAuthentication)
            let context = LAContext()
            var error: NSError?
            if !context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
                unavailabilityHint = "Face ID, Touch ID or device passcode are unavailable on this device. Please enable them in the iPhone Settings or sign out here."
            } else {
                unavailabilityHint = nil
            }
        #else
            unavailabilityHint = nil
        #endif
    }
}
