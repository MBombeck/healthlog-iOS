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
struct SettingsMcpScreen: View {
    @Environment(AccountSecurityStore.self) private var security
    @Environment(\.appContainer) private var container

    @State private var store: McpStore?
    @State private var showMintSheet = false
    @State private var moduleInFlight = false
    @State private var showModuleError = false

    var body: some View {
        HLPage {
            connectedBody
        }
        .navigationTitle("MCP connector")
        .navigationBarTitleDisplayMode(.inline)
        .hlAcknowledgeAlert("Could not update modules. Please try again.", isPresented: $showModuleError)
        .task {
            guard store == nil, let api = container?.api else { return }
            // The proof follows the account's factors, not
            // the server version (#163 B1, `elevation-if-enrolled`).
            let security = security
            let s = McpStore(repo: McpRepository(api: api)) { await McpStore.resolveProofUpFront(security: security) }
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
        return HLCard("Connector status") {
            // One description for both states: what turning the
            // switch on does. The off-state "answers 404" line is gone.
            HLSettingsToggleRow(
                title: "Enable MCP connector",
                description: "External assistants can connect with a valid credential.",
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
                // Typed into another app: breaks at slashes and dots only.
                HLIdentifierText(endpointText, style: .footnote, monospaced: true)
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
            HLCard("Something went wrong") {
                Text(error)
                    .font(.hlFootnote)
                    .foregroundStyle(StepUpRetry.messageTint(for: error))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.mcp.error")
            }
        }
    }

    // MARK: - Live connections (the revocation-critical card)

    private func connectionsCard(store: McpStore) -> some View {
        // Der Widerrufs-Hinweis steht im Bestätigungsdialog der
        // Revoke-Zeile (siehe `McpConnectionRow`). Der Untertitel,
        // der den Titel umschrieb, ist weg.
        HLCard("Connected assistants") {
            if store.isLoading, store.connections.isEmpty {
                loadingRow
            } else if store.connections.isEmpty {
                HLEmptyNote("No assistant is connected.")
                    .accessibilityIdentifier("settings.mcp.connections.empty")
            } else {
                VStack(spacing: HLSpace.md) {
                    ForEach(store.connections) { connection in
                        McpConnectionRow(
                            connection: connection,
                            isRevoking: store.revoking.contains(connection.id)
                        ) {
                            await store.revokeConnection(id: connection.id)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Connector tokens

    private func tokensCard(store: McpStore) -> some View {
        HLCard(
            "Connector tokens",
            // „nur einmal sichtbar" hatte vier Fassungen (hier, plus
            // Kartentitel, Seiten-Subtitle und Karten-Subtitle des
            // Reveal-Sheets). Heimat ist das Reveal-Sheet, wo das Geheimnis
            // tatsächlich steht; dort genügt EINE Fassung, und die trägt jetzt
            // auch den Ersatz-Weg („erstelle ein neues").
            subtitle: "For assistants you connect manually."
        ) {
            if store.isLoading, store.tokens.isEmpty {
                loadingRow
            } else if store.activeTokens.isEmpty {
                HLEmptyNote("No connector tokens.")
                    .accessibilityIdentifier("settings.mcp.tokens.empty")
            } else {
                VStack(spacing: HLSpace.md) {
                    ForEach(store.activeTokens) { token in
                        ApiTokenRow(
                            token: token,
                            isRevoking: store.revoking.contains(token.id),
                            revokeIdentifier: "settings.mcp.tokens.revoke"
                        ) {
                            await store.revokeToken(id: token.id)
                        }
                    }
                }
            }

            // The canonical create row, and only while the
            // connector is on: a dimmed row plus "switch the module on first"
            // under it is gone; the switch is the card above.
            if isModuleOn {
                HLSettingsActionRow(title: "Create token", presents: .create) {
                    showMintSheet = true
                }
                .disabled(store.isMinting)
                .accessibilityIdentifier("settings.mcp.tokens.create")
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

    /// What a connected assistant can read, and that it is read-only unless
    /// more is granted. The row and the footer that said this in two
    /// sentences (one with "Lese-Token") are one sentence; the write scope is
    /// chosen in the mint sheet, the revoke effect lives in its dialogs.
    private var infoCard: some View {
        HLCard("What an assistant can see") {
            Text("settings.mcp.scope.body")
                .hlText(.factLabel)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Connection row

private struct McpConnectionRow: View {
    let connection: McpConnectionDTO
    let isRevoking: Bool
    let onRevoke: @MainActor () async -> Void

    /// Name, then scope and last use in one line; write access is the row's
    /// status. Revoking stays its own row under it.
    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            // `displayName` is third-party text from OAuth registration —
            // rendered as plain data, never interpreted.
            HLRow(
                title: Text(verbatim: connection.displayName),
                detail: HLRowDetail.text([scopeText, lastUsedText]),
                status: connection.grantsWrite
                    ? HLRowStatus(String(localized: "Can also write"), icon: "square.and.pencil", tone: .warning)
                    : nil
            )

            // Revoking ends access and deletes no entry: the ladder asks with
            // the action's own words. The question also carries the refresh
            // consequence, at the place where the revoke is triggered.
            if isRevoking {
                ProgressView().controlSize(.small)
            } else {
                HLDeleteButton(
                    "Revoke",
                    form: .row,
                    action: SettingsRevokeAction.connection(perform: onRevoke)
                )
                .accessibilityIdentifier("settings.mcp.connections.revoke")
            }
        }
    }

    private var scopeText: String {
        let tokens = connection.scopeTokens
        return tokens.isEmpty ? String(localized: "Unknown scope") : tokens.joined(separator: ", ")
    }

    private var lastUsedText: String {
        guard let date = connection.lastUsedAt else {
            return String(localized: "Never used")
        }
        return String(localized: "passkey.lastUsed \(HLDateFormat.date(date, style: .abbreviated))")
    }
}

// MARK: - Token row (shared by the MCP + API-token screens)

struct ApiTokenRow: View {
    let token: ApiTokenDTO
    let isRevoking: Bool
    let revokeIdentifier: String
    let onRevoke: @MainActor () async -> Void

    /// Name, then rights, creation and last use in one line; a revoked or
    /// expired token, or write access, is the row's status.
    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            HLRow(
                title: Text(verbatim: token.displayName),
                detail: HLRowDetail.text([
                    token.permissions.isEmpty ? nil : token.permissions.joined(separator: ", "),
                    createdText,
                    lastUsedText
                ]),
                status: status
            )

            // Revoking ends a credential and deletes no entry: the ladder
            // asks with the action's own words.
            if isRevoking {
                ProgressView().controlSize(.small)
            } else if token.isLive() {
                HLDeleteButton(
                    "Revoke",
                    form: .row,
                    action: SettingsRevokeAction.token(perform: onRevoke)
                )
                .accessibilityIdentifier(revokeIdentifier)
            }
        }
    }

    private var status: HLRowStatus? {
        if !token.isLive() {
            return HLRowStatus(token.revoked ? String(localized: "Revoked") : String(localized: "Expired"))
        }
        if token.grantsWrite {
            return HLRowStatus(String(localized: "Can also write"), icon: "square.and.pencil", tone: .warning)
        }
        return nil
    }

    private var createdText: String {
        guard let date = token.createdAt else { return String(localized: "Created recently") }
        return String(localized: "passkey.created \(HLDateFormat.date(date, style: .abbreviated))")
    }

    private var lastUsedText: String {
        guard let date = token.lastUsedAt else { return String(localized: "Never used") }
        return String(localized: "passkey.lastUsed \(HLDateFormat.date(date, style: .abbreviated))")
    }
}

// MARK: - Revoke questions

/// The red actions in Settings that end access without deleting an entry: a
/// browser session, an assistant's connection, a token, a share link. Each
/// asks first and answers with its own word and sign instead of "Delete".
enum SettingsRevokeAction {
    static let symbol = "xmark.circle"

    static func session(perform: @escaping @MainActor () async -> Void) -> HLDeleteAction {
        .confirmed(
            title: "sessions.revoke.confirmTitle",
            message: "sessions.revoke.confirmBody",
            word: "sessions.revoke.confirmAction",
            symbol: symbol,
            perform: perform
        )
    }

    /// The question also carries the refresh consequence, at the place where
    /// the revoke is triggered.
    static func connection(perform: @escaping @MainActor () async -> Void) -> HLDeleteAction {
        .confirmed(
            title: "Disconnect this assistant?",
            message: "It loses access to your health record immediately, including any refresh it holds. You can connect it again later.",
            word: "Disconnect",
            symbol: symbol,
            perform: perform
        )
    }

    static func token(perform: @escaping @MainActor () async -> Void) -> HLDeleteAction {
        .confirmed(
            title: "Revoke this token?",
            message: "Anything using this token stops working immediately. This can't be undone.",
            word: "Revoke token",
            symbol: symbol,
            perform: perform
        )
    }

    static func shareLink(perform: @escaping @MainActor () async -> Void) -> HLDeleteAction {
        .confirmed(
            title: "Revoke this share link?",
            message: "The doctor will lose access immediately. This can't be undone.",
            word: "Revoke link",
            symbol: symbol,
            perform: perform
        )
    }
}
