import SwiftUI

/// `/settings/account` — Konto. Ships the two cards that have real iOS
/// surfaces — Profil + Passkeys — and drops the Passwort + Onboarding-Tour
/// placeholders that PB3 originally shipped, per operator AC18 directive.
///
/// Y6 collapsed the dashboard avatar entry-point onto `ProfileScreen` →
/// `EditProfileScreen`. The Konto card here pushes the same
/// `EditProfileScreen` so there is exactly one profile-editing surface in
/// the app; the legacy `PersonalSettingsScreen` was deleted in Y8.
///
/// **Abmelden + Konto löschen live here now.** They previously
/// rendered as two top-level Sections at the bottom of the Settings *hub*
/// (`SettingsScreen`). The operator wanted both account-lifecycle actions
/// under Profil/Konto rather than floating beside the hub navigation rows,
/// so they moved onto this screen. Behaviour is unchanged: sign-out drops
/// the session locally (server data is preserved), delete wipes the account
/// server-side via `DeleteAccountScreen`. Both stay HIG-correct — recoverable
/// sign-out first, irreversible delete last with its cautionary footer — and
/// keep their a11y identifiers + destructive role.
struct SettingsAccountScreen: View {
    /// On the More stack the pushes below are values, so the
    /// page under the privacy shield comes back. The avatar sheet on Today
    /// hosts this screen in its own stack without those destinations and
    /// keeps the view pushes.
    private let routesByValue: Bool

    /// 1.5 (Alex, 07.11.) — the avatar sheet on Today is the quick account
    /// door: profile, security, sessions and sign-out. Resetting data and
    /// deleting the account live only under Einstellungen > Konto.
    let showsIrreversibleActions: Bool

    init(routesByValue: Bool = false, showsIrreversibleActions: Bool = true) {
        self.routesByValue = routesByValue
        self.showsIrreversibleActions = showsIrreversibleActions
    }

    @Environment(AuthStore.self) private var authStore

    /// Konto-löschen confirmation sheet. Relocated from
    /// `SettingsScreen` together with the delete card so the destructive
    /// flow lives next to the action that opens it. Same `DeleteAccountScreen`
    /// the hub previously presented, same `.topBarTrailing` close button.
    @State private var showDeleteConfirmation = false

    /// The data-reset sheet, presented with the same modal idiom as
    /// the account-deletion sheet below so the two destructive flows feel like
    /// siblings rather than two different mechanisms.
    @State private var showResetDataConfirmation = false

    /// Profile editing presented as a sheet (an edit is
    /// a modal transaction), matching `EditMeasurementSheet`/`EditMoodSheet`/etc.
    /// Replaces the lone push-based profile editor flagged by the QoL audit.
    @State private var showEditProfile = false

    /// Sign-out is destructive and now asks first. The row below used to
    /// call `authStore.logout()` straight out of its tap handler: `presents:
    /// .confirm` only ever meant "paint no chevron", so a mis-tap ended the
    /// session before it could be taken back. The dialog, its copy and the
    /// once-only guarantee live in `LogoutConfirmationModifier`; this screen
    /// keeps the state so the row can dim while the existing cleanup runs.
    @State private var logoutConfirmation = LogoutConfirmationState()

    var body: some View {
        HLPage {
            // Two row cards: the account itself (profile, security), then
            // its lifecycle (sign out, and where allowed reset and delete).
            // W-B187 — the Units card lives in the profile editor; 1.5
            // (Alex, 07.11.) — active sessions moved into Sicherheit.
            accountCard
            lifecycleCard
        }
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
        // Konto-löschen sheet relocated here alongside the delete
        // card it serves. Same DeleteAccountScreen the hub previously mounted.
        .sheet(isPresented: $showDeleteConfirmation) {
            HLSheetScaffold("Delete account") {
                DeleteAccountScreen()
            }
        }
        // Data-reset sheet, same presentation as the delete sheet.
        .sheet(isPresented: $showResetDataConfirmation) {
            HLSheetScaffold("resetData.navTitle") {
                ResetDataScreen()
            }
        }
        // Profile editor as a sheet (was a push), aligning with every
        // other edit surface in the app.
        .sheet(isPresented: $showEditProfile) {
            EditProfileSheet()
        }
        // The shared destructive confirmation. `AuthStore.logout()` stays
        // the single cleanup path; the only thing that changed is that it is now
        // reached from an answered dialog instead of from a tap.
        .hlLogoutConfirmation($logoutConfirmation) {
            await authStore.logout()
        }
    }

    /// Profile and security in one row card. Every row carries its symbol
    /// chip, so the rows of both cards stand on one line.
    private var accountCard: some View {
        HLCard(layout: .rows) {
            profileRow
            securityRow
        }
    }

    /// Sign out, then the lesser destruction, then the irreversible one, in
    /// one row card: the order keeps the recoverable row away from delete.
    private var lifecycleCard: some View {
        HLCard(layout: .rows) {
            signOutRow
            if showsIrreversibleActions {
                resetDataRow
                deleteAccountRow
            }
        }
    }

