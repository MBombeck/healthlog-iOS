// swiftlint:disable force_unwrapping
import CryptoKit
import Foundation
@testable import HealthLog
import Testing

/// The app side of sealed pushes and of the relay (#190, final names #191):
/// the push key on a sealing server, opt-in, binding, opt-out, sign-out, the
/// operator turning it off, the 422 codes, the gates, and the update path of
/// an installation on a server that does not seal.
@Suite("Push relay: store, binding and opt-out")
@MainActor
struct PushRelayStoreTests {
    let defaults: UserDefaults
    let group: UserDefaults
    let keychain = InMemoryKeychain()
    let transport = RecordingRelayTransport()
    let directory: URL
    let sender = Curve25519.KeyAgreement.PrivateKey()
    let apnsToken = Data(repeating: 0x0F, count: 32)
    let instanceId = "6f1c2a4e-1b9d-4c3e-8a7f-0d2b5e9c1a37"
    let now = Date(timeIntervalSince1970: 1_795_000_000)

    init() throws {
        defaults = try #require(UserDefaults(suiteName: "relay.tests.\(UUID().uuidString)"))
        group = try #require(UserDefaults(suiteName: "relay.tests.group.\(UUID().uuidString)"))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    var keyring: RelayKeyring {
        RelayKeyring(store: keychain)
    }

    var ledger: RelayOpenedLedger {
        RelayOpenedLedger(url: directory.appendingPathComponent("opened.json"))
    }

    /// The test clock; a test moves it forward.
    final class ClockBox: @unchecked Sendable {
        var now: Date
        init(_ now: Date) {
            self.now = now
        }
    }

    let clockBox = ClockBox(Date(timeIntervalSince1970: 1_795_000_000))

    func makeStore(transport: RelayTransport? = nil, reRegisterCount: Counter = Counter()) -> PushRelayStore {
        let box = clockBox
        let store = PushRelayStore(
            api: nil,
            keyring: keyring,
            client: RelayClient(
                transport: transport ?? self.transport,
                pinnedKeys: [self.transport.relayKey.publicKey],
                clock: { box.now }
            ),
            defaults: defaults,
            appGroupDefaults: group,
            ledger: ledger,
            replayStore: RelayMemoryReplayStore(),
            accountKey: { "acct" },
            clock: { box.now }
        )
        store.reRegister = { reRegisterCount.value += 1 }
        return store
    }

    @MainActor
    final class Counter {
        var value = 0
    }

    /// A server that seals with its own APNs key: no relay offer.
    func sealing(envelope: Int? = nil) -> RelayCapability {
        RelayCapability(
            senderKeys: [sender.publicKey.rawRepresentation],
            envelopeVersions: [1],
            device: .init(transport: .direct, envelope: envelope)
        )
    }

    func offered(
        consent: Bool = false,
        relayState: RelayCapability.DeviceRelayState = .none,
        envelope: Int? = nil
    ) -> RelayCapability {
        RelayCapability(
            available: true,
            offered: true,
            state: .ok,
            instanceId: instanceId,
            senderKeys: [sender.publicKey.rawRepresentation],
            envelopeVersions: [1],
            liveActivity: ["end"],
            privacyURL: URL(string: "https://push.healthlog.dev/privacy"),
            consentTextVersion: "2026-11-a",
            device: .init(transport: consent ? .relay : .none, envelope: envelope, consent: consent, relayState: relayState)
        )
    }

    /// One registration that the server answered 2xx: the body, and the
    /// acknowledgement that clears its one-time parts (R1 (4)).
    func fields(_ store: PushRelayStore) -> DeviceRegistrationPushFields {
        let body = store.registrationFields(apnsTokenHex: apnsToken.relayHex)
        store.registrationAccepted(body)
        return body
    }

    // MARK: Update path

