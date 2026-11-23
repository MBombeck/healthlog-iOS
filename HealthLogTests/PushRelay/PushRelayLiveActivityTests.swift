// swiftlint:disable force_unwrapping
import CryptoKit
import Foundation
@testable import HealthLog
import Testing

/// #190 (17:58 to 18:29): Live Activity start and update over the relay. A
/// separate consent signed by the device, the push-to-start token, the
/// Activities the relay started, the direct withdrawal, and the content state
/// with unix seconds.
extension PushRelayStoreTests {
    func liveActivityOffered() -> RelayCapability {
        var capability = offered(consent: true, relayState: .bound, envelope: 1)
        capability.liveActivity = ["end", "start", "update"]
        capability.liveActivityConsentTextVersion = "2026-11-21"
        return capability
    }

    func turnedOnStore(feature: Bool = true) async -> PushRelayStore {
        let store = makeStore()
        store.liveActivityFeature = { feature }
        await store.apply(offered())
        await store.turnOn()
        _ = fields(store)
        await store.apply(liveActivityOffered())
        return store
    }

    var tokenTag: Data {
        RelayEnvelope.tokenTag(of: apnsToken)
    }

    @Test("the switch opens only with the features key and start offered; locked otherwise")
    func liveActivityGate() async {
        let locked = await turnedOnStore(feature: false)
        #expect(!locked.liveActivityUpdatesOffered)
        await locked.setLiveActivityUpdates(true)
        #expect(!locked.liveActivityUpdatesOn)
        #expect(fields(locked).liveActivityConsent == nil)
        let store = await turnedOnStore()
        #expect(store.liveActivityUpdatesAvailable)
        var endOnly = liveActivityOffered()
        endOnly.liveActivity = ["end"]
        await store.apply(endOnly)
        #expect(!store.liveActivityUpdatesAvailable)
    }

    @Test("turning it on sends hl-la-consent-v1 once, signed with the binding key")
    func liveActivityConsentSigned() async throws {
        let store = await turnedOnStore()
        await store.setLiveActivityUpdates(true)
        #expect(store.liveActivityUpdatesOn)
        let consent = try #require(fields(store).liveActivityConsent)
        #expect(consent.textVersion == "2026-11-21")
        let text = RelayStatement.liveActivityConsent(
            host: HLPushRelayKeys.host,
            instanceId: instanceId,
            tokenTag: tokenTag,
            textVersion: "2026-11-21",
            iat: consent.iat
        )
        let key = try #require(keyring.bindingKey()).publicKey
        let signature = try #require(Data(relayBase64URL: consent.signature))
        #expect(RelayStatement.verify(text, signature: signature, publicKey: key))
        #expect(fields(store).liveActivityConsent == nil, "once")
        // Not yet accepted by the relay: sent again on the next reading.
        await store.apply(liveActivityOffered())
        #expect(fields(store).liveActivityConsent != nil)
    }

    @Test("the push-to-start token goes with hl-la-start-v1, again only when new or older than 25 days")
    func liveActivityStartToken() async throws {
        let store = await turnedOnStore()
        await store.setLiveActivityUpdates(true)
        _ = fields(store)
        let start = Data(repeating: 0x2E, count: 32)
        await store.notePushToStartToken(start.relayHex)
        let firstPart = fields(store).liveActivityStart.flatMap { $0 }
        let first = try #require(firstPart)
        #expect(first.token == start.relayHex)
        let text = RelayStatement.liveActivityStart(
            host: HLPushRelayKeys.host,
            instanceId: instanceId,
            tokenTag: tokenTag,
            startTokenTag: RelayEnvelope.tokenTag(of: start),
            iat: first.statement.iat
        )
        let key = try #require(keyring.bindingKey()).publicKey
        let signature = try #require(Data(relayBase64URL: first.signature))
        #expect(RelayStatement.verify(text, signature: signature, publicKey: key))
        #expect(fields(store).liveActivityStart == nil, "unchanged token: not again")
        clockBox.now = clockBox.now.addingTimeInterval(26 * 24 * 3600)
        let refreshedPart = fields(store).liveActivityStart.flatMap { $0 }
        let refreshed = try #require(refreshedPart)
        #expect(refreshed.statement.iat > first.statement.iat)
    }

    @Test("Activities the relay started go into liveActivityTokens with relayStart and no medication")
    func relayStartedTokens() async throws {
        let store = await turnedOnStore()
        await store.setLiveActivityUpdates(true)
        let update = Data(repeating: 0x3E, count: 32).relayHex
        await store.noteRelayStartedActivityTokens([update])
        let body = fields(store)
        #expect(body.relayStartedActivities.map(\.token) == [update])
        let json = try Self.encoded(fields: body)
        let entries = try #require(json["liveActivityTokens"] as? [[String: Any]])
        let entry = try #require(entries.first)
        #expect(entry["relayStart"] as? Bool == true)
        #expect(entry["medicationId"] == nil)
        #expect(entry["statement"] != nil)
        #expect(entry["signature"] != nil)
    }

