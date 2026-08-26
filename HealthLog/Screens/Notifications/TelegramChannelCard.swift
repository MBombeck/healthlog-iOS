import SwiftUI

/// `Settings → Notifications → Telegram` channel card. Lets the user wire a
/// Telegram bot (bot token + chat ID) and send a server-side test message.
/// Mirrors the web Telegram settings card.
///
/// **Gated** by `store.showTelegramCard` (server-wide `telegramGlobal`).
///
/// **Secret handling:** the `botToken` is **write-only** — the server never
/// returns it (only `hasBotToken`). It lives only in this View's transient
/// `@State`, is sent once via `store.saveTelegram(botToken:)`, wiped from the
/// field on success, never displayed, never persisted, never logged.
struct TelegramChannelCard: View {
    @Environment(NotificationServicesStore.self) private var store

    @State private var enabled = false
    @State private var chatId = ""
    /// Transient bot-token draft. Empty ⇒ not sent (server keeps the stored
    /// token). The stored token is never read back into this field.
    @State private var botTokenDraft = ""
    @State private var hydratedFromConfig = false
    @State private var testTick = 0

    var body: some View {
        HLSettingsCard(
            icon: "paperplane.fill",
            title: "notifications.telegram.title",
            footer: "notifications.telegram.footer"
        ) {
            Toggle(isOn: $enabled) {
                Text("notifications.telegram.enable")
                    .font(.hlSubhead.weight(.semibold))
            }
            .accessibilityIdentifier("notifications.telegram.enableToggle")

            if enabled {
                Divider().opacity(0.5)

                VStack(alignment: .leading, spacing: HLSpace.xs) {
                    Text("notifications.telegram.token")
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                    SecureField(tokenPlaceholder, text: $botTokenDraft)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("notifications.telegram.tokenField")
                }

                VStack(alignment: .leading, spacing: HLSpace.xs) {
                    Text("notifications.telegram.chatId")
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                    TextField(String(localized: "notifications.telegram.chatIdPlaceholder"), text: $chatId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.numbersAndPunctuation)
                        .accessibilityIdentifier("notifications.telegram.chatIdField")
                }

                if let invalid = validationMessage {
                    Text(invalid)
                        .font(.hlCaption)
                        .foregroundStyle(HLColor.statusBad)
                        .accessibilityIdentifier("notifications.telegram.validation")
                }
            }

            HLButton(
                String(localized: "notifications.channel.save"),
                variant: .secondary,
                isLoading: store.telegramWorking
            ) {
                Task { await save() }
            }
            .disabled(store.telegramWorking || validationMessage != nil)
            .accessibilityIdentifier("notifications.telegram.saveButton")

            if enabled {
                HLButton(
                    String(localized: "notifications.channel.test"),
                    icon: "paperplane",
                    // UI-Standard R9 (U6) — siehe NtfyChannelCard: Test und
                    // Speichern sind hier beide `.secondary`.
                    variant: .secondary,
                    isLoading: store.telegramWorking
                ) {
                    Task { await test() }
                }
                .disabled(store.telegramWorking)
                .accessibilityIdentifier("notifications.telegram.testButton")
            }

            if store.telegramTestSucceeded {
                testOkRow
            }

            if let error = store.telegramError {
                // v0.14.1 #3 — generic copy for 5xx; never raw server text.
                Text(error.userFacingDescription)
                    .font(.hlCaption)
                    .foregroundStyle(HLColor.statusBad)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("notifications.telegram.error")
            }
        }
        .onAppear { hydrate() }
        .onChange(of: store.telegram) { _, _ in hydrate() }
        .sensoryFeedback(.success, trigger: testTick)
    }

    // MARK: - Derived

    private var tokenPlaceholder: String {
        if store.telegram?.hasBotToken == true {
            return String(localized: "notifications.channel.token.stored")
        }
        return String(localized: "notifications.telegram.tokenPlaceholder")
    }

    /// Mirrors the server required-field rule: when enabled, a token (stored or
    /// freshly entered) AND a chat ID are required (`route.ts:70-76`).
    private var validationMessage: String? {
        guard enabled else { return nil }
        let token = botTokenDraft.trimmingCharacters(in: .whitespaces)
        let chat = chatId.trimmingCharacters(in: .whitespaces)
        let hasTokenAfterSave = !token.isEmpty || (store.telegram?.hasBotToken == true)
        if !hasTokenAfterSave || chat.isEmpty {
            return String(localized: "notifications.telegram.validation.required")
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
        .accessibilityIdentifier("notifications.telegram.testOk")
    }

    // MARK: - Actions

    private func hydrate() {
        guard !hydratedFromConfig, let config = store.telegram else { return }
        enabled = config.enabled
        chatId = config.chatId ?? ""
        hydratedFromConfig = true
    }

    private func save() async {
        let token = botTokenDraft.trimmingCharacters(in: .whitespaces)
        let chat = chatId.trimmingCharacters(in: .whitespaces)
        await store.saveTelegram(
            enabled: enabled,
            botToken: token.isEmpty ? nil : token,
            chatId: chat.isEmpty ? nil : chat
        )
        // Wipe the transient bot token as soon as it leaves the device.
        if store.telegramError == nil {
            botTokenDraft = ""
        }
    }

    private func test() async {
        await store.testTelegram()
        if store.telegramTestSucceeded { testTick &+= 1 }
    }
}
