import CryptoKit
import Foundation

// **#190 (17:58, 18:11, 18:29) — Live Activity start and update over the
// relay.**
//
// A separate consent, off by default: ActivityKit cannot decrypt, so the relay
// and Apple see when a dose is due. Only the device can switch it on
// (`hl-la-consent-v1`, signed with the binding key); it withdraws through the
// server (`hl-la-withdraw-v1`) and directly at the relay. The relay starts
// and updates only Activities of its own type (``HealthLogDoseAttributes``,
// `relayStart: true`); Activities the app started keep their direct path and
// the `end` of today.

extension PushRelayStore {
    /// The text version the consent is signed for.
    static let liveActivityConsentTextVersion = "2026-11-21"
    /// A push-to-start statement is valid for 30 days; it is signed again
    /// after 25.
    static let startStatementRefresh: TimeInterval = 25 * 24 * 60 * 60

    /// The server reports `push.live-activity-relay` and offers `start`.
    var liveActivityUpdatesOffered: Bool {
        capability.isUsable && liveActivityFeature() && capability.liveActivity.contains("start")
    }

    /// The second switch can be used: offered, and the relay is on.
    var liveActivityUpdatesAvailable: Bool {
        isOn && liveActivityUpdatesOffered
    }

    /// The second switch.
    func setLiveActivityUpdates(_ on: Bool) async {
        if on {
            guard liveActivityUpdatesAvailable, !liveActivityUpdatesOn else { return }
            grantLiveActivityUpdates()
        } else {
            guard liveActivityUpdatesOn else { return }
            setLiveActivityFlag(false)
            liveActivityConsentDue = false
            liveActivityWithdrawDue = true
            await revokeLiveActivityAtRelay()
            await onLiveActivityConsentWithdrawn?()
        }
        await reRegister?()
    }

    func grantLiveActivityUpdates() {
        setLiveActivityFlag(true)
        liveActivityConsentDue = true
        liveActivityWithdrawDue = false
    }

    private func setLiveActivityFlag(_ on: Bool) {
        liveActivityUpdatesOn = on
        defaults.set(on, forKey: key("liveActivityUpdates"))
    }

    /// The relay went off: the server drops the Live Activity consent and the
    /// push-to-start token with it; nothing more to send.
    func clearLiveActivityLocally() {
        setLiveActivityFlag(false)
        liveActivityConsentDue = false
        liveActivityWithdrawDue = false
        relayStartedActivityTokens = []
        defaults.removeObject(forKey: key("laStartToken"))
        defaults.removeObject(forKey: key("laStartIat"))
    }

    /// `statement_stale`: sign the Live Activity statements again next time.
    func liveActivityStatementsStale() {
        liveActivityConsentDue = liveActivityUpdatesOn
        defaults.removeObject(forKey: key("laStartIat"))
    }

    /// Withdraw at the relay directly; works with the server down.
    private func revokeLiveActivityAtRelay() async {
        guard let binding = keyring.state()?.binding, let token = keyring.bindingToken(),
              let key = keyring.bindingKey() else { return }
        _ = await client.revokeLiveActivity(apnsToken: token, instanceId: binding.instanceId, bindingKey: key)
    }

    /// After a `/me` reading: the started dose for the name, and the consent
    /// sent again while the relay has not accepted it.
    func noteLiveActivityState(_ next: RelayCapability) {
        onLiveActivityStarted?(next.device?.liveActivityStarted)
        // While the server's switch is off it simply sends nothing; the
        // person's consent stays as given.
        if liveActivityUpdatesOn, liveActivityUpdatesOffered, next.device?.liveActivityConsent == false {
            liveActivityConsentDue = true
        }
    }

    /// The `push` block of a `POST /api/devices` answer: the same device
    /// state as `/me`, read at once, so the started dose's name does not wait
    /// for the next foreground (#190, 20:09).
    func noteRegistrationAnswer(_ device: RelayCapability.Device?) {
        guard let device else { return }
        var next = capability
        next.device = device
        capability = next
        // D1 (8): the answer's `envelope` switches the mode at once, not
        // only with the next `/me`.
        updateEnvelopeMode(seals: next.seals, device: device)
        onLiveActivityStarted?(device.liveActivityStarted)
    }

    /// The push-to-start token changed (``HealthLogDoseAttributes``).
    func notePushToStartToken(_ tokenHex: String?) async {
        guard pushToStartToken != tokenHex else { return }
        pushToStartToken = tokenHex
        if liveActivityUpdatesOn { await reRegister?() }
    }

