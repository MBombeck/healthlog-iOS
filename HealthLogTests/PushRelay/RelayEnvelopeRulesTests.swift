import CryptoKit
import Foundation
@testable import HealthLog
import Testing
import UserNotifications

/// The rules around the envelope that the golden vectors do not reach: the
/// replay store, at most two keys of each kind, the rebuilt notification, and
/// the one mapping into the existing intake handler.
@Suite("Push relay: replay, rebuild and intake mapping")
struct RelayEnvelopeRulesTests {
    let token = Data(repeating: 0x0F, count: 32)
    let sender = Curve25519.KeyAgreement.PrivateKey()
    let device = Curve25519.KeyAgreement.PrivateKey()
    let now: Int64 = 1_795_000_000

    func json(id: Int, type: String = "MEDICATION_REMINDER", lifetime: Int64 = 600, extra: [String: Any] = [:]) -> [String: Any] {
        var json: [String: Any] = ["v": 1, "t": type, "id": RelayTestSealer.ulid(id), "iat": now, "exp": now + lifetime]
        json.merge(extra) { $1 }
        return json
    }

    func open(_ envelope: Data, store: RelayReplayStoring? = nil, at time: Int64? = nil) throws(RelayEnvelopeError) -> RelayPlaintext {
        try RelayEnvelope.open(
            envelope,
            recipientKeys: [device],
            trustedSenders: [sender.publicKey],
            apnsToken: token,
            expectedClass: .alert,
            now: time ?? now,
            replayStore: store
        )
    }

    @Test("the same envelope opens once")
    func replayed() throws {
        let store = RelayMemoryReplayStore()
        let envelope = try RelayTestSealer.seal(json(id: 1), to: device.publicKey, from: sender, apnsToken: token, pushClass: .alert)
        _ = try open(envelope, store: store)
        #expect(throws: RelayEnvelopeError.replayed) { try open(envelope, store: store) }
    }

