import SwiftUI

/// Settings → Security — the account-protection hub.
///
/// **2FA management is now native (#57).** Since server v1.32.3 the second-factor
/// management routes accept a Bearer token that presents a single-use **step-up
/// elevation** in the `X-Step-Up` header, so a native client can enrol TOTP,
/// rotate recovery codes, and manage security keys without a browser. The card
/// below therefore shows the **real** status from `GET /api/auth/me/mfa` (which
/// is plain-Bearer) and, on a server that is new enough, drives the flows. On an
/// older self-hosted instance it falls back to the honest jump onto the web
/// security page — the capability is version-gated, not guessed.
///
/// | Surface | Reachable from Bearer client |
/// |---|---|
/// | `POST /api/auth/password` | ✅ (step-up wall only if 2FA on — cookie-only there) |
/// | `PATCH /api/auth/passkeys/{id}` | ✅ |
/// | `GET /api/auth/me/mfa` | ✅ (plain Bearer) |
/// | TOTP setup / confirm / disable | ✅ via `X-Step-Up` elevation |
/// | Recovery-code rotation | ✅ via fresh-factor elevation |
/// | Security-key list / rename / delete | ✅ via elevation |
/// | Security-key **register** (new key) | ⚠️ needs a security-key ASAuthorization ceremony not yet in `PasskeyService` |
///
/// **UI-Standard U3 — der Betreiber-Fall.** Dieser Screen war der Beleg für
/// „drei Karten, drei bis fünf Formen für dasselbe Versprechen": Passwort war
/// ein vollbreiter 48-pt-Knopf, Passkeys eine handgebaute 20-pt-Chevron-Zeile,
/// Zwei-Faktor wechselte die Form je Zustand. §2 des Standards entscheidet
/// zugunsten der Zeile (R8): jede der drei Karten trägt jetzt genau **eine**
/// `HLSettingsActionRow`, das Trailing-Glyph kommt vom `presents:`-Vertrag
/// (R10), und das Gerüst ist `HLSettingsPage` statt des handgebauten
/// `ScrollView` (R12, Gerüst B→A).
struct SettingsSecurityScreen: View {
    @Environment(AccountSecurityStore.self) private var store
    @Environment(\.appContainer) private var container
    @Environment(\.openURL) private var openURL
    @State private var showChangePassword = false

