// swiftlint:disable file_length
import CryptoKit
import Foundation
@testable import HealthLog
import Testing
import UserNotifications

// R1 (3 to 7, 10 to 12) and D1 (1 to 14): the relay's one-time parts, the
// account its keys belong to, the revoke, the sender keys, the keyring and the
// replay store, the envelope mode, and the Live Activity it starts.

// MARK: - Store based

extension PushRelayStoreTests {
    /// A store whose transport answers `status`, pinned to that transport.
    func makeStore(answering status: Int, account: AccountBox = AccountBox("acct")) -> (PushRelayStore, RecordingRelayTransport) {
        let relay = RecordingRelayTransport(status: status)
        let box = clockBox
        let store = PushRelayStore(
            api: nil,
            keyring: keyring,
            client: RelayClient(transport: relay, pinnedKeys: [relay.relayKey.publicKey], clock: { box.now }),
            defaults: defaults,
            appGroupDefaults: group,
            ledger: ledger,
            replayStore: RelayMemoryReplayStore(),
            deliveryCounters: PushDeliveryCounters(url: directory.appendingPathComponent("counters.json")),
            accountKey: { account.key },
            clock: { box.now }
        )
        return (store, relay)
    }

    @MainActor
    final class AccountBox {
        var key: String?
        init(_ key: String?) {
            self.key = key
        }
    }

    // MARK: R1 (4)

    @Test("R1 (4): the binding stays due until a 2xx; a failed post sends it again and is not read as the relay's block")
    func bindingDueUntilAccepted() async throws {
        let store = makeStore()
        await store.apply(offered())
        await store.turnOn()
        // The post failed: the body was built, never accepted.
        let lost = store.registrationFields(apnsTokenHex: apnsToken.relayHex)
        #expect(lost.relayBinding != nil)
        store.registrationFailed()
        // Before the fix the binding was marked sent here and `none` turned the relay off as blocked.
        await store.apply(offered(consent: true, relayState: .none, envelope: 1))
        #expect(store.isOn)
        #expect(store.unavailable == nil)
        #expect(!store.needsReconnect)
        let retry = try #require(store.registrationFields(apnsTokenHex: apnsToken.relayHex).relayBinding)
        #expect(retry.statement.seq > (lost.relayBinding?.statement.seq ?? 0))
        store.registrationAccepted(store.registrationFields(apnsTokenHex: apnsToken.relayHex))
        #expect(store.registrationFields(apnsTokenHex: apnsToken.relayHex).relayBinding == nil)
    }

    @Test("R1 (4): the consent withdrawal and the key withdrawal go out until the server took them")
    func withdrawalsUntilAccepted() async {
        let store = makeStore()
        await store.apply(offered())
        await store.turnOn()
        _ = fields(store)
        await store.turnOff(reason: .person)
        let first = store.registrationFields(apnsTokenHex: apnsToken.relayHex)
        #expect(first.relayConsent?.granted == false)
        store.registrationFailed()
        #expect(store.registrationFields(apnsTokenHex: apnsToken.relayHex).relayConsent?.granted == false, "sent again")
        _ = fields(store)
        #expect(store.registrationFields(apnsTokenHex: apnsToken.relayHex).relayConsent == nil)
    }

    // MARK: R1 (5)

    @Test("R1 (5): sign-out clears the relay keys of the account that leaves, though the user id is gone already")
    func signOutClearsTheRightAccount() async {
        let account = AccountBox("account-a")
        let (store, _) = makeStore(answering: 204, account: account)
        await store.apply(offered())
        await store.turnOn()
        _ = fields(store)
        #expect(defaults.bool(forKey: "hl.pushRelay.account-a.on"))
        // The logout cascade removed the user id before the relay hook ran.
        account.key = nil
        await store.handleSignOut()
        #expect(!defaults.bool(forKey: "hl.pushRelay.account-a.on"))
        #expect(!store.isOn)
    }

    // MARK: R1 (6)