    @Test("a server that does not seal: no key, no envelope mode, the 1.6 body")
    func updatePathUnchanged() async {
        let store = makeStore()
        await store.apply(.notOffered)
        #expect(!store.showsOptInCard)
        #expect(!store.showsSettings)
        #expect(keyring.state() == nil)
        #expect(!RelayEnvelopeMode.isOn(defaults: group))
        #expect(fields(store).isEmpty)
        #expect(await store.silentDecision(userInfo: ["aps": ["content-available": 1]]) == .notInEnvelopeMode)
        #expect(store.allowsTap(requestIdentifier: "x", isRemote: true))
    }

    @Test("a server that seals with its own APNs key: push key only, no relay, envelope mode after the server confirms")
    func sealingWithoutRelay() async throws {
        let counter = Counter()
        let store = makeStore(reRegisterCount: counter)
        await store.apply(sealing())
        #expect(counter.value == 1)
        #expect(!store.showsOptInCard)
        #expect(!RelayEnvelopeMode.isOn(defaults: group), "plaintext until the server has the key")
        let body = fields(store)
        guard case let .key(pushKey)? = body.pushKey else { Issue.record("no push key")
            return
        }
        #expect(pushKey.v == 1)
        #expect(pushKey.suites == [1])
        #expect(try Data(relayBase64URL: pushKey.publicKey) == #require(keyring.recipientKeys().first).publicKey.rawRepresentation)
        #expect(body.relayConsent == nil)
        #expect(body.relayBinding == nil)
        #expect(keyring.boundToken() == apnsToken)
        #expect(keyring.state()?.bindingKey == nil)
        await store.apply(sealing(envelope: 1))
        #expect(RelayEnvelopeMode.isOn(defaults: group))
        #expect(transport.requests.isEmpty)
    }

    @Test("the server stops sealing: pushKey null once, keys and envelope mode go")
    func sealingStops() async throws {
        let store = makeStore()
        await store.apply(sealing(envelope: 1))
        _ = fields(store)
        await store.apply(.notOffered)
        #expect(fields(store).pushKey == .withdrawn)
        let json = try Self.encoded(fields: DeviceRegistrationPushFields(pushKey: .withdrawn))
        #expect(json["pushKey"] is NSNull)
        #expect(fields(store).isEmpty)
        #expect(keyring.state() == nil)
        #expect(!RelayEnvelopeMode.isOn(defaults: group))
    }

    @Test("offered: the card shows; the push key goes, but no binding key and no consent until Turn on")
    func offeredWithoutConsent() async {
        let store = makeStore()
        await store.apply(offered())
        #expect(store.showsOptInCard)
        #expect(keyring.state()?.bindingKey == nil)
        let body = fields(store)
        #expect(body.relayConsent == nil)
        #expect(body.relayBinding == nil)
    }

    @Test("Not now hides the card for good and binds nothing")
    func notNow() async {
        let store = makeStore()
        await store.apply(offered())
        store.answerNotNow()
        #expect(!store.showsOptInCard)
        #expect(makeStore().cardAnswered)
        #expect(keyring.state()?.bindingKey == nil)
        #expect(store.showsSettings)
    }

    @Test("an offer that is not available (relay keys not pinned on the server) shows no card")
    func unavailableOfferHidden() async {
        var capability = offered()
        capability.available = false
        let store = makeStore()
        await store.apply(capability)
        #expect(!store.showsOptInCard)
        capability = offered()
        capability.envelopeVersions = [2]
        await store.apply(capability)
        #expect(!store.showsOptInCard)
    }

