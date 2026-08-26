import SwiftUI

/// `Settings → MCP connector` (Build 2 / 2.7, mirrors web `mcp-section.tsx`).
///
/// The surface through which a user sees — and cuts — every external
/// assistant's access to their health record:
///
/// 1. the opt-in `mcp` module toggle plus the endpoint address,
/// 2. **live OAuth connections** with a revoke action (the security-critical
///    half: revoking kills the connector's whole refresh chain), and
/// 3. manually-minted connector tokens: list, revoke, and a scoped mint whose
///    secret is shown exactly once.
///
/// Card order is deliberate: connections sit ABOVE minting. The question a
/// worried user arrives with is "who can read my record right now, and how do I
/// stop them" — not "how do I add another one".
///
/// Server-only surface; standalone mode gets the calm placeholder rather than
/// dead buttons.
struct SettingsMcpScreen: View {
    @Environment(BackendAvailability.self) private var backend
    @Environment(AuthStore.self) private var authStore
    @Environment(\.appContainer) private var container

    @State private var store: McpStore?
    @State private var showMintSheet = false
    @State private var moduleInFlight = false
    @State private var showModuleError = false

    var body: some View {
        HLSettingsPage(title: "MCP connector") {
            if backend.hasServer {
                connectedBody
            } else {
                HLCloudDerivedPlaceholder(
                    variant: .inline,
                    surfaceName: String(localized: "the MCP connector"),
                    onConnect: { authStore.beginServerPairing() }
                )
            }
        }
        .navigationTitle("MCP connector")
        .navigationBarTitleDisplayMode(.inline)
        .alert(
            String(localized: "Could not update modules. Please try again."),
            isPresented: $showModuleError
        ) {
            Button(String(localized: "OK"), role: .cancel) {}
        }
        .task {
            guard backend.hasServer, store == nil, let api = container?.api else { return }
            let s = McpStore(repo: McpRepository(api: api))
            store = s
            await s.load()
        }
    }

    @ViewBuilder
    private var connectedBody: some View {
        if let store {
            enableCard
            errorCard(store: store)
            connectionsCard(store: store)
            tokensCard(store: store)
            infoCard
        }
    }

    // MARK: - Module toggle + endpoint

    private var isModuleOn: Bool {
        container?.moduleGate.isEnabled(.mcp) ?? false
    }

    /// `<origin>/mcp` — the address the user pastes into their assistant.
    private var endpointText: String {
        guard let base = container?.environment.baseURL else { return "/mcp" }
        return base.appendingPathComponent("mcp").absoluteString
    }

