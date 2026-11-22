import SwiftUI
#if canImport(UIKit)
    import UIKit
    import UniformTypeIdentifiers
#endif

/// Mint sheet for an MCP connector token.
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
        HLSheetScaffold(
            "New connector token",
            action: .confirm("Create", isEnabled: !trimmedName.isEmpty) {
                await store.mintToken(name: name, scope: scope)
            },
            isDirty: !trimmedName.isEmpty,
            isBusy: store.isMinting,
            confirmIdentifier: "settings.mcp.mint.submit"
        ) {
            HLPage {
                HLCard("Name") {
                    TextField(String(localized: "e.g. My health dashboard"), text: $name)
                        .textFieldStyle(.plain)
                        .font(.hlSubhead)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("settings.mcp.mint.name")
                }

                // Heimat des Schreibzugriffs-Umfangs: hier wird der Scope
                // gewählt, und die Zeile unter dem Picker sagt pro Fall, was er
                // bedeutet. Der Footer über die „normale API" ist
                // weg, die Zeile reicht.
                HLCard("Access") {
                    HLAdaptiveSegmentedPicker(
                        "Access",
                        selection: $scope,
                        labels: ["Read only", "Read and write"]
                    ) {
                        Text("Read only").tag(McpTokenScope.read)
                        Text("Read and write").tag(McpTokenScope.readWrite)
                    }
                    .accessibilityIdentifier("settings.mcp.mint.scope")

                    Text(scopeExplanation)
                        .hlText(.note)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let error = store.error {
                    Text(error)
                        .font(.hlFootnote)
                        .foregroundStyle(StepUpRetry.messageTint(for: error))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // A mint the server wants a fresh proof for:
            // confirm, then mint again with the elevation. SEC — on a server
            // that reads the proof the store asks before the first attempt.
            // An account that turns out to hold nothing to
            // prove (no factor, no passkey) mints on the token instead.
            .stepUpConfirmation(
                store.stepUp,
                waiveWhen: { !McpStore.accountNeedsProof($0) },
                onWaived: { store.waiveProof() },
                onConfirmed: { await mint() }
            )
        }
        // SEC — closed, swiped down or unmounted by the privacy shield: a
        // proof given for this sheet does not outlive it.
        .onDisappear { store.abandonMint() }
    }

    private func mint() async {
        let ok = await store.mintToken(name: name, scope: scope)
        if ok { dismiss() }
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

    @State private var didCopy = false

    var body: some View {
        HLSheetScaffold("Your new token", action: .done()) {
            HLPage {
                if let fresh = store.freshToken {
                    // DIE Heimat der „nur einmal sichtbar"-Zusage. 1.4
                    // B2-c: der Kartentitel sagt sie, der Footer, der sie
                    // wiederholte, ist weg.
                    HLCard("Shown once") {
                        // A hyphen inside the token would be typed along.
                        HLIdentifierText(fresh.token, style: .footnote, monospaced: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("settings.mcp.reveal.token")

                        HLRowButton {
                            copy(fresh.token)
                        } label: {
                            HLRow(
                                didCopy ? "Copied" : "Copy token",
                                accessory: .symbol(didCopy ? "checkmark" : "doc.on.doc")
                            )
                        }
                        .accessibilityIdentifier("settings.mcp.reveal.copy")
                    }

                    if let expiresAt = fresh.expiresAt {
                        HLCard("Expires") {
                            Text(verbatim: HLDateFormat.date(expiresAt, style: .abbreviated))
                                .hlText(.factLabel)
                        }
                    }
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
