import CryptoKit
import Foundation

// The relay store's envelope mode, key ownership, registration answers, the
// direct revoke and the gates for silent pushes and taps. Split from
// `PushRelayStore.swift` (file length); same type, same rules.

// MARK: - Envelope mode, key ownership and the registration answers

extension PushRelayStore {
    /// **D1 (8).** Envelope mode follows what the server says about this
    /// device: on with any reported envelope, off only when the server stops
    /// sealing or names `envelope: null` for the device. A block without the
    /// device, or a device block without the key, changes nothing.
    func updateEnvelopeMode(seals: Bool, device: RelayCapability.Device?) {
        let current = RelayEnvelopeMode.isOn(defaults: appGroupDefaults)
        let next: Bool = if !seals {
            false
        } else if let device, device.reportsEnvelope {
            device.envelope != nil
        } else {
            current
        }
        guard next != current else { return }
        RelayEnvelopeMode.set(next, defaults: appGroupDefaults)
        onEnvelopeModeChanged?()
    }

    /// **D1 (1).** The keys belong to the signed-in account: another
    /// account's (a reinstall without sign-out, a server switch) are replaced
    /// by new ones without a predecessor and without pinned senders. `false`
    /// when no account is signed in or the item cannot be written.
    func claimKeys() -> Bool {
        guard let owner = accountKey() else { return false }
        guard let replaced = try? keyring.claim(for: owner) else { return false }
        if replaced {
            ledger.wipe()
            onEnvelopeModeChanged?()
        }
        return true
    }

    /// **R1 (4).** `POST /api/devices` answered 2xx for a body with these
    /// fields: what it carried once is no longer due.
    func registrationAccepted(_ fields: DeviceRegistrationPushFields) {
        if fields.pushKey == .withdrawn { keyWithdrawalDue = false }
        if fields.relayConsent?.granted == false { consentWithdrawalDue = false }
        if let sent = fields.relayBinding, let signed = signedBinding, signed.seq == sent.statement.seq {
            signedBinding = nil
            // A turn-on or reconnect after this body asks for its own binding.
            if signed.request == bindingRequest, isOn {
                bindingDue = false
                // The server has it now; the next `/me` reading tells.
                awaitingBinding = true
            }
        }
        acceptLiveActivityFields(fields)
    }

    /// **R1 (4).** The post failed or was refused. Every one-time part is
    /// still due; a binding that did not reach the server is not "awaited"
    /// (the next `/me` must not read its absence as the relay's block).
    func registrationFailed() {
        awaitingBinding = false
    }

    /// A 422 from `POST /api/devices` with a `devices.push.*` code (#191).
    func registrationRejected(code: String) async {
        switch code {
        case "devices.push.invalid_push_key", "devices.push.unsupported_suite":
            // Make a fresh key; the next registration carries it.
            try? keyring.update { $0.recipients = [] }
            _ = try? keyring.ensureRecipientKey(now: clock())
        case "devices.push.bad_signature":
            // §9: a fresh statement refused right after turn-on means the
            // server uses another relay. Never re-sign on our own.
            if awaitingBinding {
                freshStatementRefused = true
                unavailable = .otherRelay
                await turnOff(reason: .unavailable)
            } else if isOn {
                needsReconnect = true
            }
        case "devices.push.instance_mismatch", "devices.push.token_mismatch", "devices.push.consent_required",
             "devices.push.push_key_required":
            needsReconnect = isOn
        case "devices.push.relay_consent_required":
            // The Live Activity consent came without the relay consent.
            clearLiveActivityLocally()
        case "devices.push.statement_stale":
            liveActivityStatementsStale()
        case "devices.push.relay_not_offered":
            if isOn { await turnOff(reason: .operatorOff) }
        case "devices.push.relay_device_limit":
            if isOn { await turnOff(reason: .deviceLimit) }
        default:
            break
        }
    }
}

// MARK: - The direct revoke (D1 (3))

extension PushRelayStore {
    /// **D1 (3).** The revoke signs with the token the binding names, not
    /// the newest one. Only a 2xx confirms it; anything else (including
    /// `404`, which the relay also answers for a wrong key or instance) is
    /// kept as a pending revocation and retried with backoff, even after a
    /// sign-out wiped the keys.
    func revokeAtRelay() async {
        guard let state = keyring.state(), let binding = state.binding,
              let token = binding.apnsToken ?? state.apnsToken,
              let key = state.bindingKey else
        {
            lastRevokeConfirmed = nil
            return
        }
        let pending = RelayKeyringState.PendingRevocation(
            host: binding.host,
            instanceId: binding.instanceId,
            apnsToken: token,
            bindingKey: key.privateKey,
            attempts: 0,
            nextAttemptAt: clock()
        )
        let confirmed = await attemptRevocation(pending)
        lastRevokeConfirmed = confirmed
        if !confirmed { remember(pending.failedOnce(now: clock())) }
    }

