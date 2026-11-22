import CryptoKit
import Foundation
import Observation

/// What a silent push may start (#190 5.3).
public enum RelaySilentDecision: Sendable, Equatable {
    /// The relay is off on this device: the push is read as before.
    case notInEnvelopeMode
    /// Envelope mode, but nothing opened: no sync, no HealthKit run.
    case refused
    /// Opened; the template (mapped onto the names the sync path reads).
    case opened(String)
    /// Handled by the relay store itself (a conflict challenge); no sync.
    case handled
}

/// Why the relay cannot be used from this device right now (#190 §4, §9).
public enum RelayUnavailableReason: Sendable, Equatable {
    /// The server names a relay other than the one this build pins.
    case otherRelay
    /// The relay was turned on, but the server reports no binding: the
    /// relay's block cannot be lifted (a restored registry); only a new
    /// token brings the device back.
    case blocked
}

/// **#190 / #191 — the app side of sealed pushes and of the push relay.**
///
/// Two things, kept apart:
///
/// - **Sealing.** A server that reports `envelopeVersions` seals every push
///   for a device that registered a push key, through the relay or with its
///   own APNs key (#191). The device then makes its envelope key without
///   asking (it only reaches the own server), registers it, and once the
///   server confirms (`push.device.envelope == 1`) refuses unsealed content.
/// - **The relay.** Only "Turn on" on the card or in Settings is consent; it
///   adds `relayConsent` and the signed `relayBinding`. Turning it off revokes
///   the binding at the relay directly, then withdraws at the server.
///
/// Nothing here touches the local reminders: they are planned on the device
/// with or without the relay, and keep running when the relay is down. A
/// server without `envelopeVersions` sees the registration body of 1.6.
@MainActor
@Observable
final class PushRelayStore {
    // MARK: Published state

    /// Set by `/me` readings and by the `POST /api/devices` answer.
    var capability: RelayCapability = .notOffered
    /// The person turned the relay on for this account on this device.
    private(set) var isOn = false
    /// The operator turned it off and the app unregistered by itself.
    private(set) var operatorTurnedOff = false
    /// The server refused: five relay devices per account are bound already.
    private(set) var deviceLimitReached = false
    /// A tap on a notification the server did not confirm (cleared on view).
    var unverifiedTapNotice = false
    private(set) var cardAnswered = false
    var lastRevokeConfirmed: Bool?
    private(set) var isWorking = false
    /// The relay is on, but the server asks for a new binding: only the
    /// person may sign it (#190 §4), through ``reconnect()``.
    var needsReconnect = false
    var unavailable: RelayUnavailableReason?
    /// The separate consent to Live Activity start and update over the relay
    /// (#191), off by default.
    var liveActivityUpdatesOn = false

    // MARK: Dependencies

    @ObservationIgnored private let api: APIClientProtocol?
    @ObservationIgnored let keyring: RelayKeyring
    @ObservationIgnored let client: RelayClient
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored let appGroupDefaults: UserDefaults?
    @ObservationIgnored let ledger: RelayOpenedLedger
    @ObservationIgnored let replayStore: RelayReplayStoring
    /// The per-account key, `nil` while no account is signed in.
    @ObservationIgnored let accountKey: @MainActor () -> String?
    /// The last account key seen (R1 (5)): the sign-out cascade runs after the
    /// keychain lost the user id, and must still clear that account's keys.
    @ObservationIgnored private var cachedAccountKey: String?
    /// **D1 (1).** Moves on every sign-out and account change. A `/me` that
    /// started under one epoch and answers under another is dropped, so a
    /// late answer never brings keys back after a wipe.
    @ObservationIgnored var accountEpoch = 0
    /// The local push counters of the diagnostics (App Group).
    @ObservationIgnored let deliveryCounters: PushDeliveryCounters
    @ObservationIgnored let clock: () -> Date
    /// Re-posts `POST /api/devices` with the cached token.
    @ObservationIgnored var reRegister: (@MainActor () async -> Void)?
    /// Routes Home after an unverified tap.
    @ObservationIgnored var openHome: (@MainActor () -> Void)?
    /// Envelope mode flipped: the notification categories are registered anew
    /// (the plain medication category goes, the secret one comes).
    @ObservationIgnored var onEnvelopeModeChanged: (@MainActor () -> Void)?
    /// A binding statement is due with the next registration. Cleared only
    /// once the server answered 2xx to a body that carried it (R1 (4)).
    @ObservationIgnored var bindingDue = false
    /// Counts the person's turn-ons and reconnects, so the answer to an
    /// older registration never clears a binding asked for later.
    @ObservationIgnored var bindingRequest = 0
    /// The binding statement last signed, and for which request.
    @ObservationIgnored var signedBinding: (seq: Int64, request: Int)?
    /// `relayConsent.granted: false` still has to reach the server.
    @ObservationIgnored var consentWithdrawalDue = false
    /// `pushKey: null` still has to reach the server.
    @ObservationIgnored var keyWithdrawalDue = false
    /// Set by an explicit turn-on until the server answers with the binding.
    @ObservationIgnored var awaitingBinding = false
    /// After the person's turn-on the server answered `bad_signature`: the
    /// server uses another relay; no retry loop (#190 §9).
    @ObservationIgnored var freshStatementRefused = false

