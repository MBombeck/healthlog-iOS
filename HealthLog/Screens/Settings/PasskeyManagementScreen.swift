import SwiftUI

/// Settings → Security → Passkeys.
///
/// **CU-15 (catchup-v134 A5) — registration lives on the web.** The native
/// enrolment button is gone: `POST /api/auth/passkey/register-options` and
/// `register-verify` are cookie-only plus re-proof-gated since server v1.34.1,
/// so a Bearer client (this app) gets `401 "Fresh existing-factor proof
/// required"` before the ceremony even starts. Rather than keep a button that
/// can only fail, the screen states where passkeys are added and links to the
/// **configured** server's security settings.
///
/// Everything else stays: the list, rename, and revoke verbs run on
/// `requireAuth()` routes (`/api/auth/passkeys*`), which accept Bearer — they
/// are genuinely reachable and remain the reason this screen exists.
struct PasskeyManagementScreen: View {
    @Environment(PasskeyManagementStore.self) private var store
    @Environment(\.appContainer) private var container
    @Environment(\.openURL) private var openURL
    @State private var pendingDeleteID: String?
    @State private var renameTarget: PasskeyEntry?
    @State private var renameText: String = ""
    @State private var refreshTick: Int = 0

    var body: some View {
        List {
            Section {
                if store.isLoading, store.passkeys.isEmpty {
                    ProgressView().frame(maxWidth: .infinity)
                } else if store.passkeys.isEmpty {
                    VStack(alignment: .leading, spacing: HLSpace.sm) {
                        Text("settings.passkeys.empty.title")
                            .font(.hlBody).foregroundStyle(HLText.secondary)
                        Text("settings.passkeys.empty.body")
                            .font(.hlCaption).foregroundStyle(HLText.tertiary)
                    }
                } else {
                    ForEach(store.passkeys) { passkey in
                        VStack(alignment: .leading, spacing: HLSpace.xs) {
                            Text(passkey.displayName).font(.hlHeadline)
                            Text("passkey.created \(passkey.createdAt.formatted(.dateTime.day().month().year()))")
                                .font(.hlCaption).foregroundStyle(HLText.secondary)
                            if let deviceLabel = passkey.deviceLabel {
                                Text(deviceLabel)
                                    .font(.hlCaption).foregroundStyle(HLText.tertiary)
                            }
                            Text(passkey.lastUsedLabel)
                                .font(.hlCaption).foregroundStyle(HLText.tertiary)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                pendingDeleteID = passkey.id
                            } label: { Label("settings.passkeys.delete.action", systemImage: "trash") }
                            // Rename closed the gap that left every credential
                            // the old native enrolment created permanently
                            // named "HealthLog" (it hardcoded the name). It
                            // stays useful for web-created credentials too.
                            Button {
                                renameText = passkey.displayName
                                renameTarget = passkey
                            } label: { Label("settings.passkeys.rename", systemImage: "pencil") }
                        }
                    }
                }
            } header: {
                Text("settings.passkeys.registered")
            }

            // CU-15 — replaces the former "Add new passkey" button, which could
            // only produce a 401 against server ≥ v1.34.1 (see type doc).
            Section {
                // R8 (Muster 1.11) — der rohe `Link` mit handgesetztem
                // Trailing-Glyph ist jetzt die kanonische Absprung-Zeile; das
                // `arrow.up.right.square` kommt vom `presents: .external`-
                // Vertrag des Primitives, nicht mehr vom Aufrufer.
                HLSettingsActionRow(
                    icon: "safari",
                    title: "settings.passkeys.web.link",
                    presents: .external
                ) {
                    // Ohne eingerichteten Server gibt es keine Kontoflaeche,
                    // die wir oeffnen koennten.
                    if let url = Self.webPasskeyManagementURL(keychain: container?.keychain) {
                        openURL(url)
                    }
                }
                .accessibilityIdentifier("settings.passkeys.webLink")
            } header: {
                Text("settings.passkeys.web.title")
            } footer: {
                // R12 — Fußnoten-Tinte in Listen-Gerüsten ist `HLText.secondary`.
                Text("settings.passkeys.web.body")
                    .foregroundStyle(HLText.secondary)
            }
            // v0.14.8 W2-SYNCUX — canonical sync-status footer (same primitive
            // as Dashboard/Insights, self-suppressing via empty-section footer).
            Section {} footer: {
                HLSyncStatusFooter(screenLoading: store.isLoading)
            }
        }
        // W3b B3 — iOS 26+ soft scroll-edge (no-op on iOS 18-25).
        .hlScrollEdgeSoft()
        .navigationTitle("settings.passkeys.title")
        // SET-V2-C (C-3) — sub-screen canon is `.inline` (vgl. SettingsExportScreen).
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.load() }
        .refreshable {
            await store.load()
            refreshTick &+= 1
        }
        // POLISH-SWEEP: success-tick confirms pull-to-refresh round-trip.
        .sensoryFeedback(.success, trigger: refreshTick)
        .hlConfirmDestructive(
            Text("settings.passkeys.delete.title"),
            isPresented: Binding(get: { pendingDeleteID != nil }, set: { if !$0 { pendingDeleteID = nil } }),
            message: Text("settings.passkeys.delete.message"),
            confirm: Text("settings.passkeys.delete.action"),
            cancel: Text("settings.passkeys.cancel"),
            onCancel: { pendingDeleteID = nil },
            action: {
                if let id = pendingDeleteID {
                    Task { await delete(id: id) }
                }
            }
        )
        .alert(
            "settings.passkeys.rename.title",
            isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
        ) {
            TextField("settings.passkeys.rename.field", text: $renameText)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
            Button("settings.passkeys.rename.save") {
                if let target = renameTarget {
                    Task { await rename(id: target.id) }
                }
            }
            // Mirrors the web submit-disabled rule: a whitespace-only name is
            // rejected client-side rather than bounced as a server 422.
            .disabled(!WebAuthnKeyName.isValid(renameText))
            Button("settings.passkeys.cancel", role: .cancel) { renameTarget = nil }
        }
        .alert(
            "settings.passkeys.error.title",
            isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.clearError() } }),
            presenting: store.error
        ) { _ in
            Button("OK") { store.clearError() }
        } message: { err in
            Text(err.localizedDescription)
        }
    }

    /// Dismisses the rename alert on **both** outcomes, not just success.
    ///
    /// A failure sets `store.error`, which drives the error alert. Leaving
    /// `renameTarget` non-nil would leave two alerts simultaneously asking to be
    /// presented from the same view — SwiftUI resolves that by showing one and
    /// silently dropping the other, so the user could lose the error entirely.
    /// Exactly one alert is ever live.
    private func rename(id: String) async {
        await store.rename(id: id, name: renameText)
        renameTarget = nil
    }

    private func delete(id: String) async {
        await store.delete(id: id)
        pendingDeleteID = nil
    }

    /// The **configured** instance's security settings — where passkeys are
    /// registered on the web.
    ///
    /// Resolved against the keychain-stored server URL, not the managed host:
    /// a self-hoster sent to the managed host's `/settings/security` would land
    /// on someone else's account surface. Same contract (and same reasoning) as
    /// ``SettingsAboutScreen/privacyPolicyURL(keychain:)``. Pure + static so it
    /// is unit-testable.
    ///
    /// U3: die Auflösung selbst lebt seit dem UI-Standard-Umbau in
    /// ``AccountSecurityWebLink`` — der Sicherheits-Hub, der 2FA-Screen und
    /// der Step-up-Picker springen auf dieselbe Seite und dürfen dafür nicht
    /// je eine eigene Kopie der Regel halten. Dieser Einstieg bleibt, weil die
    /// bestehende Test-Suite ihn festnagelt.
    /// `nil`, solange kein Server eingerichtet ist.
    static func webPasskeyManagementURL(keychain: KeychainStoring?) -> URL? {
        AccountSecurityWebLink.url(keychain: keychain)
    }
}