    /// The `mcp` module switch, live on this screen (the web card carries it
    /// too). It drives the same optimistic `PATCH /api/auth/me/modules` path as
    /// the modules switchboard via ``ModuleGate``, so the two surfaces cannot
    /// disagree — the gate is the single source of truth both read.
    private var enableCard: some View {
        // Observe the gate map so a 403-driven flip repaints this row too.
        let gate = container?.moduleGate
        _ = gate?.modules
        // R2/R19 — die Aussage „aus ⇒ Endpunkt antwortet 404" stand dreimal in
        // dieser einen Karte (Subtitle, Footer, Zeilen-Beschreibung). Ihre
        // Heimat ist die **zustandsabhängige** Beschreibung direkt am Schalter:
        // sie steht am Bedienelement und ändert sich mit dem Zustand (R3 —
        // zustandsabhängiger Text schlägt statischen). Der „standardmäßig aus"-
        // Hinweis trägt nichts, was der Aus-Zustand des Schalters nicht selbst
        // zeigt (R2, Voreinstellungs-Ansage).
        return HLSettingsCard(
            icon: "powerplug",
            title: "Connector status"
        ) {
            HLSettingsToggleRow(
                title: "Enable MCP connector",
                description: isModuleOn
                    ? "External assistants can connect with a valid credential."
                    : "The endpoint answers 404 and no assistant can connect.",
                isOn: Binding(
                    get: { isModuleOn },
                    set: { setModule(enabled: $0) }
                ),
                isBusy: moduleInFlight,
                isEnabled: !moduleInFlight && gate != nil,
                accessibilityID: "settings.mcp.toggle"
            )

            VStack(alignment: .leading, spacing: HLSpace.xs) {
                Text("Endpoint")
                    .font(.hlCaption.weight(.semibold))
                    .foregroundStyle(HLText.tertiary)
                Text(endpointText)
                    .font(.hlFootnote.monospaced())
                    .foregroundStyle(HLText.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.mcp.endpoint")
            }
        }
    }

    /// Optimistic module flip. On success the connection + token lists are
    /// reloaded, because switching the connector on is exactly when the user
    /// wants to see what (if anything) is already attached.
    private func setModule(enabled: Bool) {
        guard let gate = container?.moduleGate, !moduleInFlight else { return }
        moduleInFlight = true
        Task {
            let ok = await gate.setEnabled(.mcp, enabled: enabled)
            moduleInFlight = false
            if ok {
                await store?.load()
            } else {
                showModuleError = true
            }
        }
    }

    @ViewBuilder
    private func errorCard(store: McpStore) -> some View {
        if let error = store.error {
            HLSettingsCard(
                icon: "exclamationmark.triangle",
                title: "Something went wrong"
            ) {
                Text(error)
                    .font(.hlFootnote)
                    .foregroundStyle(HLColor.statusBad)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.mcp.error")
            }
        }
    }

    // MARK: - Live connections (the revocation-critical card)

    private func connectionsCard(store: McpStore) -> some View {
        HLSettingsCard(
            icon: "link",
            title: "Connected assistants",
            // R19 — der Widerrufs-Hinweis ist nicht gestrichen, sondern an seine
            // Heimat gezogen: den Bestätigungsdialog der Revoke-Zeile (siehe
            // `McpConnectionRow`), der die Refresh-Rechte jetzt ausdrücklich
            // mitnennt. Am Ort der Handlung, in voller Stärke.
            subtitle: "Every assistant that can read your record right now."
        ) {
            if store.isLoading, store.connections.isEmpty {
                loadingRow
            } else if store.connections.isEmpty {
                Text("No assistant is connected.")
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.secondary)
                    .accessibilityIdentifier("settings.mcp.connections.empty")
            } else {
                VStack(spacing: HLSpace.md) {
                    ForEach(store.connections) { connection in
                        McpConnectionRow(
                            connection: connection,
                            isRevoking: store.revoking.contains(connection.id)
                        ) {
                            Task { await store.revokeConnection(id: connection.id) }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Connector tokens

    private func tokensCard(store: McpStore) -> some View {
        HLSettingsCard(
            icon: "key",
            title: "Connector tokens",
            // R19 — „nur einmal sichtbar" hatte vier Fassungen (hier, plus
            // Kartentitel, Seiten-Subtitle und Karten-Subtitle des
            // Reveal-Sheets). Heimat ist das Reveal-Sheet, wo das Geheimnis
            // tatsächlich steht; dort genügt EINE Fassung, und die trägt jetzt
            // auch den Ersatz-Weg („erstelle ein neues").
            subtitle: "For assistants you connect manually."
        ) {
            if store.isLoading, store.tokens.isEmpty {
                loadingRow
            } else if store.activeTokens.isEmpty {
                Text("No connector tokens.")
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.secondary)
                    .accessibilityIdentifier("settings.mcp.tokens.empty")
            } else {
                VStack(spacing: HLSpace.md) {
                    ForEach(store.activeTokens) { token in
                        ApiTokenRow(
                            token: token,
                            isRevoking: store.revoking.contains(token.id),
                            revokeIdentifier: "settings.mcp.tokens.revoke"
                        ) {
                            Task { await store.revokeToken(id: token.id) }
                        }
                    }
                }
            }

            Button {
                showMintSheet = true
            } label: {
                HStack(spacing: HLSpace.md) {
                    Text("Create token")
                        .font(.hlSubhead.weight(.semibold))
                        .foregroundStyle(HLText.primary)
                    Spacer()
                    Image(systemName: "plus.circle.fill")
                        .font(.hlIcon(HLIconSize.sm))
                        .foregroundStyle(HLText.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(store.isMinting || !isModuleOn)
            .accessibilityIdentifier("settings.mcp.tokens.create")

            if !isModuleOn {
                Text("Switch the MCP module on before creating a token.")
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(isPresented: $showMintSheet) {
            McpTokenMintSheet(store: store)
        }
        .sheet(isPresented: Binding(
            get: { store.freshToken != nil },
            set: { if !$0 { store.clearFreshToken() } }
        )) {
            McpTokenRevealSheet(store: store)
        }
    }

    private var loadingRow: some View {
        HStack {
            Spacer()
            ProgressView().controlSize(.small)
            Spacer()
        }
    }

    /// R19 — Entdopplung, keine Streichung. Die Karte behält die Aussage, die
    /// nirgendwo sonst steht (was ein Lese-Token sehen kann) und die
    /// Grundzusage. Die beiden anderen Zeilen sind an ihre Heimat gezogen:
    /// der Schreibzugriffs-Umfang an den Scope-Picker im Mint-Sheet (dort wird
    /// er gewählt), die Sofortwirkung des Widerrufs in die beiden
    /// Bestätigungsdialoge (dort wird er ausgelöst).
    ///
    /// Die Grundzusage steht als Footer statt als Subtitle: Subtitle ist auf
    /// eine Zeile beschnitten und hätte sie abgeschnitten (R5).
    private var infoCard: some View {
        HLSettingsCard(
            icon: "lock.shield",
            title: "What an assistant can see",
            footer: "MCP access is read-only unless you explicitly grant more."
        ) {
            infoRow(icon: "eye", text: "A read token can read your measurements, labs and medications.")
        }
    }

    private func infoRow(icon: String, text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: HLSpace.sm) {
            Image(systemName: icon)
                .font(.hlIcon(HLIconSize.sm))
                .foregroundStyle(HLText.tertiary)
                .frame(width: 20)
            Text(text)
                .font(.hlFootnote)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Connection row

private struct McpConnectionRow: View {
    let connection: McpConnectionDTO
    let isRevoking: Bool
    let onRevoke: () -> Void

    @State private var confirmRevoke = false

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            HStack {
                // `displayName` is third-party text from OAuth registration —
                // rendered as plain data, never interpreted.
                Text(verbatim: connection.displayName)
                    .font(.hlSubhead.weight(.semibold))
                    .foregroundStyle(HLText.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if isRevoking {
                    ProgressView().controlSize(.small)
                } else {
                    Button(role: .destructive) {
                        confirmRevoke = true
                    } label: {
                        Text("Revoke")
                            .font(.hlFootnote.weight(.semibold))
                            .foregroundStyle(HLColor.statusBad)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings.mcp.connections.revoke")
                }
            }

            if connection.grantsWrite {
                Label("Can also write", systemImage: "square.and.pencil")
                    .font(.hlCaption.weight(.semibold))
                    .foregroundStyle(HLColor.statusWarn)
            }

            HStack(spacing: HLSpace.md) {
                Label(scopeText, systemImage: "key")
                Label(lastUsedText, systemImage: "clock")
            }
            .font(.hlCaption)
            .foregroundStyle(HLText.tertiary)
        }
        .padding(.vertical, HLSpace.xs)
        .hlConfirmDestructive(
            Text("Disconnect this assistant?"),
            isPresented: $confirmRevoke,
            // R19 — Heimat des Widerrufs-Hinweises. Die Refresh-Rechte standen
            // vorher nur im Karten-Footer darüber; sie gehören dorthin, wo der
            // Widerruf ausgelöst wird.
            message: Text(
                "It loses access to your health record immediately, including any refresh it holds. You can connect it again later."
            ),
            confirm: Text("Disconnect"),
            cancel: Text("Cancel"),
            action: onRevoke
        )
    }

    private var scopeText: String {
        let tokens = connection.scopeTokens
        return tokens.isEmpty ? String(localized: "Unknown scope") : tokens.joined(separator: ", ")
    }

    private var lastUsedText: String {
        guard let date = connection.lastUsedAt else {
            return String(localized: "Never used")
        }
        return HLDateFormat.date(date, style: .abbreviated)
    }
}

// MARK: - Token row (shared by the MCP + API-token screens)

struct ApiTokenRow: View {
    let token: ApiTokenDTO
    let isRevoking: Bool
    let revokeIdentifier: String
    let onRevoke: () -> Void

    @State private var confirmRevoke = false

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            HStack {
                Text(verbatim: token.displayName)
                    .font(.hlSubhead.weight(.semibold))
                    .foregroundStyle(HLText.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if isRevoking {
                    ProgressView().controlSize(.small)
                } else if token.isLive() {
                    Button(role: .destructive) {
                        confirmRevoke = true
                    } label: {
                        Text("Revoke")
                            .font(.hlFootnote.weight(.semibold))
                            .foregroundStyle(HLColor.statusBad)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(revokeIdentifier)
                } else {
                    Text(token.revoked ? "Revoked" : "Expired")
                        .font(.hlCaption.weight(.semibold))
                        .foregroundStyle(HLText.tertiary)
                }
            }

            if token.grantsWrite, token.isLive() {
                Label("Can also write", systemImage: "square.and.pencil")
                    .font(.hlCaption.weight(.semibold))
                    .foregroundStyle(HLColor.statusWarn)
            }

            if !token.permissions.isEmpty {
                Text(verbatim: token.permissions.joined(separator: ", "))
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: HLSpace.md) {
                Label(createdText, systemImage: "calendar")
                Label(lastUsedText, systemImage: "clock")
            }
            .font(.hlCaption)
            .foregroundStyle(HLText.tertiary)
        }
        .padding(.vertical, HLSpace.xs)
        .hlConfirmDestructive(
            Text("Revoke this token?"),
            isPresented: $confirmRevoke,
            message: Text("Anything using this token stops working immediately. This can't be undone."),
            confirm: Text("Revoke token"),
            cancel: Text("Cancel"),
            action: onRevoke
        )
    }

    private var createdText: String {
        guard let date = token.createdAt else { return String(localized: "Created recently") }
        return HLDateFormat.date(date, style: .abbreviated)
    }

    private var lastUsedText: String {
        guard let date = token.lastUsedAt else { return String(localized: "Never used") }
        return HLDateFormat.date(date, style: .abbreviated)
    }
}