    /// One revoke, with a single retry on `stale_timestamp` using the
    /// relay's own clock.
    private func attemptRevocation(_ pending: RelayKeyringState.PendingRevocation) async -> Bool {
        guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: pending.bindingKey) else { return false }
        var outcome = await client.revoke(apnsToken: pending.apnsToken, instanceId: pending.instanceId, bindingKey: key)
        if let offset = Self.relayClockOffset(outcome, now: clock()) {
            outcome = await client.revoke(
                apnsToken: pending.apnsToken,
                instanceId: pending.instanceId,
                bindingKey: key,
                iatOffset: offset
            )
        }
        return Self.revokeConfirmed(outcome)
    }

    /// Only a 2xx counts (D1 (3)).
    static func revokeConfirmed(_ outcome: RelayCallOutcome) -> Bool {
        if case let .confirmed(status, _, _) = outcome { return (200 ..< 300).contains(status) }
        return false
    }

    /// `401 stale_timestamp` names `relayTime`: the offset to sign with once.
    static func relayClockOffset(_ outcome: RelayCallOutcome, now: Date) -> Int64? {
        guard case let .confirmed(status, body, _) = outcome, status == 401,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              object["error"] as? String == "stale_timestamp",
              let relayTime = (object["relayTime"] as? NSNumber)?.int64Value else { return nil }
        let offset = relayTime - Int64(now.timeIntervalSince1970)
        return offset == 0 ? nil : offset
    }

    private func remember(_ pending: RelayKeyringState.PendingRevocation) {
        try? keyring.update { state in
            state.pendingRevocations.removeAll { $0.apnsToken == pending.apnsToken && $0.instanceId == pending.instanceId }
            state.pendingRevocations.append(pending)
            state.pendingRevocations = Array(state.pendingRevocations.suffix(4))
        }
    }

    /// Retries every pending revocation whose backoff ran out; a confirmed
    /// one goes, the others wait longer. Gives up after
    /// ``RelayKeyringState/PendingRevocation/maxAttempts``.
    func retryPendingRevocations() async {
        let now = clock()
        guard let due = keyring.state()?.pendingRevocations.filter({ $0.nextAttemptAt <= now }), !due.isEmpty else { return }
        for pending in due {
            let confirmed = await attemptRevocation(pending)
            try? keyring.update { state in
                state.pendingRevocations.removeAll { $0.apnsToken == pending.apnsToken && $0.instanceId == pending.instanceId }
                if !confirmed, pending.attempts + 1 < RelayKeyringState.PendingRevocation.maxAttempts {
                    state.pendingRevocations.append(pending.failedOnce(now: now))
                }
            }
            if confirmed { lastRevokeConfirmed = true }
        }
    }
}

// MARK: - Silent pushes, the challenge and taps

extension PushRelayStore {
    // MARK: Silent pushes and taps

    func silentDecision(userInfo: [AnyHashable: Any]) async -> RelaySilentDecision {
        deliveryCounters.note(.received, pushClass: .silent, now: clock())
        // §6: the conflict challenge is a plaintext background push with `c`
        // (the relay holds no sender key). It never starts a sync. D1 (7):
        // the answer is awaited, so the wake lasts until it is posted.
        if let challenge = userInfo[Self.challengeKey] as? String, userInfo[RelayNotificationRebuilder.envelopeKey] == nil {
            if shouldAnswerChallenge(challenge) {
                await answerChallenge(challenge)
            }
            deliveryCounters.note(.opened, pushClass: .silent, now: clock())
            return .handled
        }
        // D1 (8): a push that carries an envelope always goes the envelope
        // way; the flag only says whether plaintext is refused.
        let carriesEnvelope = userInfo[RelayNotificationRebuilder.envelopeKey] != nil
        guard carriesEnvelope || RelayEnvelopeMode.isOn(defaults: appGroupDefaults) else {
            deliveryCounters.note(.opened, pushClass: .silent, now: clock())
            return .notInEnvelopeMode
        }
        let opened = RelayNotificationRebuilder.open(
            userInfo: userInfo,
            pushClass: .silent,
            keyring: keyring,
            replayStore: replayStore,
            now: clock()
        )
        guard case let .success(plaintext) = opened else {
            deliveryCounters.note(.discarded, pushClass: .silent, now: clock())
            return .refused
        }
        ledger.record(RelayNotificationRebuilder.ledgerEntry(for: plaintext, requestId: nil, pushClass: .silent, now: clock()))
        // D1 (13): a template v1 does not know starts nothing.
        guard RelayTemplate.isKnownSilent(plaintext.type) else {
            deliveryCounters.note(.discarded, pushClass: .silent, now: clock())
            return .handled
        }
        deliveryCounters.note(.opened, pushClass: .silent, now: clock())
        if plaintext.type == RelayDataChange.template {
            lastDataChange = RelayDataChange(plaintext: plaintext)
        }
        // 1.7: a confirmation that arrives as a silent push (the person turned
        // the visible one off) is still a resolved dose: into the ledger the
        // widget and the next start read, then the intake reconcile.
        if MedicationIntakeRecordedGate.isOpen(), let payload = RelayIntakeBridge.payload(from: plaintext),
           let dose = MedicationIntakeRecordedPush.parse(userInfo: payload, now: clock())
        {
            ResolvedDoseLedger().record(dose, now: clock())
        }
        return .opened(Self.syncTemplate(for: plaintext))
    }