    @Test("the /api/auth/me shape of #191 parses, including push.device")
    func parsesFinalShape() throws {
        let me: [String: Any] = ["push": [
            "relay": [
                "available": true, "offered": true, "state": "degraded", "since": "2026-11-21T06:40:00.000Z",
                "instanceId": instanceId, "senderKeys": [[
                    "publicKey": sender.publicKey.rawRepresentation.relayBase64URL,
                    "status": "current"
                ]],
                "envelopeVersions": [1], "liveActivity": ["end"], "termsUrl": "https://push.healthlog.dev/terms",
                "privacyUrl": "https://push.healthlog.dev/privacy", "consentTextVersion": "2026-11-a"
            ],
            "device": [
                "transport": "relay", "envelope": 1, "consent": true, "relayState": "bound", "intakeSync": "ok",
                "senderKeys": [["publicKey": sender.publicKey.rawRepresentation.relayBase64URL, "status": "current"]],
                "relayInstanceId": instanceId
            ]
        ]]
        let capability = RelayCapability.parse(me: me)
        #expect(capability.isUsable)
        #expect(capability.sealsForThisDevice)
        #expect(capability.state == .degraded)
        #expect(capability.since != nil)
        #expect(capability.device?.transport == .relay)
        #expect(capability.trustedSenderKeys == [sender.publicKey.rawRepresentation])
        #expect(capability.isDegraded)
        let decoded = try JSONDecoder().decode(AuthMeRelay.self, from: JSONSerialization.data(withJSONObject: me))
        #expect(decoded.relay == capability)
    }

    // MARK: Binding

    @Test("Turn on: binding key, consent and a signed hl-bind-v1 in the body")
    func turnOnBinds() async throws {
        let counter = Counter()
        let store = makeStore(reRegisterCount: counter)
        await store.apply(offered())
        let before = counter.value
        await store.turnOn()
        #expect(store.isOn)
        #expect(counter.value == before + 1)
        let state = try #require(keyring.state())
        #expect(state.trustedSenders == [sender.publicKey.rawRepresentation])
        #expect(state.categories["MEDICATION_REMINDER"]?.hasPrefix("hl.") == true)

        let body = fields(store)
        #expect(body.relayConsent == RelayConsentRecord(granted: true, textVersion: "2026-11-a"))
        let binding = try #require(body.relayBinding)
        #expect(binding.statement.seq == 1)
        #expect(binding.statement.kind == "device")
        #expect(binding.statement.instanceId == instanceId)
        #expect(binding.statement.tokenTag == RelayEnvelope.tokenTag(of: apnsToken).relayHex)
        let text = RelayStatement.bind(
            host: HLPushRelayKeys.host,
            instanceId: instanceId,
            tokenTag: RelayEnvelope.tokenTag(of: apnsToken),
            seq: 1,
            iat: Int64(now.timeIntervalSince1970)
        )
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: #require(Data(relayBase64URL: binding.bindingKey)))
        let signature = try #require(Data(relayBase64URL: binding.signature))
        #expect(signature.count == 64)
        #expect(RelayStatement.verify(text, signature: signature, publicKey: key))
        let json = try Self.encoded(fields: body)
        #expect(Set(json.keys).isSuperset(of: ["pushKey", "relayConsent", "relayBinding"]))
    }

    @Test("a 422 invalid_push_key makes a new envelope key")
    func rejectedKeyRotates() async {
        let store = makeStore()
        await store.apply(sealing())
        guard case let .key(first)? = fields(store).pushKey else { Issue.record("no key")
            return
        }
        await store.registrationRejected(code: "devices.push.invalid_push_key")
        guard case let .key(second)? = fields(store).pushKey else { Issue.record("no key")
            return
        }
        #expect(first.publicKey != second.publicKey)
    }

