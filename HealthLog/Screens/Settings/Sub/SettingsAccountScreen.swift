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
/// **v0.11 IA — Abmelden + Konto löschen live here now.** They previously
/// rendered as two top-level Sections at the bottom of the Settings *hub*
/// (`SettingsScreen`). The operator wanted both account-lifecycle actions
/// under Profil/Konto rather than floating beside the hub navigation rows,
/// so they moved onto this screen. Behaviour is unchanged: sign-out drops
/// the session locally (server data is preserved), delete wipes the account
/// server-side via `DeleteAccountScreen`. Both stay HIG-correct — recoverable
/// sign-out first, irreversible delete last with its cautionary footer — and
/// keep their a11y identifiers + destructive role. As before they only
/// surface on a server-paired install; a standalone install has no server
/// account to sign out of or delete.
struct SettingsAccountScreen: View {
    @Environment(AuthStore.self) private var authStore
    @Environment(SyncModeStore.self) private var syncMode

    /// v0.11 IA — Konto-löschen confirmation sheet. Relocated from
    /// `SettingsScreen` together with the delete card so the destructive
    /// flow lives next to the action that opens it. Same `DeleteAccountScreen`
    /// the hub previously presented, same `.topBarTrailing` close button.
    @State private var showDeleteConfirmation = false

    /// Parity 2.5 — the data-reset sheet, presented with the same modal idiom as
    /// the account-deletion sheet below so the two destructive flows feel like
    /// siblings rather than two different mechanisms.
    @State private var showResetDataConfirmation = false

    /// SET-6 (AUDIT-QOL-UX §5) — profile editing presented as a sheet (an edit is
    /// a modal transaction), matching `EditMeasurementSheet`/`EditMoodSheet`/etc.
    /// Replaces the lone push-based profile editor flagged by the QoL audit.
    @State private var showEditProfile = false

    /// 08-09 — sign-out is destructive and now asks first. The row below used to
    /// call `authStore.logout()` straight out of its tap handler: `presents:
    /// .confirm` only ever meant "paint no chevron", so a mis-tap ended the
    /// session before it could be taken back. The dialog, its copy and the
    /// once-only guarantee live in `LogoutConfirmationModifier`; this screen
    /// keeps the state so the row can dim while the existing cleanup runs.
    @State private var logoutConfirmation = LogoutConfirmationState()

