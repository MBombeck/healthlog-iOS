import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// **1.4 B4 — one card, one zone.**
///
/// The card projects its "Nächste Einnahme" in the account zone the server
/// keeps (`computeNextDose(timeZone:)`, the `/me` zone), and the server grades
/// the dose window in that zone too. The window verdict ("Jetzt fällig",
/// "Überfällig") used to be read in the device zone instead. For anyone whose
/// phone is not in the account zone (travel, an account zone set on the web)
/// the card then said "due now" at the device's 08:00 while its own next-dose
/// line pointed at the account's 08:00, hours apart.
///
/// Each case names the instant and the zone it judges in, so the verdict does
/// not depend on the zone the test host runs in: New York and Tokyo are
/// thirteen hours apart, and at most one of them can be the host's.
@Suite("MedicationCard — window verdict in the account zone")
struct MedicationCardProfileZoneTests {
    private static let newYork = TimeZone(identifier: "America/New_York") ?? .gmt
    private static let tokyo = TimeZone(identifier: "Asia/Tokyo") ?? .gmt

    /// 2026-05-20 at `hour:minute` on the wall clock of `zone`.
    private static func instant(_ zone: TimeZone, hour: Int, minute: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: 2026, month: 5, day: 20, hour: hour, minute: minute))
            ?? .distantPast
    }

    /// A daily 08:00 dose with its 08:00 to 09:00 window, nothing taken today
    /// and no server instant, so the verdict is the window arithmetic alone.
    private static let morningDose = Medication(
        id: "med-profile-zone",
        name: "Lisinopril",
        dose: "5 mg",
        schedule: MedicationSchedule(entries: [ScheduleEntry(
            cadence: .daily,
            timesOfDay: [TimeOfDay(hour: 8, minute: 0)],
            windowStart: TimeOfDay(hour: 8, minute: 0),
            windowEnd: TimeOfDay(hour: 9, minute: 0)
        )]),
        todayEventCount: 0,
        active: true
    )

    @Test("08:30 in the account zone is due now, whatever the device zone")
    func dueInTheAccountZone() {
        let now = Self.instant(Self.newYork, hour: 8, minute: 30)
        #expect(MedicationCard.resolveWindowStatus(
            medication: Self.morningDose, timeZone: Self.newYork, now: now
        ) == .inWindow)
    }

    @Test("The same instant judged in an account zone thirteen hours away is past every window")
    func sameInstantOtherAccountZone() {
        // 08:30 in New York is 21:30 in Tokyo: twelve and a half hours past the
        // 09:00 window end, beyond the 240-minute "missed" horizon.
        let now = Self.instant(Self.newYork, hour: 8, minute: 30)
        #expect(MedicationCard.resolveWindowStatus(
            medication: Self.morningDose, timeZone: Self.tokyo, now: now
        ) == nil)
    }

    @Test("Verdict and next-dose line read the same zone")
    func verdictAgreesWithNextDoseLine() {
        // 10:30 in the account zone: the 08:00 dose is late, and the next-dose
        // line points at tomorrow 08:00 in that same zone.
        let now = Self.instant(Self.tokyo, hour: 10, minute: 30)
        #expect(MedicationCard.resolveWindowStatus(
            medication: Self.morningDose, timeZone: Self.tokyo, now: now
        ) == .late)
        let next = MedicationCard.computeNextDose(medication: Self.morningDose, timeZone: Self.tokyo, now: now)
        #expect(next == Self.instant(Self.tokyo, hour: 8, minute: 0).addingTimeInterval(24 * 3600))
    }
}
