// swiftlint:disable force_unwrapping
import CryptoKit
import Foundation
@testable import HealthLog
import Testing
import UserNotifications

/// Round 2 of #190 and #191: `ui.level`, the dose reminder and its discreet
/// form, `DATA_CHANGED`, the follow-up stages and the server-mode fallback,
/// the secret category, the stale Live Activity, and the reserved class.
@Suite("Push relay: templates, follow-ups and stale state")
struct RelayRoundTwoRulesTests {
    let token = Data(repeating: 0x0F, count: 32)
    let sender = Curve25519.KeyAgreement.PrivateKey()
    let device = Curve25519.KeyAgreement.PrivateKey()
    let now: Int64 = 1_795_000_000

    func plaintext(type: String, extra: [String: Any] = [:]) throws -> RelayPlaintext {
        var json: [String: Any] = ["v": 1, "t": type, "id": RelayTestSealer.ulid(40), "iat": now, "exp": now + 600]
        json.merge(extra) { $1 }
        let envelope = try RelayTestSealer.seal(json, to: device.publicKey, from: sender, apnsToken: token, pushClass: .alert)
        return try RelayEnvelope.open(
            envelope,
            recipientKeys: [device],
            trustedSenders: [sender.publicKey],
            apnsToken: token,
            expectedClass: .alert,
            now: now
        )
    }

    // MARK: §8 ui.level

    @Test("§8: time-sensitive only for the four templates; timeSensitive or anything else is absent")
    func levels() {
        for type in ["MEDICATION_REMINDER", "SYSTEM_ALERT", "SECURITY_ALERT", "REMINDER"] {
            #expect(RelayTemplate.level("time-sensitive", type: type) == .timeSensitive)
        }
        #expect(RelayTemplate.level("time-sensitive", type: "MEDICATION_INTAKE_RECORDED") == .active)
        #expect(RelayTemplate.level("timeSensitive", type: "MEDICATION_REMINDER") == nil)
        #expect(RelayTemplate.level("critical", type: "SECURITY_ALERT") == nil)
        #expect(RelayTemplate.level("passive", type: "X") == .passive)
        #expect(RelayNotificationRebuilder.interruptionLevel("time-sensitive", type: "PERSONAL_RECORD") == .active)
        #expect(RelayNotificationRebuilder.interruptionLevel("time-sensitive", type: "SECURITY_ALERT") == .timeSensitive)
    }

    // MARK: §7 dose reminders

    @Test("§7: the discreet REMINDER with a medication and a slot acts as a dose reminder")
    func discreetReminder() throws {
        let reminder = try plaintext(type: "REMINDER", extra: [
            "d": ["medicationId": "m1", "scheduleId": "s1", "date": "2026-11-21", "scheduledAt": "2026-11-21T07:00:00.000Z"],
            "ui": ["category": "REMINDER", "thread": "REMINDER", "level": "time-sensitive"]
        ])
        #expect(RelayTemplate.isDoseReminder(reminder))
        let info = RelayNotificationRebuilder.userInfo(from: reminder)
        #expect(info["eventType"] as? String == "MEDICATION_REMINDER")
        #expect(info["scheduledFor"] as? String == "2026-11-21T07:00:00.000Z")
        let content = RelayNotificationRebuilder.content(
            for: reminder,
            placeholderTitle: "P",
            placeholderBody: "B",
            secretCategory: { $0 == "MEDICATION_REMINDER" ? "hl.secret" : nil }
        )
        #expect(content.categoryIdentifier == "hl.secret")
        #expect(content.interruptionLevel == .timeSensitive)
        let slot = try #require(RelayFollowUps.slot(of: reminder))
        #expect(slot.medicationId == "m1")
    }

    @Test("§7: a discreet REMINDER without a medication is no dose reminder and gets no actions")
    func discreetOther() throws {
        let other = try plaintext(type: "REMINDER", extra: ["ui": ["category": "REMINDER", "level": "time-sensitive"]])
        #expect(!RelayTemplate.isDoseReminder(other))
        let content = RelayNotificationRebuilder.content(for: other, placeholderTitle: "P", placeholderBody: "B") { _ in "hl.secret" }
        #expect(content.categoryIdentifier.isEmpty)
        #expect(content.interruptionLevel == .timeSensitive)
    }

