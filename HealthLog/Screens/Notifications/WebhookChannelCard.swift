import SwiftUI

/// `Settings → Notifications → Webhook` channel card. Lets the user point
/// HealthLog at a generic outbound webhook (covers Gotify / Discord / Slack /
/// Matrix-bridge / Home Assistant in one) with an optional custom auth header.
/// Mirrors the web `webhook-card.tsx` and the iOS `NtfyChannelCard` pattern.
///
/// Unlike ntfy/Telegram there is **no** server-wide availability flag, so the
/// card always renders once the parent mounts the channel section.
///
/// **Secret handling:** the optional `headerValue` (shared secret) lives only
/// in this View's transient `@State`. It is sent once via
/// `store.saveWebhook(headerValue:)` and wiped on success — never displayed
/// (the server returns only `hasHeaderValue`), never persisted, never logged.
struct WebhookChannelCard: View {
    @Environment(NotificationServicesStore.self) private var store

    @State private var enabled = false
    @State private var url = ""
    @State private var headerName = ""
    /// Transient header-value draft. Empty ⇒ not sent (server keeps any stored
    /// secret). The stored value is never read back into this field.
    @State private var headerValueDraft = ""
    @State private var hydratedFromConfig = false
    @State private var testTick = 0

    var body: some View {
        HLSettingsCard(
            icon: "link",
            title: "notifications.webhook.title",
            footer: "notifications.webhook.footer"
        ) {
            Toggle(isOn: $enabled) {
                Text("notifications.webhook.enable")
                    .font(.hlSubhead.weight(.semibold))
            }
            .accessibilityIdentifier("notifications.webhook.enableToggle")

            if enabled {
                Divider().opacity(0.5)

                VStack(alignment: .leading, spacing: HLSpace.xs) {
                    Text("notifications.webhook.url")
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                    TextField(String(localized: "notifications.webhook.urlPlaceholder"), text: $url)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .accessibilityIdentifier("notifications.webhook.urlField")
                }

                VStack(alignment: .leading, spacing: HLSpace.xs) {
                    Text("notifications.webhook.headerName")
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                    TextField(String(localized: "notifications.webhook.headerNamePlaceholder"), text: $headerName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("notifications.webhook.headerNameField")
                }

                VStack(alignment: .leading, spacing: HLSpace.xs) {
                    Text("notifications.webhook.headerValue")
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                    SecureField(headerValuePlaceholder, text: $headerValueDraft)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("notifications.webhook.headerValueField")
                }

                if let invalid = validationMessage {
                    Text(invalid)
                        .font(.hlCaption)
                        .foregroundStyle(HLColor.statusBad)
                        .accessibilityIdentifier("notifications.webhook.validation")
                }
            }

            HLButton(
                String(localized: "notifications.channel.save"),
                variant: .secondary,
                isLoading: store.webhookWorking
            ) {
                Task { await save() }
            }
            .disabled(store.webhookWorking || validationMessage != nil)
            .accessibilityIdentifier("notifications.webhook.saveButton")

            if enabled {
                HLButton(
                    String(localized: "notifications.channel.test"),
                    icon: "paperplane",
                    // UI-Standard R9 (U6) — siehe NtfyChannelCard: Test und
                    // Speichern sind hier beide `.secondary`.
                    variant: .secondary,
                    isLoading: store.webhookWorking
                ) {
                    Task { await test() }
                }
                .disabled(store.webhookWorking)
                .accessibilityIdentifier("notifications.webhook.testButton")
            }

            if store.webhookTestSucceeded {
                testOkRow
            }

            if let error = store.webhookError {
                Text(error.userFacingDescription)
                    .font(.hlCaption)
                    .foregroundStyle(HLColor.statusBad)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("notifications.webhook.error")
            }
        }
        .onAppear { hydrate() }
        .onChange(of: store.webhook) { _, _ in hydrate() }
        .sensoryFeedback(.success, trigger: testTick)
    }

    // MARK: - Derived

    private var headerValuePlaceholder: String {
        if store.webhook?.hasHeaderValue == true {
            return String(localized: "notifications.channel.token.stored")
        }
        return String(localized: "notifications.webhook.headerValuePlaceholder")
    }

    /// Mirrors the server required-field rule: when enabled, the URL must be
    /// non-empty (`route.ts:64-66`).
    private var validationMessage: String? {
        guard enabled else { return nil }
        if url.trimmingCharacters(in: .whitespaces).isEmpty {
            return String(localized: "notifications.webhook.validation.required")
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
        .accessibilityIdentifier("notifications.webhook.testOk")
    }

    // MARK: - Actions

    private func hydrate() {
        guard !hydratedFromConfig, let config = store.webhook else { return }
        enabled = config.enabled
        url = config.url
        headerName = config.headerName
        hydratedFromConfig = true
    }

    private func save() async {
        let secret = headerValueDraft.trimmingCharacters(in: .whitespaces)
        let name = headerName.trimmingCharacters(in: .whitespaces)
        await store.saveWebhook(
            enabled: enabled,
            url: url.trimmingCharacters(in: .whitespaces),
            headerName: name.isEmpty ? nil : name,
            headerValue: secret.isEmpty ? nil : secret
        )
        // Wipe the transient secret as soon as it leaves the device.
        if store.webhookError == nil {
            headerValueDraft = ""
        }
    }

    private func test() async {
        await store.testWebhook()
        if store.webhookTestSucceeded { testTick &+= 1 }
    }
}
