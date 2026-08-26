import SwiftUI

/// `/settings/integrations/whoop` — WHOOP integration detail. Mirrors
/// ``WithingsIntegrationScreen`` (server-brokered OAuth, `hasServer` gate, same
/// card style) plus the BYO-key delta: a credentials-entry step precedes the
/// Connect CTA.
///
/// **State machine** (driven by ``WhoopIntegrationStore/stage``):
/// 1. `.needsCredentials`  → Client ID/Secret entry card (`PUT /credentials`).
/// 2. `.needsConnect`      → "Connect WHOOP" CTA → `/api/whoop/connect` opened in
///                           the system browser (same mechanism Withings uses).
/// 3. `.connected`         → status + Sync now / Test / Disconnect / Remove creds.
///
/// The `clientSecret` lives only in this View's transient `@State`; it is passed
/// straight to `store.saveCredentials` and never logged or persisted.
struct WhoopIntegrationScreen: View {
    @Environment(WhoopIntegrationStore.self) private var store
    /// WHOOP is a pure (B) surface — the OAuth connect is impossible without a
    /// backend. Standalone renders the calm placeholder instead of a doomed
    /// browser tab. `hasServer` is always `true` in paired mode → inert there.
    @Environment(BackendAvailability.self) private var backend
    @Environment(AuthStore.self) private var authStore
    @State private var clientIdDraft: String = ""
    @State private var clientSecretDraft: String = ""
    @State private var refreshTick: Int = 0