    // MARK: Live Activity over the relay (state; logic in +LiveActivity)

    /// Reads the server's `features` key `push.live-activity-relay`.
    @ObservationIgnored var liveActivityFeature: @MainActor () -> Bool = { false }
    /// The started dose changed: the app fills the name locally (#190, 18:29).
    @ObservationIgnored var onLiveActivityStarted: (@MainActor (RelayCapability.Device.StartedDose?) -> Void)?
    @ObservationIgnored var liveActivityConsentDue = false
    @ObservationIgnored var liveActivityWithdrawDue = false
    /// The push-to-start token of ``HealthLogDoseAttributes`` (hex).
    @ObservationIgnored var pushToStartToken: String?
    /// Update tokens of the Activities the relay started (hex).
    @ObservationIgnored var relayStartedActivityTokens: [String] = []

    /// Sign-out: the relay's own Activities end and their name goes (R1 (3)).
    @ObservationIgnored var onSignOut: (@MainActor () async -> Void)?
    /// The Live Activity consent or the relay went off: the relay's running
    /// Activities end at once (D1 (9)).
    @ObservationIgnored var onLiveActivityConsentWithdrawn: (@MainActor () async -> Void)?

    /// Helpers that live as long as the store (the Activity observer).
    @ObservationIgnored var retainedHelpers: [AnyObject] = []

    /// The domains of the last opened `DATA_CHANGED` (#191).
    @ObservationIgnored var lastDataChange: RelayDataChange?

    init(
        api: APIClientProtocol?,
        keyring: RelayKeyring = .production(),
        client: RelayClient = RelayClient(),
        defaults: UserDefaults = .standard,
        appGroupDefaults: UserDefaults? = UserDefaults(suiteName: RelayAppGroupFile.appGroup),
        ledger: RelayOpenedLedger = RelayOpenedLedger(),
        replayStore: RelayReplayStoring = RelayFileReplayStore(),
        deliveryCounters: PushDeliveryCounters = PushDeliveryCounters(),
        accountKey: @escaping @MainActor () -> String?,
        clock: @escaping () -> Date = { .now }
    ) {
        self.api = api
        self.keyring = keyring
        self.client = client
        self.defaults = defaults
        self.appGroupDefaults = appGroupDefaults
        self.ledger = ledger
        self.replayStore = replayStore
        self.deliveryCounters = deliveryCounters
        self.accountKey = accountKey
        self.clock = clock
        loadLocalState()
    }

    // MARK: Per account and server

    func key(_ suffix: String) -> String {
        "hl.pushRelay.\(currentAccountKey()).\(suffix)"
    }

    /// The signed-in account's key, else the one last seen (R1 (5)).
    func currentAccountKey() -> String {
        if let live = accountKey() {
            if let cachedAccountKey, cachedAccountKey != live { accountEpoch += 1 }
            cachedAccountKey = live
            return live
        }
        return cachedAccountKey ?? Self.accountKey(userID: "", serverHost: "")
    }

    private func loadLocalState() {
        isOn = defaults.bool(forKey: key("on"))
        liveActivityUpdatesOn = isOn && defaults.bool(forKey: key("liveActivityUpdates"))
        cardAnswered = defaults.bool(forKey: key("answered"))
        operatorTurnedOff = defaults.bool(forKey: key("operatorOff"))
    }