    var body: some View {
        HLSettingsPage(title: "settings.security.title") {
            passwordCard
            passkeysCard
            twoFactorCard
        }
        .navigationTitle("settings.security.title")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showChangePassword) {
            ChangePasswordSheet()
        }
        .task { await store.loadTwoFactor() }
    }

    /// R2/R5 — der frühere Subtitle („Ersetze dein aktuelles Passwort durch ein
    /// neues.") formulierte die Zeile darunter um und fällt damit die
    /// Abdeck-Probe: Kartentitel + Zeile bedienen sich unverändert.
    private var passwordCard: some View {
        HLSettingsCard(
            icon: "lock.fill",
            title: "settings.security.password.cardTitle"
        ) {
            HLSettingsActionRow(
                title: "settings.security.password.cta",
                presents: .sheet
            ) {
                showChangePassword = true
            }
            .accessibilityIdentifier("settings.security.changePasswordRow")
        }
    }

    /// R3/R9 (Audit-Gruppe „Hier verwaltest du Passwort / Passkeys / 2FA") —
    /// der Subtitle war ein Copy-Paste-Griff nach `settings.security.subtitle`
    /// und beschrieb den ganzen Hub statt dieser Karte. Seine Heimat ist die
    /// Konto-Karte, die hierher führt.
    private var passkeysCard: some View {
        HLSettingsCard(
            icon: "key.fill",
            title: "settings.passkeys.title"
        ) {
            HLSettingsActionRow(
                title: "settings.passkeys.manage",
                presents: .push
            ) {
                PasskeyManagementScreen()
            }
            .accessibilityIdentifier("settings.security.passkeysRow")
        }
    }

    /// Real status now — no more "status unknown" guess. Drives the native flows
    /// when the server supports them, and jumps to the web security page on an
    /// older instance.
    private var twoFactorCard: some View {
        HLSettingsCard(
            icon: "lock.shield",
            title: "settings.security.twoFactor.title"
        ) {
            twoFactorContent
        }
    }

    /// Alle Zustände enden in derselben Form: Statuszeile (falls es einen
    /// Status gibt) plus **eine** Auslöse-Zeile. Die früheren
    /// `VStack(spacing: HLSpace.sm)`-Verschachtelungen sind weg — der Abstand
    /// kommt vom Kartenkörper (R12/§3.2).
    @ViewBuilder
    private var twoFactorContent: some View {
        switch store.twoFactor {
        case .idle, .loading:
            HStack(spacing: HLSpace.sm) {
                ProgressView()
                Text("settings.security.twoFactor.loading")
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("settings.security.twoFactorNote")
        case .unavailable:
            // R4 — die beiden erklärenden Sätze („… nur in der Web-App
            // verwalten." + der Server-Versions-Hinweis) waren Wegweiser ohne
            // Weg. An ihrer Stelle steht der Absprung selbst.
            webSecurityRow
        case let .failed(message):
            Text(verbatim: message)
                .font(.hlSubhead)
                .foregroundStyle(HLColor.statusBad)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("settings.security.twoFactorNote")
            // R9 — „Erneut versuchen" ist app-weit `.secondary`.
            HLButton(
                String(localized: "settings.security.twoFactor.retry"),
                variant: .secondary,
                action: { Task { await store.loadTwoFactor() } }
            )
        case let .loaded(status):
            statusLine(status)
            HLSettingsActionRow(
                title: "settings.security.twoFactor.manage",
                presents: .push
            ) {
                TwoFactorManagementScreen()
            }
            .accessibilityIdentifier("settings.security.twoFactorManageRow")
        }
    }

    private func statusLine(_ status: MfaStatus) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: HLSpace.sm) {
            Image(systemName: status.totp.enabled ? "checkmark.shield.fill" : "shield.slash")
                .foregroundStyle(status.totp.enabled ? HLColor.statusOK : HLText.tertiary)
            VStack(alignment: .leading, spacing: HLSpace.xxs) {
                Text(status.totp.enabled
                    ? "settings.security.twoFactor.on"
                    : "settings.security.twoFactor.off")
                    .font(.hlSubhead.weight(.semibold))
                    .foregroundStyle(HLText.primary)
                if status.totp.enabled {
                    Text("settings.security.twoFactor.recoveryRemaining \(status.recoveryCodesRemaining)")
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings.security.twoFactorNote")
    }

    private var webSecurityRow: some View {
        HLSettingsActionRow(
            title: "settings.security.web.manage",
            presents: .external
        ) {
            // Ohne eingerichteten Server gibt es keine Kontoflaeche zu oeffnen.
            // 09-03 — aus dem Server-Schnappschuss, nicht aus dem Keychain.
            if let url = (container?.configuredServer ?? .bundleFallback).accountSecurityURL {
                openURL(url)
            }
        }
        .accessibilityIdentifier("settings.security.webLink")
    }
}

// MARK: - Web security page

/// Die Sicherheitsseite der **konfigurierten** Instanz — das eine Ziel aller
/// „das geht nur im Browser"-Absprünge dieses Bereichs (UI-Standard R4).
///
/// Gegen den Keychain-Server aufgelöst, nicht gegen den Managed-Host: ein
/// Self-Hoster, den man auf `/settings/security` des Managed-Hosts schickt,
/// landet auf fremder Kontofläche. Rein + statisch, damit testbar — die
/// Fälle stehen in `PasskeyManagementWebLinkTests`.
enum AccountSecurityWebLink {
    /// `nil`, solange kein Server eingerichtet ist — es gibt dann keine
    /// Kontofläche, auf die man verlinken könnte.
    static func url(keychain: KeychainStoring?) -> URL? {
        ConfiguredServerSnapshot.resolve(keychain: keychain).accountSecurityURL
    }
}