    @Test("a full store refuses instead of forgetting; expired ids make room")
    func replayStoreFull() throws {
        var entries: [RelayReplayRule.Entry] = []
        for index in 0 ..< RelayReplayRule.capacity {
            entries = try RelayReplayRule.record(id: "id\(index)", expiresAt: now + 600, now: now, in: entries)
        }
        #expect(throws: RelayEnvelopeError.replayStoreFull) {
            try RelayReplayRule.record(id: "one-more", expiresAt: now + 600, now: now, in: entries)
        }
        let later = now + 600 + RelayEnvelope.clockSkew + 1
        let pruned = try RelayReplayRule.record(id: "one-more", expiresAt: later + 600, now: later, in: entries)
        #expect(pruned.count == 1)
        #expect(RelayReplayRule.capacity == 512)
    }

    @Test("the App Group file store keeps ids across instances")
    func fileStore() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("replay-\(UUID().uuidString).json")
        defer { RelayAppGroupFile.remove(url) }
        try RelayFileReplayStore(url: url).checkAndRecord(id: "a", expiresAt: now + 60, now: now)
        #expect(throws: RelayEnvelopeError.replayed) {
            try RelayFileReplayStore(url: url).checkAndRecord(id: "a", expiresAt: now + 60, now: now)
        }
    }

    @Test("at most two device keys and two senders are tried")
    func atMostTwoKeys() throws {
        let envelope = try RelayTestSealer.seal(json(id: 2), to: device.publicKey, from: sender, apnsToken: token, pushClass: .alert)
        let others = (0 ..< 2).map { _ in Curve25519.KeyAgreement.PrivateKey() }
        #expect(throws: RelayEnvelopeError.authFailure) {
            try RelayEnvelope.open(
                envelope,
                recipientKeys: others + [device],
                trustedSenders: [sender.publicKey],
                apnsToken: token,
                expectedClass: .alert,
                now: now
            )
        }
        _ = try RelayEnvelope.open(
            envelope,
            recipientKeys: [others[0], device],
            trustedSenders: [sender.publicKey],
            apnsToken: token,
            expectedClass: .alert,
            now: now
        )
    }

    @Test("a fresh CryptoKit seal opens, with the AAD bound to the token")
    func tokenBinding() throws {
        let envelope = try RelayTestSealer.seal(json(id: 3), to: device.publicKey, from: sender, apnsToken: token, pushClass: .alert)
        #expect(envelope.count == RelayPushClass.alert.envelopeLength)
        #expect(try open(envelope).type == "MEDICATION_REMINDER")
        #expect(throws: RelayEnvelopeError.authFailure) {
            try RelayEnvelope.open(
                envelope,
                recipientKeys: [device],
                trustedSenders: [sender.publicKey],
                apnsToken: Data(repeating: 1, count: 32),
                expectedClass: .alert,
                now: now
            )
        }
    }

    @Test("clock skew: five minutes either side, not more")
    func clockSkew() throws {
        let envelope = try RelayTestSealer.seal(
            json(id: 4, lifetime: 600),
            to: device.publicKey,
            from: sender,
            apnsToken: token,
            pushClass: .alert
        )
        _ = try open(envelope, at: now - 300)
        _ = try open(envelope, at: now + 600 + 300)
        #expect(throws: RelayEnvelopeError.notYetValid) { try open(envelope, at: now - 301) }
        #expect(throws: RelayEnvelopeError.expired) { try open(envelope, at: now + 600 + 301) }
    }

    @Test("a boolean or fractional time is malformed")
    func strictSchema() throws {
        var bad = json(id: 5)
        bad["iat"] = true
        let boolean = try RelayTestSealer.seal(bad, to: device.publicKey, from: sender, apnsToken: token, pushClass: .alert)
        #expect(throws: RelayEnvelopeError.malformed) { try open(boolean) }
        bad["iat"] = Double(now) + 0.5
        let fractional = try RelayTestSealer.seal(bad, to: device.publicKey, from: sender, apnsToken: token, pushClass: .alert)
        #expect(throws: RelayEnvelopeError.malformed) { try open(fractional) }
    }

    // MARK: Rebuild

    @Test("the rebuilt userInfo holds only plaintext fields, never a URL or deep link")
    func rebuiltUserInfo() throws {
        let extra: [String: Any] = [
            "d": [
                "medicationId": "cm_med_1",
                "scheduledAt": "2026-11-21T07:00:00Z",
                "deepLink": "https://evil.example",
                "url": "https://evil.example"
            ],
            "n": ["title": "Lisinopril", "body": "Due at 08:00"],
            "ui": ["category": "MEDICATION_REMINDER", "thread": "med-1", "level": "time-sensitive"]
        ]
        let envelope = try RelayTestSealer.seal(
            json(id: 6, extra: extra),
            to: device.publicKey,
            from: sender,
            apnsToken: token,
            pushClass: .alert
        )
        let plaintext = try open(envelope)
        let info = RelayNotificationRebuilder.userInfo(from: plaintext)
        #expect(info["deepLink"] == nil)
        #expect(info["url"] == nil)
        #expect(info["medicationId"] as? String == "cm_med_1")
        #expect(info["eventType"] as? String == "MEDICATION_REMINDER")
        #expect(info[RelayNotificationRebuilder.verifiedKey] as? String == RelayTestSealer.ulid(6))
        #expect(RelayNotificationRebuilder.target(of: plaintext) == "medication:cm_med_1")

        let content = RelayNotificationRebuilder.content(
            for: plaintext,
            placeholderTitle: "P",
            placeholderBody: "B",
            secretCategory: { $0 == "MEDICATION_REMINDER" ? "hl.secret" : nil }
        )
        #expect(content.title == "Lisinopril")
        #expect(content.categoryIdentifier == "hl.secret")
        #expect(content.threadIdentifier == "med-1")
        #expect(content.interruptionLevel == .timeSensitive)
    }

    @Test("the placeholder carries no category, thread, userInfo or Time Sensitive")
    func placeholder() {
        let content = RelayNotificationRebuilder.placeholder(title: "HealthLog", body: "Open")
        #expect(content.categoryIdentifier.isEmpty)
        #expect(content.threadIdentifier.isEmpty)
        #expect(content.userInfo.isEmpty)
        #expect(content.interruptionLevel == .passive)
    }

    @Test("a push without e, or with a plaintext e, does not open")
    func noEnvelope() {
        let keyring = RelayKeyring(store: InMemoryKeychain())
        let result = RelayNotificationRebuilder.open(
            userInfo: ["aps": ["alert": ["title": "Phish"], "category": "MEDICATION_REMINDER"], "deepLink": "healthlog://x"],
            pushClass: .alert,
            keyring: keyring,
            replayStore: RelayMemoryReplayStore()
        )
        #expect(result == .failure(.malformed))
        let locked = RelayNotificationRebuilder.open(
            userInfo: ["e": Data(count: 1075).relayBase64URL],
            pushClass: .alert,
            keyring: keyring,
            replayStore: RelayMemoryReplayStore()
        )
        #expect(locked == .failure(.authFailure))
    }

    // MARK: Intake bridge

    @Test("the golden MEDICATION_INTAKE_RECORDED plaintext reaches the existing handler's parser")
    func intakeBridge() throws {
        let vector = try #require(RelayGoldenVectorTests.vectors.envelopes.first { $0.name == "alert" })
        let json = try #require(vector.plaintext?.propertyListValue as? [String: Any])
        let envelope = try RelayTestSealer.seal(json, to: device.publicKey, from: sender, apnsToken: token, pushClass: .alert)
        let plaintext = try RelayEnvelope.open(
            envelope,
            recipientKeys: [device],
            trustedSenders: [sender.publicKey],
            apnsToken: token,
            expectedClass: .alert,
            now: RelayGoldenVectorTests.vectors.constants.now
        )
        let info = try #require(RelayIntakeBridge.payload(from: plaintext))
        let dose = try #require(MedicationIntakeRecordedPush.parse(userInfo: info))
        #expect(dose.medicationId == "cm_test_med_1")
        #expect(dose.slotAt == ISO8601DateFormatter().date(from: "2026-11-21T07:00:00Z"))
        #expect(dose.wasTaken)
        #expect(dose.takenAt == ISO8601DateFormatter().date(from: "2026-11-21T07:12:00Z"))
        #expect(dose.source == "IOS")
        #expect(dose.intakeId == "cm_test_intake_1")
    }

    @Test("the #191 payload names (slotInstant, takenVia) map as well")
    func intakeBridgeFinalNames() throws {
        let extra: [String: Any] = ["d": [
            "medicationId": "m1", "intakeId": "i1", "slotInstant": "2026-11-21T07:00:00.000Z",
            "outcome": "taken", "takenAt": "2026-11-21T07:12:00.000Z", "takenVia": "INTEGRATION"
        ]]
        let envelope = try RelayTestSealer.seal(
            json(id: 7, type: "MEDICATION_INTAKE_RECORDED", extra: extra),
            to: device.publicKey,
            from: sender,
            apnsToken: token,
            pushClass: .alert
        )
        let info = try #require(RelayIntakeBridge.payload(from: open(envelope)))
        let dose = try #require(MedicationIntakeRecordedPush.parse(userInfo: info))
        #expect(dose.medicationId == "m1")
        #expect(dose.source == "INTEGRATION")
        #expect(info["outcome"] as? String == "taken")
    }

    @Test("another template never reaches the intake handler")
    func intakeBridgeOnlyForItsTemplate() throws {
        let envelope = try RelayTestSealer.seal(
            json(id: 8, extra: ["d": ["medicationId": "m1"]]),
            to: device.publicKey,
            from: sender,
            apnsToken: token,
            pushClass: .alert
        )
        #expect(try RelayIntakeBridge.payload(from: open(envelope)) == nil)
    }
}