    /// The update tokens of the Activities the relay started.
    func noteRelayStartedActivityTokens(_ tokens: [String]) async {
        let sorted = tokens.sorted()
        guard relayStartedActivityTokens != sorted else { return }
        relayStartedActivityTokens = sorted
        if liveActivityUpdatesOn { await reRegister?() }
    }

    /// The Live Activity part of `POST /api/devices`.
    func addLiveActivityFields(to fields: inout DeviceRegistrationPushFields, apnsToken: Data, instanceId: String) {
        guard let bindingKey = keyring.bindingKey() else { return }
        let host = client.host
        let tokenTag = RelayEnvelope.tokenTag(of: apnsToken)
        let iat = Int64(clock().timeIntervalSince1970)
        if liveActivityWithdrawDue {
            let text = RelayStatement.liveActivityWithdraw(host: host, instanceId: instanceId, tokenTag: tokenTag, iat: iat)
            if let signature = try? RelayStatement.sign(text, with: bindingKey) {
                fields.liveActivityWithdraw = RelayLiveActivityWithdraw(iat: iat, signature: signature.relayBase64URL)
            }
        }
        guard liveActivityUpdatesOn else {
            if defaults.string(forKey: key("laStartToken")) != nil {
                fields.liveActivityStart = .some(nil)
            }
            return
        }
        if liveActivityConsentDue {
            let version = capability.liveActivityConsentTextVersion ?? Self.liveActivityConsentTextVersion
            let text = RelayStatement.liveActivityConsent(
                host: host,
                instanceId: instanceId,
                tokenTag: tokenTag,
                textVersion: version,
                iat: iat
            )
            if let signature = try? RelayStatement.sign(text, with: bindingKey) {
                fields.liveActivityConsent = RelayLiveActivityConsent(textVersion: version, iat: iat, signature: signature.relayBase64URL)
            }
        }
        if let start = startIfDue(apnsTokenTag: tokenTag, instanceId: instanceId, bindingKey: bindingKey, iat: iat) {
            fields.liveActivityStart = .some(start)
        }
        fields.relayStartedActivities = relayStartedActivityTokens.map {
            RelayStartedActivityToken(token: $0, proof: activityProof(liveActivityTokenHex: $0))
        }
    }

    /// **R1 (4).** The server took a body with these Live Activity parts:
    /// the withdrawal and the consent are no longer due, and the start
    /// statement counts as sent (or withdrawn) only now.
    func acceptLiveActivityFields(_ fields: DeviceRegistrationPushFields) {
        if fields.liveActivityWithdraw != nil { liveActivityWithdrawDue = false }
        if fields.liveActivityConsent != nil, liveActivityUpdatesOn { liveActivityConsentDue = false }
        switch fields.liveActivityStart {
        case .some(.none):
            defaults.removeObject(forKey: key("laStartToken"))
            defaults.removeObject(forKey: key("laStartIat"))
        case let .some(.some(start)):
            defaults.set(start.token, forKey: key("laStartToken"))
            defaults.set(NSNumber(value: start.statement.iat), forKey: key("laStartIat"))
        case .none:
            break
        }
    }

    /// `hl-la-start-v1` when the push-to-start token is new or its statement
    /// is older than ``startStatementRefresh``.
    private func startIfDue(
        apnsTokenTag: Data,
        instanceId: String,
        bindingKey: Curve25519.Signing.PrivateKey,
        iat: Int64
    ) -> RelayLiveActivityStart? {
        guard let tokenHex = pushToStartToken, let startToken = Data(relayHex: tokenHex) else { return nil }
        let sentToken = defaults.string(forKey: key("laStartToken"))
        let sentIat = defaults.object(forKey: key("laStartIat")) as? Int64 ?? (defaults.object(forKey: key("laStartIat")) as? NSNumber)?
            .int64Value
        if sentToken == tokenHex, let sentIat, TimeInterval(iat - sentIat) < Self.startStatementRefresh { return nil }
        let startTag = RelayEnvelope.tokenTag(of: startToken)
        let text = RelayStatement.liveActivityStart(
            host: client.host,
            instanceId: instanceId,
            tokenTag: apnsTokenTag,
            startTokenTag: startTag,
            iat: iat
        )
        guard let signature = try? RelayStatement.sign(text, with: bindingKey) else { return nil }
        return RelayLiveActivityStart(
            token: tokenHex,
            statement: .init(instanceId: instanceId, tokenTag: apnsTokenTag.relayHex, laTokenTag: startTag.relayHex, iat: iat),
            signature: signature.relayBase64URL
        )
    }
}
