import Foundation
@testable import HealthLog
import Testing

/// Optimistic-Toggle Verhalten + Revert bei Server-Fehler. NotificationsStore
/// hängt am NotificationsRepository (das wiederum am APIClientProtocol). Wir
/// nutzen den vorhandenen StubAPIClient aus dem Repo-Test-Setup.
@MainActor
@Suite("NotificationsStore optimistic toggle")
struct NotificationsStoreTests {
    private func makeStub() -> StubAPIClient {
        StubAPIClient()
    }

    private func makeStore(api: StubAPIClient) -> NotificationsStore {
        NotificationsStore(repo: NotificationsRepository(api: api))
    }

    private let initialPayload = NotificationPreferencesPayload(
        channels: [
            NotificationChannel(id: "ch_apns_1", type: "APNS", label: "iPhone", enabled: true, globallyEnabled: true)
        ],
        preferences: [
            NotificationPreference(channelId: "ch_apns_1", eventType: "MEDICATION_REMINDER", enabled: true)
        ],
        eventTypes: ["MEDICATION_REMINDER", "PERSONAL_RECORD"]
    )

    @Test("Erfolgs-Toggle aendert Preference + setzt error=nil")
    func toggleHappy() async {
        let api = makeStub()
        let payload = initialPayload
        await api.setHandler { _ in payload }

        let store = makeStore(api: api)
        await store.load()
        #expect(store.payload?.isEnabled(channelId: "ch_apns_1", eventType: "PERSONAL_RECORD") == false)

        // Switch handler auf void-success für den PUT.
        await api.setHandler { _ in EmptyPayload() }
        await store.toggle(channelId: "ch_apns_1", eventType: "PERSONAL_RECORD", to: true)
        #expect(store.payload?.isEnabled(channelId: "ch_apns_1", eventType: "PERSONAL_RECORD") == true)
        #expect(store.error == nil)
    }

    @Test("PUT-Fehler revertiert die Preference + setzt error")
    func toggleRevertOnError() async {
        let api = makeStub()
        let payload = initialPayload
        await api.setHandler { _ in payload }
        let store = makeStore(api: api)
        await store.load()
        #expect(store.payload?.isEnabled(channelId: "ch_apns_1", eventType: "MEDICATION_REMINDER") == true)

        await api.setHandler { _ in throw HLError.server(status: 500, code: nil, message: "boom") }
        await store.toggle(channelId: "ch_apns_1", eventType: "MEDICATION_REMINDER", to: false)

        // Toggle muss zurückgekippt sein, weil PUT failed.
        #expect(store.payload?.isEnabled(channelId: "ch_apns_1", eventType: "MEDICATION_REMINDER") == true)
        #expect(store.error != nil)
    }

    @Test("PERSONAL_RECORD ohne Server-Preference defaultet auf false (server-default-OFF)")
    func personalRecordDefaultsOff() async {
        let api = makeStub()
        // Payload OHNE PERSONAL_RECORD-Preference.
        let payload = NotificationPreferencesPayload(
            channels: initialPayload.channels,
            preferences: [],
            eventTypes: ["PERSONAL_RECORD"]
        )
        await api.setHandler { _ in payload }

        let store = makeStore(api: api)
        await store.load()
        #expect(store.payload?.isEnabled(channelId: "ch_apns_1", eventType: "PERSONAL_RECORD") == false)
    }
}
