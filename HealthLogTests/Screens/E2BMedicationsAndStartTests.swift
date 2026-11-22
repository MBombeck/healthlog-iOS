import Foundation
@testable import HealthLog
import SwiftUI
import Testing

/// The medication page and Home in build 309: the supply headline names only
/// figures the server sent, the object card falls back to the history's newest
/// take, the history rows report dose and grade, Home names today's
/// medications once and the intake sheet counts what Home counts as open.
@Suite("E2 medications and start")
struct E2BMedicationsAndStartTests {
    private static let now = Date(timeIntervalSince1970: 1_790_000_000)

    // MARK: Supply headline

    private static func summary(dosesTotal: Double) -> MedicationSupplySummary {
        MedicationSupplySummary(unitsRemaining: 28, unitsTotal: dosesTotal, dosesRemaining: 28, dosesTotal: dosesTotal, expiredUnits: 0)
    }

    @Test("Without a capacity the headline names the doses left alone, no dash")
    func supplyWithoutCapacity() {
        #expect(MedicationInventorySection.summaryLine(stockDosesRemaining: 28, summary: nil) == .remaining("28"))
        #expect(MedicationInventorySection.summaryLine(stockDosesRemaining: 4, summary: Self.summary(dosesTotal: 0)) == .remaining("4"))
    }