/// Server payload from `GET /api/auth/passkeys` (see `src/app/api/auth/passkeys/route.ts`).
/// Prisma `select` projects: `id`, `name` (nullable), `credentialDeviceType` (nullable),
/// `credentialBackedUp` (nullable), `createdAt`, and `lastUsedAt` (nullable).
///
/// **#60 — `lastUsedAt` restored (tolerant).** The server has tracked and delivered
/// `lastUsedAt` since v1.23.0 (`prisma/schema.prisma` `Passkey.lastUsedAt`, confirmed on
/// issue #60); `null` means the credential has not been used for a login yet. It is
/// decoded as `Date?` so an older self-hosted instance that omits the key still decodes
/// the list — the earlier removal was because a **non-optional** `lastUsedAt` made the
/// inner `[PasskeyEntry]` decode throw on a missing key, falling through to the
/// `{ data, error }` envelope ("Expected to decode Array<Any> but found a dictionary").
/// Optional avoids that: a missing key decodes to `nil`, never a throw.
public struct PasskeyEntry: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String?
    public let credentialDeviceType: String?
    public let credentialBackedUp: Bool?
    public let createdAt: Date
    public let lastUsedAt: Date?

    /// User-facing title: fall back to a date-derived label when the user never
    /// named the credential (server stores `name` nullable; older platform-bound
    /// authenticators created entries without a friendly name).
    var displayName: String {
        if let name, !name.isEmpty { return name }
        return String(localized: "Passkey")
    }

    /// Optional secondary line — SimpleWebAuthn reports `singleDevice` or
    /// `multiDevice` (synced via iCloud Keychain). Surface only when we have a
    /// value so the row stays compact for legacy entries.
    var deviceLabel: String? {
        switch credentialDeviceType {
        case "multiDevice": String(localized: "Synced via iCloud Keychain")
        case "singleDevice": String(localized: "Bound to this device")
        default: nil
        }
    }

    /// "Last used" line (#60). A concrete `lastUsedAt` renders the date; `nil`
    /// reads "never used" — which is the credential's honest state, since the
    /// server delivers `null` until the passkey is first used for a login.
    var lastUsedLabel: String {
        if let lastUsedAt {
            return String(
                localized: "passkey.lastUsed \(lastUsedAt.formatted(.dateTime.day().month().year()))"
            )
        }
        return String(localized: "settings.passkeys.neverUsed")
    }
}