    private var profileRow: some View {
        HLSettingsActionRow(
            icon: "person.crop.circle.fill",
            title: "Profile",
            subtitle: "Display name, date of birth, height, time zone.",
            presents: .sheet
        ) {
            showEditProfile = true
        }
        .accessibilityIdentifier("settings.account.profileRow")
    }

    /// Entry point into Settings → Security.
    ///
    /// Replaces the former passkey-only card: passkeys now live *inside* the
    /// security hub alongside password change, so the account screen offers one
    /// "how I secure my account" door instead of a lone credential list. Also
    /// retires three hardcoded English literals ("Passkeys", "Sign in with Face
    /// ID instead of a password.", "Manage passkeys") flagged by audit C12.
    private var securityRow: some View {
        Group {
            if routesByValue {
                HLSettingsActionRow(
                    icon: "lock.shield.fill",
                    title: "settings.security.title",
                    subtitle: "settings.security.subtitle",
                    presents: .push,
                    value: SettingsRoute.security
                )
            } else {
                HLSettingsActionRow(
                    icon: "lock.shield.fill",
                    title: "settings.security.title",
                    subtitle: "settings.security.subtitle",
                    presents: .push
                ) {
                    SettingsSecurityScreen()
                }
            }
        }
        .accessibilityIdentifier("settings.account.securityRow")
    }

    // MARK: - Account lifecycle

    /// Sign-out is a *recoverable* action: it drops the session locally while
    /// the server keeps the user's data. It is the first row of the lifecycle
    /// card; the lesser destruction (reset) stands between it and the
    /// irreversible delete, so the recoverable row never sits next to delete
    /// (Apple HIG destructive-action discipline). Reuses the `MoreScreen`
    /// `Layout` row descriptors so the copy stays a single source of truth.
    private var signOutRow: some View {
        HLSettingsActionRow(
            icon: MoreScreen.Layout.signOutRow.icon,
            title: LocalizedStringKey(MoreScreen.Layout.signOutRow.title),
            subtitle: MoreScreen.Layout.signOutRow.subtitle.map { LocalizedStringKey($0) },
            role: .destructive,
            presents: .confirm
        ) {
            logoutConfirmation.request()
        }
        .disabled(logoutConfirmation.isSigningOut)
        .accessibilityIdentifier(MoreScreen.Layout.signOutRow.accessibilityIdentifier)
    }

    /// Reset health data without deleting the account. Deliberately
    /// placed BETWEEN sign-out and delete-account: it is destructive, so it sits
    /// below the recoverable action, but it is the *lesser* destruction, so it
    /// precedes the irreversible one. That ordering also makes it discoverable
    /// to the user who came here to delete their account but actually only wants
    /// their data gone — the whole point of the feature.
    ///
    /// **R19 (`privacy-review`) — Entdopplung, keine Kürzung.** Der frühere
    /// Karten-Footer sagte dasselbe wie der Subtitle darüber („Konto und
    /// Anmeldung bleiben") plus dasselbe wie `resetData.explain.keepsAccount`
    /// und `resetData.explain.bullet.irreversible` auf dem Screen, den die
    /// Zeile darunter öffnet. Die Zusicherung steht dort in voller Stärke —
    /// am Ort der Entscheidung, und dort sogar präziser (sie nennt die
    /// Passkeys namentlich).
    private var resetDataRow: some View {
        // The promise (account and sign-in stay) is the reason to pick this
        // row over deletion; it is the row's detail line like its neighbours'.
        HLSettingsActionRow(
            icon: "arrow.counterclockwise",
            title: "resetData.title",
            subtitle: "settings.account.resetData.rowSubtitle",
            // hl-delete-ladder: stage-3 resetting all data goes through its own typed confirmation screen
            role: .destructive,
            presents: .confirm
        ) {
            showResetDataConfirmation = true
        }
        .accessibilityIdentifier("settings.account.resetDataRow")
    }

    /// Delete-account is the irreversible action, isolated last before the user
    /// reaches the type-to-confirm `DeleteAccountScreen` sheet.
    ///
    /// **R19 (`privacy-review`) — Entdopplung, keine Kürzung.** Subtitle und
    /// Footer trugen dieselben zwei Aussagen („entfernt alle serverseitigen
    /// Daten" / „nicht rückgängig"), und der Screen dahinter sagt beide noch
    /// einmal in zwei Sätzen. Der Subtitle bleibt vollständig
    /// („Unwiderruflich · Server entfernt alle Daten"), die ausführliche
    /// Warnung lebt am Ort der Handlung (`DeleteAccountScreen`, Intro-Satz +
    /// Bullet „Diese Aktion kann nicht rückgängig gemacht werden.").
    private var deleteAccountRow: some View {
        HLSettingsActionRow(
            icon: MoreScreen.Layout.deleteAccountRow.icon,
            title: LocalizedStringKey(MoreScreen.Layout.deleteAccountRow.title),
            subtitle: MoreScreen.Layout.deleteAccountRow.subtitle.map { LocalizedStringKey($0) },
            // hl-delete-ladder: stage-3 deleting the account goes through its own typed confirmation screen
            role: .destructive,
            presents: .confirm
        ) {
            showDeleteConfirmation = true
        }
        .accessibilityIdentifier(MoreScreen.Layout.deleteAccountRow.accessibilityIdentifier)
    }
}