    /// **D1 (9).** Whether an Activity the relay started may stay: an account
    /// is signed in, the relay is on and the person consented to Live
    /// Activity starts. A push-to-start token cannot be withdrawn, so any
    /// other start is ended at once.
    var allowsRelayActivities: Bool {
        isOn && liveActivityUpdatesOn && accountKey() != nil
    }

    /// The one card on the dashboard (#190 5.1 (3)): offered, not yet consented
    /// on this device, never answered for this account.
    var showsOptInCard: Bool {
        capability.isUsable && capability.device?.consent != true && !isOn && !cardAnswered
    }

    /// The settings row is there once the operator offers the relay, or while
    /// it is on, or to say why it went off.
    var showsSettings: Bool {
        capability.isUsable || isOn || operatorTurnedOff || deviceLimitReached || unavailable != nil
    }

    /// The calm line on the dashboard (#191 rule).
    var showsDegradedLine: Bool {
        capability.isDegraded
    }

    var privacyURL: URL? {
        capability.privacyURL ?? capability.termsURL
    }

    // MARK: Capability

    /// Reads `push` from `/api/auth/me` and reacts. Fail-quiet: offline keeps
    /// the last reading and changes nothing.
    func refresh() async {
        guard let api else { return }
        loadLocalState()
        await retryPendingRevocations()
        let epoch = accountEpoch
        let request: APIRequest<AuthMeRelay> = .get("/api/auth/me")
        guard let me = try? await api.send(request) else { return }
        // D1 (1): the answer belongs to the account that asked; after a
        // sign-out or an account change it is dropped.
        _ = currentAccountKey()
        guard epoch == accountEpoch, accountKey() != nil else { return }
        // R1 (6): an answer without the `push` block says nothing about
        // sealing or the relay. It is not "off": nothing changes.
        guard me.reportsPush else { return }
        await apply(me.relay)
    }

    func apply(_ next: RelayCapability) async {
        capability = next
        unavailable = next.usesOtherRelay ? .otherRelay : (unavailable == .otherRelay ? nil : unavailable)
        var postNeeded = false
        if next.seals {
            postNeeded = prepareSealing(next) || postNeeded
        } else if keyring.state()?.recipients.isEmpty == false {
            // The server stopped sealing: take the key back. R1 (6): a relay
            // that is on is revoked first, while the binding key still exists;
            // only then do the keys go.
            if isOn { await turnOff(reason: .operatorOff) }
            keyWithdrawalDue = true
            keyring.wipe()
            ledger.wipe()
            postNeeded = true
        }
        updateEnvelopeMode(seals: next.seals, device: next.device)
        if isOn {
            if !(next.available && next.offered) || next.usesOtherRelay {
                // 5.1 (5): the operator turned it off; unregister without asking.
                await turnOff(reason: .operatorOff)
                return
            }
            switch next.device?.relayState ?? .none {
            case .none where awaitingBinding:
                // §4: right after turn-on the server holds no binding: the
                // relay keeps a block it cannot lift. Show it as unavailable.
                awaitingBinding = false
                unavailable = .blocked
                await turnOff(reason: .unavailable)
                return
            case .rebindNeeded, .none:
                // §4: never sign on our own; the person reconnects. A binding
                // the person asked for that has not reached the server yet
                // goes with the next registration (R1 (4)).
                needsReconnect = !awaitingBinding && !bindingDue
            case .bound, .conflict:
                awaitingBinding = false
                needsReconnect = false
            }
            noteLiveActivityState(next)
        }
        if postNeeded { await reRegister?() }
    }

    /// The envelope key, the pinned senders and the secret categories. Returns
    /// whether the server still has to learn the key.
    private func prepareSealing(_ next: RelayCapability) -> Bool {
        guard claimKeys() else { return false }
        let hadKey = keyring.state()?.recipients.isEmpty == false
        do {
            try keyring.ensureRecipientKey(now: clock())
            try keyring.update { state in
                state.trustedSenders = next.trustedSenderKeys
                for template in Self.actionTemplates where state.categories[template] == nil {
                    state.categories[template] = RelayKeyring.makeCategoryIdentifier()
                }
            }
        } catch {
            HLLog.notifications.error("push key: keychain refused the device key")
            return false
        }
        return !hadKey || next.device?.envelope != 1
    }

    // MARK: Opt-in

    /// "Not now": hides the card for good and changes nothing else.
    func answerNotNow() {
        cardAnswered = true
        defaults.set(true, forKey: key("answered"))
    }