    var body: some View {
        if backend.hasServer {
            liveBody
        } else {
            ScrollView {
                HLCloudDerivedPlaceholder(
                    variant: .hero,
                    surfaceName: String(localized: "cloud_derived.surface.whoop"),
                    onConnect: { authStore.beginServerPairing() }
                )
                .padding(HLSpace.lg)
            }
            .background(HLColor.background)
            .navigationTitle("WHOOP")
            // SET-V2-C (C-4) — integrations detail canon is `.inline` (uniform with AppleHealthIntegrationDetailScreen).
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    /// **UI-Standard U2 (R12) — Gerüst C→A.** Bis U2 ein handgebautes
    /// `ScrollView` + `HLCard` im `.elevated`-Stil: anderes Karten-Primitive
    /// (16 pt statt 14 pt Innenabstand, 1 pt volle Kontur statt 0,5 pt bei
    /// 0,6), handgebauter 17-pt-Kartenkopf und **kein** unterer Seitenrand.
    /// Liegt jetzt auf `HLSettingsPage` + `HLSettingsCard`.
    private var liveBody: some View {
        HLSettingsPage(title: "WHOOP") {
            connectionCard
            if store.stage == .needsCredentials {
                credentialsCard
            }
            // v0.14.8 W2-SYNCUX — canonical sync-status footer (same
            // primitive as Dashboard/Insights, self-suppressing).
            HLSyncStatusFooter(screenLoading: store.isWorking)
        }
        .navigationTitle("WHOOP")
        // SET-V2-C (C-4) — integrations detail canon is `.inline` (uniform with AppleHealthIntegrationDetailScreen).
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.loadStatus() }
        .refreshable {
            await store.loadStatus()
            refreshTick &+= 1
        }
        .sensoryFeedback(.success, trigger: refreshTick)
    }

    // MARK: - Connection card

    /// Status + Aktionen. Der frühere handgebaute 17-pt-Kartenkopf
    /// („Verbunden" / „Nicht konfiguriert" / …) ist jetzt die `HLStatusPill`
    /// im Trailing-Slot der Karte, wie auf der Integrationen-Liste.
    private var connectionCard: some View {
        HLSettingsCard(
            icon: "link.circle.fill",
            title: "WHOOP",
            trailing: { statusPill },
            content: { connectionBody }
        )
    }

    @ViewBuilder
    private var statusPill: some View {
        switch store.stage {
        case .loading:
            HLStatusPill(.unknown(label: String(localized: "Checking")))
        case .needsCredentials:
            HLStatusPill(.disconnected(label: String(localized: "Not configured")))
        case .needsConnect:
            HLStatusPill(.disconnected(label: String(localized: "Not connected")))
        case .tokenExpired:
            HLStatusPill(.error(label: String(localized: "Reconnect needed")))
        case .connected:
            HLStatusPill(.connected(label: String(localized: "Connected")))
        }
    }

    private var connectionBody: some View {
        VStack(alignment: .leading, spacing: HLSpace.md) {
            if let statusSubtitle {
                Text(statusSubtitle)
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            stageContent
            if let error = store.error {
                Text(mappedErrorMessage(error))
                    .font(.hlCaption)
                    .foregroundStyle(HLColor.statusBad)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.whoop.error")
            }
        }
    }

    /// Die eine Statuszeile der Karte. `nil` heißt: der Pill-Zustand und die
    /// Karte darunter sagen bereits alles.
    ///
    /// - `.needsCredentials` trug „Gib zum Start deine WHOOP-Entwickler-
    ///   Zugangsdaten ein." — genau das, was die Zugangsdaten-Karte direkt
    ///   darunter ausführlich erklärt (Klasse A, ersatzlos).
    /// - `.needsConnect` trug „Zugangsdaten gespeichert. Tippe unten, um zu
    ///   verbinden." — Audit-Gruppe 3: die zweite Hälfte beschreibt den Knopf
    ///   darunter, die erste ist echter Status und bleibt.
    private var statusSubtitle: String? {
        switch store.stage {
        case .loading:
            return String(localized: "Loading WHOOP status.")
        case .needsCredentials:
            return nil
        case .needsConnect:
            return String(localized: "whoop.status.credentialsSaved")
        case .tokenExpired:
            return String(localized: "Your WHOOP authorization expired — sync is paused.")
        case .connected:
            let last = store.status?.lastSyncedAt?.formatted(.relative(presentation: .named)) ?? "—"
            return String(localized: "Last sync \(last)")
        }
    }

    // MARK: - Stage content

    @ViewBuilder
    private var stageContent: some View {
        switch store.stage {
        case .loading, .needsCredentials:
            EmptyView()
        case .needsConnect:
            connectActions
        case .tokenExpired, .connected:
            connectedActions
        }
    }

    // MARK: - 1. Credentials entry

    private var credentialsCard: some View {
        HLSettingsCard(
            icon: "key.horizontal.fill",
            title: "WHOOP developer credentials"
        ) {
            // Klasse D — die Aussage „verschlüsselt auf deinem Server
            // gespeichert, nie auf diesem iPhone" bleibt wortgleich und an
            // ihrem Ort (direkt über den Feldern, die das Secret aufnehmen).
            Text(
                "Create a WHOOP developer app at developer.whoop.com, then paste its Client ID and Client Secret here. They are stored encrypted on your server and never on this iPhone."
            )
            .font(.hlCaption)
            .foregroundStyle(HLText.secondary)
            .fixedSize(horizontal: false, vertical: true)

            TextField(String(localized: "Client ID"), text: $clientIdDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("settings.whoop.clientIdField")

            SecureField(String(localized: "Client Secret"), text: $clientSecretDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("settings.whoop.clientSecretField")

            // v0.14.1 #6 — was "Save credentials" / "Zugangsdaten
            // speichern"; shortened to the canonical "Save" / "Speichern"
            // (operator: too long/confusing on credential screens).
            // R9 — „Speichern" am Formularende ist das Commit dieses Schritts;
            // in dieser Stufe rendert kein zweites `.primary`.
            HLButton(
                String(localized: "Save"),
                variant: .primary,
                isLoading: store.isWorking
            ) {
                Task { await saveCredentials() }
            }
            .disabled(!canSaveCredentials || store.isWorking)
            .accessibilityIdentifier("settings.whoop.saveCredentialsButton")
        }
    }

    private var canSaveCredentials: Bool {
        !clientIdDraft.trimmingCharacters(in: .whitespaces).isEmpty
            && !clientSecretDraft.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func saveCredentials() async {
        let id = clientIdDraft.trimmingCharacters(in: .whitespaces)
        let secret = clientSecretDraft.trimmingCharacters(in: .whitespaces)
        await store.saveCredentials(clientId: id, clientSecret: secret)
        // Wipe the transient secret from the field as soon as it leaves the
        // device — it is never needed again locally (server holds it encrypted).
        if store.error == nil {
            clientSecretDraft = ""
        }
    }

    // MARK: - 2. Connect

    private var connectActions: some View {
        VStack(alignment: .leading, spacing: HLSpace.md) {
            // R9 — „Verbinden" ist auf jedem Integrations-Screen das eine
            // `.primary`.
            HLButton(
                String(localized: "Connect WHOOP"),
                icon: "link",
                variant: .primary,
                isLoading: store.isWorking
            ) {
                Task { await store.connect() }
            }
            .accessibilityIdentifier("settings.whoop.connectButton")

            removeCredentialsRow
        }
    }

    // MARK: - 3. Connected

    private var connectedActions: some View {
        VStack(alignment: .leading, spacing: HLSpace.md) {
            if store.status?.tokenExpired == true {
                // Audit-Gruppe 4 — die Warnzeile „Deine WHOOP-Autorisierung ist
                // abgelaufen. Verbinde neu, um weiter zu synchronisieren."
                // stand hier zusätzlich zur Statuszeile der Karte („… – die
                // Synchronisierung pausiert.") und zum Pill „Erneut verbinden
                // nötig". Ersatzlos gefallen; die Statuszeile trägt die Folge.
                HLButton(
                    String(localized: "Reconnect WHOOP"),
                    icon: "link",
                    variant: .primary,
                    isLoading: store.isWorking
                ) {
                    Task { await store.connect() }
                }
                .accessibilityIdentifier("settings.whoop.reconnectButton")
            }
            if store.isRateLimitParked {
                rateLimitedParkedNotice
                HLButton(
                    String(localized: "Resume sync"),
                    icon: "play.circle",
                    variant: .secondary,
                    isLoading: store.isWorking
                ) {
                    Task { await store.resume() }
                }
                .accessibilityIdentifier("settings.whoop.resumeButton")
            }
            if let scope = store.status?.scope, !scope.isEmpty {
                detailRow(label: String(localized: "Scope"), value: scope)
            }

            HLButton(
                String(localized: "Sync now"),
                icon: "arrow.triangle.2.circlepath",
                variant: .secondary,
                isLoading: store.isWorking
            ) {
                Task { await store.syncNow() }
            }
            .accessibilityIdentifier("settings.whoop.syncButton")

            HLButton(
                String(localized: "Test connection"),
                icon: "checkmark.shield",
                variant: .secondary,
                isLoading: store.isWorking
            ) {
                Task { await store.testConnection() }
            }
            .accessibilityIdentifier("settings.whoop.testButton")

            if let result = store.lastTestResult, result.ok {
                testOkRow(result)
            }

            HLButton(String(localized: "Disconnect"), variant: .destructive) {
                Task { await store.disconnect() }
            }
            .accessibilityIdentifier("settings.whoop.disconnectButton")

            removeCredentialsRow
        }
    }

    private var rateLimitedParkedNotice: some View {
        HStack(alignment: .top, spacing: HLSpace.xs) {
            Image(systemName: "pause.circle.fill")
                .font(.hlIcon(HLIconSize.sm))
                .foregroundStyle(HLColor.statusBad)
            Text("WHOOP rate-limited the connection and paused syncing. Resume to continue.")
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func testOkRow(_ result: WhoopTestResult) -> some View {
        HStack(alignment: .top, spacing: HLSpace.xs) {
            Image(systemName: "checkmark.seal.fill")
                .font(.hlIcon(HLIconSize.sm))
                .foregroundStyle(HLColor.statusOK)
            Text(testOkText(result))
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings.whoop.testOk")
    }

    private func testOkText(_ result: WhoopTestResult) -> String {
        if let ms = result.latencyMs {
            String(localized: "Connection OK · \(ms) ms")
        } else {
            String(localized: "Connection OK")
        }
    }

    /// R8 (Audit-Muster 1.6) — war ein bloßer 13-pt-Text als Knopf, die
    /// leiseste destruktive Form der App. Jetzt die kanonische destruktive
    /// Zeile: 15 pt semibold rot mit rotem Chip.
    private var removeCredentialsRow: some View {
        HLSettingsActionRow(
            icon: "trash",
            title: "Remove credentials",
            role: .destructive,
            presents: .confirm
        ) {
            Task { await store.removeCredentials() }
        }
        .disabled(store.isWorking)
        .accessibilityIdentifier("settings.whoop.removeCredentialsButton")
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack(spacing: HLSpace.sm) {
            Text(label)
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
            Spacer(minLength: HLSpace.sm)
            Text(value)
                .font(.hlCaption.weight(.semibold))
                .foregroundStyle(HLText.primary)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Error mapping

    /// Maps the server `errorCode` (carried on `HLError.server(code:)`) to a
    /// human message for the `test` probe + the connect/credentials failures.
    private func mappedErrorMessage(_ error: HLError) -> String {
        if case let .server(_, code, message) = error {
            switch code {
            case "not_configured":
                return String(localized: "Save your WHOOP credentials before testing.")
            case "credentials_rejected":
                return String(localized: "WHOOP rejected these credentials. Check the Client ID and Secret.")
            case "rate_limited", "rate_limited_self":
                return String(localized: "WHOOP is rate-limiting requests. Try again in a moment.")
            case "upstream_error":
                return String(localized: "WHOOP returned an error. Try again later.")
            case "connection_failed":
                return String(localized: "Couldn't reach WHOOP. Check your connection and retry.")
            case "timeout":
                return String(localized: "WHOOP took too long to respond. Try again.")
            default:
                return message
            }
        }
        return error.localizedDescription
    }
}