    @Test("a SECURITY_ALERT is shown time-sensitive and without actions")
    func securityAlert() throws {
        let alert = try plaintext(type: "SECURITY_ALERT", extra: [
            "d": ["securityKind": "new_device"],
            "n": ["title": "New sign-in", "body": "A new device signed in."],
            "ui": ["category": "SECURITY_ALERT", "thread": "SECURITY_ALERT", "level": "time-sensitive", "sound": "default"]
        ])
        let content = RelayNotificationRebuilder.content(for: alert, placeholderTitle: "P", placeholderBody: "B") { _ in "hl.secret" }
        #expect(content.title == "New sign-in")
        #expect(content.interruptionLevel == .timeSensitive)
        #expect(content.categoryIdentifier.isEmpty)
        #expect(content.userInfo["url"] as? String == "/settings/security")
        #expect(content.userInfo["securityKind"] as? String == "new_device")
    }

    // MARK: #191 DATA_CHANGED

    @Test("DATA_CHANGED: domains read tolerantly; reloads at most every two minutes")
    func dataChanged() throws {
        let change = try RelayDataChange(plaintext: plaintext(
            type: "DATA_CHANGED",
            extra: ["d": ["domains": ["sleep", "measurements", "sleep"]]]
        ))
        #expect(change.domains == ["measurements", "sleep"])
        let other = try RelayDataChange(plaintext: plaintext(
            type: "DATA_CHANGED",
            extra: ["d": ["domains": ["nutrition", "workouts"], "changedAt": "2026-11-21T07:12:00.000Z"]]
        ))
        #expect(other.domains == ["nutrition", "workouts"])
        let discreetSecurity = try plaintext(type: "REMINDER", extra: ["d": ["securityKind": "passkey_added"]])
        #expect(RelayTemplate.isSecurityAlert(discreetSecurity))
        #expect(RelayNotificationRebuilder.userInfo(from: discreetSecurity)["eventType"] as? String == "SECURITY_ALERT")
        let start = Date(timeIntervalSince1970: TimeInterval(now))
        #expect(RelayDataChange.shouldReload(lastReload: nil, now: start))
        #expect(!RelayDataChange.shouldReload(lastReload: start, now: start.addingTimeInterval(119)))
        #expect(RelayDataChange.shouldReload(lastReload: start, now: start.addingTimeInterval(120)))
    }

    // MARK: 5.6 follow-ups and fallback

    @Test("5.6: a client device with the relay on plans two follow-up stages, a server device a fallback, others nothing")
    func followUps() {
        let slot = Date(timeIntervalSince1970: TimeInterval(now))
        let open = [(medicationId: "m1", slot: slot)]
        #expect(RelayFollowUps.mode(relayOn: false, delivery: .delivery(.client)) == .none)
        #expect(RelayFollowUps.mode(relayOn: true, delivery: DeviceMedicationDeliveryReport.none) == .none)
        let client = RelayFollowUps.plan(open: open, mode: .followUps, now: slot)
        #expect(client.map(\.fireAt) == [slot.addingTimeInterval(3600), slot.addingTimeInterval(3600 + 240 * 60)])
        #expect(client.allSatisfy { $0.identifier.hasPrefix(RelayFollowUps.prefix) })
        let server = RelayFollowUps.plan(open: open, mode: .fallback, now: slot)
        #expect(server.map(\.fireAt) == [slot.addingTimeInterval(600)])
        #expect(server.first?.identifier == RelayFollowUps.fallbackIdentifier(medicationId: "m1", slot: slot))
        #expect(RelayFollowUps.plan(open: open, mode: .fallback, now: slot.addingTimeInterval(601)).isEmpty, "only ahead")
        let many = (0 ..< 20).map { (medicationId: "m\($0)", slot: slot) }
        #expect(RelayFollowUps.plan(open: many, mode: .followUps, now: slot).count == RelayFollowUps.maxRequests)
    }

    @Test("the follow-up content carries the slot, so a recorded dose withdraws it")
    @MainActor
    func followUpWithdrawn() {
        let slot = MedicationReminderReopen.Slot(medicationId: "m1", scheduledAt: Date(timeIntervalSince1970: TimeInterval(now)))
        let reminder = ResolvedReminderPlan.reminder(
            identifier: RelayFollowUps.identifier(stage: "window", medicationId: "m1", slot: slot.scheduledAt),
            userInfo: NotificationService.medicationUserInfo(medicationId: "m1", scheduleId: nil, scheduledFor: slot.scheduledAt),
            firesAt: slot.scheduledAt.addingTimeInterval(3600)
        )
        #expect(ResolvedReminderPlan.isResolved(reminder, by: [ResolvedDose(medicationId: "m1", slotAt: slot.scheduledAt)]))
    }

