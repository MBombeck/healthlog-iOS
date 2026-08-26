import SwiftUI

// MARK: - One-time recovery-code display

/// Renders a one-time batch of recovery codes with a share affordance. The
/// codes live in the presenting sheet's own state, never the store beyond the
/// hand-off, and are never logged.
struct RecoveryCodesView: View {
    let codes: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.md) {
            Text("settings.security.twoFactor.recovery.saveTitle")
                .font(.hlSubhead.weight(.semibold))
                .foregroundStyle(HLText.primary)
            Text("settings.security.twoFactor.recovery.saveBody")
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
            VStack(alignment: .leading, spacing: HLSpace.xs) {
                ForEach(codes, id: \.self) { code in
                    Text(verbatim: code)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(HLText.primary)
                        .textSelection(.enabled)
                }
            }
            .padding(HLSpace.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(HLColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: HLRadius.sm, style: .continuous))
            ShareLink(item: codes.joined(separator: "\n")) {
                Label("settings.security.twoFactor.recovery.share", systemImage: "square.and.arrow.up")
                    .font(.hlSubhead)
            }
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
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HLSpace.lg) {
                    stepBody
                }
                .padding(HLSpace.lg)
            }
            .navigationTitle("settings.security.twoFactor.enable")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("settings.passkeys.cancel") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var stepBody: some View {
        switch step {
        case .verifySetup:
            // setup is non-fresh; TOTP is not active yet → password/passkey only.
            StepUpArmPicker(operation: .totpSetup, hasTotp: false) { elevation in
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
            VStack(alignment: .leading, spacing: HLSpace.lg) {
                RecoveryCodesView(codes: codes)
                HLButton(String(localized: "settings.security.twoFactor.done"), variant: .primary) {
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
                Text("settings.security.twoFactor.enrol.scanTitle")
                    .font(.hlSubhead.weight(.semibold))
                    .foregroundStyle(HLText.primary)
                QRCodeImage(payload: setup.otpauthUri, side: 200)
                    .frame(maxWidth: .infinity, alignment: .center)
                Text("settings.security.twoFactor.enrol.manualLabel")
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                Text(verbatim: setup.totpSecret)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(HLText.primary)
                Text("settings.security.twoFactor.enrol.codeLabel")
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                TextField("", text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .font(.hlBody)
                    .padding(HLSpace.md)
                    .background(HLColor.surface)
                    .clipShape(RoundedRectangle(cornerRadius: HLRadius.sm, style: .continuous))
                HLButton(String(localized: "settings.security.twoFactor.enrol.continue"), variant: .primary) {
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
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HLSpace.lg) {
                    Text("settings.security.twoFactor.disable.body")
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.secondary)
                    Picker("settings.security.twoFactor.disable.method", selection: $useRecovery) {
                        Text("settings.security.twoFactor.disable.methodTotp").tag(false)
                        Text("settings.security.twoFactor.disable.methodRecovery").tag(true)
                    }
                    .pickerStyle(.segmented)
                    TextField("", text: $code)
                        .keyboardType(useRecovery ? .default : .numberPad)
                        .textContentType(.oneTimeCode)
                        .autocorrectionDisabled()
                        .font(.hlBody)
                        .padding(HLSpace.md)
                        .background(HLColor.surface)
                        .clipShape(RoundedRectangle(cornerRadius: HLRadius.sm, style: .continuous))
                    if let held = heldElevation, !held.isSpent {
                        HLButton(String(localized: "settings.security.twoFactor.stepUp.retryHeld"), variant: .primary) {
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
                .padding(HLSpace.lg)
            }
            .navigationTitle("settings.security.twoFactor.disable")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: code) { _, _ in store.clearActionError() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("settings.passkeys.cancel") { dismiss() }
                }
            }
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
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HLSpace.lg) {
                    if done {
                        RecoveryCodesView(codes: codes)
                        HLButton(String(localized: "settings.security.twoFactor.done"), variant: .primary) { dismiss() }
                    } else {
                        Text("settings.security.twoFactor.recovery.regenerateBody")
                            .font(.hlSubhead)
                            .foregroundStyle(HLText.secondary)
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
                .padding(HLSpace.lg)
            }
            .navigationTitle("settings.security.twoFactor.recovery.regenerate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("settings.passkeys.cancel") { dismiss() }
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
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HLSpace.lg) {
                    TextField("", text: $name)
                        .font(.hlBody)
                        .padding(HLSpace.md)
                        .background(HLColor.surface)
                        .clipShape(RoundedRectangle(cornerRadius: HLRadius.sm, style: .continuous))
                    // Rename is non-fresh — password arm allowed.
                    StepUpArmPicker(operation: .securityKeyRename, hasTotp: store.isTotpEnabled) { elevation in
                        await store.renameSecurityKey(id: key.id, name: name, elevation: elevation)
                        if store.actionError == nil { dismiss() }
                    }
                    .disabled(!WebAuthnKeyName.isValid(name))
                }
                .padding(HLSpace.lg)
            }
            .navigationTitle("settings.security.twoFactor.securityKeys.rename")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("settings.passkeys.cancel") { dismiss() }
                }
            }
        }
    }
}

struct DeleteSecurityKeySheet: View {
    let key: MfaStatus.SecurityKey
    @Environment(AccountSecurityStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HLSpace.lg) {
                    Text("settings.security.twoFactor.securityKeys.removeBody \(key.name)")
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.secondary)
                    // Removal is a fresh-factor route — password arm hidden.
                    StepUpArmPicker(operation: .securityKeyRemove, hasTotp: store.isTotpEnabled) { elevation in
                        await store.deleteSecurityKey(id: key.id, elevation: elevation)
                        if store.actionError == nil { dismiss() }
                    }
                    if let error = store.actionError {
                        Text(verbatim: error).font(.hlCaption).foregroundStyle(HLColor.statusBad)
                    }
                }
                .padding(HLSpace.lg)
            }
            .navigationTitle("settings.security.twoFactor.securityKeys.remove")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("settings.passkeys.cancel") { dismiss() }
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
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}
