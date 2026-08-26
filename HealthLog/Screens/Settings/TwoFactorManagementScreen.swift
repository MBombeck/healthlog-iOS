import SwiftUI

/// Settings → Security → Two-factor authentication — the native management hub
/// (#57). Every mutation here rides a single-use step-up **elevation** minted by
/// re-proving a factor (`X-Step-Up` header). The UI picks the ceremony **up
/// front**: fresh-factor actions (disable, recovery-code rotation, security-key
/// removal) never offer the password arm, because a password elevation would be
/// rejected server-side *after* being spent.
///
/// **UI-Standard U3.** Gerüst B→A (`HLSettingsPage` statt handgebautem
/// `ScrollView` mit rundum-16-Rändern, R12), jede Aktion in einer Karte ist
/// eine `HLSettingsActionRow` (R8) — auch die beiden Sicherheitsschlüssel-Verben,
/// die vorher hinter einem `ellipsis.circle`-`Menu` versteckt waren. Der eine
/// verbleibende `HLButton(variant: .primary)` ist „Zwei-Faktor einrichten": der
/// Standard nennt ihn in R9 namentlich als legitimes `.primary` — solange 2FA
/// aus ist, will dieser Screen genau das vom Nutzer. Ist 2FA an, gibt es auf
/// dem Screen keinen gefüllten Knopf mehr.
struct TwoFactorManagementScreen: View {
    @Environment(AccountSecurityStore.self) private var store
    @Environment(\.appContainer) private var container
    @Environment(\.openURL) private var openURL

    @State private var showEnable = false
    @State private var showDisable = false
    @State private var showRegenerate = false
    @State private var renameTarget: MfaStatus.SecurityKey?
    @State private var deleteTarget: MfaStatus.SecurityKey?