    @Test("the Live Activity proof is a signed hl-activity-v1, and only with the relay on")
    func activityProof() async throws {
        let store = makeStore()
        let laToken = Data(repeating: 0x2E, count: 32)
        await store.apply(offered())
        #expect(store.activityProof(liveActivityTokenHex: laToken.relayHex) == nil)
        await store.turnOn()
        _ = fields(store)
        let proof = try #require(store.activityProof(liveActivityTokenHex: laToken.relayHex))
        let text = RelayStatement.activity(
            host: HLPushRelayKeys.host,
            instanceId: instanceId,
            tokenTag: RelayEnvelope.tokenTag(of: apnsToken),
            laTokenTag: RelayEnvelope.tokenTag(of: laToken),
            iat: Int64(now.timeIntervalSince1970)
        )
        let key = try #require(keyring.bindingKey()).publicKey
        #expect(try RelayStatement.verify(text, signature: #require(Data(relayBase64URL: proof.signature)), publicKey: key))
        #expect(transport.requests.isEmpty)
        let entry = LiveActivityTokenWire(token: laToken.relayHex, medicationId: "m1", slotInstant: now, relayProof: proof)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        #expect(Set(json.keys) == ["token", "medicationId", "slotInstant", "statement", "signature"])
        let plain = LiveActivityTokenWire(token: laToken.relayHex, medicationId: "m1", slotInstant: now)
        let plainJSON = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as? [String: Any])
        #expect(Set(plainJSON.keys) == ["token", "medicationId", "slotInstant"])
    }

    static func encoded(fields: DeviceRegistrationPushFields) throws -> [String: Any] {
        var body = DeviceRegistration(
            token: "d",
            bundleId: "b",
            locale: "de-DE",
            appVersion: "1.7",
            model: "m",
            apnsToken: "aa",
            apnsEnvironment: .sandbox
        )
        body.pushFields = fields
        return try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
    }
}

// MARK: - Opt-out and gates

extension PushRelayStoreTests {
    // MARK: Opt-out