    /// "Turn on": the person's consent. Only now is a binding key made and
    /// the relay asked to bind.
    func turnOn(liveActivityUpdates: Bool = false) async {
        guard capability.isUsable, let version = capability.consentTextVersion else { return }
        isWorking = true
        defer { isWorking = false }
        guard prepareSealing(capability) || keyring.state() != nil else { return }
        defaults.set(version, forKey: key("consentVersion"))
        defaults.set(true, forKey: key("on"))
        defaults.set(true, forKey: key("answered"))
        defaults.removeObject(forKey: key("operatorOff"))
        isOn = true
        cardAnswered = true
        operatorTurnedOff = false
        deviceLimitReached = false
        unavailable = nil
        needsReconnect = false
        freshStatementRefused = false
        if liveActivityUpdates, liveActivityUpdatesAvailable { grantLiveActivityUpdates() }
        bindingDue = true
        bindingRequest += 1
        awaitingBinding = true
        consentWithdrawalDue = false
        await reRegister?()
        await refresh()
    }

    /// The person's "Connect again" after `rebind_needed` (a new token): the
    /// same binding key, a higher `seq`, a later `iat` (#190 §4).
    func reconnect() async {
        guard isOn, capability.isUsable else { return }
        bindingDue = true
        bindingRequest += 1
        awaitingBinding = true
        needsReconnect = false
        await reRegister?()
        await refresh()
    }

    enum OffReason {
        case person
        case operatorOff
        case deviceLimit
        case unavailable
        case signOut
    }

    /// Off or withdrawn consent (#190 5.5): the direct revoke at the relay
    /// first (works with the server down), then `relayConsent.granted: false`
    /// to the server. The envelope key stays while the server seals.
    func turnOff(reason: OffReason) async {
        isWorking = true
        defer { isWorking = false }
        await revokeAtRelay()
        defaults.removeObject(forKey: key("on"))
        isOn = false
        bindingDue = false
        signedBinding = nil
        awaitingBinding = false
        needsReconnect = false
        // Withdrawing the relay consent also drops the Live Activity consent
        // and the push-to-start token on the server.
        clearLiveActivityLocally()
        await onLiveActivityConsentWithdrawn?()
        try? keyring.dropBinding()
        switch reason {
        case .operatorOff:
            operatorTurnedOff = true
            defaults.set(true, forKey: key("operatorOff"))
        case .deviceLimit:
            deviceLimitReached = true
        case .person, .unavailable, .signOut:
            break
        }
        guard reason != .signOut else { return }
        consentWithdrawalDue = true
        await reRegister?()
    }

    /// Sign-out (every logout path): revoke at the relay, then every key, the
    /// pinned senders, the ledger and envelope mode go. The device row goes on
    /// the server anyway, so nothing is posted.
    ///
    /// The account's in-memory state goes with it, so the next account on
    /// this device starts from a fresh store: the domains of the last opened
    /// `DATA_CHANGED`, the notices and the per-account answers. The flags kept
    /// per account in `defaults` stay on disk and are read again for the
    /// account that signs in next (`refresh()` → `loadLocalState()`).
    func handleSignOut() async {
        if isOn { await turnOff(reason: .signOut) }
        keyring.wipe()
        ledger.wipe()
        RelayEnvelopeMode.set(false, defaults: appGroupDefaults)
        capability = .notOffered
        consentWithdrawalDue = false
        keyWithdrawalDue = false
        bindingDue = false
        awaitingBinding = false
        freshStatementRefused = false
        isOn = false
        liveActivityUpdatesOn = false
        cardAnswered = false
        operatorTurnedOff = false
        deviceLimitReached = false
        unverifiedTapNotice = false
        lastRevokeConfirmed = nil
        needsReconnect = false
        unavailable = nil
        lastDataChange = nil
        await onSignOut?()
        deliveryCounters.wipe()
        // The next account starts with its own keys; late answers of this
        // one are dropped (D1 (1)).
        cachedAccountKey = nil
        accountEpoch += 1
    }

    /// "Stop pushes from this server" in the diagnostics: the same off.
    func stopPushesFromThisServer() async {
        await turnOff(reason: .person)
    }

    // MARK: Registration fields