    var body: some View {
        HLSettingsPage(title: "Account") {
            profileCard
            // W-B187 (Settings consolidation §A.2) — the Units card moved OUT of
            // Account INTO the Profile editor (`EditProfileScreen`), alongside the
            // relocated time-format picker, so "how I read my own data" (units +
            // clock) lives in one place. Account now holds only profile-link +
            // Passkeys + Sign-out + Delete (account-lifecycle only).
            securityCard
            // v0.12 W7-1 (preserved) — Sign-out + Delete-account are server
            // account actions; a standalone install has no server account and
            // no token, so surfacing them there would fire doomed server calls
            // and drop the user into a dead-end delete flow. Hidden until the
            // install is paired. Parity 2.2 (sessions) and 2.5 (data reset) are
            // server actions for the same reason and join the same gate.
            if !syncMode.isStandalone {
                sessionsCard
                signOutCard
                resetDataCard
                deleteAccountCard
            }
        }
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
        // v0.11 IA — Konto-löschen sheet relocated here alongside the delete
        // card it serves. Same DeleteAccountScreen the hub previously mounted.
        .sheet(isPresented: $showDeleteConfirmation) {
            NavigationStack {
                DeleteAccountScreen()
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(String(localized: "Close")) {
                                showDeleteConfirmation = false
                            }
                        }
                    }
            }
            .hlSheetPresentation(.form)
        }
        // Parity 2.5 — data-reset sheet, same presentation as the delete sheet.
        .sheet(isPresented: $showResetDataConfirmation) {
            NavigationStack {
                ResetDataScreen()
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(String(localized: "Close")) {
                                showResetDataConfirmation = false
                            }
                        }
                    }
            }
            .hlSheetPresentation(.form)
        }
        // SET-6 — profile editor as a sheet (was a push), aligning with every
        // other edit surface in the app.
        .sheet(isPresented: $showEditProfile) {
            EditProfileSheet()
        }
        // 08-09 — the shared destructive confirmation. `AuthStore.logout()` stays
        // the single cleanup path; the only thing that changed is that it is now
        // reached from an answered dialog instead of from a tap.
        .hlLogoutConfirmation($logoutConfirmation) {
            await authStore.logout()
        }
    }

    private var profileCard: some View {
        HLSettingsCard(
            icon: "person.crop.circle.fill",
            title: "Profile",
            subtitle: "Display name, date of birth, height, time zone."
        ) {
            // R10 — die Zeile öffnete schon immer ein Sheet, trug aber einen
            // Chevron. `presents: .sheet` malt jetzt das `pencil` und macht
            // die Bearbeiten-Transaktion vor dem Tippen sichtbar.
            HLSettingsActionRow(title: "Open profile", presents: .sheet) {
                showEditProfile = true
            }
            .accessibilityIdentifier("settings.account.profileRow")
        }
    }

    /// Entry point into Settings → Security.
    ///
    /// Replaces the former passkey-only card: passkeys now live *inside* the
    /// security hub alongside password change, so the account screen offers one
    /// "how I secure my account" door instead of a lone credential list. Also
    /// retires three hardcoded English literals ("Passkeys", "Sign in with Face
    /// ID instead of a password.", "Manage passkeys") flagged by audit C12.
    private var securityCard: some View {
        HLSettingsCard(
            icon: "lock.shield",
            title: "settings.security.title",
            subtitle: "settings.security.subtitle"
        ) {
            HLSettingsActionRow(title: "settings.security.open", presents: .push) {
                SettingsSecurityScreen()
            }
            .accessibilityIdentifier("settings.account.securityRow")
        }
    }

    /// Parity 2.2 — active sessions. Sits directly above sign-out: both answer
    /// "who is signed in to my account", and the single-device answer
    /// (sign myself out here) belongs next to the all-devices one.
    private var sessionsCard: some View {
        HLSettingsCard(
            icon: "desktopcomputer",
            title: "sessions.title",
            subtitle: "sessions.card.subtitle"
        ) {
            HLSettingsActionRow(title: "sessions.card.manage", presents: .push) {
                SessionsScreen()
            }
            .accessibilityIdentifier("settings.account.sessionsRow")
        }
    }

    // MARK: - Account lifecycle (relocated from SettingsScreen, v0.11 IA)

    /// Sign-out is a *recoverable* action — it drops the session locally while
    /// the server keeps the user's data. It sits above the irreversible delete
    /// card so the recoverable affordance is never adjacent to the destructive
    /// one (Apple HIG destructive-action discipline). Reuses the `MoreScreen`
    /// `Layout` row descriptors so the copy stays a single source of truth.
    private var signOutCard: some View {
        HLSettingsCard(
            icon: "rectangle.portrait.and.arrow.right",
            title: LocalizedStringKey(MoreScreen.Layout.signOutRow.title),
            subtitle: MoreScreen.Layout.signOutRow.subtitle.map { LocalizedStringKey($0) }
        ) {
            HLSettingsActionRow(
                icon: MoreScreen.Layout.signOutRow.icon,
                title: LocalizedStringKey(MoreScreen.Layout.signOutRow.title),
                role: .destructive,
                presents: .confirm
            ) {
                logoutConfirmation.request()
            }
            .disabled(logoutConfirmation.isSigningOut)
            .accessibilityIdentifier(MoreScreen.Layout.signOutRow.accessibilityIdentifier)
        }
    }

    /// Parity 2.5 — reset health data without deleting the account. Deliberately
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
    private var resetDataCard: some View {
        HLSettingsCard(
            icon: "arrow.counterclockwise",
            title: "resetData.title",
            subtitle: "resetData.card.subtitle"
        ) {
            HLSettingsActionRow(
                icon: "arrow.counterclockwise",
                title: "resetData.card.action",
                role: .destructive,
                presents: .confirm
            ) {
                showResetDataConfirmation = true
            }
            .accessibilityIdentifier("settings.account.resetDataRow")
        }
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
    private var deleteAccountCard: some View {
        HLSettingsCard(
            icon: "trash.fill",
            title: LocalizedStringKey(MoreScreen.Layout.deleteAccountRow.title),
            subtitle: MoreScreen.Layout.deleteAccountRow.subtitle.map { LocalizedStringKey($0) }
        ) {
            HLSettingsActionRow(
                icon: MoreScreen.Layout.deleteAccountRow.icon,
                title: LocalizedStringKey(MoreScreen.Layout.deleteAccountRow.title),
                role: .destructive,
                presents: .confirm
            ) {
                showDeleteConfirmation = true
            }
            .accessibilityIdentifier(MoreScreen.Layout.deleteAccountRow.accessibilityIdentifier)
        }
    }
}
