import SwiftUI
#if canImport(AuthenticationServices)
    import AuthenticationServices
#endif
#if canImport(UIKit)
    import UIKit
#endif

/// #37 / v1.23.0 — second-factor challenge sheet. Presented on the auth step
/// when an MFA-enrolled user's password is accepted but the server returns
/// `meta.mfaRequired`. The user enters the 6-digit TOTP code from an
/// authenticator app, switches to a saved recovery code, or (on the default
/// passkey host) completes the challenge with a security key.
///
/// On success the store joins the normal post-login handoff
/// (`phase = .authenticating`), which advances OnboardingFlow off the auth step
/// — unmounting this sheet. A wrong code keeps the sheet up with an inline
/// error; an expired ticket clears the challenge and routes back to the
/// password form (see `AuthStore.verifyMFA`). All copy is localized (de+en);
/// the entered code is never logged.
struct MfaChallengeSheet: View {
    let challenge: AuthStore.MfaChallenge
    /// Whether the WebAuthn affordance may be offered — the host must be the
    /// bundled default passkey host (RP binding), gated by the caller, AND the
    /// server must have listed `webauthn` in the challenge methods.
    let passkeySupportedForHost: Bool

    @Environment(AuthStore.self) private var authStore
    @Environment(\.dismiss) private var dismiss

    @State private var code: String = ""
    @State private var useRecovery: Bool = false
    /// Parity item 2.4 — "trust this device" opt-in, mirroring
    /// `mfa-login-step.tsx:48-49`. **Off by default**: a 2FA-bypass credential
    /// is opt-in only, never a default the user has to notice and undo.
    @State private var rememberDevice: Bool = false
    @FocusState private var codeFocused: Bool

    private var showWebAuthn: Bool {
        passkeySupportedForHost && challenge.offersWebAuthn
    }

    /// The trusted-device opt-in is hidden on the recovery-code path. The server
    /// refuses to mint a trusted device for a recovery login (that path means
    /// "I lost my authenticator"), so showing the toggle there would promise
    /// something the server silently drops. Web solves the same problem by
    /// forcing the flag false; hiding it is the more honest affordance.
    private var showRememberDevice: Bool {
        !useRecovery
    }