    @Test("R1 (6): /me without the push block is unknown; a server that stops sealing revokes before the keys go")
    func missingPushBlockIsUnknown() async throws {
        let answer = try JSONDecoder().decode(AuthMeRelay.self, from: Data(#"{"user":{"id":"u1"}}"#.utf8))
        #expect(!answer.reportsPush)
        let sealed = try JSONDecoder().decode(AuthMeRelay.self, from: Data(#"{"push":{"device":{"envelope":1}}}"#.utf8))
        #expect(sealed.reportsPush)

        let (store, relay) = makeStore(answering: 204)
        await store.apply(offered())
        await store.turnOn()
        _ = fields(store)
        await store.apply(offered(consent: true, relayState: .bound, envelope: 1))
        #expect(keyring.bindingKey() != nil)
        // The server stopped sealing (push block present, no envelope versions).
        await store.apply(RelayCapability(device: .init(transport: .direct)))
        #expect(relay.requests.contains { $0.httpMethod == "DELETE" && $0.url?.path == "/v1/bindings/self" })
        #expect(!store.isOn)
        #expect(keyring.state()?.recipients.isEmpty ?? true)
    }

    // MARK: D1 (1)

    @Test("D1 (1): keys of another account are replaced by new ones without predecessor or pinned senders")
    func keysBelongToTheAccount() async throws {
        let account = AccountBox("account-a")
        let (store, _) = makeStore(answering: 204, account: account)
        await store.apply(sealing(envelope: 1))
        _ = fields(store)
        let keyOfA = try #require(keyring.state()?.recipients.first?.privateKey)
        #expect(keyring.state()?.owner == "account-a")
        // A reinstall without sign-out, then account B signs in; its server
        // pins another sealing key.
        account.key = "account-b"
        let otherSender = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        await store.apply(RelayCapability(senderKeys: [otherSender], envelopeVersions: [1], device: .init(transport: .direct)))
        let state = try #require(keyring.state())
        #expect(state.owner == "account-b")
        #expect(state.recipients.count == 1, "no predecessor")
        #expect(state.recipients.first?.privateKey != keyOfA)
        #expect(state.trustedSenders == [otherSender], "the senders of A are gone")
    }

    @Test("D1 (1), update path: a 1.7 item without an owner is adopted, not replaced")
    func ownerlessItemIsAdopted() throws {
        let ring = keyring
        try ring.ensureRecipientKey(now: now)
        let before = try #require(ring.state()?.recipients.first)
        #expect(try ring.claim(for: "acct") == false)
        #expect(ring.state()?.recipients.first == before)
        #expect(ring.state()?.owner == "acct")
        #expect(try ring.claim(for: "other") == true)
        #expect(ring.state()?.recipients.isEmpty == true)
    }

    @Test("D1 (1): sign-out moves the account epoch, so a late /me is dropped")
    func signOutMovesTheEpoch() async {
        let store = makeStore()
        let before = store.accountEpoch
        await store.handleSignOut()
        #expect(store.accountEpoch == before + 1)
    }

    // MARK: D1 (3)

    @Test("D1 (3): a 404 is not a confirmed revoke; it is kept and retried with the bound token")
    func revokeNotConfirmedOn404() async throws {
        let (store, relay) = makeStore(answering: 404)
        await store.apply(offered())
        await store.turnOn()
        _ = fields(store)
        // A new APNs token arrives after binding.
        let newToken = Data(repeating: 0x22, count: 32)
        store.registrationAccepted(store.registrationFields(apnsTokenHex: newToken.relayHex))
        await store.turnOff(reason: .person)
        #expect(store.lastRevokeConfirmed == false)
        let request = try #require(relay.requests.first { $0.httpMethod == "DELETE" })
        let body = try #require(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        #expect(body["token"] as? String == apnsToken.relayHex, "the token the binding names")
        let pending = try #require(keyring.state()?.pendingRevocations.first)
        #expect(pending.attempts == 1)
        // Sign-out wipes the keys, not the unconfirmed revocation.
        await store.handleSignOut()
        #expect(keyring.state()?.pendingRevocations.count == 1)
        clockBox.now = clockBox.now.addingTimeInterval(3600)
        await store.retryPendingRevocations()
        #expect(relay.requests.filter { $0.httpMethod == "DELETE" }.count == 2)
    }

    @Test("D1 (3): only a 2xx confirms; stale_timestamp names the relay's clock")
    func revokeOutcomes() {
        #expect(PushRelayStore.revokeConfirmed(.confirmed(status: 204, body: Data(), retryAfter: nil)))
        #expect(!PushRelayStore.revokeConfirmed(.confirmed(status: 404, body: Data(), retryAfter: nil)))
        #expect(!PushRelayStore.revokeConfirmed(.transportError))
        let stale = Data(#"{"error":"stale_timestamp","relayTime":1795000400}"#.utf8)
        let offset = PushRelayStore.relayClockOffset(.confirmed(status: 401, body: stale, retryAfter: nil), now: now)
        #expect(offset == 400)
    }

    // MARK: D1 (8)

    @Test("D1 (8): the registration answer switches envelope mode; only an explicit null turns it off")
    func envelopeModeFromTheAnswer() async {
        let store = makeStore()
        await store.apply(sealing())
        #expect(!RelayEnvelopeMode.isOn(defaults: group))
        store.noteRegistrationAnswer(.init(transport: .direct, envelope: 1))
        #expect(RelayEnvelopeMode.isOn(defaults: group))
        // A /me without the device block, or a device block without the key: nothing changes.
        await store.apply(RelayCapability(senderKeys: [sender.publicKey.rawRepresentation], envelopeVersions: [1]))
        #expect(RelayEnvelopeMode.isOn(defaults: group))
        store.updateEnvelopeMode(seals: true, device: .init(transport: .direct))
        #expect(RelayEnvelopeMode.isOn(defaults: group))
        store.updateEnvelopeMode(seals: true, device: RelayCapability.parseDevice(["envelope": NSNull()]))
        #expect(!RelayEnvelopeMode.isOn(defaults: group))
    }

    @Test("D1 (8): an envelope opens even while the flag is still off")
    func envelopeByPayload() async {
        let store = makeStore()
        await store.apply(sealing())
        #expect(!RelayEnvelopeMode.isOn(defaults: group))
        // A broken envelope: refused, not read as plaintext.
        #expect(await store.silentDecision(userInfo: ["e": "AAAA"]) == .refused)
    }

    // MARK: D1 (9)

    @Test("D1 (9): a relay Activity stays only with the relay on, the Live Activity consent and an account")
    func relayActivitiesNeedConsent() async {
        let account = AccountBox("acct")
        let (store, _) = makeStore(answering: 204, account: account)
        #expect(!store.allowsRelayActivities)
        await store.apply(offered())
        await store.turnOn()
        #expect(!store.allowsRelayActivities, "relay on, no Live Activity consent")
        store.grantLiveActivityUpdates()
        #expect(store.allowsRelayActivities)
        account.key = nil
        #expect(!store.allowsRelayActivities)
    }

    // MARK: Push diagnostics

    @Test("push diagnostics: silent pushes are counted received, opened and discarded; sign-out clears them")
    func silentCounters() async {
        let (store, _) = makeStore(answering: 204)
        _ = await store.silentDecision(userInfo: ["aps": ["content-available": 1]])
        _ = await store.silentDecision(userInfo: ["e": "AAAA"])
        let snapshot = store.deliveryCounters.snapshot()
        #expect(snapshot.count(.received, .silent) == 2)
        #expect(snapshot.count(.opened, .silent) == 1)
        #expect(snapshot.count(.discarded, .silent) == 1)
        #expect(snapshot.lastDeliveryAt != nil)
        await store.handleSignOut()
        #expect(store.deliveryCounters.snapshot().isEmpty)
    }
}

// MARK: - Pure rules

@Suite("Relay integrity: pure rules (R1, D1)")
struct RelayIntegrityRuleTests {
    private let slot = Date(timeIntervalSince1970: 1_800_000_000)

    private func label(slot: Date?) -> RelayLiveActivityLabel {
        RelayLiveActivityLabel(medicationId: "m1", slotInstant: slot, title: "Lisinopril", detail: "5 mg")
    }

    @Test("R1 (3): the name shows only on the Activity of its own slot; R1 (12): never with names hidden")
    func labelMatchesItsSlot() {
        let due = HealthLogDoseContentState(status: .due, countdownTarget: Int64(slot.timeIntervalSince1970))
        #expect(RelayLiveActivityLabel.shown(label(slot: slot), for: due, hideNames: false) != nil)
        let later = HealthLogDoseContentState(status: .due, countdownTarget: Int64(slot.addingTimeInterval(6 * 3600).timeIntervalSince1970))
        #expect(RelayLiveActivityLabel.shown(label(slot: slot), for: later, hideNames: false) == nil, "the name of an earlier dose")
        #expect(RelayLiveActivityLabel.shown(label(slot: nil), for: due, hideNames: false) == nil)
        #expect(RelayLiveActivityLabel.shown(label(slot: slot), for: due, hideNames: true) == nil)
        let taken = HealthLogDoseContentState(status: .taken, countdownTarget: 0, confirmed: true)
        #expect(RelayLiveActivityLabel.shown(label(slot: slot), for: taken, hideNames: false) != nil)
    }

    @Test("R1 (7): a fallback whose server reminder arrived is not planned again")
    func deliveredFallbackNotReplanned() {
        let open = [RelayFollowUps.OpenDose(medicationId: "m1", slot: slot)]
        let id = RelayFollowUps.fallbackIdentifier(medicationId: "m1", slot: slot)
        #expect(RelayFollowUps.plan(open: open, mode: .fallback, now: slot).map(\.identifier) == [id])
        #expect(RelayFollowUps.plan(open: open, mode: .fallback, now: slot, delivered: [id]).isEmpty)
    }

    @Test("R1 (7): the extension's record survives and is read back by the app")
    func deliveredRemindersFile() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("delivered-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = RelayDeliveredReminders(url: url)
        store.record(medicationId: "m1", slot: slot, now: slot)
        #expect(store.identifiers(now: slot) == [RelayFollowUps.fallbackIdentifier(medicationId: "m1", slot: slot)])
        #expect(store.identifiers(now: slot.addingTimeInterval(3 * 24 * 3600)).isEmpty, "pruned after two days")
    }

    @Test("D3 (5): no stage after missedAfter or the next slot; a missed dose is not open")
    func stagesStopAtTheWindow() {
        let missedAfter = slot.addingTimeInterval(4 * 3600)
        let open = [RelayFollowUps.OpenDose(
            medicationId: "m1",
            slot: slot,
            missedAfter: missedAfter,
            nextSlot: slot.addingTimeInterval(6 * 3600)
        )]
        let plan = RelayFollowUps.plan(open: open, mode: .followUps, now: slot)
        // Window at +1 h stays, the late stage at +5 h is past missedAfter.
        #expect(plan.count == 1)
        #expect(plan.allSatisfy { $0.fireAt < missedAfter })

        let state = ServerDoseState(state: "missed", missedAfter: missedAfter)
        let intakes = [
            MedicationIntake(id: "a", medicationId: "m1", scheduledAt: slot, status: .missed),
            MedicationIntake(id: "b", medicationId: "m1", scheduledAt: slot.addingTimeInterval(3600), status: .pending, doseState: state),
            MedicationIntake(id: "c", medicationId: "m1", scheduledAt: slot.addingTimeInterval(7200), status: .pending),
            MedicationIntake(id: "d", medicationId: "m1", scheduledAt: slot.addingTimeInterval(9000), status: .pending)
        ]
        let doses = AppContainer.relayOpenDoses(in: intakes)
        #expect(doses.map(\.slot) == [slot.addingTimeInterval(7200), slot.addingTimeInterval(9000)])
        #expect(doses.first?.nextSlot == slot.addingTimeInterval(9000))
    }

    @Test("D3 (11): a medication with reminders off gets no follow-up")
    func remindersOffNoFollowUp() {
        let intakes = [
            MedicationIntake(id: "a", medicationId: "on", scheduledAt: slot, status: .pending),
            MedicationIntake(id: "b", medicationId: "off", scheduledAt: slot, status: .pending)
        ]
        #expect(AppContainer.relayOpenDoses(in: intakes, planned: { $0 == "on" }).map(\.medicationId) == ["on"])
    }

    @Test("D1 (4): up to three sealing keys, current first, a retired one not trusted")
    func threeSenderKeys() {
        let keys = (0 ..< 4).map { _ in Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation }
        let entries: [[String: Any]] = [
            ["publicKey": keys[0].relayBase64URL, "status": "previous"],
            ["publicKey": keys[1].relayBase64URL, "status": "next"],
            ["publicKey": keys[2].relayBase64URL, "status": "current"],
            ["publicKey": keys[3].relayBase64URL, "status": "retired"]
        ]
        #expect(RelayCapability.keys(entries) == [keys[2], keys[1], keys[0]])
        let capability = RelayCapability(senderKeys: RelayCapability.keys(entries), envelopeVersions: [1])
        #expect(capability.trustedSenderKeys.count == 3)
    }

    @Test("D1 (14): a later envelope version still counts as sealed")
    func laterEnvelopeVersionSeals() {
        #expect(RelayCapability(device: .init(envelope: 2)).sealsForThisDevice)
        #expect(!RelayCapability(device: .init(envelope: nil)).sealsForThisDevice)
    }

    @Test("D1 (10): an absurd countdown is no countdown, never a trap")
    func absurdCountdown() throws {
        let json = #"{"status":"due","countdownTarget":1e300,"isOverdue":false,"confirmed":false,"pendingConfirm":false,"timeFormatRaw":"AUTO"}"#
        let state = try JSONDecoder().decode(HealthLogDoseContentState.self, from: Data(json.utf8))
        #expect(state.countdownTarget == 0)
        #expect(HealthLogDoseContentState.countdownSeconds(-5) == 0)
        #expect(HealthLogDoseContentState.countdownSeconds(.nan) == 0)
        #expect(HealthLogDoseContentState.countdownSeconds(1_795_000_600) == 1_795_000_600)
    }

    @Test("D1 (13): unknown templates show the placeholder and start nothing")
    func unknownTemplates() {
        #expect(RelayTemplate.isKnownAlert("MEDICATION_REMINDER"))
        #expect(!RelayTemplate.isKnownAlert("SOMETHING_NEW"))
        #expect(RelayTemplate.isKnownSilent("DATA_CHANGED"))
        #expect(!RelayTemplate.isKnownSilent("SOMETHING_NEW"))
    }
}

// MARK: - Keyring and replay store

@Suite("Relay integrity: keyring and replay store (D1 (5), (6), (11))")
struct RelayKeyringIntegrityTests {
    @Test("D1 (5): an item this build cannot read is never overwritten")
    func unreadableItemNotOverwritten() throws {
        let store = InMemoryKeychain()
        try store.setData(Data("not json".utf8), forKey: "relay.state.v1")
        let ring = RelayKeyring(store: store)
        #expect(ring.read() == .unreadable)
        #expect(throws: RelayKeyringError.unreadable) { try ring.ensureRecipientKey() }
        #expect(store.getData(forKey: "relay.state.v1") == Data("not json".utf8))
    }

    @Test("D1 (5): a later build's extra field and a missing field still decode")
    func tolerantDecode() throws {
        let json = #"{"formatVersion":9,"recipients":[],"futureField":{"x":1}}"#
        let state = try JSONDecoder().decode(RelayKeyringState.self, from: Data(json.utf8))
        #expect(state.formatVersion == 9)
        #expect(state.trustedSenders.isEmpty)
        let old = try JSONDecoder().decode(
            RelayKeyringState.self,
            from: Data(#"{"recipients":[],"trustedSenders":[],"categories":{}}"#.utf8)
        )
        #expect(old.formatVersion == 1)
        #expect(old.owner == nil)
    }

    @Test("D1 (11): the previous device key opens for seven days after the new one, not thirty")
    func previousKeyGrace() throws {
        let ring = RelayKeyring(store: InMemoryKeychain())
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        try ring.ensureRecipientKey(now: start)
        let rotated = start.addingTimeInterval(RelayKeyring.rotationInterval + 1)
        try ring.ensureRecipientKey(now: rotated)
        #expect(ring.recipientKeys(now: rotated.addingTimeInterval(24 * 3600)).count == 2)
        #expect(ring.recipientKeys(now: rotated.addingTimeInterval(8 * 24 * 3600)).count == 1)
    }

    @Test("D1 (6): an unreadable replay file refuses until every id it could hold expired")
    func replayFailsClosed() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("replay-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("garbage".utf8).write(to: url)
        let store = RelayFileReplayStore(url: url)
        let now = Int64(Date().timeIntervalSince1970)
        #expect(throws: RelayEnvelopeError.replayStoreFull) {
            try store.checkAndRecord(id: "01ARZ3NDEKTSV4RRFFQ69G5FAV", expiresAt: now + 60, now: now)
        }
        // Once the longest window has passed the file may be reset.
        let later = now + RelayFileReplayStore.longestWindow + 10
        try store.checkAndRecord(id: "01ARZ3NDEKTSV4RRFFQ69G5FAV", expiresAt: later + 60, now: later)
        #expect(throws: RelayEnvelopeError.replayed) {
            try store.checkAndRecord(id: "01ARZ3NDEKTSV4RRFFQ69G5FAV", expiresAt: later + 60, now: later)
        }
    }
}

// MARK: - Content privacy, diagnostics, sign-out files

@Suite("Notification content privacy, push counters and sign-out files")
struct NotificationPrivacyAndCountersTests {
    @Test("hide content: every text is neutral, actions and userInfo stay; off changes nothing")
    func contentIsNeutral() {
        let content = UNMutableNotificationContent()
        content.title = "Lisinopril"
        content.subtitle = "5 mg"
        content.body = "Take it now"
        content.categoryIdentifier = "MEDICATION_REMINDER"
        content.userInfo = ["medicationId": "m1"]
        NotificationContentPrivacy.apply(to: content, kind: .reminder, isOn: false)
        #expect(content.title == "Lisinopril")
        NotificationContentPrivacy.apply(to: content, kind: .reminder, isOn: true)
        #expect(content.title != "Lisinopril")
        #expect(content.subtitle.isEmpty)
        #expect(!content.body.contains("Take"))
        #expect(content.categoryIdentifier == "MEDICATION_REMINDER")
        #expect(content.userInfo["medicationId"] as? String == "m1")
    }

    @Test("hide content: the extension's scrub picks the kind from category and event type")
    func scrubKinds() {
        #expect(NotificationContentPrivacy.kind(category: "MEDICATION_REMINDER", eventType: nil) == .reminder)
        #expect(NotificationContentPrivacy.kind(category: "hl.secret", eventType: nil, secretMedicationCategory: "hl.secret") == .reminder)
        #expect(NotificationContentPrivacy.kind(category: nil, eventType: "MEDICATION_INTAKE_RECORDED") == .healthData)
        #expect(NotificationContentPrivacy.kind(category: "SYSTEM_ALERT", eventType: nil) == .generic)
        let original = UNMutableNotificationContent()
        original.title = "Blood pressure 160/100"
        original.userInfo = ["eventType": "THRESHOLD_NUDGE"]
        #expect(NotificationContentPrivacy.scrubbed(original, isOn: true).title != original.title)
        #expect(NotificationContentPrivacy.scrubbed(original, isOn: false).title == original.title)
    }

    @Test("hide content hides names as well; the names switch reads only itself; default off")
    func contentImpliesNames() throws {
        let defaults = try #require(UserDefaults(suiteName: "privacy.\(UUID().uuidString)"))
        #expect(!NotificationContentPrivacy.isOn(defaults: defaults))
        #expect(!LockScreenPrivacy.hideMedicationName(defaults: defaults))
        NotificationContentPrivacy.set(true, defaults: defaults)
        #expect(LockScreenPrivacy.hideMedicationName(defaults: defaults))
        #expect(!LockScreenPrivacy.hideMedicationNameSetting(defaults: defaults))
    }

    @Test("push counters: per class and event, the last delivery, wiped clean")
    func counters() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("counters-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let counters = PushDeliveryCounters(url: url)
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        counters.note(.received, pushClass: .alert, now: at)
        counters.note(.opened, pushClass: .alert, now: at)
        counters.note(.received, pushClass: .liveActivity, now: at.addingTimeInterval(5))
        counters.note(.discarded, pushClass: .liveActivity, now: at.addingTimeInterval(5))
        let snapshot = counters.snapshot()
        #expect(snapshot.count(.received, .alert) == 1)
        #expect(snapshot.count(.opened, .alert) == 1)
        #expect(snapshot.count(.discarded, .liveActivity) == 1)
        #expect(snapshot.count(.received, .silent) == 0)
        #expect(snapshot.lastDeliveryAt == at.addingTimeInterval(5))
        counters.wipe()
        #expect(counters.snapshot().isEmpty)
    }

    @Test("R1 (10): sign-out removes the App Group files about this account's doses and pushes")
    @MainActor
    func signOutRemovesDoseFiles() throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("group-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let kept = container.appendingPathComponent("widget-snapshot.json")
        try Data("{}".utf8).write(to: kept)
        for name in AppContainer.accountDoseFilenames {
            try Data("[]".utf8).write(to: container.appendingPathComponent(name))
        }
        #expect(AppContainer.accountDoseFilenames.contains("external-take-log.json"))
        #expect(AppContainer.accountDoseFilenames.contains("resolved-doses.json"))
        AppContainer.removeAccountDoseFiles(containerURL: container)
        for name in AppContainer.accountDoseFilenames {
            #expect(!FileManager.default.fileExists(atPath: container.appendingPathComponent(name).path))
        }
        #expect(FileManager.default.fileExists(atPath: kept.path))
    }
}

// MARK: - R1 (7) planner

@Suite("R1 (7): relay follow-ups are planned one at a time")
@MainActor
struct RelayFollowUpPlannerTests {
    @MainActor
    final class Log {
        var entries: [String] = []
    }

    @Test("a newer plan waits for the older one and makes it stop at its next step")
    func newerPlanWins() async {
        let planner = RelayFollowUpPlanner()
        let log = Log()
        let gate = AsyncStream<Void>.makeStream()
        let first = planner.schedule { isCurrent in
            log.entries.append("first-start")
            var iterator = gate.stream.makeAsyncIterator()
            _ = await iterator.next()
            if isCurrent() { log.entries.append("first-add") }
        }
        let second = planner.schedule { isCurrent in
            log.entries.append("second-start")
            if isCurrent() { log.entries.append("second-add") }
        }
        await Task.yield()
        gate.continuation.yield()
        gate.continuation.finish()
        await first.value
        await second.value
        #expect(!log.entries.contains("first-add"), "the older plan adds nothing once a newer one exists")
        #expect(log.entries.last == "second-add")
    }
}

// MARK: - Not deeply checked: the outbox and alreadyTaken

@Suite("Outbox: a queued take the server answers alreadyTaken is done, not a discard")
struct OutboxAlreadyTakenTests {
    private actor AlreadyTakenAPI: APIClientProtocol {
        func send<T: Decodable & Sendable>(_: APIRequest<T>) async throws -> T {
            let json = """
            {"processed":1,"inserted":0,"duplicates":0,"entries":[{"index":0,"status":"alreadyTaken",\
            "intake":{"id":"box-row"},"takenAt":"2027-01-15T07:12:00Z","takenVia":"INTEGRATION"}]}
            """
            return try JSONDecoder.hlDefault.decode(T.self, from: Data(json.utf8))
        }

        func sendVoid(_: APIRequest<EmptyPayload>) async throws {}

        func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
            throw HLError.unknown("not stubbed")
        }
    }

    @Test("the replay returns normally")
    func replayAlreadyTaken() async throws {
        let api = AlreadyTakenAPI()
        let repo = try MedicationsRepository(api: api, outbox: OutboxQueue(inMemory: true))
        let entry = MedicationsRepository.BulkIntakeEntry(
            medicationId: "m1", scheduledFor: Date(timeIntervalSince1970: 1_800_000_000),
            takenAt: Date(timeIntervalSince1970: 1_800_000_000), skipped: false, idempotencyKey: "k1"
        )
        try await repo.replayReminderIntake(entry: entry, idempotencyKey: "k1")
    }
}
