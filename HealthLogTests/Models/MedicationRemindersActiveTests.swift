import Foundation
@testable import HealthLog
import Testing

/// **W3 (iOS 1.3, #126 P2, server v1.42.2) — `remindersActive`.**
///
/// The server publishes, on `MedicationListEntry` and `MedicationDetail`
/// (`docs/api/openapi.yaml` at tag `v1.42.2`), whether it sends dose reminders
/// for a medication: `notificationsEnabled && !autoMarkTaken && active &&
/// trackIntake && !asNeeded && course not ended` (`sendsMedicationReminders`,
/// `src/lib/medications/auto-mark-taken.ts`). A client that arms local
/// reminders arms them from this. Before 1.3 the app armed from
/// `notificationsEnabled` alone, so a supplement set to "mark as taken
/// automatically" still reminded on the phone.
///
/// The fixtures are the same daily 08:00 list entry the #1040 suite uses, with
/// the two v1.42.2 fields added. `autoMarkTaken: true` and
/// `notificationsEnabled: true` is exactly the reported case: every local flag
/// says "remind", only the server's answer says no.
@Suite("v1.42.2 — local medication reminders follow remindersActive")
struct MedicationRemindersActiveTests {
    static func json(remindersActive: Bool?, autoMarkTaken: Bool = true) -> String {
        let base = MedicationCourseStatusV1394Tests.json(courseStatus: "CURRENT", intakeActionable: true)
        let added = (remindersActive.map { #""remindersActive":\#($0),"# } ?? "")
            + #""autoMarkTaken":\#(autoMarkTaken),"autoMarkTakenSince":null,"#
        return base.replacingOccurrences(of: #""trackIntake":true,"#, with: #""trackIntake":true,"# + added)
    }

    static func decode(_ json: String) throws -> Medication {
        try MedicationCourseStatusV1394Tests.decode(json)
    }

    static func autoMarked() throws -> Medication {
        try decode(json(remindersActive: false))
    }

    static func reminding() throws -> Medication {
        try decode(json(remindersActive: true, autoMarkTaken: false))
    }

    static func olderServer() throws -> Medication {
        try decode(json(remindersActive: nil, autoMarkTaken: false))
    }

    // MARK: - Decode

    @Test("remindersActive decodes verbatim and is absent from an older server")
    func decodes() throws {
        #expect(try Self.autoMarked().remindersActive == false)
        #expect(try Self.reminding().remindersActive == true)
        #expect(try Self.olderServer().remindersActive == nil)
    }

    @Test("the cached medication keeps remindersActive")
    func cacheRoundTrip() throws {
        let medication = try Self.autoMarked()
        let data = try JSONEncoder().encode(medication)
        let restored = try JSONDecoder().decode(Medication.self, from: data)
        #expect(restored.remindersActive == false)
    }

    @Test("copies keep remindersActive")
    func copiesKeepIt() throws {
        let medication = try Self.autoMarked()
        #expect(medication.replacingSchedule(medication.schedule).remindersActive == false)
        #expect(medication.withAppleHealthProvenance(externalId: "x").remindersActive == false)
    }

    // MARK: - The planner

    @Test("an auto-marked supplement arms no local reminder")
    func autoMarkedDoesNotRemind() throws {
        let medication = try Self.autoMarked()
        #expect(medication.notificationsEnabled)
        #expect(!MedicationReminderDeliveryPolicy.plansLocalReminder(for: medication))
    }

    @Test("remindersActive true arms, and an older server keeps the old rule")
    func remindingAndOlderServerArm() throws {
        #expect(try MedicationReminderDeliveryPolicy.plansLocalReminder(for: Self.reminding()))
        #expect(try MedicationReminderDeliveryPolicy.plansLocalReminder(for: Self.olderServer()))
    }

    /// Coordinator request (W4 overlap): `autoMarkTaken` on its own also stops
    /// local reminders, even where `remindersActive` is missing or says true.
    @Test("autoMarkTaken alone stops local reminders", arguments: [Bool?.none, true])
    func autoMarkTakenAloneStopsReminders(remindersActive: Bool?) throws {
        let medication = try Self.decode(Self.json(remindersActive: remindersActive, autoMarkTaken: true))
        #expect(medication.remindersActive == false)
        #expect(!MedicationReminderDeliveryPolicy.plansLocalReminder(for: medication))
        #expect(!CriticalMedAlarmRouting.isAlarmEligible(
            medication: medication,
            alarmEnabled: { _ in true },
            authorized: true
        ))
    }

    @Test("the device does not claim delivery for a medication the server keeps quiet")
    func noClaimForAutoMarked() throws {
        #expect(try !MedicationReminderDeliveryPolicy.deliversLocally(
            notificationsAuthorized: true,
            medications: [Self.autoMarked()]
        ))
    }

    @Test("an auto-marked supplement never gets a critical alarm")
    func noCriticalAlarm() throws {
        #expect(try !CriticalMedAlarmRouting.isAlarmEligible(
            medication: Self.autoMarked(),
            alarmEnabled: { _ in true },
            authorized: true
        ))
        #expect(try CriticalMedAlarmRouting.isAlarmEligible(
            medication: Self.reminding(),
            alarmEnabled: { _ in true },
            authorized: true
        ))
    }

    #if canImport(SpeziScheduler) && canImport(UserNotifications)
        @Test("reminders armed before auto-mark was switched on are purged on the next reconcile")
        @MainActor
        func armedRemindersArePurged() throws {
            let now = Date()
            #expect(try !MedicationsSchedulerModule.desiredTaskIDs(for: [Self.reminding()], now: now).isEmpty)
            #expect(try MedicationsSchedulerModule.desiredTaskIDs(for: [Self.autoMarked()], now: now).isEmpty)
        }
    #endif
}
