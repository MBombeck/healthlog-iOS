import Foundation
import Observation

/// `@Observable` store for the **ntfy** + **Telegram** notification-channel
/// settings under `Settings → Notifications`. Wraps
/// ``NotificationServicesRepository`` (status read + saves + test probes) and
/// the server-wide availability gate.
///
/// **Gating:** the View only renders a channel card when its global flag is on
/// (``GlobalServicesFlags``) — mirroring the web `globalServices`
/// (`telegramGlobal` / `ntfyGlobal`). A server admin who disabled a channel
/// globally hides the card entirely.
///
/// **Secret handling:** neither the ntfy `authToken` nor the Telegram
/// `botToken` is ever stored on this store. The Views hold the draft secrets in
/// transient `@State` and pass them straight through `saveNtfy` / `saveTelegram`;
/// the store forwards them once and never logs them.
///
/// **No outbox.** These are user-config writes (not health data), so a network
/// failure surfaces an inline error and the user retries — no replay queue.
@MainActor
@Observable
public final class NotificationServicesStore {
    public private(set) var ntfy: NtfyConfig?
    public private(set) var telegram: TelegramConfig?
    public private(set) var webhook: WebhookConfig?
    /// Server-wide availability flags. Defaults to all-enabled until loaded so a
    /// slow/missing flags response never hides a channel the user configured.
    public private(set) var globals: GlobalServicesFlags = .allEnabled

    /// Per-card in-flight + result state.
    public private(set) var ntfyWorking = false
    public private(set) var telegramWorking = false
    public private(set) var webhookWorking = false
    public private(set) var ntfyError: HLError?
    public private(set) var telegramError: HLError?
    public private(set) var webhookError: HLError?
    /// `true` after a successful test send; cleared on the next action. Drives
    /// the transient "test sent" confirmation row + success haptic.
    public private(set) var ntfyTestSucceeded = false
    public private(set) var telegramTestSucceeded = false
    public private(set) var webhookTestSucceeded = false

    private let repo: NotificationServicesRepository

    public init(repo: NotificationServicesRepository) {
        self.repo = repo
    }

    /// Should the ntfy card render? `false` when the server disabled it globally.
    public var showNtfyCard: Bool {
        globals.ntfyGlobal
    }

    /// Should the Telegram card render? `false` when disabled globally.
    public var showTelegramCard: Bool {
        globals.telegramGlobal
    }

    // MARK: - Load

    /// Loads the global flags + both channel configs. Flags load first so the
    /// View can skip fetching a channel's config when it's globally hidden.
    public func load() async {
        await loadGlobals()
        async let n: Void = loadNtfy()
        async let t: Void = loadTelegram()
        async let w: Void = loadWebhook()
        _ = await (n, t, w)
    }

    /// Loads the generic-webhook channel config. No global flag gates this
    /// channel, so it always loads (unlike ntfy/Telegram).
    public func loadWebhook() async {
        webhookError = nil
        do {
            webhook = try await repo.webhookConfig()
        } catch let err as HLError {
            webhookError = err
        } catch {
            webhookError = .unknown(String(describing: error))
        }
    }

    public func loadGlobals() async {
        do {
            globals = try await repo.globalServices()
        } catch {
            // Keep the all-enabled fallback — a flags failure must not hide
            // channels the user may already use. The per-card load surfaces any
            // real auth/network error.
            globals = .allEnabled
        }
    }

    public func loadNtfy() async {
        guard globals.ntfyGlobal else { return }
        ntfyError = nil
        do {
            ntfy = try await repo.ntfyConfig()
        } catch let err as HLError {
            ntfyError = err
        } catch {
            ntfyError = .unknown(String(describing: error))
        }
    }

    public func loadTelegram() async {
        guard globals.telegramGlobal else { return }
        telegramError = nil
        do {
            telegram = try await repo.telegramConfig()
        } catch let err as HLError {
            telegramError = err
        } catch {
            telegramError = .unknown(String(describing: error))
        }
    }

    // MARK: - ntfy mutations

    /// Saves the ntfy config, then re-loads so `hasAuthToken` + persisted values
    /// reflect the server. `authToken` is forwarded only when the user entered
    /// one (`nil` keeps the stored token); it is never retained here.
    public func saveNtfy(enabled: Bool, serverUrl: String, topic: String, authToken: String?) async {
        ntfyWorking = true
        ntfyError = nil
        ntfyTestSucceeded = false
        defer { ntfyWorking = false }
        do {
            try await repo.saveNtfy(
                enabled: enabled,
                serverUrl: serverUrl,
                topic: topic,
                authToken: authToken
            )
            await loadNtfy()
        } catch let err as HLError {
            ntfyError = err
        } catch {
            ntfyError = .unknown(String(describing: error))
        }
    }

    public func testNtfy() async {
        ntfyWorking = true
        ntfyError = nil
        ntfyTestSucceeded = false
        defer { ntfyWorking = false }
        do {
            let result = try await repo.testNtfy()
            ntfyTestSucceeded = result.sent
        } catch let err as HLError {
            ntfyError = err
        } catch {
            ntfyError = .unknown(String(describing: error))
        }
    }

    // MARK: - Telegram mutations

    /// Saves the Telegram config, then re-loads. `botToken` (write-only secret)
    /// + `chatId` are forwarded only on change; the token is never retained.
    public func saveTelegram(enabled: Bool, botToken: String?, chatId: String?) async {
        telegramWorking = true
        telegramError = nil
        telegramTestSucceeded = false
        defer { telegramWorking = false }
        do {
            try await repo.saveTelegram(enabled: enabled, botToken: botToken, chatId: chatId)
            await loadTelegram()
        } catch let err as HLError {
            telegramError = err
        } catch {
            telegramError = .unknown(String(describing: error))
        }
    }

    public func testTelegram() async {
        telegramWorking = true
        telegramError = nil
        telegramTestSucceeded = false
        defer { telegramWorking = false }
        do {
            let result = try await repo.testTelegram()
            telegramTestSucceeded = result.sent
        } catch let err as HLError {
            telegramError = err
        } catch {
            telegramError = .unknown(String(describing: error))
        }
    }

    // MARK: - Webhook mutations

    /// Saves the webhook config, then re-loads so `hasHeaderValue` + persisted
    /// values reflect the server. `headerValue` (write-only secret) is
    /// forwarded only when the user entered one; it is never retained here.
    public func saveWebhook(enabled: Bool, url: String, headerName: String?, headerValue: String?) async {
        webhookWorking = true
        webhookError = nil
        webhookTestSucceeded = false
        defer { webhookWorking = false }
        do {
            try await repo.saveWebhook(
                enabled: enabled,
                url: url,
                headerName: headerName,
                headerValue: headerValue
            )
            await loadWebhook()
        } catch let err as HLError {
            webhookError = err
        } catch {
            webhookError = .unknown(String(describing: error))
        }
    }

    public func testWebhook() async {
        webhookWorking = true
        webhookError = nil
        webhookTestSucceeded = false
        defer { webhookWorking = false }
        do {
            let result = try await repo.testWebhook()
            webhookTestSucceeded = result.sent
        } catch let err as HLError {
            webhookError = err
        } catch {
            webhookError = .unknown(String(describing: error))
        }
    }

    // MARK: - Lifecycle

    public func clearOnLogout() {
        ntfy = nil
        telegram = nil
        webhook = nil
        globals = .allEnabled
        ntfyError = nil
        telegramError = nil
        webhookError = nil
        ntfyTestSucceeded = false
        telegramTestSucceeded = false
        webhookTestSucceeded = false
    }
}
