import SwiftUI
#if canImport(SafariServices)
    import SafariServices
#endif

/// Connect / manage surface for the server-OAuth wearables **Oura**, **Polar**
/// and **Fitbit** (Google Health). Mirrors ``WithingsIntegrationScreen`` — a
/// pure backend (B) surface: the connect flow is a server-brokered 3-leg OAuth
/// (`GET /api/<provider>/connect`, a 302 redirect), impossible without a
/// backend. In standalone we render the calm ``HLCloudDerivedPlaceholder``
/// instead of a "Connect" button that opens a doomed browser tab.
///
/// The data these providers sync (`MeasurementSource`) already flows
/// server-side; this is the missing iOS manage card (web-parity ❌-7).
///
/// **UI-Standard U2 (R12) — Gerüst C→A.** Diese Seite lief bis U2 auf einem
/// handgebauten `ScrollView` + `HLCard` im `.elevated`-Stil: anderes Karten-
/// Primitive (16 pt statt 14 pt Innenabstand, 1 pt volle Kontur statt 0,5 pt
/// bei 0,6), handgebauter 17-pt-Kartenkopf und **kein** unterer Seitenrand.
/// Sie liegt jetzt auf `HLSettingsPage` + `HLSettingsCard` wie ihr migriertes
/// fünftes Geschwister ``AppleHealthIntegrationDetailScreen``.
///
/// **R3 — der durchgereichte Provider-Satz ist weg.** „Schlaf, Readiness und
/// Aktivität aus deinem Oura-Konto importieren." stand als Karten-Untertitel
/// auf der Integrationen-Liste *und* wurde als `subtitle:`-Parameter hierher
/// durchgereicht und erneut gemalt (Audit-Gruppe 2, 8 Fundstellen / 4 Sätze).
/// Die Heimat ist die Liste — dort fällt die Navigationsentscheidung. Der
/// Parameter existiert nicht mehr; `integration.oauth.howItWorks` erklärt
/// dasselbe Thema hier konkret.
struct OAuthIntegrationScreen<Store: OAuthIntegrationStoreProtocol & Observable & AnyObject>: View {
    @Environment(\.appContainer) private var container
    @Environment(BackendAvailability.self) private var backend
    @Environment(AuthStore.self) private var authStore
    @Environment(Store.self) private var store

    let displayName: String
    /// Localized cloud-derived placeholder surface name for standalone mode.
    let placeholderSurface: String

    @State private var refreshTick: Int = 0
    /// BYO-credential form drafts — held transiently only; the secret never
    /// reaches disk and is cleared once saved (server stores it encrypted).
    @State private var clientIdDraft: String = ""
    @State private var clientSecretDraft: String = ""

