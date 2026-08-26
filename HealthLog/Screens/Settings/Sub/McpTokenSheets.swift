import SwiftUI
#if canImport(UIKit)
    import UIKit
    import UniformTypeIdentifiers
#endif

/// Mint sheet for an MCP connector token (Build 2 / 2.7).
///
/// Two inputs only, matching the server's closed contract: a name and the
/// read / read-write scope choice (`z.enum(["read", "read_write"])`). Read is
/// preselected — least privilege is the default the user has to actively leave.
struct McpTokenMintSheet: View {
    let store: McpStore

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var scope: McpTokenScope = .read

    var body: some View {
        NavigationStack {
            HLSettingsPage(title: "New connector token") {
                HLSettingsCard(icon: "tag", title: "Name") {
                    TextField(String(localized: "e.g. My health dashboard"), text: $name)
                        .textFieldStyle(.plain)
                        .font(.hlSubhead)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("settings.mcp.mint.name")
                }

                // R19 — Heimat des Schreibzugriffs-Umfangs: hier wird der Scope
                // gewählt. Der Footer trägt die Aussage deshalb in voller
                // Stärke, inklusive „getrennt und freiwillig", das vorher auf
                // der Info-Karte des MCP-Screens stand. Der Rat „Nur-Lesen
                // reicht meistens" ist entfallen — die Auswahl steht auf
                // „Nur Lesen" und die Erklärzeile unter dem Picker sagt pro
                // Fall, was er bedeutet (R2, R3).
                HLSettingsCard(
                    icon: "key",
                    title: "Access",
                    footer: "Write access is separate and opt-in. It is limited to the MCP endpoint — through the normal API the assistant can never change anything."
                ) {
                    Picker(String(localized: "Access"), selection: $scope) {
                        Text("Read only").tag(McpTokenScope.read)
                        Text("Read and write").tag(McpTokenScope.readWrite)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("settings.mcp.mint.scope")

                    Text(scopeExplanation)
                        .font(.hlFootnote)
                        .foregroundStyle(HLText.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let error = store.error {
                    Text(error)
                        .font(.hlFootnote)
                        .foregroundStyle(HLColor.statusBad)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .navigationTitle("New connector token")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task {
                            let ok = await store.mintToken(name: name, scope: scope)
                            if ok { dismiss() }
                        }
                    }
                    .disabled(trimmedName.isEmpty || store.isMinting)
                    .accessibilityIdentifier("settings.mcp.mint.submit")
                }
            }
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var scopeExplanation: LocalizedStringKey {
        switch scope {
        case .read: "The assistant can read your health record. It cannot change anything."
        case .readWrite: "The assistant can also add entries. Only grant this if you actually need it."
        }
    }
}

/// Show-once reveal for a freshly minted connector token.
///
/// The raw `hlk_…` bearer exists here and nowhere else — it is never persisted
/// and never logged. Copy uses the local-only, 2-minute-expiring pasteboard
/// idiom shared with the share-link token sheet, so the secret does not sync to
/// other devices via Universal Clipboard.
struct McpTokenRevealSheet: View {
    let store: McpStore

    @Environment(\.dismiss) private var dismiss
    @State private var didCopy = false

    var body: some View {
        NavigationStack {
            HLSettingsPage(title: "Your new token") {
                if let fresh = store.freshToken {
                    // R19 — DIE Heimat der „nur einmal sichtbar"-Zusage. Sie
                    // steht als Footer statt als Subtitle, weil der Subtitle auf
                    // eine Zeile beschnitten ist und den Ersatz-Weg („erstelle
                    // ein neues") abgeschnitten hätte (R5).
                    HLSettingsCard(
                        icon: "exclamationmark.triangle",
                        title: "Shown once",
                        footer: "This is the only time the token is displayed. If you lose it, create a new one."
                    ) {
                        Text(verbatim: fresh.token)
                            .font(.hlFootnote.monospaced())
                            .foregroundStyle(HLText.primary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(HLSpace.md)
                            .background(
                                RoundedRectangle(cornerRadius: HLRadius.card, style: .continuous)
                                    .fill(HLSurface.secondary)
                            )
                            .accessibilityIdentifier("settings.mcp.reveal.token")

                        Button {
                            copy(fresh.token)
                        } label: {
                            HStack(spacing: HLSpace.md) {
                                Text(didCopy ? "Copied" : "Copy token")
                                    .font(.hlSubhead.weight(.semibold))
                                    .foregroundStyle(HLText.primary)
                                Spacer()
                                Image(systemName: didCopy ? "checkmark.circle.fill" : "doc.on.doc")
                                    .font(.hlIcon(HLIconSize.sm))
                                    .foregroundStyle(didCopy ? HLColor.statusOK : HLText.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .hlPressable()
                        .accessibilityIdentifier("settings.mcp.reveal.copy")
                    }

                    if let expiresAt = fresh.expiresAt {
                        HLSettingsCard(icon: "clock", title: "Expires") {
                            Text(verbatim: HLDateFormat.date(expiresAt, style: .abbreviated))
                                .font(.hlSubhead)
                                .foregroundStyle(HLText.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Your new token")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("settings.mcp.reveal.done")
                }
            }
        }
        .sensoryFeedback(.success, trigger: didCopy) { _, new in new }
    }

    private func copy(_ string: String) {
        #if canImport(UIKit)
            Self.copySensitive(string)
        #endif
        didCopy = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            didCopy = false
        }
    }

    #if canImport(UIKit)
        /// Local-only pasteboard write with a 2-minute expiry — a bearer must
        /// not ride Universal Clipboard to other devices or linger indefinitely.
        static func copySensitive(_ string: String) {
            UIPasteboard.general.setItems(
                [[UTType.utf8PlainText.identifier: string]],
                options: [
                    .localOnly: true,
                    .expirationDate: Date().addingTimeInterval(120)
                ]
            )
        }
    #endif
}