    /// `pushKey`, `relayConsent` and `relayBinding` for this attempt.
    ///
    /// **R1 (4).** Building the body marks nothing as sent: the one-time
    /// parts (key withdrawal, consent withdrawal, binding, the Live Activity
    /// statements) stay due until ``registrationAccepted(_:)`` hears a 2xx
    /// for a body that carried them. A failed or skipped post sends them again.
    func registrationFields(apnsTokenHex: String) -> DeviceRegistrationPushFields {
        var fields = DeviceRegistrationPushFields()
        let version = defaults.string(forKey: key("consentVersion")) ?? capability.consentTextVersion
        if keyWithdrawalDue {
            fields.pushKey = .withdrawn
            if consentWithdrawalDue, !isOn, let version {
                fields.relayConsent = RelayConsentRecord(granted: false, textVersion: version)
            }
            return fields
        }
        guard capability.seals, let token = Data(relayHex: apnsTokenHex), claimKeys(),
              let publicKey = try? keyring.ensureRecipientKey(now: clock()) else { return fields }
        if keyring.boundToken() != token { try? keyring.update { $0.apnsToken = token } }
        fields.pushKey = .key(RelayPushKey(publicKey: publicKey.rawRepresentation.relayBase64URL))
        if consentWithdrawalDue, !isOn, let version {
            fields.relayConsent = RelayConsentRecord(granted: false, textVersion: version)
        }
        guard isOn, capability.isUsable, let instanceId = capability.instanceId, let version else { return fields }
        fields.relayConsent = RelayConsentRecord(granted: true, textVersion: version)
        fields.relayBinding = bindingIfDue(token: token, instanceId: instanceId, consentTextVersion: version)
        addLiveActivityFields(to: &fields, apnsToken: token, instanceId: instanceId)
        return fields
    }

    private func bindingIfDue(token: Data, instanceId: String, consentTextVersion: String) -> RelayBindingStatement? {
        let host = client.host
        let tokenTag = RelayEnvelope.tokenTag(of: token)
        // §4: only after the person's turn-on or reconnect, never because the
        // token, the instance or the server's state moved.
        guard bindingDue, let next = try? keyring.nextBinding(host: host) else { return nil }
        let iat = Int64(clock().timeIntervalSince1970)
        let text = RelayStatement.bind(host: host, instanceId: instanceId, tokenTag: tokenTag, seq: next.seq, iat: iat)
        guard let signature = try? RelayStatement.sign(text, with: next.key) else { return nil }
        // Stays due until the server's 2xx (R1 (4)); the record is kept now,
        // so turning off can revoke at the relay even if the answer is lost.
        signedBinding = (next.seq, bindingRequest)
        try? keyring.update { state in
            state.binding = .init(
                host: host,
                instanceId: instanceId,
                tokenTag: tokenTag,
                consentTextVersion: consentTextVersion,
                apnsToken: token
            )
        }
        return RelayBindingStatement(
            bindingKey: next.key.publicKey.rawRepresentation.relayBase64URL,
            statement: .init(instanceId: instanceId, tokenTag: tokenTag.relayHex, kind: "device", seq: next.seq, iat: iat),
            signature: signature.relayBase64URL
        )
    }

    /// #190 5.4: the `statement` and `signature` of one `liveActivityTokens[]`
    /// entry, signed at activity start. The relay sees it only inside the
    /// `end` push. `nil` while the relay is off or offers no Live Activity end.
    func activityProof(liveActivityTokenHex: String) -> RelayActivityProof? {
        guard isOn, capability.liveActivity.contains("end"), let instanceId = capability.instanceId,
              let token = keyring.bindingToken(), let laToken = Data(relayHex: liveActivityTokenHex),
              let bindingKey = keyring.bindingKey() else { return nil }
        let tokenTag = RelayEnvelope.tokenTag(of: token)
        let laTag = RelayEnvelope.tokenTag(of: laToken)
        let iat = Int64(clock().timeIntervalSince1970)
        let text = RelayStatement.activity(host: client.host, instanceId: instanceId, tokenTag: tokenTag, laTokenTag: laTag, iat: iat)
        guard let signature = try? RelayStatement.sign(text, with: bindingKey) else { return nil }
        return RelayActivityProof(
            statement: .init(instanceId: instanceId, tokenTag: tokenTag.relayHex, laTokenTag: laTag.relayHex, iat: iat),
            signature: signature.relayBase64URL
        )
    }
}