    @Test("Turn off revokes at the relay directly, sends granted false once, and keeps the envelope key")
    func turnOff() async throws {
        let counter = Counter()
        let store = makeStore(reRegisterCount: counter)
        await store.apply(offered())
        await store.turnOn()
        _ = fields(store)
        let bindingKey = try #require(keyring.bindingKey()).publicKey
        let before = counter.value
        await store.turnOff(reason: .person)

        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.absoluteString == "https://push.healthlog.dev/v1/bindings/self")
        // §2: a fresh 22-character nonce, a declared length, nothing for servers.
        #expect(request.value(forHTTPHeaderField: "HL-Nonce")?.count == 22)
        #expect(request.value(forHTTPHeaderField: "Content-Length") == request.httpBody.map { String($0.count) })
        #expect((request.httpBody?.count ?? 0) <= 4096)
        #expect(request.value(forHTTPHeaderField: "HL-Instance") == nil)
        #expect(request.value(forHTTPHeaderField: "HL-Timestamp") == nil)
        let httpBody = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: httpBody) as? [String: Any])
        #expect(body["token"] as? String == apnsToken.relayHex)
        let statement = try #require(body["statement"] as? [String: Any])
        let iat = try #require((statement["iat"] as? NSNumber)?.int64Value)
        let text = RelayStatement.unbind(
            host: HLPushRelayKeys.host,
            instanceId: instanceId,
            tokenTag: RelayEnvelope.tokenTag(of: apnsToken),
            iat: iat
        )
        let signatureText = try #require(body["signature"] as? String)
        let signature = try #require(Data(relayBase64URL: signatureText))
        #expect(RelayStatement.verify(text, signature: signature, publicKey: bindingKey))
        #expect(store.lastRevokeConfirmed == true)

        #expect(!store.isOn)
        #expect(counter.value == before + 1)
        let withdrawal = fields(store)
        #expect(withdrawal.relayConsent == RelayConsentRecord(granted: false, textVersion: "2026-11-a"))
        #expect(withdrawal.relayBinding == nil)
        if case .key? = withdrawal.pushKey {} else { Issue.record("the envelope key stays") }
        #expect(fields(store).relayConsent == nil)
        #expect(keyring.state()?.binding == nil)
        #expect(!keyring.recipientKeys().isEmpty)
    }

    @Test("the opt-out works while the relay and the server are down")
    func turnOffOffline() async {
        let store = makeStore(transport: FailingRelayTransport())
        await store.apply(offered())
        await store.turnOn()
        _ = fields(store)
        await store.stopPushesFromThisServer()
        #expect(store.lastRevokeConfirmed == false)
        #expect(!store.isOn)
        #expect(keyring.state()?.binding == nil)
    }

    @Test("sign-out revokes directly, deletes every key and leaves envelope mode")
    func signOut() async {
        let counter = Counter()
        let store = makeStore(reRegisterCount: counter)
        await store.apply(offered(envelope: 1))
        await store.turnOn()
        _ = fields(store)
        let before = counter.value
        await store.handleSignOut()
        #expect(transport.requests.count == 1)
        #expect(counter.value == before)
        #expect(keyring.state() == nil)
        #expect(!RelayEnvelopeMode.isOn(defaults: group))
        #expect(fields(store).isEmpty)
    }

    @Test("sign-out without the relay still deletes the envelope key")
    func signOutSealingOnly() async {
        let store = makeStore()
        await store.apply(sealing(envelope: 1))
        await store.handleSignOut()
        #expect(transport.requests.isEmpty)
        #expect(keyring.state() == nil)
        #expect(!RelayEnvelopeMode.isOn(defaults: group))
    }

    @Test("sign-out leaves no in-memory state of the account for the next one")
    func signOutDropsAccountState() async {
        let store = makeStore()
        await store.apply(offered(envelope: 1))
        store.answerNotNow()
        store.unverifiedTapNotice = true
        store.lastDataChange = RelayDataChange(domains: ["medications"])
        await store.handleSignOut()
        #expect(!store.isOn)
        #expect(!store.cardAnswered)
        #expect(!store.unverifiedTapNotice)
        #expect(!store.operatorTurnedOff)
        #expect(!store.needsReconnect)
        #expect(store.lastDataChange == nil)
        #expect(store.capability == .notOffered)
        // The answer stays on disk, keyed by that account, for its next sign-in.
        #expect(defaults.bool(forKey: store.key("answered")))
    }

    @Test("the operator turning the relay off unregisters by itself and leaves a quiet line")
    func operatorOff() async {
        let store = makeStore()
        await store.apply(offered())
        await store.turnOn()
        _ = fields(store)
        var off = offered(consent: true, relayState: .bound, envelope: 1)
        off.offered = false
        await store.apply(off)
        #expect(!store.isOn)
        #expect(store.operatorTurnedOff)
        #expect(store.showsSettings)
        #expect(transport.requests.first?.httpMethod == "DELETE")
        #expect(fields(store).relayConsent?.granted == false)
    }

    // MARK: Gates

    @Test("silent push: no envelope, no sync; a valid one opens once")
    func silentGate() async throws {
        let store = makeStore()
        await store.apply(sealing(envelope: 1))
        _ = fields(store)
        #expect(await store.silentDecision(userInfo: ["aps": ["content-available": 1], "eventType": "MEDICATION_INTAKE_SYNC"]) == .refused)

        let iat = Int(now.timeIntervalSince1970)
        let json: [String: Any] = [
            "v": 1, "t": "MEDICATION_INTAKE_SYNC", "id": RelayTestSealer.ulid(1), "iat": iat, "exp": iat + 3600,
            "d": ["syncedAt": "2026-11-21T07:12:00.000Z"]
        ]
        let recipient = try #require(keyring.recipientKeys().first).publicKey
        let envelope = try RelayTestSealer.seal(json, to: recipient, from: sender, apnsToken: apnsToken, pushClass: .silent)
        let userInfo: [AnyHashable: Any] = ["aps": ["content-available": 1], "e": envelope.relayBase64URL]
        #expect(await store.silentDecision(userInfo: userInfo) == .opened("MEDICATION_INTAKE_SYNC"))
        #expect(await store.silentDecision(userInfo: userInfo) == .refused)
        #expect(ledger.receipts()[.silent] == [RelayTestSealer.ulid(1)])
        let query = RelayReceiptQuery.items(ledger: ledger, envelopeMode: true)
        #expect(query.map(\.0) == ["openedSilent"])
        #expect(query.first?.1 == RelayTestSealer.ulid(1))
        #expect(RelayReceiptQuery.items(ledger: ledger, envelopeMode: false).isEmpty)

        let alertEnvelope = try RelayTestSealer.seal(json, to: recipient, from: sender, apnsToken: apnsToken, pushClass: .alert)
        #expect(await store.silentDecision(userInfo: ["e": alertEnvelope.relayBase64URL]) == .refused)
    }

    @Test("tap: a remote notification acts only when the extension opened it; local ones always")
    func tapGate() async {
        let store = makeStore()
        let openedHome = Counter()
        store.openHome = { openedHome.value += 1 }
        await store.apply(sealing(envelope: 1))
        #expect(store.allowsTap(requestIdentifier: "local", isRemote: false))
        #expect(!store.allowsTap(requestIdentifier: "remote-1", isRemote: true))
        #expect(store.unverifiedTapNotice)
        #expect(openedHome.value == 1)
        ledger.record(.init(
            requestId: "remote-2",
            envelopeId: RelayTestSealer.ulid(2),
            type: "MEDICATION_REMINDER",
            pushClass: .alert,
            target: nil,
            openedAt: now
        ))
        // D1 (2): the request id alone is not enough; the envelope id must match.
        #expect(!store.allowsTap(requestIdentifier: "remote-2", isRemote: true))
        #expect(!store.allowsTap(
            requestIdentifier: "remote-2",
            isRemote: true,
            userInfo: [RelayNotificationRebuilder.verifiedKey: RelayTestSealer.ulid(3)]
        ))
        #expect(store.allowsTap(
            requestIdentifier: "remote-2",
            isRemote: true,
            userInfo: [RelayNotificationRebuilder.verifiedKey: RelayTestSealer.ulid(2)]
        ))
    }

    @Test("the degraded line: offered, bound, and the relay or the intake sync not well")
    func degraded() async {
        let store = makeStore()
        var capability = offered(consent: true, relayState: .bound, envelope: 1)
        await store.apply(capability)
        #expect(!store.showsDegradedLine)
        capability.device?.intakeSync = .degraded
        await store.apply(capability)
        #expect(store.showsDegradedLine)
        capability.device?.intakeSync = .ok
        capability.state = .down
        await store.apply(capability)
        #expect(store.showsDegradedLine)
        capability.device?.relayState = .rebindNeeded
        await store.apply(capability)
        #expect(!store.showsDegradedLine, "only a bound device shows it")
    }
}

