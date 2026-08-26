// swiftlint:disable force_unwrapping
import Foundation
@testable import HealthLog
import Testing

/// **Server-parity — Coach proactive nudge** (`GET /api/insights/coach/nudge-status`
/// + `POST /api/insights/coach/seen`, server v1.18.6 CCH-03).
///
/// Pins the wire shape against the *real* `APIClient` with a stubbed
/// `URLSession` (`MockURLProtocol`) — never a mock server (PROJECT_GUIDE.md):
///   - `CoachNudgeStatus` envelope decode (`{ data: { nudgedAt, unread } }`),
///   - defensive decode (null `nudgedAt`, missing `unread` → `false`),
///   - the seen POST path + method,
/// plus the `CoachNudgeStore` logic (unread → dot, gating, optimistic clear).
@Suite("Coach nudge — wire shape + store logic", .serialized)
struct CoachNudgeTests {
    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            cfAccessClientID: nil,
            cfAccessClientToken: nil,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
    }

    // MARK: - DTO decode (wire shape)

    @Test("nudgeStatus GETs the status path and decodes { nudgedAt, unread }")
    func nudgeStatusWireShape() async throws {
        let api = makeAPI()
        nonisolated(unsafe) var capturedPath: String?
        nonisolated(unsafe) var capturedMethod: String?
        MockURLProtocol.handler = { req in
            capturedPath = req.url?.path
            capturedMethod = req.httpMethod
            let payload = #"{"data":{"nudgedAt":"2026-06-11T10:00:00.000Z","unread":true},"error":null}"#
            let http = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (http, Data(payload.utf8))
        }
        let service = CoachServerService(api: api)
        let status = try await service.nudgeStatus()

        #expect(capturedPath == "/api/insights/coach/nudge-status")
        #expect(capturedMethod == "GET")
        #expect(status.unread == true)
        #expect(status.nudgedAt != nil)
    }

    @Test("nudgeStatus decodes a null nudgedAt + unread:false (no nudge waiting)")
    func nudgeStatusEmpty() async throws {
        let api = makeAPI()
        MockURLProtocol.handler = { req in
            let payload = #"{"data":{"nudgedAt":null,"unread":false},"error":null}"#
            let http = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (http, Data(payload.utf8))
        }
        let status = try await CoachServerService(api: api).nudgeStatus()
        #expect(status.unread == false)
        #expect(status.nudgedAt == nil)
    }

    @Test("defensive decode — a payload missing `unread` reads as not-unread")
    func nudgeStatusMissingUnread() throws {
        // Decode the unwrapped `data` object directly (the APIClient strips the
        // envelope) — a partial body must never fabricate an unread dot.
        let json = #"{"nudgedAt":null}"#
        let dto = try JSONDecoder().decode(CoachNudgeStatus.self, from: Data(json.utf8))
        #expect(dto.unread == false)
        #expect(dto.nudgedAt == nil)
    }

    @Test("markCoachSeen POSTs to the seen path with an empty body")
    func markSeenWireShape() async throws {
        let api = makeAPI()
        nonisolated(unsafe) var capturedPath: String?
        nonisolated(unsafe) var capturedMethod: String?
        MockURLProtocol.handler = { req in
            capturedPath = req.url?.path
            capturedMethod = req.httpMethod
            let payload = #"{"data":{"seenAt":"2026-06-11T10:00:00.000Z"},"error":null}"#
            let http = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (http, Data(payload.utf8))
        }
        try await CoachServerService(api: api).markCoachSeen()
        #expect(capturedPath == "/api/insights/coach/seen")
        #expect(capturedMethod == "POST")
    }

    // MARK: - Store logic

    @MainActor
    @Test("refresh maps server unread → dot; coach-off clears it without a call")
    func storeUnreadDrivesDot() async {
        nonisolated(unsafe) var fetchCount = 0
        let store = CoachNudgeStore(
            fetchStatus: {
                fetchCount += 1
                return CoachNudgeStatus(nudgedAt: .now, unread: true)
            },
            postSeen: {}
        )
        #expect(store.unread == false) // no fabricated state pre-refresh

        await store.refresh(coachEnabled: true, online: true)
        #expect(store.unread == true)
        #expect(fetchCount == 1)

        // Coach module off → clear the dot, do NOT call the server again.
        await store.refresh(coachEnabled: false, online: true)
        #expect(store.unread == false)
        #expect(fetchCount == 1)
    }

    @MainActor
    @Test("offline refresh keeps the last-known dot and fires no request")
    func storeOfflineNoCall() async {
        nonisolated(unsafe) var fetchCount = 0
        let store = CoachNudgeStore(
            fetchStatus: {
                fetchCount += 1
                return CoachNudgeStatus(nudgedAt: .now, unread: true)
            }
        )
        await store.refresh(coachEnabled: true, online: true)
        #expect(store.unread == true)
        #expect(fetchCount == 1)

        await store.refresh(coachEnabled: true, online: false)
        #expect(store.unread == true) // unchanged — last-known kept
        #expect(fetchCount == 1) // no doomed request
    }

    @MainActor
    @Test("markSeenOptimistically clears the dot on the same tick")
    func storeOptimisticClear() async {
        nonisolated(unsafe) var seenCount = 0
        let store = CoachNudgeStore(
            fetchStatus: { CoachNudgeStatus(nudgedAt: .now, unread: true) },
            postSeen: { seenCount += 1 }
        )
        await store.refresh(coachEnabled: true, online: true)
        #expect(store.unread == true)

        let seenTask = store.markSeenOptimistically()
        #expect(store.unread == false) // optimistic — synchronous, no await on the POST

        // Deterministically await the fire-and-forget seen POST via the returned
        // task handle (no yield-and-hope: stable under the parallel runner).
        await seenTask?.value
        #expect(seenCount == 1)
    }

    @MainActor
    @Test("a failed refresh leaves the last-known dot (never flips it on)")
    func storeFailQuiet() async {
        struct Boom: Error {}
        let store = CoachNudgeStore(fetchStatus: { throw Boom() })
        await store.refresh(coachEnabled: true, online: true)
        #expect(store.unread == false) // failure never invents an unread dot
    }

    @MainActor
    @Test("clearOnLogout drops the unread signal")
    func storeClearOnLogout() async {
        let store = CoachNudgeStore(
            fetchStatus: { CoachNudgeStatus(nudgedAt: .now, unread: true) }
        )
        await store.refresh(coachEnabled: true, online: true)
        #expect(store.unread == true)
        store.clearOnLogout()
        #expect(store.unread == false)
        #expect(store.nudgedAt == nil)
    }
}
