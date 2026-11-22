import SwiftUI

/// Connect / manage surface for **Nightscout** — the self-hoster CGM bridge
/// (server v1.17.0). Unlike the OAuth wearables, Nightscout is a URL-+-token
/// paste flow: the user points HealthLog at their own instance, so the connect
/// step is a real `POST` (no browser redirect).
///
/// The instance URL + optional API token are stored encrypted server-side and
/// never on this iPhone (held only transiently in the form drafts below).
struct NightscoutIntegrationScreen: View {
    @Environment(NightscoutIntegrationStore.self) private var store

    @State private var urlDraft: String = ""
    @State private var tokenDraft: String = ""
    @State private var allowPrivateHost: Bool = false
    @State private var refreshTick: Int = 0

    var body: some View {
        liveBody
    }

    /// **UI-Standard U2 — Gerüst C→A.** Bis U2 ein handgebautes
    /// `ScrollView` + `HLCard` im `.elevated`-Stil (16 pt Innenabstand, 1 pt
    /// volle Kontur, handgebauter 17-pt-Kartenkopf, **kein** unterer
    /// Seitenrand). Liegt jetzt auf `HLPage` + `HLCard`.
    private var liveBody: some View {
        HLPage {
            // No app sync footer; the card says when this
            // provider last synced.
            connectionCard
        }
        .navigationTitle("Nightscout")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.loadStatus() }
        .refreshable {
            await store.loadStatus()
            refreshTick &+= 1
        }
        .sensoryFeedback(.success, trigger: refreshTick)
    }

    /// Eine Karte für Status, Formular und Aktionen. Der Zustand steht in der
    /// `HLStatusPill`; `nightscout.formIntro` (Klasse D — Verschlüsselung /
    /// „nie auf diesem iPhone") bleibt wortgleich, aber nur im Formular-Zweig.
    ///
    /// Audit-Gruppe 5 — `nightscout.connectedDetail` („Deine Nightscout-Instanz
    /// ist verbunden.") stand unter dem Kartenkopf „Verbunden" und sagte
    /// dasselbe ein zweites Mal; ersatzlos gefallen. Audit-Gruppe 3 —
    /// `nightscout.connectHint` beschrieb den Knopf darunter; ebenfalls
    /// gefallen.
    private var connectionCard: some View {
        HLCard(
            // The page is named after the service; the card says its state.
            "Status",
            footer: isConnected ? nil : "nightscout.formIntro",
            trailing: { statusPill },
            content: { connectionBody }
        )
    }

    private var isConnected: Bool {
        store.status?.connected == true
    }

    @ViewBuilder
    private var statusPill: some View {
        switch store.isConnected {
        case .some(true):
            // The pill follows `health.state` when the server sends it.
            if let health = store.status?.health {
                HLStatusPill(ConnectionHealthPresentation(health: health).pill)
            } else {
                HLStatusPill(.connected(label: String(localized: "Connected")))
            }
        case .some(false):
            HLStatusPill(.disconnected(label: String(localized: "Not connected")))
        case .none:
            // "Checking" only while it is, not after a failed read.
            if store.error == nil {
                HLStatusPill(.unknown(label: String(localized: "Checking")))
            }
        }
    }

    @ViewBuilder
    private var connectionBody: some View {
        if isConnected {
            // The reason in one sentence. No button: Nightscout has no
            // connect flow to re-run and no resume route; the person changes
            // the URL or token by disconnecting and connecting again.
            if let health = store.status?.health {
                ConnectionHealthSection(health: health)
            }
            // CU-35 (1) — `POST /api/nightscout/sync` (v1.32.28): pull
            // the recent SGV window now instead of waiting for the cron.
            HLButton(
                "integration.sync.button",
                systemImage: "arrow.triangle.2.circlepath",
                variant: .secondary,
                isLoading: store.isWorking
            ) {
                Task { await store.syncNow() }
            }
            .accessibilityIdentifier("integration.sync.button")
            ManualSyncStatusRow(state: store.syncState, providerName: "Nightscout")
            HLButton(
                "integration.test.button",
                systemImage: "checkmark.shield",
                variant: .secondary,
                isLoading: store.isWorking
            ) {
                Task { await store.testConnection() }
            }
            .accessibilityIdentifier("settings.nightscout.testButton")
            if let result = store.lastTestResult {
                testResultRow(result)
            }
            HLButton("Disconnect", variant: .destructive) {
                Task { await store.disconnect() }
            }
        } else {
            connectForm
        }
        if let error = store.error {
            // A sentence for people, never the decoder's text; the
            // route and error id are in "Support-Info kopieren".
            Text(error.userFacingDescription)
                .font(.hlCaption)
                .foregroundStyle(HLColor.statusBad)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var connectForm: some View {
        VStack(alignment: .leading, spacing: HLSpace.md) {
            TextField(String(localized: "nightscout.urlPlaceholder"), text: $urlDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .textContentType(.URL)
                .accessibilityIdentifier("settings.nightscout.urlField")

            SecureField(String(localized: "nightscout.tokenPlaceholder"), text: $tokenDraft)
                .hlSecretEntry()
                .accessibilityIdentifier("settings.nightscout.tokenField")

            HLSettingsToggleRow(
                title: "nightscout.allowPrivateHost",
                description: nil,
                isOn: $allowPrivateHost,
                accessibilityID: "settings.nightscout.allowPrivateHostToggle"
            )

            HLButton("Connect", variant: .primary, isLoading: store.isWorking) {
                Task { await connect() }
            }
            .disabled(!canConnect || store.isWorking)
            .accessibilityIdentifier("settings.nightscout.connectButton")
        }
    }

    private func testResultRow(_ result: ConnectionTestResult) -> some View {
        HStack(spacing: HLSpace.md) {
            Image(systemName: result.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(result.ok ? HLColor.statusOK : HLColor.statusBad)
            if result.ok, let latency = result.latencyMs {
                Text(
                    // Interpolates a runtime latency number.
                    verbatim: String(
                        format: NSLocalizedString(
                            "integration.test.ok_latency",
                            comment: "Connection test OK; %d is the latency in ms."
                        ),
                        latency
                    )
                )
                .hlText(.prose)
            } else {
                Text(result.ok ? "integration.test.ok" : "integration.test.failed")
                    .hlText(.prose)
            }
        }
    }

    private var canConnect: Bool {
        !urlDraft.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func connect() async {
        let ok = await store.connect(
            url: urlDraft.trimmingCharacters(in: .whitespacesAndNewlines),
            token: tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines),
            allowPrivateHost: allowPrivateHost
        )
        if ok {
            tokenDraft = ""
            refreshTick &+= 1
        }
    }
}
