import SwiftUI
#if canImport(LocalAuthentication)
    import LocalAuthentication
#endif

enum RootPrivacyShieldReason: Equatable, Sendable {
    case inactive
    case biometricLocked
}

enum RootPrivacyShieldPolicy {
    enum Resolution: Equatable, Sendable {
        case protected(RootPrivacyShieldReason)
        case unprotected
    }

    static func resolve(sceneIsActive: Bool, biometricLocked: Bool) -> Resolution {
        if !sceneIsActive { return .protected(.inactive) }
        if biometricLocked { return .protected(.biometricLocked) }
        return .unprotected
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
                    icon: "rectangle.portrait.and.arrow.right",
                    variant: .secondary,
                    size: .regular,
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