    /// `SYNC` naming the medications is the intake reconcile the sync path
    /// already knows; every other template keeps its name.
    static func syncTemplate(for plaintext: RelayPlaintext) -> String {
        if plaintext.type == RelayTemplate.intakeRecorded { return RelayTemplate.intakeSync }
        if plaintext.type == "SYNC", case let .array(scope)? = plaintext.data?["scope"],
           scope.contains(.string("medications"))
        {
            return "MEDICATION_INTAKE_SYNC"
        }
        return plaintext.type
    }

    /// The key of the conflict challenge in the plaintext push (§6).
    static let challengeKey = "c"

    /// Only while the relay is on here and the server reports `conflict`,
    /// and only a well-formed challenge (43 base64url characters).
    func shouldAnswerChallenge(_ challenge: String) -> Bool {
        guard isOn, capability.device?.relayState == .conflict, challenge.count == 43,
              let bytes = Data(relayBase64URL: challenge), bytes.count == 32 else { return false }
        return keyring.bindingKey() != nil && keyring.bindingToken() != nil
    }

    /// Signs `hl-challenge-v1` over `c` as received and posts it to the relay,
    /// with the token the binding names (D1 (3)).
    func answerChallenge(_ challenge: String) async {
        guard let token = keyring.bindingToken(), let key = keyring.bindingKey() else { return }
        _ = await client.answerChallenge(challenge, apnsToken: token, bindingKey: key)
    }

    /// Whether a tap may act. Local notifications always may; a remote one in
    /// envelope mode only when the extension recorded it as opened.
    ///
    /// **D1 (2).** The request id alone proves nothing: it comes from
    /// `apns-collapse-id` or `apns-id`, which a sender with the APNs key can
    /// reuse, and a plaintext push with the same id replaces the opened one.
    /// The tap acts only when its `userInfo` names the envelope id the ledger
    /// recorded (it travels inside the ciphertext only), and, when the entry
    /// names a medication, the same medication.
    func allowsTap(requestIdentifier: String, isRemote: Bool, userInfo: [AnyHashable: Any] = [:]) -> Bool {
        guard isRemote, RelayEnvelopeMode.isOn(defaults: appGroupDefaults) else { return true }
        if let entry = ledger.verified(requestId: requestIdentifier), Self.tap(userInfo, matches: entry) { return true }
        unverifiedTapNotice = true
        openHome?()
        return false
    }

    static func tap(_ userInfo: [AnyHashable: Any], matches entry: RelayOpenedLedger.Entry) -> Bool {
        guard let envelopeId = userInfo[RelayNotificationRebuilder.verifiedKey] as? String,
              envelopeId == entry.envelopeId else { return false }
        if let target = entry.target {
            guard let medicationId = userInfo["medicationId"] as? String, target == "medication:\(medicationId)" else { return false }
        }
        return true
    }

    // MARK: Diagnostics

    var receiptCounts: [RelayPushClass: Int] {
        ledger.receipts().mapValues(\.count)
    }

    /// The action categories that get random per-install identifiers.
    static let actionTemplates = ["MEDICATION_REMINDER"]

    /// The per-account key: a hash of account and server host, never either.
    static func accountKey(userID: String, serverHost: String) -> String {
        SHA256.hash(data: Data("\(userID)|\(serverHost)".utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