    // MARK: 5.3 secret category

    @Test("5.3: local dose reminders use the secret category only in envelope mode")
    func secretCategory() {
        #expect(RelayCategoryIdentity.medication(envelopeMode: false) { "hl.secret" } == "MEDICATION_REMINDER")
        #expect(RelayCategoryIdentity.medication(envelopeMode: true) { "hl.secret" } == "hl.secret")
        #expect(RelayCategoryIdentity.medication(envelopeMode: true) { nil } == "MEDICATION_REMINDER")
    }

    // MARK: 5.4 stale Live Activity

    @Test("5.4 (20:09): the stale date is missedAfter; without the window, an hour after the due time, never earlier")
    func staleDate() {
        let due = Date(timeIntervalSince1970: TimeInterval(now))
        let band = ServerDoseState(
            state: "upcoming",
            dueAt: due,
            overdueSince: due.addingTimeInterval(1800),
            slotInstant: due,
            missedAfter: due.addingTimeInterval(4 * 3600)
        )
        #expect(MedicationLiveActivityPlan.staleDate(countdownTarget: due, now: due.addingTimeInterval(-60), band: band)
            == due.addingTimeInterval(4 * 3600))
        #expect(MedicationLiveActivityPlan.staleDate(countdownTarget: due, now: due.addingTimeInterval(-60), band: nil)
            == due.addingTimeInterval(MedicationLiveActivityPlan.intakeWindow))
        let late = due.addingTimeInterval(5 * 3600)
        #expect(MedicationLiveActivityPlan.staleDate(countdownTarget: due, now: late, band: band) == late)
    }

    @Test("20:09: local state changes are planned on dueAt, overdueSince and missedAfter, the overdue look from the same window")
    func transitions() {
        let due = Date(timeIntervalSince1970: TimeInterval(now))
        let band = ServerDoseState(
            state: "upcoming",
            dueAt: due,
            overdueSince: due.addingTimeInterval(1800),
            missedAfter: due.addingTimeInterval(4 * 3600)
        )
        #expect(MedicationLiveActivityPlan.nextTransition(band: band, now: due.addingTimeInterval(-10)) == due)
        #expect(MedicationLiveActivityPlan.nextTransition(band: band, now: due.addingTimeInterval(10)) == due.addingTimeInterval(1800))
        #expect(MedicationLiveActivityPlan.nextTransition(band: band, now: due.addingTimeInterval(2000)) == due
            .addingTimeInterval(4 * 3600))
        #expect(MedicationLiveActivityPlan.nextTransition(band: band, now: due.addingTimeInterval(5 * 3600)) == nil)
        #expect(MedicationLiveActivityPlan.nextTransition(band: nil, now: due) == nil)
        #expect(!MedicationLiveActivityPlan.isOverdue(band: band, now: due.addingTimeInterval(60), fallback: true))
        #expect(MedicationLiveActivityPlan.isOverdue(band: band, now: due.addingTimeInterval(1800), fallback: false))
        #expect(MedicationLiveActivityPlan.isOverdue(band: nil, now: due, fallback: true), "no window: the plan's verdict")
    }

    @Test("20:09: the first follow-up fires at overdueSince; without it the fallback window")
    func followUpsAtOverdueSince() {
        let slot = Date(timeIntervalSince1970: TimeInterval(now))
        let closes = slot.addingTimeInterval(45 * 60)
        let plan = RelayFollowUps.plan(
            open: [RelayFollowUps.OpenDose(medicationId: "m1", slot: slot, overdueSince: closes)],
            mode: .followUps,
            now: slot
        )
        #expect(plan.map(\.fireAt) == [closes, closes.addingTimeInterval(240 * 60)])
        let intake = MedicationIntake(
            id: "i1",
            medicationId: "m1",
            scheduledAt: slot,
            status: .pending,
            doseState: ServerDoseState(state: "due", dueAt: slot, overdueSince: closes, missedAfter: slot.addingTimeInterval(3 * 3600))
        )
        #expect(AppContainer.relayOpenDoses(in: [intake]).first?.overdueSince == closes)
    }

    // MARK: §10 reserved class

    @Test("§10: the class byte 0x03 is reserved; no class of the device carries it")
    func reservedClass() {
        #expect(!RelayPushClass.allCases.map(\.classByte).contains(0x03))
        #expect(RelayGoldenVectorTests.vectors.envelopes
            .contains { $0.name == "reservedLiveActivityClass" && $0.expect == "classMismatch" })
    }
}
