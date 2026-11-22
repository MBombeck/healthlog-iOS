import SwiftUI

/// Settings → Security — the account-protection hub.
///
/// **2FA management is now native.** Since server v1.32.3 the second-factor
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
/// zugunsten der Zeile: jede der drei Karten trägt jetzt genau **eine**
/// `HLSettingsActionRow`, das Trailing-Glyph kommt vom `presents:`-Vertrag
/// (R10), und das Gerüst ist `HLPage` statt des handgebauten
/// `ScrollView` (R12, Gerüst B→A).
struct SettingsSecurityScreen: View {
    /// See ``SettingsAccountScreen``: values on the More
    /// stack, view pushes in the avatar sheet's own stack.
    private let routesByValue: Bool

    init(routesByValue: Bool = false) {
        self.routesByValue = routesByValue
    }

    @Environment(AccountSecurityStore.self) private var store
    @Environment(\.appContainer) private var container
    @Environment(\.openURL) private var openURL
    @State private var showChangePassword = false

    var body: some View {
        HLPage {
            // How you sign in and who is signed in, as rows of one card: four
            // cards of one row each read as four topics. Two-factor sign-in is
            // a row with its state as the value once the state is known.
            HLCard(layout: .rows) {
                passwordRow
                passkeysRow
                if case let .loaded(status) = store.twoFactor {
                    twoFactorRow(status)
                }
                // 1.5 (Alex, 07.11.) — who is signed in belongs with how they
                // sign in. Moved here from Konto.
                sessionsRow
            }
            if !store.twoFactor.isLoaded {
                twoFactorCard
            }
        }
        .navigationTitle("settings.security.title")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showChangePassword) {
            ChangePasswordSheet()
        }
        .task { await store.loadTwoFactor() }
    }

    /// Active sessions (from Konto since 1.5). Title and row say
    /// it, no subtitle.
    private var sessionsRow: some View {
        Group {
            if routesByValue {
                HLSettingsActionRow(title: "sessions.title", presents: .push, value: SettingsRoute.sessions)
            } else {
                HLSettingsActionRow(title: "sessions.title", presents: .push) {
                    SessionsScreen()
                }
            }
        }
        .accessibilityIdentifier("settings.security.sessionsRow")
    }

    /// R2/R5 — der frühere Subtitle („Ersetze dein aktuelles Passwort durch ein
    /// neues.") formulierte die Zeile darunter um und fällt damit die
    /// Abdeck-Probe: Kartentitel + Zeile bedienen sich unverändert.
    /// One row, one heading: "Passwort ändern" says it.
    private var passwordRow: some View {
        HLSettingsActionRow(
            title: "settings.security.password.cta",
            presents: .sheet
        ) {
            showChangePassword = true
        }
        .accessibilityIdentifier("settings.security.changePasswordRow")
    }

    /// R3/R9 (Audit-Gruppe „Hier verwaltest du Passwort / Passkeys / 2FA") —
    /// der Subtitle war ein Copy-Paste-Griff nach `settings.security.subtitle`
    /// und beschrieb den ganzen Hub statt dieser Karte. Seine Heimat ist die
    /// Konto-Karte, die hierher führt.
    /// One row, one heading: the row names its screen.
    private var passkeysRow: some View {
        Group {
            if routesByValue {
                HLSettingsActionRow(title: "settings.passkeys.title", presents: .push, value: SettingsRoute.passkeys)
            } else {
                HLSettingsActionRow(title: "settings.passkeys.title", presents: .push) {
                    PasskeyManagementScreen()
                }
            }
        }
        .accessibilityIdentifier("settings.security.passkeysRow")
    }

    /// Two-factor sign-in as a row: its state is the value ("Off"), the
    /// recovery codes left are the detail, the row opens the management
    /// page. The status line under a card title repeated the title.
    private func twoFactorRow(_ status: MfaStatus) -> some View {
        let subtitle: LocalizedStringKey? = status.totp.enabled
            ? "settings.security.twoFactor.recoveryRemaining \(status.recoveryCodesRemaining)"
            : nil
        let state = HLSettingsRowValueText(value: String(localized: status.totp.enabled
                ? "settings.security.twoFactor.state.on"
                : "settings.security.twoFactor.state.off"))
        return Group {
            if routesByValue {
                HLSettingsActionRow(
                    title: "settings.security.twoFactor.title",
                    subtitle: subtitle,
                    presents: .push,
                    value: SettingsRoute.twoFactor,
                    trailing: { state }
                )
            } else {
                HLSettingsActionRow(
                    title: "settings.security.twoFactor.title",
                    subtitle: subtitle,
                    presents: .push,
                    trailing: { state },
                    destination: { TwoFactorManagementScreen() }
                )
            }
        }
        .accessibilityIdentifier("settings.security.twoFactorManageRow")
    }

    /// Real status now — no more "status unknown" guess. Drives the native flows
    /// when the server supports them, and jumps to the web security page on an
    /// older instance.
    private var twoFactorCard: some View {
        HLCard("settings.security.twoFactor.title") {
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
                    .hlText(.factLabel)
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
            // „Erneut versuchen" ist app-weit `.secondary`.
            HLButton(
                "settings.security.twoFactor.retry",
                variant: .secondary,
                action: { Task { await store.loadTwoFactor() } }
            )
        case let .loaded(status):
            statusLine(status)
            Group {
                if routesByValue {
                    HLSettingsActionRow(title: "settings.security.twoFactor.manage", presents: .push, value: SettingsRoute.twoFactor)
                } else {
                    HLSettingsActionRow(title: "settings.security.twoFactor.manage", presents: .push) {
                        TwoFactorManagementScreen()
                    }
                }
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
                    .hlText(.rowTitle)
                if status.totp.enabled {
                    Text("settings.security.twoFactor.recoveryRemaining \(status.recoveryCodesRemaining)")
                        .hlText(.rowSubtitle)
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
            // Aus dem Server-Schnappschuss, nicht aus dem Keychain.
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

private extension AccountSecurityStore.TwoFactorState {
    /// Whether the state is known, so two-factor sign-in stands as a row of
    /// the sign-in card instead of in a card of its own.
    var isLoaded: Bool {
        if case .loaded = self { return true }
        return false
    }
}