// MARK: - Round 2: rebinding, other relay, Live Activity consent, challenge

extension PushRelayStoreTests {
    @Test("§4: the binding is signed only on the person's turn-on or reconnect, never on rebind_needed or a new token")
    func rebindingOnlyOnRequest() async throws {
        let store = makeStore()
        await store.apply(offered())
        await store.turnOn()
        let first = try #require(fields(store).relayBinding)
        await store.apply(offered(consent: true, relayState: .bound, envelope: 1))
        #expect(fields(store).relayBinding == nil)
        await store.apply(offered(consent: true, relayState: .rebindNeeded, envelope: 1))
        #expect(store.needsReconnect)
        #expect(fields(store).relayBinding == nil, "never signed on its own")
        let newToken = Data(repeating: 0x11, count: 32)
        let moved = store.registrationFields(apnsTokenHex: newToken.relayHex)
        store.registrationAccepted(moved)
        #expect(moved.relayBinding == nil)
        clockBox.now = clockBox.now.addingTimeInterval(60)
        await store.reconnect()
        let second = try #require(fields(store).relayBinding)
        #expect(second.statement.seq == first.statement.seq + 1)
        #expect(second.statement.iat > first.statement.iat)
        #expect(second.bindingKey == first.bindingKey)
        #expect(!store.needsReconnect)
    }

