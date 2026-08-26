import SwiftUI

/// Connect / manage surface for **Nightscout** — the self-hoster CGM bridge
/// (server v1.17.0). Unlike the OAuth wearables, Nightscout is a URL-+-token
/// paste flow: the user points HealthLog at their own instance, so the connect
/// step is a real `POST` (no browser redirect). A pure backend (B) surface — in
/// standalone we render the calm ``HLCloudDerivedPlaceholder``.
///
/// The instance URL + optional API token are stored encrypted server-side and
/// never on this iPhone (held only transiently in the form drafts below).
struct NightscoutIntegrationScreen: View {
    @Environment(BackendAvailability.self) private var backend
    @Environment(AuthStore.self) private var authStore
    @Environment(NightscoutIntegrationStore.self) private var store

    @State private var urlDraft: String = ""
    @State private var tokenDraft: String = ""
    @State private var allowPrivateHost: Bool = false
    @State private var refreshTick: Int = 0

    var body: some View {
        if backend.hasServer {
            liveBody
        } else {
            ScrollView {
                HLCloudDerivedPlaceholder(
                    variant: .hero,
                    surfaceName: String(localized: "cloud_derived.surface.nightscout"),
                    onConnect: { authStore.beginServerPairing() }
                )
                .padding(HLSpace.lg)
            }
            .background(HLColor.background)
            .navigationTitle("Nightscout")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    /// **UI-Standard U2 (R12) — Gerüst C→A.** Bis U2 ein handgebautes
    /// `ScrollView` + `HLCard` im `.elevated`-Stil (16 pt Innenabstand, 1 pt
    /// volle Kontur, handgebauter 17-pt-Kartenkopf, **kein** unterer
    /// Seitenrand). Liegt jetzt auf `HLSettingsPage` + `HLSettingsCard`.
    private var liveBody: some View {
        HLSettingsPage(title: "Nightscout") {
            connectionCard
            HLSyncStatusFooter(screenLoading: store.isWorking)
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
        HLSettingsCard(
            icon: "drop.circle.fill",
            title: "Nightscout",
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
            HLStatusPill(.connected(label: String(localized: "Connected")))
        case .some(false):
            HLStatusPill(.disconnected(label: String(localized: "Not connected")))
        case .none:
            HLStatusPill(.unknown(label: String(localized: "Checking")))
        }
    }

    @ViewBuilder
    private var connectionBody: some View {
        if isConnected {
            // CU-35 (1) — `POST /api/nightscout/sync` (v1.32.28): pull
            // the recent SGV window now instead of waiting for the cron.
            HLButton(
                "integration.sync.button",
                icon: "arrow.triangle.2.circlepath",
                variant: .secondary,
                isLoading: store.isWorking
            ) {
                Task { await store.syncNow() }
            }
            .accessibilityIdentifier("integration.sync.button")
            ManualSyncStatusRow(state: store.syncState, providerName: "Nightscout")
            HLButton(
                "integration.test.button",
                icon: "checkmark.shield",
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
            Text(error.localizedDescription).foregroundStyle(HLColor.statusBad)
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
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("settings.nightscout.tokenField")

            HLSettingsToggleRow(
                title: "nightscout.allowPrivateHost",
                description: nil,
                isOn: $allowPrivateHost,
                accessibilityID: "settings.nightscout.allowPrivateHostToggle"
            )

            HLButton(String(localized: "Connect"), variant: .primary, isLoading: store.isWorking) {
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