    @Test("With the server's capacity the headline reads left of total")
    func supplyWithCapacity() {
        #expect(
            MedicationInventorySection.summaryLine(stockDosesRemaining: 28, summary: Self.summary(dosesTotal: 30))
                == .remainingOfTotal("28", "30")
        )
    }

    @Test("Without a count there is no headline sentence, whatever the capacity")
    func supplyUnknown() {
        #expect(MedicationInventorySection.summaryLine(stockDosesRemaining: nil, summary: nil) == .unknown)
        #expect(MedicationInventorySection.summaryLine(stockDosesRemaining: nil, summary: Self.summary(dosesTotal: 30)) == .unknown)
        #expect(MedicationInventorySection.summaryLine(stockDosesRemaining: -2, summary: nil) == .unknown)
    }

    @Test("A real zero stays a zero")
    func supplyExhausted() {
        #expect(MedicationInventorySection.summaryLine(stockDosesRemaining: 0, summary: Self.summary(dosesTotal: 30)) == .remainingOfTotal(
            "0",
            "30"
        ))
    }

    // MARK: Last take

    private static func ledgerRow(
        _ status: String,
        hoursAgo: Double,
        takenAt: Date? = nil,
        dose: String? = nil
    ) -> MedicationDoseHistoryRow {
        let at = now.addingTimeInterval(-hoursAgo * 3600)
        return MedicationDoseHistoryRow(
            kind: status == "ad_hoc" ? "ad_hoc" : "slot",
            at: at,
            timeOfDay: nil,
            statusRaw: status,
            intake: MedicationDoseHistoryRow.Intake(
                id: "i\(hoursAgo)",
                scheduledFor: at,
                takenAt: takenAt,
                skipped: status == "skipped",
                doseTaken: dose
            )
        )
    }

    @Test("The newest take in the ledger, never a skip or a miss")
    func latestTakeFromLedger() {
        let taken = Self.now.addingTimeInterval(-30 * 3600)
        let rows = [
            Self.ledgerRow("skipped", hoursAgo: 2),
            Self.ledgerRow("missed", hoursAgo: 5),
            Self.ledgerRow("taken_late", hoursAgo: 31, takenAt: taken),
            Self.ledgerRow("taken_on_time", hoursAgo: 80, takenAt: Self.now.addingTimeInterval(-80 * 3600))
        ]
        #expect(MedicationHeroSection.latestTake(ledger: rows, intakes: []) == taken)
    }

    @Test("Without a ledger the intake pages give the newest take")
    func latestTakeFromIntakes() {
        let older = Self.now.addingTimeInterval(-48 * 3600)
        let newer = Self.now.addingTimeInterval(-24 * 3600)
        let intakes = [
            PaginatedIntakeEvent(id: "a", takenAt: older, skipped: false, scheduledFor: older),
            PaginatedIntakeEvent(id: "b", takenAt: newer, skipped: false, scheduledFor: newer),
            PaginatedIntakeEvent(id: "c", takenAt: nil, skipped: true, scheduledFor: Self.now)
        ]
        #expect(MedicationHeroSection.latestTake(ledger: nil, intakes: intakes) == newer)
        #expect(MedicationHeroSection.latestTake(ledger: [], intakes: intakes) == nil)
    }

    @Test("The object card shows the newer of the medication's and the history's last take")
    func lastTakenPicksTheNewer() {
        let row = Self.now.addingTimeInterval(-3600)
        let history = Self.now.addingTimeInterval(-60)
        #expect(MedicationHeroSection.lastTaken(nil, latestHistoryTake: history) == history)
        #expect(MedicationHeroSection.lastTaken(row, latestHistoryTake: history) == history)
        #expect(MedicationHeroSection.lastTaken(row, latestHistoryTake: nil) == row)
        #expect(MedicationHeroSection.lastTaken(nil, latestHistoryTake: nil) == nil)
    }

    @Test("A known ingredient is named from the catalogue, an unknown one as sent")
    func ingredientLabel() {
        #expect(!MedicationHeroSection.innLabel("Dulaglutide").isEmpty)
        #expect(MedicationHeroSection.innLabel("Retatrutide") == "Retatrutide")
    }

    // MARK: Plan in the object card

    @Test("No times and no weekdays is no plan fact")
    func planWithoutComponents() {
        #expect(MedicationPlanText.line(MedicationSchedule(times: [])) == nil)
        #expect(MedicationPlanText.doseWindows(MedicationSchedule(times: [])) == nil)
    }

    @Test("A plan with a time names it")
    func planWithTime() throws {
        let line = try #require(MedicationPlanText.line(MedicationSchedule(times: [TimeOfDay(hour: 8, minute: 0)])))
        #expect(!line.isEmpty)
    }

    // MARK: History rows

    @Test("A taken row reports the recorded dose, else the configured one")
    func takenRowDose() {
        let recorded = Self.ledgerRow("taken_on_time", hoursAgo: 1, takenAt: Self.now, dose: "5 mg")
        let plain = Self.ledgerRow("taken_late", hoursAgo: 1, takenAt: Self.now)
        #expect(LedgerHistoryRow.shownDose(row: recorded, scheduledDose: "10 mg") == "5 mg")
        #expect(LedgerHistoryRow.shownDose(row: plain, scheduledDose: "10 mg") == "10 mg")
        #expect(LedgerHistoryRow.shownDose(row: plain, scheduledDose: " ") == nil)
    }

    @Test("A skip, a miss or a planned slot took nothing and shows no dose")
    func untakenRowsShowNoDose() {
        for status in ["skipped", "missed", "upcoming"] {
            #expect(LedgerHistoryRow.shownDose(row: Self.ledgerRow(status, hoursAgo: 1), scheduledDose: "10 mg") == nil)
        }
    }

    @Test("Only a late take and a missed dose carry a colour")
    func statusLineTones() {
        #expect(LedgerHistoryRow.statusLine(.takenOnTime)?.tone == .neutral)
        #expect(LedgerHistoryRow.statusLine(.adHoc)?.tone == .neutral)
        #expect(LedgerHistoryRow.statusLine(.skipped)?.tone == .neutral)
        #expect(LedgerHistoryRow.statusLine(.upcoming)?.tone == .neutral)
        #expect(LedgerHistoryRow.statusLine(.takenLate)?.tone == .warning)
        #expect(LedgerHistoryRow.statusLine(.missed)?.tone == .critical)
        #expect(LedgerHistoryRow.statusLine(nil) == nil)
    }

    @Test("An older server's intake rows show the dose only for a take")
    func legacyRowDose() {
        let taken = PaginatedIntakeEvent(id: "t", takenAt: Self.now, skipped: false, scheduledFor: Self.now)
        let skipped = PaginatedIntakeEvent(id: "s", takenAt: nil, skipped: true, scheduledFor: Self.now)
        let open = PaginatedIntakeEvent(id: "o", takenAt: nil, skipped: false, scheduledFor: Self.now)
        #expect(IntakeHistoryRow.shownDose(event: taken, dose: " 1,5 mg ") == "1,5 mg")
        #expect(IntakeHistoryRow.shownDose(event: taken, dose: "") == nil)
        #expect(IntakeHistoryRow.shownDose(event: skipped, dose: "1,5 mg") == nil)
        #expect(IntakeHistoryRow.shownDose(event: open, dose: "1,5 mg") == nil)
    }

    // MARK: Home

    private static func digest(_ facts: String) throws -> DailyDigest {
        try JSONDecoder.hlDefault.decode(
            DailyDigest.self,
            from: Data((#"{"date":"2026-11-13","lead":"Ein ruhiger Tag.","score":{"value":71,"band":"green","delta":null},"today":["# +
                    facts + "]}").utf8)
        )
    }

    @Test("Home leaves the compliance card out while the hero names the medications")
    @MainActor
    func heroNamesMedications() throws {
        let withMeds = try Self.digest(#"{"kind":"medication","label":"Medikamente","value":"2 von 3 genommen","href":null}"#)
        let withModule = try Self
            .digest(#"{"kind":"medications","label":"Medikamente","value":"2 von 3","href":"/medications","moduleKey":"medications"}"#)
        let withoutMeds = try Self.digest(#"{"kind":"sleep","label":"Letzte Nacht","value":"7 Std.","href":null}"#)
        #expect(ComplianceRingCard.heroNamesMedications(withMeds))
        #expect(ComplianceRingCard.heroNamesMedications(withModule))
        #expect(!ComplianceRingCard.heroNamesMedications(withoutMeds))
        #expect(!ComplianceRingCard.heroNamesMedications(nil))
    }

    // MARK: Intake sheet

    private static let daily = MedicationWireDTO(
        id: "med_daily_e2b",
        name: "Lisinopril",
        dose: "10 mg",
        active: true,
        schedules: [MedicationScheduleDTO(windowStart: "08:00", timesOfDay: ["08:00"])],
        asNeeded: false
    ).toDomain()

    private static func pending(_ id: String, minutesFromNow: Double) -> MedicationIntake {
        MedicationIntake(
            id: id,
            medicationId: daily.id,
            scheduledAt: now.addingTimeInterval(minutesFromNow * 60),
            takenAt: nil,
            status: .pending
        )
    }

    @Test("A slot still to come today is named as later, not as due")
    func laterSlotsAreNamed() {
        let options = MedicationQuickIntakeOptions.resolve(
            medications: [Self.daily],
            intakes: [Self.pending("later", minutesFromNow: 140)],
            now: Self.now
        )
        #expect(options.due.isEmpty)
        #expect(options.isEmpty, "nothing to log yet")
        #expect(options.later.map(\.id) == ["later"])
    }

    @Test("A due slot stays due and is not listed as later")
    func dueSlotIsNotLater() {
        let options = MedicationQuickIntakeOptions.resolve(
            medications: [Self.daily],
            intakes: [Self.pending("due", minutesFromNow: -10), Self.pending("later", minutesFromNow: 60)],
            now: Self.now
        )
        #expect(options.due.map(\.id) == ["due"])
        #expect(options.later.map(\.id) == ["later"])
    }

    @Test("Nothing to log is a short sheet; something to log may grow")
    @MainActor
    func sheetSize() {
        let empty = MedicationQuickIntakeOptions.resolve(medications: [Self.daily], intakes: [], now: Self.now)
        let due = MedicationQuickIntakeOptions.resolve(
            medications: [Self.daily],
            intakes: [Self.pending("due", minutesFromNow: -10)],
            now: Self.now
        )
        #expect(MedicationQuickIntakeSheet.size(for: empty) == .compact)
        #expect(MedicationQuickIntakeSheet.size(for: due) == .standard)
    }

    @Test("The sheet says nothing is open only when nothing is")
    @MainActor
    func emptyNoteKey() {
        let none = MedicationQuickIntakeOptions.resolve(medications: [Self.daily], intakes: [], now: Self.now)
        let later = MedicationQuickIntakeOptions.resolve(
            medications: [Self.daily],
            intakes: [Self.pending("later", minutesFromNow: 60)],
            now: Self.now
        )
        #expect(MedicationQuickIntakeSheet.emptyNoteKey(for: none) == LocalizedStringKey("meds.quick.empty.title"))
        #expect(MedicationQuickIntakeSheet.emptyNoteKey(for: later) == LocalizedStringKey("meds.quick.empty.notYet"))
    }
}

/// The hint cards under the hero keep one identity each, so the cards below a
/// swiped-away one move up instead of taking its place.
@Suite("E2 hint card identity")
struct E2BHintCardIdentityTests {
    private static func item(_ key: String?) -> DailyPriorityItem {
        DailyPriorityItem(kind: "milestone", itemKey: key, title: "Neuer Rekord", body: nil, status: "success", actions: [], moduleKey: nil)
    }

    @Test("A dismissible hint is known by its key, the others by their place")
    @MainActor
    func cardIDs() {
        let ids = TodayHeroWorthALookSection.cardIDs([Self.item("a"), Self.item(nil), Self.item("b")])
        #expect(ids == ["key:a", "index:1", "key:b"])
        let afterDismiss = TodayHeroWorthALookSection.cardIDs([Self.item(nil), Self.item("b")])
        #expect(afterDismiss.last == "key:b")
    }
}