    var body: some View {
        HLSettingsPage(title: "settings.security.twoFactor.title") {
            content
        }
        .navigationTitle("settings.security.twoFactor.title")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.loadTwoFactor() }
        .sheet(isPresented: $showEnable) { TotpEnableSheet() }
        .sheet(isPresented: $showDisable) { DisableTotpSheet() }
        .sheet(isPresented: $showRegenerate) { RegenerateRecoveryCodesSheet() }
        .sheet(item: $renameTarget) { key in SecurityKeyRenameSheet(key: key) }
        .sheet(item: $deleteTarget) { key in DeleteSecurityKeySheet(key: key) }
    }

    @ViewBuilder
    private var content: some View {
        switch store.twoFactor {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, HLSpace.xl)
        case .unavailable:
            HLSettingsCard(icon: "lock.shield", title: "settings.security.twoFactor.title") {
                // R4 — derselbe Katalogschlüssel stand wortgleich auf dem
                // Sicherheits-Hub und hier. Statt ihn zweimal zu erklären,
                // steht an beiden Stellen jetzt der Absprung.
                webSecurityRow
            }
        case let .failed(message):
            HLSettingsCard(icon: "exclamationmark.triangle", title: "settings.security.twoFactor.title") {
                Text(verbatim: message)
                    .font(.hlSubhead)
                    .foregroundStyle(HLColor.statusBad)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HLButton(String(localized: "settings.security.twoFactor.retry"), variant: .secondary) {
                    Task { await store.loadTwoFactor() }
                }
            }
        case let .loaded(status):
            totpCard(status)
            securityKeysCard(status)
            if let error = store.actionError {
                Text(verbatim: error)
                    .font(.hlCaption)
                    .foregroundStyle(HLColor.statusBad)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// R8 — die beiden Verwaltungsverben sind Zeilen, kein `.secondary`/
    /// `.destructive`-Knopfpaar mehr. `.primary` bleibt genau einer und genau
    /// im Zustand „2FA ist aus" (R9).
    private func totpCard(_ status: MfaStatus) -> some View {
        HLSettingsCard(
            icon: status.totp.enabled ? "checkmark.shield.fill" : "lock.shield",
            title: "settings.security.twoFactor.totp.title",
            subtitle: "settings.security.twoFactor.totp.subtitle"
        ) {
            if status.totp.enabled {
                Text("settings.security.twoFactor.recoveryRemaining \(status.recoveryCodesRemaining)")
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HLSettingsActionRow(
                    title: "settings.security.twoFactor.recovery.regenerate",
                    presents: .create
                ) {
                    showRegenerate = true
                }
                .accessibilityIdentifier("settings.security.twoFactor.regenerateRow")
                HLSettingsActionRow(
                    title: "settings.security.twoFactor.disable",
                    role: .destructive,
                    presents: .confirm
                ) {
                    showDisable = true
                }
                .accessibilityIdentifier("settings.security.twoFactor.disableRow")
            } else {
                // R9 — namentlich als `.primary` sanktioniert: solange 2FA aus
                // ist, will dieser Screen genau diese eine Sache.
                HLButton(String(localized: "settings.security.twoFactor.enable"), variant: .primary) {
                    showEnable = true
                }
            }
        }
    }

    private func securityKeysCard(_ status: MfaStatus) -> some View {
        HLSettingsCard(
            icon: "key.horizontal.fill",
            title: "settings.security.twoFactor.securityKeys.title",
            subtitle: "settings.security.twoFactor.securityKeys.subtitle"
        ) {
            if status.webauthn.isEmpty {
                Text("settings.security.twoFactor.securityKeys.none")
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(status.webauthn) { key in
                    securityKeyRows(key)
                }
            }
            // Registering a NEW physical security key needs a security-key
            // ASAuthorization ceremony not yet in `PasskeyService`. R4: der
            // frühere Hinweissatz nannte den Ort, ohne hinzuführen — jetzt
            // führt die Zeile hin.
            HLSettingsActionRow(
                title: "settings.security.twoFactor.securityKeys.addInBrowser",
                presents: .external
            ) {
                // Ohne eingerichteten Server gibt es keine Kontoflaeche zu oeffnen.
                if let url = AccountSecurityWebLink.url(keychain: container?.keychain) {
                    openURL(url)
                }
            }
            .accessibilityIdentifier("settings.security.twoFactor.securityKeys.addLink")
        }
    }

    /// R8 (Muster 1.8) — das `ellipsis.circle`-`Menu` war die vierte Affordanz
    /// auf diesem Pfad und blieb unsichtbar, bis man es antippte. In einer
    /// Karte gilt „eine Zeile pro Aktion"; der Schlüsselname steht deshalb im
    /// Zeilentitel, damit ohne Gruppierungsrahmen eindeutig bleibt, welcher
    /// Schlüssel gemeint ist.
    @ViewBuilder
    private func securityKeyRows(_ key: MfaStatus.SecurityKey) -> some View {
        HLSettingsActionRow(
            title: "settings.security.twoFactor.securityKeys.renameNamed \(key.name)",
            presents: .sheet,
            trailing: {
                if let added = SecurityKeyDateFormat.shortDate(key.createdAt) {
                    Text("settings.security.twoFactor.securityKeys.added \(added)")
                        .font(.hlCaption)
                        .foregroundStyle(HLText.tertiary)
                }
            },
            action: { renameTarget = key }
        )
        HLSettingsActionRow(
            title: "settings.security.twoFactor.securityKeys.removeNamed \(key.name)",
            role: .destructive,
            presents: .confirm
        ) {
            deleteTarget = key
        }
    }

    private var webSecurityRow: some View {
        HLSettingsActionRow(
            title: "settings.security.web.manage",
            presents: .external
        ) {
            // Ohne eingerichteten Server gibt es keine Kontoflaeche zu oeffnen.
            if let url = AccountSecurityWebLink.url(keychain: container?.keychain) {
                openURL(url)
            }
        }
        .accessibilityIdentifier("settings.security.twoFactor.webLink")
    }
}

// MARK: - Step-up arm picker (reusable, inline)

/// The "confirm your identity" affordance. Offers exactly the arms the target
/// route accepts and mints a single-use elevation, handing it to `onElevation`.
/// Inline (not a sheet) so a flow can host it as one step of a wizard without
/// chained-sheet dismissal hazards.
struct StepUpArmPicker: View {
    /// The route this proof is for. Its ``MfaManagementOperation/requiresFreshFactor``
    /// decides whether the **password** arm is offered at all — on a fresh-factor
    /// route a password elevation is refused at the gate, and a gate refusal is
    /// the one failure class that burns the proof.
    let operation: MfaManagementOperation
    /// Whether the account has an active TOTP factor (drives the TOTP arm).
    /// Read from the live status, never assumed.
    let hasTotp: Bool
    let onElevation: (ConsumableElevation) async -> Void

    private var requiresFresh: Bool {
        operation.requiresFreshFactor
    }

    /// A picker error is either a catalog key (our own copy) or verbatim server
    /// prose — the two render differently, so the type keeps them apart rather
    /// than forcing a dynamic string through catalog lookup.
    private enum PickerError: Equatable {
        case key(LocalizedStringKey)
        case verbatim(String)
    }

    @Environment(AccountSecurityStore.self) private var store
    @Environment(\.appContainer) private var container
    @Environment(\.openURL) private var openURL
    @State private var password = ""
    @State private var totpCode = ""
    @State private var localError: PickerError?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.md) {
            Text("settings.security.twoFactor.stepUp.prompt")
                .font(.hlSubhead)
                .foregroundStyle(HLText.secondary)

            // Passkey is always offered — a 409 (no passkey on the account) is
            // the honest discovery path and points the user at another arm.
            HLButton(String(localized: "settings.security.twoFactor.stepUp.passkey"), variant: .primary, isLoading: busy) {
                Task { await mintPasskey() }
            }
            .disabled(busy)

            if hasTotp {
                codeField("settings.security.twoFactor.stepUp.totpLabel", text: $totpCode)
                HLButton(String(localized: "settings.security.twoFactor.stepUp.totpSubmit"), variant: .secondary, isLoading: busy) {
                    Task { await mint { try await store.mint(totp: totpCode) } }
                }
                .disabled(busy || totpCode.isEmpty)
            } else if requiresFresh {
                // Security-key-only account: the passkey arm above is the only
                // native fresh factor. A security-key assertion would also work
                // server-side, but that ceremony is web-only here — say so
                // rather than showing a code field that can never succeed.
                // R4 (privacy-review): die Aussage bleibt, der Weg dorthin ist
                // jetzt die Zeile statt einer Ortsangabe im Fliesstext.
                Text("settings.security.twoFactor.stepUp.freshOnWeb")
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
                HLSettingsActionRow(
                    title: "settings.security.web.manage",
                    presents: .external
                ) {
                    // Ohne eingerichteten Server gibt es keine Kontoflaeche zu oeffnen.
                    if let url = AccountSecurityWebLink.url(keychain: container?.keychain) {
                        openURL(url)
                    }
                }
                .accessibilityIdentifier("settings.security.twoFactor.stepUp.webLink")
            }

            if !requiresFresh {
                secureField("settings.security.twoFactor.stepUp.passwordLabel", text: $password)
                HLButton(String(localized: "settings.security.twoFactor.stepUp.passwordSubmit"), variant: .secondary, isLoading: busy) {
                    Task { await mint { try await store.mint(password: password) } }
                }
                .disabled(busy || password.isEmpty)
            }

            if let localError {
                errorText(localError)
                    .font(.hlCaption)
                    .foregroundStyle(HLColor.statusBad)
            }
        }
    }

    @ViewBuilder
    private func errorText(_ error: PickerError) -> some View {
        switch error {
        case let .key(key): Text(key)
        case let .verbatim(text): Text(verbatim: text)
        }
    }

    private func mintPasskey() async {
        await mint { try await store.mintWithPasskey(anchor: SceneAnchorProvider.shared) }
    }

    private func mint(_ operation: @escaping () async throws -> ConsumableElevation) async {
        guard !busy else { return }
        busy = true
        localError = nil
        defer { busy = false }
        do {
            let elevation = try await operation()
            await onElevation(elevation)
        } catch let err as HLError {
            // A 409 from the passkey options leg means "no passkey on this
            // account" — steer to another arm rather than a scary error.
            if case .server(409, _, _) = err {
                localError = .key("settings.security.twoFactor.stepUp.noPasskey")
            } else if case .canceled = err {
                localError = nil
            } else {
                // Server prose (generic 401 "Verification failed", rate-limit).
                localError = .verbatim(err.userFacingDescription)
            }
        } catch {
            localError = .key("settings.security.twoFactor.error.generic")
        }
    }

    private func codeField(_ label: LocalizedStringKey, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            Text(label).font(.hlCaption).foregroundStyle(HLText.secondary)
            TextField("", text: text)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .font(.hlBody)
                .padding(HLSpace.md)
                .background(HLColor.surface)
                .clipShape(RoundedRectangle(cornerRadius: HLRadius.sm, style: .continuous))
        }
    }

    private func secureField(_ label: LocalizedStringKey, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            Text(label).font(.hlCaption).foregroundStyle(HLText.secondary)
            SecureField("", text: text)
                .textContentType(.password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.hlBody)
                .padding(HLSpace.md)
                .background(HLColor.surface)
                .clipShape(RoundedRectangle(cornerRadius: HLRadius.sm, style: .continuous))
        }
    }
}
