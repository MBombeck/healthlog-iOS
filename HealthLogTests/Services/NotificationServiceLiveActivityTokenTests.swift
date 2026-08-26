import Foundation
import Testing
#if canImport(UserNotifications) && canImport(UIKit) && canImport(ActivityKit)
    @testable import HealthLog
    import UserNotifications

    // swiftlint:disable force_unwrapping

    /// W-B189 (#22) — wires the ActivityKit Live-Activity push token into the
    /// existing `POST /api/devices` registration so the server (≥ v1.17.1) can
    /// send a direct `apns-push-type: liveactivity` `end`/`update` push to a
    /// running medication Live Activity.
    ///
    /// These tests pin the iOS contract:
    ///   - The `/api/devices` body carries `liveActivityPushToken` when a token
    ///     is cached at registration time (and omits it when none is cached).
    ///   - A *new* LA token arriving at the sink re-fires the registration; an
    ///     unchanged token does not (idempotent — no spam).
    ///   - The silent `MEDICATION_INTAKE_SYNC` push parses + dispatches a
    ///     force-reconcile (the inbound side the server already drives).
    @Suite("NotificationService — Live-Activity push-token registration (W-B189 #22)", .serialized)
    @MainActor
    struct NotificationServiceLiveActivityTokenTests {
        private static let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.14.1",
            buildNumber: "189"
        )

        private func makeAPI() -> APIClient {
            let keychain = InMemoryKeychain()
            try? keychain.setString("token", forKey: KeychainKey.authToken)
            return APIClient(
                environment: Self.env,
                keychain: keychain,
                sessionConfiguration: .mock()
            )
        }

        private func makeDefaults() -> UserDefaults {
            let suiteName = "test.notif.laToken.\(UUID().uuidString)"
            return UserDefaults(suiteName: suiteName)!
        }

        private func makeService(
            api: APIClient,
            defaults: UserDefaults,
            backgroundSync: BackgroundSyncCoordinator? = nil
        ) -> NotificationService {
            let appRouter = AppRouter()
            let deepLinks = DeepLinkRouter(router: appRouter, isAuthenticated: { true })
            return NotificationService(
                api: api,
                environment: Self.env,
                keychain: InMemoryKeychain(),
                deepLinks: deepLinks,
                backgroundSync: backgroundSync,
                defaults: defaults
            )
        }

        nonisolated static func okResponse(_ req: URLRequest, status: Int = 200) -> HTTPURLResponse {
            HTTPURLResponse(
                url: req.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
        }

        /// A request-body recorder shared with the off-actor `MockURLProtocol`
        /// handler. Drains the body stream so we can assert the encoded fields.
        private final class BodyRecorder: @unchecked Sendable {
            private let lock = NSLock()
            private var bodies: [Data] = []
            func record(_ data: Data) {
                lock.withLock { bodies.append(data) }
            }

            var count: Int {
                lock.withLock { bodies.count }
            }

            var isEmpty: Bool {
                lock.withLock { bodies.isEmpty }
            }

            var last: Data? {
                lock.withLock { bodies.last }
            }

            func decodedLast() -> [String: Any]? {
                guard let data = last,
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
                return obj
            }
        }

        // MARK: - Body carries liveActivityPushToken

        @Test("POST /api/devices includes liveActivityPushToken when a token is cached")
        func bodyIncludesLiveActivityToken() async {
            let recorder = BodyRecorder()
            MockURLProtocol.handler = { req in
                if let body = req.httpBody ?? req.bodyStreamData() {
                    recorder.record(body)
                }
                return (Self.okResponse(req), Data())
            }
            let svc = makeService(api: makeAPI(), defaults: makeDefaults())

            // Cache a per-activity update token BEFORE the APNs registration so
            // the registration body picks it up. (didReceiveActivityUpdateToken
            // also triggers a re-register, but there is no cached APNs token yet,
            // so that path is a no-op — the registration below is the first POST.)
            await svc.didReceiveActivityUpdateToken("deadbeefcafef00d", medicationId: "med_abc")
            #expect(recorder.isEmpty) // no APNs token yet → no POST

            // Now the APNs token arrives → first real POST carries the LA token.
            await svc.didRegister(deviceToken: Data(repeating: 0xAB, count: 64))

            #expect(recorder.count == 1)
            let body = recorder.decodedLast()
            #expect(body?["liveActivityPushToken"] as? String == "deadbeefcafef00d")
            #expect(body?["apnsToken"] is String)
        }

        @Test("POST /api/devices omits liveActivityPushToken when none is cached")
        func bodyOmitsTokenWhenAbsent() async {
            let recorder = BodyRecorder()
            MockURLProtocol.handler = { req in
                if let body = req.httpBody ?? req.bodyStreamData() {
                    recorder.record(body)
                }
                return (Self.okResponse(req), Data())
            }
            let svc = makeService(api: makeAPI(), defaults: makeDefaults())

            await svc.didRegister(deviceToken: Data(repeating: 0xAB, count: 64))

            #expect(recorder.count == 1)
            let body = recorder.decodedLast()
            // The field is omitted (not `null`) so pre-1.17.1 servers see the
            // unchanged body shape.
            #expect(body?.keys.contains("liveActivityPushToken") == false)
        }

        // MARK: - Re-registration on token change

        @Test("A new LA token after APNs registration re-fires POST /api/devices")
        func newTokenReRegisters() async {
            let recorder = BodyRecorder()
            MockURLProtocol.handler = { req in
                if let body = req.httpBody ?? req.bodyStreamData() {
                    recorder.record(body)
                }
                return (Self.okResponse(req), Data())
            }
            let svc = makeService(api: makeAPI(), defaults: makeDefaults())

            // 1) First the APNs token registers (no LA token yet).
            await svc.didRegister(deviceToken: Data(repeating: 0xAB, count: 64))
            #expect(recorder.count == 1)
            #expect(recorder.decodedLast()?.keys.contains("liveActivityPushToken") == false)

            // 2) A LA update token arrives → idempotent re-register with the
            //    cached APNs token, now carrying the LA token.
            await svc.didReceiveActivityUpdateToken("aa11bb22cc33", medicationId: "med_x")
            #expect(recorder.count == 2)
            #expect(recorder.decodedLast()?["liveActivityPushToken"] as? String == "aa11bb22cc33")
        }

        @Test("An unchanged LA token does not re-fire POST /api/devices (idempotent)")
        func unchangedTokenDoesNotSpam() async {
            let recorder = BodyRecorder()
            MockURLProtocol.handler = { req in
                if let body = req.httpBody ?? req.bodyStreamData() {
                    recorder.record(body)
                }
                return (Self.okResponse(req), Data())
            }
            let svc = makeService(api: makeAPI(), defaults: makeDefaults())

            await svc.didRegister(deviceToken: Data(repeating: 0xAB, count: 64))
            #expect(recorder.count == 1)

            // Same token twice → first re-registers, second is deduped away.
            await svc.didReceiveActivityUpdateToken("aa11bb22cc33", medicationId: "med_x")
            #expect(recorder.count == 2)
            await svc.didReceiveActivityUpdateToken("aa11bb22cc33", medicationId: "med_x")
            #expect(recorder.count == 2) // unchanged → no extra POST
        }

        @Test("currentLiveActivityPushToken prefers update token, falls back to push-to-start")
        func tokenPreferenceOrder() async {
            let svc = makeService(api: makeAPI(), defaults: makeDefaults())

            // Only a push-to-start token cached → it is the current token.
            await svc.didReceivePushToStartToken("p2s-token")
            #expect(svc.currentLiveActivityPushToken == "p2s-token")

            // An update token takes precedence (it can push a *running* Activity).
            await svc.didReceiveActivityUpdateToken("update-token", medicationId: "med_a")
            #expect(svc.currentLiveActivityPushToken == "update-token")
        }

        // MARK: - Inbound silent-push verification (MEDICATION_INTAKE_SYNC)

        @Test("MEDICATION_INTAKE_SYNC silent push parses payload + triggers reconcile")
        func intakeSyncTriggersReconcile() async {
            MockURLProtocol.handler = { req in (Self.okResponse(req), Data()) }

            let coordinator = BackgroundSyncCoordinator(healthKit: nil)
            let reconcileRan = ReconcileFlag()
            coordinator.attachMedicationReconcileHook {
                await reconcileRan.set()
            }
            let svc = makeService(
                api: makeAPI(),
                defaults: makeDefaults(),
                backgroundSync: coordinator
            )

            // Exact payload shape the server (≥ 1.17.1) dispatches.
            let userInfo: [AnyHashable: Any] = [
                "aps": ["content-available": 1],
                "eventType": "MEDICATION_INTAKE_SYNC",
                "medicationId": "med_abc",
                "scheduledFor": "2026-06-14T09:00:00.000Z"
            ]
            // Confirm the parser extracts the fields the handler routes on.
            let parsed = APNsPayload.parse(userInfo: userInfo)
            #expect(parsed?.eventType == "MEDICATION_INTAKE_SYNC")
            #expect(parsed?.medicationId == "med_abc")
            #expect(parsed?.scheduledFor != nil)

            let result = await svc.didReceiveSilentNotification(
                userInfo: RemoteNotificationUserInfo(userInfo)
            )

            #expect(await reconcileRan.value == true)
            #expect(result == .newData)
        }

        @Test("Non-intake silent push does not trigger reconcile")
        func unrelatedSilentPushIsNoop() async {
            MockURLProtocol.handler = { req in (Self.okResponse(req), Data()) }

            let coordinator = BackgroundSyncCoordinator(healthKit: nil)
            let reconcileRan = ReconcileFlag()
            coordinator.attachMedicationReconcileHook {
                await reconcileRan.set()
            }
            let svc = makeService(
                api: makeAPI(),
                defaults: makeDefaults(),
                backgroundSync: coordinator
            )

            let userInfo: [AnyHashable: Any] = [
                "aps": ["content-available": 1],
                "eventType": "SOME_OTHER_EVENT"
            ]
            let result = await svc.didReceiveSilentNotification(
                userInfo: RemoteNotificationUserInfo(userInfo)
            )

            #expect(await reconcileRan.value == false)
            #expect(result == .noData)
        }
    }

    /// Actor flag so the off-isolation reconcile hook can flip + the test can
    /// read it without a data race.
    private actor ReconcileFlag {
        private(set) var value = false
        func set() {
            value = true
        }
    }

    // MARK: - URLRequest body-stream helper

    private extension URLRequest {
        /// `URLProtocol` pipes the POST body through `httpBodyStream`, leaving
        /// `httpBody` nil. Drain it synchronously — requests here are < 1 KB.
        func bodyStreamData() -> Data? {
            guard let stream = httpBodyStream else { return nil }
            stream.open()
            defer { stream.close() }
            var data = Data()
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { buf.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buf, maxLength: 4096)
                if read <= 0 { break }
                data.append(buf, count: read)
            }
            return data.isEmpty ? nil : data
        }
    }

    // swiftlint:enable force_unwrapping
#endif
