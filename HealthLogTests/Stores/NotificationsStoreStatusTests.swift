import Foundation
@testable import HealthLog
import Testing

/// Verifies the new parallel-status-fetch in `NotificationsStore.load()`:
/// - happy path populates `status`
/// - status failure does NOT clobber the prefs payload or set `error`
/// - `channelStatus(id:)` returns the matching row
@MainActor
@Suite("NotificationsStore status loading")
struct NotificationsStoreStatusTests {
    private let prefsPayload = NotificationPreferencesPayload(
        channels: [
            NotificationChannel(id: "ch_apns_1", type: "APNS", label: "iPhone", enabled: true, globallyEnabled: true)
        ],
        preferences: [],
        eventTypes: ["MEDICATION_REMINDER"]
    )

    private let statusPayload = NotificationStatusPayload(channels: [
        NotificationChannelStatus(
            id: "ch_apns_1",
            type: "APNS",
            label: "iPhone",
            enabled: true,
            state: .active,
            disabledReason: nil,
            consecutiveFailures: 0,
            lastSuccessAt: Date(timeIntervalSince1970: 1_716_800_000),
            lastFailureAt: nil,
            lastFailureReason: nil,
            nextRetryAt: nil
        )
    ])

    @Test("Happy path: prefs + status both populate")
    func happyPath() async {
        let api = StubAPIClient()
        let prefs = prefsPayload
        let status = statusPayload
        // Handler routes by URL — prefs vs. status endpoint
        await api.setHandler { request in
            guard let req = request as? any APIRequestType else {
                throw HLError.unknown("stub handler received a non-APIRequestType request")
            }
            if req.urlPath.contains("/status") {
                return status
            }
            return prefs
        }
        let store = NotificationsStore(repo: NotificationsRepository(api: api))
        await store.load()
        #expect(store.payload != nil)
        #expect(store.status != nil)
        #expect(store.channelStatus(id: "ch_apns_1")?.state == .active)
        #expect(store.error == nil)
    }

    @Test("Status failure does not block prefs success")
    func statusFailsSoftly() async {
        let api = StubAPIClient()
        let prefs = prefsPayload
        await api.setHandler { request in
            guard let req = request as? any APIRequestType else {
                throw HLError.unknown("stub handler received a non-APIRequestType request")
            }
            if req.urlPath.contains("/status") {
                throw HLError.server(status: 500, code: nil, message: "boom")
            }
            return prefs
        }
        let store = NotificationsStore(repo: NotificationsRepository(api: api))
        await store.load()
        #expect(store.payload != nil)
        #expect(store.status == nil)
        #expect(store.error == nil, "Status failure must NOT bubble into prefs.error")
    }

    @Test("channelStatus returns nil when status hasn't loaded")
    func channelStatusEmpty() {
        let api = StubAPIClient()
        let store = NotificationsStore(repo: NotificationsRepository(api: api))
        #expect(store.channelStatus(id: "anything") == nil)
    }

    // MARK: - REG-12 retry coverage

    /// Verifies the happy-path of `retry(channelId:)`: POST returns
    /// 2xx, the store reloads `/status` (which now reports `.active`),
    /// and the channel-id briefly lands in `lastRetrySucceededIds` so
    /// the row can render the confirmation badge.
    @Test("retry happy path flips channel back to active + sets success flag")
    func retrySucceeds() async {
        let api = StubAPIClient()
        let activeStatus = NotificationStatusPayload(channels: [
            NotificationChannelStatus(
                id: "ch_apns_1",
                type: "APNS",
                label: "iPhone",
                enabled: true,
                state: .active,
                disabledReason: nil,
                consecutiveFailures: 0,
                lastSuccessAt: Date(timeIntervalSince1970: 1_716_800_000),
                lastFailureAt: nil,
                lastFailureReason: nil,
                nextRetryAt: nil
            )
        ])
        await api.setHandler { request in
            guard let req = request as? any APIRequestType else { return EmptyPayload() }
            if req.urlPath.contains("/status") {
                // Both the GET (post-POST status reload) and the POST
                // land here — the GET returns the healthy status
                // payload. `sendVoid` reaches the same handler and
                // discards the return value.
                return activeStatus
            }
            return EmptyPayload()
        }
        let store = NotificationsStore(repo: NotificationsRepository(api: api))
        await store.retry(channelId: "ch_apns_1")
        #expect(store.error == nil)
        #expect(store.channelStatus(id: "ch_apns_1")?.state == .active)
        #expect(store.lastRetrySucceededIds.contains("ch_apns_1"))
        #expect(store.retryingChannelIds.isEmpty, "in-flight set must clear after the POST resolves")
    }

    /// Verifies the failure-path: POST throws a 5xx; the store
    /// surfaces the error via the standard `error: HLError?` slot (so
    /// the screen's existing alert binding fires) and the in-flight
    /// set drains so the button is re-enabled.
    @Test("retry surfaces server errors + drains in-flight set")
    func retryFails() async {
        let api = StubAPIClient()
        await api.setHandler { _ in
            throw HLError.server(status: 500, code: nil, message: "boom")
        }
        let store = NotificationsStore(repo: NotificationsRepository(api: api))
        await store.retry(channelId: "ch_apns_1")
        #expect(store.error != nil)
        #expect(store.lastRetrySucceededIds.isEmpty, "success flag must NOT fire on failure")
        #expect(store.retryingChannelIds.isEmpty)
    }
}

/// Helper protocol so the test handler can inspect the URL path of arbitrary
/// `APIRequest<T>` values without importing the generic shape.
protocol APIRequestType {
    var urlPath: String { get }
}

extension APIRequest: APIRequestType {
    var urlPath: String {
        path
    }
}
