// swiftlint:disable force_unwrapping
import CryptoKit
import Foundation
import Testing
#if canImport(UserNotifications) && canImport(UIKit)
    @testable import HealthLog

    /// #190 (20:09): `liveActivityStarted` straight from the `POST
    /// /api/devices` answer, and a dose recorded elsewhere reaching a relay
    /// device as a sealed silent sync that clears its reminders and its Live
    /// Activity, with the intake confirmation off.
    @Suite("Push relay: registration answer and the silent intake sync", .serialized, .mockURLSession)
    @MainActor
    struct PushRelayRoundThreeTests {
        private static let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "1.7.0",
            buildNumber: "1"
        )

        private actor Steps {
            private(set) var names: [String] = []
            func add(_ name: String) {
                names.append(name)
            }
        }

        @MainActor
        final class StartedBox {
            var dose: RelayCapability.Device.StartedDose?
            var calls = 0
        }

        private func makeService(backgroundSync: BackgroundSyncCoordinator? = nil) throws -> NotificationService {
            let keychain = InMemoryKeychain()
            try keychain.setString("token", forKey: KeychainKey.authToken)
            let api = APIClient(environment: Self.env, keychain: keychain, sessionConfiguration: .mock())
            let owner = InMemoryKeychain()
            try owner.setString("usr_a", forKey: KeychainKey.userID)
            return try NotificationService(
                api: api,
                environment: Self.env,
                keychain: owner,
                deepLinks: DeepLinkRouter(router: AppRouter(), isAuthenticated: { true }),
                backgroundSync: backgroundSync,
                defaults: #require(UserDefaults(suiteName: "test.relay3.\(UUID().uuidString)"))
            )
        }

        @Test("the answer's push block is push.device; liveActivityStarted is read at once")
        func registrationAnswer() async throws {
            let answer = #"{"data":{"id":"dev_1","push":{"transport":"relay","envelope":1,"consent":true,"relayState":"bound","#
                + #""intakeSync":"ok","senderKeys":[],"relayInstanceId":"6f1c2a4e-1b9d-4c3e-8a7f-0d2b5e9c1a37","#
                + #""liveActivityStarted":{"medicationId":"m1","slotInstant":"2026-11-21T07:00:00.000Z"}}}}"#
            MockURLProtocol.install { req in
                (
                    HTTPURLResponse(
                        url: req.url!,
                        statusCode: 200,
                        httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    Data(answer.utf8)
                )
            }
            let service = try makeService()
            let box = StartedBox()
            service.relayRegistrationAnswer = { device in
                box.calls += 1
                box.dose = device?.liveActivityStarted
            }
            await service.didRegister(deviceToken: Data(repeating: 0x05, count: 32))
            #expect(box.calls == 1)
            #expect(box.dose?.medicationId == "m1")
            #expect(box.dose?.slotInstant == ISO8601DateFormatter().date(from: "2026-11-21T07:00:00Z"))
        }

        @Test("a bodiless answer still counts as a registration")
        func bodilessAnswer() async throws {
            nonisolated(unsafe) var posts = 0
            MockURLProtocol.install { req in
                if req.targets("/api/devices") { posts += 1 }
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!, Data())
            }
            let service = try makeService()
            await service.didRegister(deviceToken: Data(repeating: 0x06, count: 32))
            #expect(posts == 1)
            #expect(service.lastRegistrationSnapshot?.lastRegistrationServerStatus == 200)
        }

        @Test("the store takes the started dose from the answer")
        func storeTakesAnswer() throws {
            let store = try PushRelayStore(
                api: nil,
                keyring: RelayKeyring(store: InMemoryKeychain()),
                defaults: #require(UserDefaults(suiteName: "test.relay3.store.\(UUID().uuidString)")),
                appGroupDefaults: UserDefaults(suiteName: "test.relay3.group.\(UUID().uuidString)"),
                ledger: RelayOpenedLedger(url: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")),
                replayStore: RelayMemoryReplayStore(),
                accountKey: { "acct" }
            )
            let box = StartedBox()
            store.onLiveActivityStarted = { box.dose = $0 }
            store.noteRegistrationAnswer(RelayCapability.Device(
                relayState: .bound,
                liveActivityStarted: .init(medicationId: "m2", slotInstant: nil)
            ))
            #expect(box.dose?.medicationId == "m2")
            #expect(store.capability.device?.liveActivityStarted?.medicationId == "m2")
            store.noteRegistrationAnswer(RelayCapability.Device(relayState: .bound))
            #expect(box.dose == nil, "null once the slot is resolved")
        }

        @Test("a sealed MEDICATION_INTAKE_SYNC on a relay device reconciles the medications, then ends the Live Activity")
        func sealedIntakeSyncClears() async throws {
            MockURLProtocol.install { req in
                (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!, Data())
            }
            let coordinator = BackgroundSyncCoordinator(healthKit: nil)
            let steps = Steps()
            coordinator.attachMedicationReconcileHook { await steps.add("meds") }
            coordinator.attachLiveActivityReconcileHook { await steps.add("liveActivity") }
            let service = try makeService(backgroundSync: coordinator)

            // A relay device: the server seals for it and the store opens the envelope.
            let keychain = InMemoryKeychain()
            let group = try #require(UserDefaults(suiteName: "test.relay3.group.\(UUID().uuidString)"))
            let store = try PushRelayStore(
                api: nil,
                keyring: RelayKeyring(store: keychain),
                defaults: #require(UserDefaults(suiteName: "test.relay3.store.\(UUID().uuidString)")),
                appGroupDefaults: group,
                ledger: RelayOpenedLedger(url: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")),
                replayStore: RelayMemoryReplayStore(),
                accountKey: { "acct" }
            )
            let sender = Curve25519.KeyAgreement.PrivateKey()
            let token = Data(repeating: 0x0F, count: 32)
            await store.apply(RelayCapability(
                senderKeys: [sender.publicKey.rawRepresentation],
                envelopeVersions: [1],
                device: .init(transport: .relay, envelope: 1, consent: true, relayState: .bound)
            ))
            _ = store.registrationFields(apnsTokenHex: token.relayHex)
            service.relaySilentGate = { await store.silentDecision(userInfo: $0) }

            let iat = Int(Date().timeIntervalSince1970)
            let json: [String: Any] = [
                "v": 1, "t": "MEDICATION_INTAKE_SYNC", "id": RelayTestSealer.ulid(77), "iat": iat, "exp": iat + 3600,
                "d": ["syncedAt": "2026-11-21T07:12:00.000Z"]
            ]
            let recipient = try #require(RelayKeyring(store: keychain).recipientKeys().first).publicKey
            let envelope = try RelayTestSealer.seal(json, to: recipient, from: sender, apnsToken: token, pushClass: .silent)
            let result = await service.didReceiveSilentNotification(userInfo: RemoteNotificationUserInfo([
                "aps": ["content-available": 1], "e": envelope.relayBase64URL
            ]))
            #expect(result == .newData)
            let names = await steps.names
            #expect(names.prefix(2) == ["meds", "liveActivity"])

            // The same push in plaintext does nothing on a relay device.
            let before = await steps.names.count
            _ = await service.didReceiveSilentNotification(userInfo: RemoteNotificationUserInfo([
                "aps": ["content-available": 1], "eventType": "MEDICATION_INTAKE_SYNC"
            ]))
            #expect(await steps.names.count == before)
        }

        @Test("R1 (11): a DATA_CHANGED wake extends the local reminders like every other silent push")
        func dataChangedTopsUp() async throws {
            let coordinator = BackgroundSyncCoordinator(healthKit: nil)
            let steps = Steps()
            coordinator.attachReminderTopUpHook { await steps.add("topUp") }
            let service = try makeService(backgroundSync: coordinator)
            service.relayDataChanged = { true }
            let result = await service.didReceiveSilentNotification(userInfo: RemoteNotificationUserInfo([
                "aps": ["content-available": 1], "eventType": "DATA_CHANGED"
            ]))
            #expect(result == .newData)
            #expect(await steps.names == ["topUp"])
        }

        @Test("R1 (4): only a 2xx acknowledges the relay fields; a failed post reports a failure")
        func registrationAcknowledgement() async throws {
            MockURLProtocol.install { req in
                (HTTPURLResponse(url: req.url!, statusCode: 422, httpVersion: "HTTP/1.1", headerFields: nil)!, Data())
            }
            let service = try makeService()
            let box = StartedBox()
            service.relayRegistrationAccepted = { _ in box.calls += 1 }
            service.relayRegistrationFailed = { box.calls += 100 }
            service.relayRegistrationProvider = { _ in
                DeviceRegistrationPushFields(relayConsent: RelayConsentRecord(granted: false, textVersion: "v1"))
            }
            await service.didRegister(deviceToken: Data(repeating: 0x07, count: 32))
            #expect(box.calls == 100, "a 422 acknowledges nothing")
            MockURLProtocol.install { req in
                (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!, Data())
            }
            await service.didRegister(deviceToken: Data(repeating: 0x07, count: 32))
            #expect(box.calls == 101)
        }
    }
#endif
