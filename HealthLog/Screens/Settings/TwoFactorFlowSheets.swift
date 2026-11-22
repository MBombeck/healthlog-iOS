import SwiftUI

// MARK: - One-time recovery-code display

/// Renders a one-time batch of recovery codes with a share affordance. The
/// codes live in the presenting sheet's own state, never the store beyond the
/// hand-off, and are never logged.
struct RecoveryCodesView: View {
    let codes: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.md) {
            HLRowTitle("settings.security.twoFactor.recovery.saveTitle")
            Text("settings.security.twoFactor.recovery.saveBody")
                .hlText(.rowSubtitle)
            VStack(alignment: .leading, spacing: HLSpace.xs) {
                ForEach(codes, id: \.self) { code in
                    HLIdentifierText(code, style: .body, monospaced: true)
                }
            }
            .padding(HLSpace.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(HLTextField.plate)
            .clipShape(RoundedRectangle(cornerRadius: HLRadius.sm, style: .continuous))
            ShareLink(item: codes.joined(separator: "\n")) {
                HLButtonLabel(
                    "settings.security.twoFactor.recovery.share",
                    systemImage: "square.and.arrow.up",
                    variant: .secondary
                )
            }
            .hlPressable()
        }
    }
}

// MARK: - Enable (TOTP enrolment wizard)

