import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **Build 6.5 — the per-channel notification matrix.**
///
/// Two contracts are pinned here:
/// 1. **Effective toggle state** mirrors the server's `EVENT_DEFAULT_ENABLED`
///    default-policy — a default-ON event with no explicit preference reads as
///    on (not a flat "off"), and the privacy-sensitive opt-in events read as off,
///    with any explicit `NotificationPreference` row winning.
/// 2. **Routing bodies** — toggling any channel (APNs OR a relay: Telegram /
///    ntfy / Webhook / Email) PUTs the same `{ channelId, eventType, enabled }`
///    to `/api/notifications/preferences`, routed by the opaque `channelId`. The
///    body is captured off the real `APIRequest` (encoded by the production
///    `JSONEncoder.hlDefault`), the same seam the sibling
///    `NotificationServicesStoreTests` uses for this no-outbox surface — so
///    body/shape drift surfaces here.
@Suite("NotificationChannelMatrix")
struct NotificationChannelMatrixTests {
    /// One captured void request the repo sent.
    private struct CapturedRequest {
        let path: String
        let method: HTTPMethod
        let body: Data?
    }

    /// Captures the exact encoded wire body of each void request the repo sends.
    private final class CapturingAPIClient: APIClientProtocol, @unchecked Sendable {
        var voidRequests: [CapturedRequest] = []

        func send<T: Decodable & Sendable>(_: APIRequest<T>) async throws -> T {
            throw HLError.unknown("no send handler")
        }

        func sendVoid(_ request: APIRequest<EmptyPayload>) async throws {
            voidRequests.append(CapturedRequest(path: request.path, method: request.method, body: request.body))
        }

        func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
            throw HLError.canceled
        }
    }

    // MARK: - Effective default policy (EVENT_DEFAULT_ENABLED mirror)

    private func payload(preferences: [NotificationPreference]) -> NotificationPreferencesPayload {
        NotificationPreferencesPayload(
            channels: [
                NotificationChannel(id: "ch1", type: "APNS", label: "iPhone", enabled: true, globallyEnabled: true)
            ],
            preferences: preferences,
            eventTypes: ["MEDICATION_REMINDER", "PERSONAL_RECORD", "DAILY_BRIEFING", "SYSTEM_ALERT"]
        )
    }

    @Test("a default-ON event with no preference row reads as effectively enabled")
    func defaultOnNoRow() {
        let p = payload(preferences: [])
        #expect(p.effectiveEnabled(channelId: "ch1", eventType: "MEDICATION_REMINDER"))
        #expect(p.effectiveEnabled(channelId: "ch1", eventType: "SYSTEM_ALERT"))
        #expect(p.effectiveEnabled(channelId: "ch1", eventType: "MEASUREMENT_REMINDER"))
    }

    @Test("a default-OFF (opt-in) event with no preference row reads as effectively disabled")
    func defaultOffNoRow() {
        let p = payload(preferences: [])
        #expect(!p.effectiveEnabled(channelId: "ch1", eventType: "PERSONAL_RECORD"))
        #expect(!p.effectiveEnabled(channelId: "ch1", eventType: "DAILY_BRIEFING"))
        #expect(!p.effectiveEnabled(channelId: "ch1", eventType: "MOOD_REMINDER"))
        #expect(!p.effectiveEnabled(channelId: "ch1", eventType: "CYCLE_FERTILE_SOON"))
    }

    @Test("an explicit preference row wins over the default policy — both directions")
    func explicitRowWins() {
        let disabled = payload(preferences: [
            NotificationPreference(channelId: "ch1", eventType: "MEDICATION_REMINDER", enabled: false)
        ])
        #expect(
            !disabled.effectiveEnabled(channelId: "ch1", eventType: "MEDICATION_REMINDER"),
            "an explicit off beats the default-on"
        )

        let enabled = payload(preferences: [
            NotificationPreference(channelId: "ch1", eventType: "PERSONAL_RECORD", enabled: true)
        ])
        #expect(
            enabled.effectiveEnabled(channelId: "ch1", eventType: "PERSONAL_RECORD"),
            "an explicit on beats the default-off"
        )
    }

    @Test("an unknown future event defaults ON (mirrors the server's `?? true`)")
    func unknownEventDefaultsOn() {
        #expect(NotificationEventDefaults.isOn("SOME_FUTURE_EVENT"))
        #expect(payload(preferences: []).effectiveEnabled(channelId: "ch1", eventType: "SOME_FUTURE_EVENT"))
    }

    @Test("isEnabled stays explicit-only (missing row → false) — unchanged contract")
    func isEnabledStaysExplicit() {
        let p = payload(preferences: [])
        #expect(
            !p.isEnabled(channelId: "ch1", eventType: "MEDICATION_REMINDER"),
            "isEnabled reports only an explicit enabled row, not the default policy"
        )
    }

    // MARK: - Routing bodies per channel

    @Test(
        "toggling any channel PUTs { channelId, eventType, enabled } routed by channelId",
        arguments: [
            "ch_apns", // APNS
            "ch_tg", // TELEGRAM
            "ch_ntfy", // NTFY
            "ch_webhook", // WEBHOOK
            "ch_email", // EMAIL
        ]
    )
    func routingBodyPerChannel(channelId: String) async throws {
        let api = CapturingAPIClient()
        let repo = NotificationsRepository(api: api)

        try await repo.setPreference(channelId: channelId, eventType: "MEDICATION_REMINDER", enabled: false)

        let sent = try #require(api.voidRequests.first)
        #expect(sent.method == .put)
        #expect(sent.path == "/api/notifications/preferences")
        let json = try #require(try JSONSerialization.jsonObject(with: sent.body ?? Data()) as? [String: Any])
        #expect(json["channelId"] as? String == channelId, "routing is by the opaque channelId")
        #expect(json["eventType"] as? String == "MEDICATION_REMINDER")
        #expect(json["enabled"] as? Bool == false)
    }
}

// swiftlint:enable force_unwrapping