    /// TOTP codes are exactly 6 digits; recovery codes are longer/alphanumeric
    /// so we only gate the submit button on non-empty for those.
    private var canSubmit: Bool {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        return useRecovery ? !trimmed.isEmpty : trimmed.count == 6
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HLSpace.lg) {
                    header

                    HLCard {
                        codeField
                    }
                    .padding(.horizontal, HLSpace.lg)

                    if showRememberDevice {
                        rememberDeviceToggle
                            .padding(.horizontal, HLSpace.xl)
                    }

                    if challenge.offersRecovery {
                        recoveryToggle
                            .padding(.horizontal, HLSpace.xl)
                    }

                    if let err = authStore.lastError {
                        Text(err.localizedDescription)
                            .font(.hlSubhead)
                            .foregroundStyle(HLColor.statusBad)
                            .padding(.horizontal, HLSpace.xl)
                            .accessibilityIdentifier("mfa.error")
                    }

                    HLButton(
                        String(localized: "onboarding.mfa.verify"),
                        variant: .primary,
                        size: .large,
                        isLoading: authStore.isWorking,
                        action: { Task { await submit() } }
                    )
                    .disabled(!canSubmit || authStore.isWorking)
                    .padding(.horizontal, HLSpace.xl)
                    .accessibilityIdentifier("mfa.verifyCTA")

                    if showWebAuthn {
                        webAuthnButton
                            .padding(.horizontal, HLSpace.xl)
                    }

                    Spacer(minLength: HLSpace.xxl)
                }
                .padding(.top, HLSpace.md)
            }
            .background(HLColor.background)
            .navigationTitle(String(localized: "onboarding.mfa.navTitle"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) {
                        authStore.cancelMFA()
                        dismiss()
                    }
                    .accessibilityIdentifier("mfa.cancel")
                }
            }
            .onAppear { codeFocused = true }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            Text("onboarding.mfa.title")
                .font(.hlTitle2)
                .foregroundStyle(HLText.primary)
            Text(useRecovery ? "onboarding.mfa.recovery.subtitle" : "onboarding.mfa.subtitle")
                .font(.hlBody)
                .foregroundStyle(HLText.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, HLSpace.xl)
    }

    private var codeField: some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            Text(useRecovery ? "onboarding.mfa.field.recovery" : "onboarding.mfa.field.code")
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)

            Group {
                if useRecovery {
                    TextField("", text: $code)
                        .textContentType(.oneTimeCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                } else {
                    TextField("", text: $code)
                    #if canImport(UIKit)
                        .keyboardType(.numberPad)
                    #endif
                        .textContentType(.oneTimeCode)
                        .onChange(of: code) { _, newValue in
                            // Keep TOTP entry to digits only; auto-submit when a
                            // full 6-digit code lands (HIG one-time-code UX).
                            let digits = String(newValue.filter(\.isNumber).prefix(6))
                            if digits != newValue { code = digits }
                            if digits.count == 6, !authStore.isWorking {
                                Task { await submit() }
                            }
                        }
                }
            }
            .font(.hlTitle3.monospacedDigit())
            .foregroundStyle(HLText.primary)
            .focused($codeFocused)
            .padding(HLSpace.md)
            .background(HLColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: HLRadius.sm, style: .continuous))
            .accessibilityIdentifier("mfa.codeField")
        }
    }

    /// Parity item 2.4. Web ref `mfa-login-step.tsx:179-194`. The caption states
    /// the actual window (30 days, `TRUSTED_DEVICE_TTL_MS`) rather than a vague
    /// "stay signed in" — this is a second-factor bypass and the user deserves
    /// the real duration before opting in.
    private var rememberDeviceToggle: some View {
        Toggle(isOn: $rememberDevice) {
            VStack(alignment: .leading, spacing: HLSpace.xxs) {
                Text("onboarding.mfa.rememberDevice")
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.primary)
                Text("onboarding.mfa.rememberDevice.caption")
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .accessibilityIdentifier("mfa.rememberDeviceToggle")
    }

    private var recoveryToggle: some View {
        Button {
            useRecovery.toggle()
            code = ""
        } label: {
            Text(useRecovery ? "onboarding.mfa.useAuthenticator" : "onboarding.mfa.useRecovery")
                .font(.hlSubhead)
                .foregroundStyle(HLText.primary)
        }
        .accessibilityIdentifier("mfa.recoveryToggle")
    }

    private var webAuthnButton: some View {
        HLButton(
            String(localized: "onboarding.mfa.useSecurityKey"),
            icon: "faceid",
            variant: .ghost,
            action: {
                #if canImport(AuthenticationServices) && canImport(UIKit)
                    Task {
                        await authStore.verifyMFAWithSecurityKey(
                            anchor: SceneAnchorProvider.shared,
                            rememberDevice: rememberDevice
                        )
                    }
                #endif
            }
        )
        .accessibilityIdentifier("mfa.securityKeyCTA")
    }

    private func submit() async {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await authStore.verifyMFA(
            method: useRecovery ? .recovery : .totp,
            code: trimmed,
            rememberDevice: rememberDevice
        )
        // L3 — a WRONG code keeps the challenge up with an inline error (#37/H1).
        // Clear the stale digits so the field is empty for the retry; otherwise the
        // 6-digit auto-submit never re-fires (the value is unchanged) and the user
        // has to manually delete the old code first. A dead ticket clears the
        // challenge (routes to the password form), so this no-ops there.
        if authStore.mfaChallenge != nil, authStore.lastError != nil {
            code = ""
        }
    }
}