    var body: some View {
        if backend.hasServer {
            liveBody
        } else {
            ScrollView {
                HLCloudDerivedPlaceholder(
                    variant: .hero,
                    surfaceName: placeholderSurface,
                    onConnect: { authStore.beginServerPairing() }
                )
                .padding(HLSpace.lg)
            }
            .background(HLColor.background)
            .navigationTitle(Text(displayName))
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var liveBody: some View {
        // 1.4 B2-c — no sync footer: the card's "Last sync" line is the
        // provider's sync, the app's own sync state has no bearing here.
        HLSettingsPage(title: LocalizedStringKey(displayName)) {
            connectionCard
            if showsCredentialsCard {
                credentialsCard
            }
        }
        .navigationTitle(Text(displayName))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await store.loadStatus()
            await store.loadCredentialsStatus()
        }
        .refreshable {
            await store.loadStatus()
            await store.loadCredentialsStatus()
            refreshTick &+= 1
        }
        .sensoryFeedback(.success, trigger: refreshTick)
    }

    // MARK: - Connection

    /// Status + Aktionen in einer Karte: der Kartenkopf trägt den Provider, die
    /// `HLStatusPill` den Zustand (vorher ein handgebauter 17-pt-Titel
    /// „Verbunden" / „Nicht verbunden"), der Footer die Datenschutz-Aussage.
    /// 1.4 B2-c: die Aussage ist ein Satz (Anmeldung im Browser, das Passwort
    /// sieht HealthLog nie) und steht nur, solange noch nicht verbunden ist;
    /// Token und Server sind aus dem Text.
    private var connectionCard: some View {
        HLSettingsCard(
            icon: "link.circle.fill",
            title: LocalizedStringKey(displayName),
            footer: store.isConnected == true ? nil : "integration.oauth.howItWorks",
            trailing: { statusPill },
            content: { connectionBody }
        )
    }

    /// 1.4 B2-c — the own-credentials card is an instance-admin tool: it shows
    /// while the provider is not connected (the instance may need its own app)
    /// or while own credentials are stored (so they can be removed), never
    /// beside a connection that already works without them.
    private var showsCredentialsCard: Bool {
        store.isConnected != true || store.hasOwnCredentials == true
    }

    @ViewBuilder
    private var statusPill: some View {
        switch store.isConnected {
        case .some(true):
            // #139 — a connected provider's pill follows `health.state`; a
            // server without `health` keeps the plain "Connected".
            if let health = store.status?.health {
                HLStatusPill(ConnectionHealthPresentation(health: health).pill)
            } else {
                HLStatusPill(.connected(label: String(localized: "Connected")))
            }
        case .some(false):
            HLStatusPill(.disconnected(label: String(localized: "Not connected")))
        case .none:
            // 1.4 B4 — "Checking" only while it is, not after a failed read.
            if store.error == nil {
                HLStatusPill(.unknown(label: String(localized: "Checking")))
            }
        }
    }

    private var connectionBody: some View {
        VStack(alignment: .leading, spacing: HLSpace.md) {
            // R2 Folge/Status — die einzige Zeile, die der Kartenkopf nicht
            // schon trägt. Die frühere „Tippe unten, um zu verbinden."-Caption
            // im Nicht-verbunden-Zweig (Audit-Gruppe 3) ist ersatzlos gefallen:
            // der Knopf darunter beschriftet sich selbst.
            if let status = store.status, status.connected {
                Text("Last sync \(status.lastSync?.formatted(.relative(presentation: .named)) ?? "—")")
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                if let health = status.health {
                    ConnectionHealthSection(
                        health: health,
                        supportedActions: supportedHealthActions,
                        isWorking: store.isWorking
                    ) { action in
                        Task { await perform(action) }
                    }
                }
            }
            actions
            if let result = store.lastTestResult {
                testResultRow(result)
            }
            if let error = store.error {
                // 1.4 B4 — a sentence for people, never the decoder's text; the
                // route and error id are in "Support-Info kopieren".
                Text(error.userFacingDescription)
                    .font(.hlCaption)
                    .foregroundStyle(HLColor.statusBad)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - BYO credentials (per-user OAuth client id/secret)

    /// Lets a self-hoster register their OWN OAuth app credentials so the connect
    /// flow works on an instance without a shared env app. On managed cloud this
    /// is optional (the env app is the default); the copy says so.
    private var credentialsCard: some View {
        HLSettingsCard(
            icon: "key.horizontal.fill",
            title: "integration.byo.title",
            subtitle: "integration.byo.subtitle"
        ) {
            if store.hasOwnCredentials == true {
                HStack(spacing: HLSpace.md) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(HLColor.statusOK)
                    Text("integration.byo.set")
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.primary)
                }
                HLButton("integration.byo.remove", variant: .destructive, isLoading: store.isWorking) {
                    Task { await store.deleteCredentials() }
                }
                .accessibilityIdentifier("integration.byo.remove")
            } else {
                TextField(String(localized: "integration.byo.clientId.placeholder"), text: $clientIdDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("integration.byo.clientId")
                SecureField(String(localized: "integration.byo.clientSecret.placeholder"), text: $clientSecretDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("integration.byo.clientSecret")
                // R9 — nachgeordnete Vollbreiten-Aktion: das `.primary` dieses
                // Screens ist „Verbinden" in der Karte darüber.
                HLButton("integration.byo.save", variant: .secondary, isLoading: store.isWorking) {
                    Task { await saveCredentials() }
                }
                .disabled(!canSaveCredentials || store.isWorking)
                .accessibilityIdentifier("integration.byo.save")
            }
        }
    }

    private var canSaveCredentials: Bool {
        !clientIdDraft.trimmingCharacters(in: .whitespaces).isEmpty
            && !clientSecretDraft.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func saveCredentials() async {
        let ok = await store.saveCredentials(
            clientId: clientIdDraft.trimmingCharacters(in: .whitespacesAndNewlines),
            clientSecret: clientSecretDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        if ok {
            clientIdDraft = ""
            clientSecretDraft = ""
            refreshTick &+= 1
        }
    }

    private func testResultRow(_ result: ConnectionTestResult) -> some View {
        HStack(spacing: HLSpace.md) {
            Image(systemName: result.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(result.ok ? HLColor.statusOK : HLColor.statusBad)
            if result.ok, let latency = result.latencyMs {
                Text(
                    // W-I18N: interpolates a runtime latency number.
                    verbatim: String(
                        format: NSLocalizedString(
                            "integration.test.ok_latency",
                            comment: "Connection test OK; %d is the latency in ms."
                        ),
                        latency
                    )
                )
                .font(.hlSubhead)
                .foregroundStyle(HLText.primary)
            } else {
                Text(result.ok ? "integration.test.ok" : "integration.test.failed")
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.primary)
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        if let status = store.status, status.connected {
            if store.supportsManualSync {
                // CU-35 (1) — every server-OAuth provider has `POST
                // /api/<provider>/sync` since v1.32.28, not just Fitbit.
                HLButton(
                    "integration.sync.button",
                    icon: "arrow.triangle.2.circlepath",
                    variant: .secondary,
                    isLoading: store.isWorking
                ) {
                    Task { await store.syncNow() }
                }
                .accessibilityIdentifier("integration.sync.button")
                ManualSyncStatusRow(state: store.syncState, providerName: displayName)
            }
            if store.supportsConnectionTest {
                HLButton(
                    "integration.test.button",
                    icon: "checkmark.shield",
                    variant: .secondary,
                    isLoading: store.isWorking
                ) {
                    Task { await store.testConnection() }
                }
                .accessibilityIdentifier("integration.test.button")
            }
            HLButton("Disconnect", variant: .destructive) {
                Task { await store.disconnect() }
            }
        } else {
            // R9 — „Verbinden" ist auf jedem Integrations-Screen die
            // abschließende Commit-Aktion und damit das eine `.primary`.
            HLButton(
                // W-I18N: interpolates the runtime provider name (server
                // value) — paint verbatim, never re-resolve as a key.
                verbatim: String(
                    format: NSLocalizedString(
                        "integration.connectProvider",
                        comment: "Connect button label; %@ is the provider name (Oura/Polar/Fitbit)."
                    ),
                    displayName
                ),
                icon: "link",
                variant: .primary,
                isLoading: store.isWorking
            ) {
                Task { await beginConnect() }
            }
        }
    }

    /// #139 — reconnect is the browser connect flow every provider has; resume
    /// only where the server has a resume route.
    private var supportedHealthActions: Set<ConnectionHealth.Action> {
        store.supportsResume ? [.reconnect, .resume] : [.reconnect]
    }

    private func perform(_ action: ConnectionHealth.Action) async {
        switch action {
        case .reconnect: await beginConnect()
        case .resume: await store.resume()
        }
    }

    private func beginConnect() async {
        // Server-OAuth connect is browser-only by design (3-leg OAuth, same as
        // Withings): we open `/api/<provider>/connect` directly in the system
        // browser; the server sets its state cookie and 302's to the provider's
        // authorize URL. No POST, no response JSON — stays in the View, only the
        // `isWorking` spinner is toggled via the store.
        guard let baseURL = container?.environment.baseURL else { return }
        let connectURL = baseURL.appendingPathComponent("/api/\(store.provider.rawValue)/connect")
        await store.openingExternalConnect {
            #if canImport(UIKit)
                if UIApplication.shared.canOpenURL(connectURL) {
                    await UIApplication.shared.open(connectURL)
                }
            #endif
        }
    }
}
