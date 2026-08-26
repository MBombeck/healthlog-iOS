import SwiftUI

/// `Settings → Notifications → ntfy` channel card. Lets the user point HealthLog
/// at their **own ntfy server** (the literal "Server-Einstellung") + topic and
/// send a server-side test push. Mirrors the web `ntfy-card.tsx`.
///
/// **Gated** by `store.showNtfyCard` (server-wide `ntfyGlobal`) — the parent
/// only mounts this when the channel is globally enabled.
///
/// **Secret handling:** the optional `authToken` lives only in this View's
/// transient `@State`. It is sent once via `store.saveNtfy(authToken:)` and
/// wiped from the field on success — never displayed (the server returns only
/// `hasAuthToken`), never persisted, never logged.
struct NtfyChannelCard: View {
    @Environment(NotificationServicesStore.self) private var store

    @State private var enabled = false
    @State private var serverUrl = "https://ntfy.sh"
    @State private var topic = ""
    /// Transient auth-token draft. Empty ⇒ not sent (server keeps any stored
    /// token). The stored token is never read back into this field.
    @State private var authTokenDraft = ""
    /// Tracks whether local fields were hydrated from the server config so a
    /// re-render (e.g. after a save round-trip) doesn't clobber user edits.
    @State private var hydratedFromConfig = false
    @State private var testTick = 0

    var body: some View {
        HLSettingsCard(
            icon: "server.rack",
            title: "notifications.ntfy.title",
            footer: "notifications.ntfy.footer"
        ) {
            Toggle(isOn: $enabled) {
                Text("notifications.ntfy.enable")
                    .font(.hlSubhead.weight(.semibold))
            }
            .accessibilityIdentifier("notifications.ntfy.enableToggle")

            if enabled {
                Divider().opacity(0.5)

                VStack(alignment: .leading, spacing: HLSpace.xs) {
                    Text("notifications.ntfy.server")
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                    TextField("https://ntfy.sh", text: $serverUrl)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .accessibilityIdentifier("notifications.ntfy.serverField")
                }

                VStack(alignment: .leading, spacing: HLSpace.xs) {
                    Text("notifications.ntfy.topic")
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                    TextField(String(localized: "notifications.ntfy.topicPlaceholder"), text: $topic)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("notifications.ntfy.topicField")
                }

                VStack(alignment: .leading, spacing: HLSpace.xs) {
                    Text("notifications.ntfy.token")
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                    SecureField(tokenPlaceholder, text: $authTokenDraft)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("notifications.ntfy.tokenField")
                }

                if let invalid = validationMessage {
                    Text(invalid)
                        .font(.hlCaption)
                        .foregroundStyle(HLColor.statusBad)
                        .accessibilityIdentifier("notifications.ntfy.validation")
                }
            }

            HLButton(
                String(localized: "notifications.channel.save"),
                variant: .secondary,
                isLoading: store.ntfyWorking
            ) {
                Task { await save() }
            }
            .disabled(store.ntfyWorking || validationMessage != nil)
            .accessibilityIdentifier("notifications.ntfy.saveButton")

            if enabled {
                HLButton(
                    String(localized: "notifications.channel.test"),
                    icon: "paperplane",
                    // UI-Standard R9 (U6) — „Verbindung testen" ist überall
                    // `.secondary`; „Speichern" darüber ebenso, weil auf
                    // „Benachrichtigungen" mehrere Kanal-Karten nebeneinander
                    // stehen und höchstens ein `.primary` pro Screen erlaubt ist.
                    variant: .secondary,
                    isLoading: store.ntfyWorking
                ) {
                    Task { await test() }
                }
                .disabled(store.ntfyWorking)
                .accessibilityIdentifier("notifications.ntfy.testButton")
            }

            if store.ntfyTestSucceeded {
                testOkRow
            }

            if let error = store.ntfyError {
                // v0.14.1 #3 — generic copy for 5xx; never raw server text.
                Text(error.userFacingDescription)
                    .font(.hlCaption)
                    .foregroundStyle(HLColor.statusBad)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("notifications.ntfy.error")
            }
        }
        .onAppear { hydrate() }
        .onChange(of: store.ntfy) { _, _ in hydrate() }
        .sensoryFeedback(.success, trigger: testTick)
    }

    // MARK: - Derived

    private var tokenPlaceholder: String {
        if store.ntfy?.hasAuthToken == true {
            return String(localized: "notifications.channel.token.stored")
        }
        return String(localized: "notifications.ntfy.tokenPlaceholder")
    }

    /// Mirrors the server required-field rule: when enabled, serverUrl + topic
    /// must be non-empty (`route.ts:62-67`).
    private var validationMessage: String? {
        guard enabled else { return nil }
        let url = serverUrl.trimmingCharacters(in: .whitespaces)
        let t = topic.trimmingCharacters(in: .whitespaces)
        if url.isEmpty || t.isEmpty {
            return String(localized: "notifications.ntfy.validation.required")
        }
        return nil
    }

    private var testOkRow: some View {
        HStack(alignment: .top, spacing: HLSpace.xs) {
            Image(systemName: "checkmark.seal.fill")
                .font(.hlIcon(HLIconSize.sm))
                .foregroundStyle(HLText.primary)
            Text("notifications.channel.test.sent")
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("notifications.ntfy.testOk")
    }

    // MARK: - Actions

    private func hydrate() {
        guard !hydratedFromConfig, let config = store.ntfy else { return }
        enabled = config.enabled
        serverUrl = config.serverUrl.isEmpty ? "https://ntfy.sh" : config.serverUrl
        topic = config.topic
        hydratedFromConfig = true
    }

    private func save() async {
        let token = authTokenDraft.trimmingCharacters(in: .whitespaces)
        await store.saveNtfy(
            enabled: enabled,
            serverUrl: serverUrl.trimmingCharacters(in: .whitespaces),
            topic: topic.trimmingCharacters(in: .whitespaces),
            authToken: token.isEmpty ? nil : token
        )
        // Wipe the transient token as soon as it leaves the device.
        if store.ntfyError == nil {
            authTokenDraft = ""
        }
    }

    private func test() async {
        await store.testNtfy()
        if store.ntfyTestSucceeded { testTick &+= 1 }
    }
}