    @Test("§4: after Stop pushes, turning on again uses the same binding key, a higher seq and a later iat")
    func returnAfterSelfRevoke() async throws {
        let store = makeStore()
        await store.apply(offered())
        await store.turnOn()
        let first = try #require(fields(store).relayBinding)
        await store.apply(offered(consent: true, relayState: .bound, envelope: 1))
        await store.stopPushesFromThisServer()
        #expect(!store.isOn)
        _ = fields(store)
        await store.apply(offered(consent: false, relayState: .rebindNeeded, envelope: 1))
        #expect(fields(store).relayBinding == nil, "off after the opt-out, whatever the server says")
        clockBox.now = clockBox.now.addingTimeInterval(120)
        await store.turnOn()
        let back = try #require(fields(store).relayBinding)
        #expect(back.bindingKey == first.bindingKey)
        #expect(back.statement.seq > first.statement.seq)
        #expect(back.statement.iat > first.statement.iat)
    }

    @Test("§4: relayState none right after turn-on shows the relay as unavailable and turns it off")
    func blockedAfterTurnOn() async {
        let store = makeStore()
        await store.apply(offered())
        await store.turnOn()
        _ = fields(store)
        await store.apply(offered(consent: true, relayState: .none, envelope: 1))
        #expect(store.unavailable == .blocked)
        #expect(!store.isOn)
        #expect(store.showsSettings)
    }

    @Test("§9: another relay host means not offered; bad_signature right after turn-on means the same, no retry")
    func otherRelay() async {
        var capability = offered()
        capability.host = "relay.example.org"
        let store = makeStore()
        await store.apply(capability)
        #expect(!store.showsOptInCard)
        #expect(store.unavailable == .otherRelay)
        let other = makeStore()
        await other.apply(offered())
        await other.turnOn()
        _ = fields(other)
        await other.registrationRejected(code: "devices.push.bad_signature")
        #expect(!other.isOn)
        #expect(other.unavailable == .otherRelay)
    }

    @Test("a 422 relay_device_limit turns the relay off with a line")
    func deviceLimit() async {
        let store = makeStore()
        await store.apply(offered())
        await store.turnOn()
        _ = fields(store)
        await store.apply(offered(consent: true, relayState: .bound, envelope: 1))
        await store.registrationRejected(code: "devices.push.relay_device_limit")
        #expect(!store.isOn)
        #expect(store.deviceLimitReached)
        #expect(store.showsSettings)
    }

    @Test("§6: the plaintext challenge is answered only with the relay on and relayState conflict; never a sync")
    func challenge() async throws {
        let store = makeStore()
        let challenge = Data(repeating: 0x63, count: 32).relayBase64URL
        let push: [AnyHashable: Any] = ["aps": ["content-available": 1], "c": challenge]
        #expect(await store.silentDecision(userInfo: push) == .handled)
        #expect(!store.shouldAnswerChallenge(challenge))
        await store.apply(offered())
        await store.turnOn()
        _ = fields(store)
        await store.apply(offered(consent: true, relayState: .bound, envelope: 1))
        #expect(!store.shouldAnswerChallenge(challenge), "only in conflict")
        await store.apply(offered(consent: true, relayState: .conflict, envelope: 1))
        #expect(store.shouldAnswerChallenge(challenge))
        #expect(!store.shouldAnswerChallenge("short"))
        #expect(await store.silentDecision(userInfo: push) == .handled)
        await store.answerChallenge(challenge)
        let request = try #require(transport.requests.last { $0.url?.path == "/v1/bindings/challenge" })
        #expect(request.httpMethod == "POST")
        let httpBody = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: httpBody) as? [String: Any])
        #expect(body["challenge"] as? String == challenge)
        let text = RelayStatement.challenge(
            host: HLPushRelayKeys.host,
            challenge: challenge,
            tokenTag: RelayEnvelope.tokenTag(of: apnsToken)
        )
        let key = try #require(keyring.bindingKey()).publicKey
        let signatureText = try #require(body["signature"] as? String)
        let signature = try #require(Data(relayBase64URL: signatureText))
        #expect(RelayStatement.verify(text, signature: signature, publicKey: key))
    }
}