/// TOTP enrolment: verify → scan → verify → recovery. Two step-up ceremonies
/// (setup and confirm each burn one single-use elevation — the server's
/// contract, not an oversight).
struct TotpEnableSheet: View {
    @Environment(AccountSecurityStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private enum Step { case verifySetup, scan, verifyConfirm, recovery }
    @State private var step: Step = .verifySetup
    @State private var code = ""
    @State private var codes: [String] = []
    /// An elevation the confirm call did NOT spend — a mistyped code is refused
    /// by `…/totp/confirm` *before* `commitElevation()`, so the proof is still
    /// alive server-side. Holding it lets the user fix the code and retry
    /// without burning one of five mints per 15 minutes.
    @State private var heldElevation: ConsumableElevation?

    var body: some View {
        HLSheetScaffold("settings.security.twoFactor.enable.sheetTitle") {
            HLPage {
                stepBody
            }
        }
    }

    @ViewBuilder
    private var stepBody: some View {
        switch step {
        case .verifySetup:
            // TOTP is not active yet → no app-code arm. Setup is non-fresh on an
            // account without a second factor; on a security-key-only account
            // server v1.39.3 wants the key or a passkey, so the
            // password arm is hidden there.
            StepUpArmPicker(
                requiresFresh: MfaManagementOperation.totpSetup
                    .requiresFreshFactor(accountHasSecondFactor: store.hasSecondFactor),
                hasTotp: false
            ) { elevation in
                await store.beginTotpSetup(elevation: elevation)
                if store.pendingTotpSetup != nil { step = .scan }
            }
        case .scan:
            scanStep
        case .verifyConfirm:
            StepUpArmPicker(operation: .totpConfirm, hasTotp: false) { elevation in
                await confirm(with: elevation)
            }
        case .recovery:
            VStack(alignment: .leading, spacing: HLLayout.cardGap) {
                RecoveryCodesView(codes: codes)
                HLButton("settings.security.twoFactor.done", variant: .primary) {
                    store.clearPendingTotpSetup()
                    dismiss()
                }
            }
        }
    }

    /// Runs the confirm call and routes on the outcome. A wrong code leaves the
    /// elevation unspent (`…/totp/confirm/route.ts:102` refuses before
    /// `commitElevation()` at `:109`), so it is kept and the user returns to the
    /// code field rather than to a fresh ceremony.
    private func confirm(with elevation: ConsumableElevation) async {
        await store.confirmTotp(code: code, elevation: elevation)
        if let revealed = store.consumeRevealedRecoveryCodes() {
            heldElevation = nil
            codes = revealed
            step = .recovery
            return
        }
        heldElevation = elevation.isSpent ? nil : elevation
        step = .scan
    }

    @ViewBuilder
    private var scanStep: some View {
        if let setup = store.pendingTotpSetup {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                HLRowTitle("settings.security.twoFactor.enrol.scanTitle")
                QRCodeImage(payload: setup.otpauthUri, side: 200)
                    .frame(maxWidth: .infinity, alignment: .center)
                Text("settings.security.twoFactor.enrol.manualLabel")
                    .hlText(.rowSubtitle)
                HLIdentifierText(setup.totpSecret, style: .callout, monospaced: true)
                Text("settings.security.twoFactor.enrol.codeLabel")
                    .hlText(.rowSubtitle)
                TextField("", text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .font(.hlBody)
                    .padding(HLSpace.md)
                    .background(HLTextField.plate)
                    .clipShape(RoundedRectangle(cornerRadius: HLRadius.sm, style: .continuous))
                HLButton("settings.security.twoFactor.enrol.continue", variant: .primary) {
                    // A retained (unspent) elevation from a previous wrong code
                    // goes straight back to confirm — no second ceremony.
                    if let held = heldElevation, !held.isSpent {
                        Task { await confirm(with: held) }
                    } else {
                        step = .verifyConfirm
                    }
                }
                .disabled(code.count < 6)
                if let error = store.actionError {
                    Text(verbatim: error).font(.hlCaption).foregroundStyle(HLColor.statusBad)
                }
            }
        } else {
            ProgressView()
        }
    }
}

// MARK: - Disable

struct DisableTotpSheet: View {
    @Environment(AccountSecurityStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var code = ""
    @State private var useRecovery = false
    /// See ``TotpEnableSheet``: `…/mfa/disable/route.ts:84-87` spends the
    /// elevation only after the body code verifies, so a wrong code (or a 429)
    /// leaves it usable. Retrying with it costs nothing; re-minting costs one of
    /// five per-account mints per 15 minutes.
    @State private var heldElevation: ConsumableElevation?

    var body: some View {
        HLSheetScaffold("settings.security.twoFactor.disable.sheetTitle") {
            HLPage {
                Text("settings.security.twoFactor.disable.body")
                    .hlText(.factLabel)
                HLAdaptiveSegmentedPicker(
                    "settings.security.twoFactor.disable.method",
                    selection: $useRecovery,
                    labels: [
                        "settings.security.twoFactor.disable.methodTotp",
                        "settings.security.twoFactor.disable.methodRecovery"
                    ]
                ) {
                    Text("settings.security.twoFactor.disable.methodTotp").tag(false)
                    Text("settings.security.twoFactor.disable.methodRecovery").tag(true)
                }
                TextField("", text: $code)
                    .keyboardType(useRecovery ? .default : .numberPad)
                    .textContentType(.oneTimeCode)
                    .autocorrectionDisabled()
                    .font(.hlBody)
                    .padding(HLSpace.md)
                    .background(HLTextField.plate)
                    .clipShape(RoundedRectangle(cornerRadius: HLRadius.sm, style: .continuous))
                if let held = heldElevation, !held.isSpent {
                    HLButton("settings.security.twoFactor.stepUp.retryHeld", variant: .primary) {
                        Task { await disable(with: held) }
                    }
                    .disabled(code.isEmpty)
                } else {
                    // Fresh-factor route: password arm hidden.
                    StepUpArmPicker(operation: .totpDisable, hasTotp: store.isTotpEnabled) { elevation in
                        await disable(with: elevation)
                    }
                }
                if let error = store.actionError {
                    Text(verbatim: error).font(.hlCaption).foregroundStyle(HLColor.statusBad)
                }
            }
            .onChange(of: code) { _, _ in store.clearActionError() }
        }
    }

    private func disable(with elevation: ConsumableElevation) async {
        await store.disableTotp(
            code: code,
            method: useRecovery ? .recovery : .totp,
            elevation: elevation
        )
        if store.actionError == nil {
            dismiss()
            return
        }
        heldElevation = elevation.isSpent ? nil : elevation
    }
}

// MARK: - Regenerate recovery codes

struct RegenerateRecoveryCodesSheet: View {
    @Environment(AccountSecurityStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var codes: [String] = []
    @State private var done = false

    var body: some View {
        HLSheetScaffold("settings.security.twoFactor.recovery.sheetTitle") {
            HLPage {
                if done {
                    RecoveryCodesView(codes: codes)
                    HLButton("settings.security.twoFactor.done", variant: .primary) { dismiss() }
                } else {
                    Text("settings.security.twoFactor.recovery.regenerateBody")
                        .hlText(.factLabel)
                    StepUpArmPicker(operation: .recoveryRegenerate, hasTotp: store.isTotpEnabled) { elevation in
                        await store.regenerateRecoveryCodes(elevation: elevation)
                        if let revealed = store.consumeRevealedRecoveryCodes() {
                            codes = revealed
                            done = true
                        }
                    }
                    if let error = store.actionError {
                        Text(verbatim: error).font(.hlCaption).foregroundStyle(HLColor.statusBad)
                    }
                }
            }
        }
    }
}

// MARK: - Security key rename / delete

struct SecurityKeyRenameSheet: View {
    let key: MfaStatus.SecurityKey
    @Environment(AccountSecurityStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(key: MfaStatus.SecurityKey) {
        self.key = key
        _name = State(initialValue: key.name)
    }

    var body: some View {
        HLSheetScaffold("settings.security.twoFactor.securityKeys.rename") {
            HLPage {
                TextField("", text: $name)
                    .font(.hlBody)
                    .padding(HLSpace.md)
                    .background(HLTextField.plate)
                    .clipShape(RoundedRectangle(cornerRadius: HLRadius.sm, style: .continuous))
                // Rename is non-fresh — password arm allowed.
                StepUpArmPicker(operation: .securityKeyRename, hasTotp: store.isTotpEnabled) { elevation in
                    await store.renameSecurityKey(id: key.id, name: name, elevation: elevation)
                    if store.actionError == nil { dismiss() }
                }
                .disabled(!WebAuthnKeyName.isValid(name))
            }
        }
    }
}

struct DeleteSecurityKeySheet: View {
    let key: MfaStatus.SecurityKey
    @Environment(AccountSecurityStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HLSheetScaffold("settings.security.twoFactor.securityKeys.remove") {
            HLPage {
                Text("settings.security.twoFactor.securityKeys.removeBody \(key.name)")
                    .hlText(.factLabel)
                // Removal is a fresh-factor route — password arm hidden.
                StepUpArmPicker(operation: .securityKeyRemove, hasTotp: store.isTotpEnabled) { elevation in
                    await store.deleteSecurityKey(id: key.id, elevation: elevation)
                    if store.actionError == nil { dismiss() }
                }
                if let error = store.actionError {
                    Text(verbatim: error).font(.hlCaption).foregroundStyle(HLColor.statusBad)
                }
            }
        }
    }
}

// MARK: - Lenient date formatting

enum SecurityKeyDateFormat {
    /// Parses an ISO-8601 string leniently and renders a short localized date.
    /// Returns nil on a parse miss so the row simply omits the date.
    static func shortDate(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = iso.date(from: raw) ?? {
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            return plain.date(from: raw)
        }()
        guard let date else { return nil }
        return HLDateFormat.date(date)
    }
}