    @Test("turning it off withdraws directly at the relay and through the server, and drops the start token")
    func liveActivityWithdraw() async throws {
        let store = await turnedOnStore()
        await store.setLiveActivityUpdates(true)
        await store.notePushToStartToken(Data(repeating: 0x2E, count: 32).relayHex)
        _ = fields(store)
        await store.setLiveActivityUpdates(false)
        let request = try #require(transport.requests.last)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.path == "/v1/bindings/self/liveactivity")
        let httpBody = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: httpBody) as? [String: Any])
        let statement = try #require(body["statement"] as? [String: Any])
        let iat = try #require((statement["iat"] as? NSNumber)?.int64Value)
        let text = RelayStatement.liveActivityWithdraw(host: HLPushRelayKeys.host, instanceId: instanceId, tokenTag: tokenTag, iat: iat)
        let key = try #require(keyring.bindingKey()).publicKey
        let signatureText = try #require(body["signature"] as? String)
        #expect(try RelayStatement.verify(text, signature: #require(Data(relayBase64URL: signatureText)), publicKey: key))
        let after = fields(store)
        #expect(after.liveActivityWithdraw != nil)
        #expect(after.liveActivityStart == .some(nil), "liveActivityStart: null")
        let json = try Self.encoded(fields: after)
        #expect(json["liveActivityStart"] is NSNull)
        #expect(fields(store).liveActivityWithdraw == nil, "once")
    }

    @Test("turning the relay off drops the Live Activity consent locally; the server drops it too")
    func relayOffDropsLiveActivity() async {
        let store = await turnedOnStore()
        await store.setLiveActivityUpdates(true)
        await store.turnOff(reason: .person)
        #expect(!store.liveActivityUpdatesOn)
    }

    @Test("a 422 relay_consent_required switches the Live Activity part off; statement_stale signs again")
    func liveActivityRejections() async {
        let store = await turnedOnStore()
        await store.setLiveActivityUpdates(true)
        _ = fields(store)
        await store.registrationRejected(code: "devices.push.statement_stale")
        #expect(fields(store).liveActivityConsent != nil)
        await store.registrationRejected(code: "devices.push.relay_consent_required")
        #expect(!store.liveActivityUpdatesOn)
    }

    @Test("the started dose reaches the app from push.device, never from the push")
    func startedDose() {
        let store = makeStore()
        let seen = Counter()
        let started = StartedBox()
        store.onLiveActivityStarted = { dose in
            seen.value += 1
            started.medicationId = dose?.medicationId
        }
        let me: [String: Any] = ["push": [
            "relay": ["available": true, "offered": true, "liveActivityConsentTextVersion": "2026-11-21"],
            "device": ["relayState": "bound", "liveActivityStarted": ["medicationId": "m1", "slotInstant": "2026-11-21T07:00:00.000Z"]]
        ]]
        let capability = RelayCapability.parse(me: me)
        #expect(capability.device?.liveActivityStarted?.medicationId == "m1")
        #expect(capability.liveActivityConsentTextVersion == "2026-11-21")
        store.noteLiveActivityState(capability)
        #expect(seen.value == 1)
        #expect(started.medicationId == "m1")
    }
}

@MainActor
final class StartedBox {
    var medicationId: String?
}

@Suite("Push relay: the Activity the relay starts")
struct HealthLogDoseAttributesTests {
    @Test("the content state reads unix seconds; 0 is no countdown; an unknown status is neutral")
    func decoding() throws {
        let json = #"{"status":"due","countdownTarget":1795000000,"isOverdue":false,"confirmed":false,"pendingConfirm":false,"timeFormatRaw":"H24"}"#
        let state = try JSONDecoder().decode(HealthLogDoseContentState.self, from: Data(json.utf8))
        #expect(state.status == .due)
        #expect(state.countdownDate == Date(timeIntervalSince1970: 1_795_000_000))
        #expect(state.timeFormatRaw == "H24")
        let none = try JSONDecoder().decode(HealthLogDoseContentState.self, from: Data(#"{"status":"later","countdownTarget":0}"#.utf8))
        #expect(none.status == .unknown)
        #expect(none.countdownDate == nil)
        #expect(none.timeFormatRaw == "AUTO")
        for status in ["pending", "due", "overdue", "snoozed", "taken", "skipped"] {
            let decoded = try JSONDecoder().decode(
                HealthLogDoseContentState.self,
                from: Data(#"{"status":"\#(status)","countdownTarget":0}"#.utf8)
            )
            #expect(decoded.status.rawValue == status)
        }
    }

    @Test("the attributes are {\"v\":1}")
    func attributes() throws {
        let data = try JSONEncoder().encode(HealthLogDoseAttributes())
        #expect(String(data: data, encoding: .utf8) == #"{"v":1}"#)
    }

    @Test("the label round-trips through the App Group file and can be removed")
    func label() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("label-\(UUID().uuidString).json")
        let label = RelayLiveActivityLabel(medicationId: "m1", slotInstant: nil, title: "Lisinopril", detail: "5 mg")
        RelayLiveActivityLabel.write(label, url: url)
        #expect(RelayLiveActivityLabel.read(url: url) == label)
        RelayLiveActivityLabel.write(nil, url: url)
        #expect(RelayLiveActivityLabel.read(url: url) == nil)
    }
}
