import Foundation

/// Wraps the per-user notification-channel settings verbs the
/// `Settings → Notifications` surface needs for the **ntfy** + **Telegram**
/// channels, plus the server-wide availability gate.
///
/// All routes live under `/api/settings/…` and ride the shared pinned
/// `APIClient`. Mirrors the `WhoopRepository` actor seam (contract-testable,
/// endpoint paths owned here, not hand-rolled inline in the View).
///
/// - `GET  /api/settings/ntfy`              — `{ enabled, serverUrl, topic, hasAuthToken }`.
/// - `PUT  /api/settings/ntfy`              — save `{ enabled, serverUrl, topic, authToken? }` → `{ saved }`.
/// - `POST /api/settings/ntfy/test`         — send a test push → `{ sent }`.
/// - `GET  /api/settings/telegram`          — `{ enabled, hasBotToken, chatId }`.
/// - `PUT  /api/settings/telegram`          — save `{ enabled, botToken?, chatId? }` → `{ updated }`.
/// - `POST /api/settings/telegram/test`     — send a test message → `{ sent }`.
/// - `GET  /api/settings/global-services`   — server-wide channel availability flags.
///
/// **Secret handling:** the ntfy `authToken` and Telegram `botToken` are sent
/// **once** via `PUT` and stored encrypted server-side. They are never returned
/// on any read, never persisted client-side, and never logged — the bodies are
/// plain `Encodable` structs with no `CustomStringConvertible`, and no logging
/// path touches them. The GET shapes carry only `hasAuthToken` / `hasBotToken`.
///
/// **Idempotency:** the `PUT` saves are single user-initiated upserts riding the
/// default `Idempotency-Key` (per `APIRequest.put`). The `test` POSTs are
/// low-rate, server-rate-limited probes — no outbox `Kind` is wired (these are
/// Settings actions, not high-volume health writes).
public actor NotificationServicesRepository {
    /// `PUT /api/settings/ntfy` body. `authToken` is sent only when the user
    /// entered/changed one; `nil` ⇒ the server keeps the stored token.
    struct SaveNtfyBody: Encodable {
        let enabled: Bool
        let serverUrl: String
        let topic: String
        let authToken: String?
    }

    /// `PUT /api/settings/telegram` body. `botToken` / `chatId` are sent only
    /// when changed; omitted fields leave the stored values untouched
    /// (server `route.ts` — `botToken !== undefined` / `chatId !== undefined`).
    struct SaveTelegramBody: Encodable {
        let enabled: Bool
        let botToken: String?
        let chatId: String?
    }

    /// `PUT /api/settings/webhook` body. `headerValue` (write-only shared
    /// secret) is sent only on change; an empty value leaves the stored secret
    /// untouched server-side (`route.ts:68-82`).
    struct SaveWebhookBody: Encodable {
        let enabled: Bool
        let url: String
        let headerName: String?
        let headerValue: String?
    }

    private let api: APIClientProtocol

    public init(api: APIClientProtocol) {
        self.api = api
    }

    // MARK: - ntfy

    public func ntfyConfig() async throws -> NtfyConfig {
        let req: APIRequest<NtfyConfig> = .get("/api/settings/ntfy")
        return try await api.send(req)
    }

    /// Saves the ntfy channel config. `authToken` is forwarded only on change.
    public func saveNtfy(
        enabled: Bool,
        serverUrl: String,
        topic: String,
        authToken: String?
    ) async throws {
        let req: APIRequest<EmptyPayload> = try .put(
            "/api/settings/ntfy",
            body: SaveNtfyBody(
                enabled: enabled,
                serverUrl: serverUrl,
                topic: topic,
                authToken: authToken
            )
        )
        try await api.sendVoid(req)
    }

    /// Fires a server-side test push via the configured ntfy server.
    public func testNtfy() async throws -> NotificationChannelTestResult {
        let req: APIRequest<NotificationChannelTestResult> = try .post(
            "/api/settings/ntfy/test",
            body: EmptyBody()
        )
        return try await api.send(req)
    }

    // MARK: - Telegram

    public func telegramConfig() async throws -> TelegramConfig {
        let req: APIRequest<TelegramConfig> = .get("/api/settings/telegram")
        return try await api.send(req)
    }

    /// Saves the Telegram channel config. `botToken` (write-only secret) and
    /// `chatId` are forwarded only on change.
    public func saveTelegram(
        enabled: Bool,
        botToken: String?,
        chatId: String?
    ) async throws {
        let req: APIRequest<EmptyPayload> = try .put(
            "/api/settings/telegram",
            body: SaveTelegramBody(enabled: enabled, botToken: botToken, chatId: chatId)
        )
        try await api.sendVoid(req)
    }

    /// Fires a server-side test message via the configured Telegram bot.
    public func testTelegram() async throws -> NotificationChannelTestResult {
        let req: APIRequest<NotificationChannelTestResult> = try .post(
            "/api/settings/telegram/test",
            body: EmptyBody()
        )
        return try await api.send(req)
    }

    // MARK: - Webhook

    public func webhookConfig() async throws -> WebhookConfig {
        let req: APIRequest<WebhookConfig> = .get("/api/settings/webhook")
        return try await api.send(req)
    }

    /// Saves the generic-webhook channel config. `headerValue` (write-only
    /// shared secret) is forwarded only on change.
    public func saveWebhook(
        enabled: Bool,
        url: String,
        headerName: String?,
        headerValue: String?
    ) async throws {
        let req: APIRequest<EmptyPayload> = try .put(
            "/api/settings/webhook",
            body: SaveWebhookBody(
                enabled: enabled,
                url: url,
                headerName: headerName,
                headerValue: headerValue
            )
        )
        try await api.sendVoid(req)
    }

    /// Fires a server-side test notification via the configured webhook.
    public func testWebhook() async throws -> NotificationChannelTestResult {
        let req: APIRequest<NotificationChannelTestResult> = try .post(
            "/api/settings/webhook/test",
            body: EmptyBody()
        )
        return try await api.send(req)
    }

    // MARK: - Global gating

    public func globalServices() async throws -> GlobalServicesFlags {
        let req: APIRequest<GlobalServicesFlags> = .get("/api/settings/global-services")
        return try await api.send(req)
    }
}

/// Empty JSON `{}` POST body for the bodiless `…/test` POSTs.
private struct EmptyBody: Encodable {}
