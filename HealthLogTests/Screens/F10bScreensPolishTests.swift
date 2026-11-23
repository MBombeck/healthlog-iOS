@testable import HealthLog
import SwiftUI
import Testing

/// Row details take a second line instead of cutting a hint mid-word; the
/// title keeps one so rows line up, and nothing is cut at the accessibility
/// sizes.
@MainActor
@Suite("Row line limits")
struct F10bRowLineLimitsTests {
    @Test("title one line, detail two, nothing cut at accessibility sizes")
    func limits() {
        #expect(HLRowLineLimits.title(limitsLines: true, dynamicTypeSize: .large) == 1)
        #expect(HLRowLineLimits.subtitle(limitsLines: true, dynamicTypeSize: .large) == 2)
        #expect(HLRowLineLimits.subtitle(limitsLines: true, dynamicTypeSize: .xxxLarge) == 2)
        #expect(HLRowLineLimits.title(limitsLines: true, dynamicTypeSize: .accessibility1) == nil)
        #expect(HLRowLineLimits.subtitle(limitsLines: true, dynamicTypeSize: .accessibility3) == nil)
    }

    @Test("a row that does not limit its lines stays unlimited")
    func unlimited() {
        #expect(HLRowLineLimits.title(limitsLines: false, dynamicTypeSize: .large) == nil)
        #expect(HLRowLineLimits.subtitle(limitsLines: false, dynamicTypeSize: .large) == nil)
    }
}

/// Short sheets open as tall as their content plus the bar; before the
/// content measured itself they stand at their fallback.
@MainActor
@Suite("Content-fitted sheets")
struct F10bContentSheetTests {
    @Test("unmeasured content stands at the fallback")
    func fallback() {
        #expect(HLSheetSize.content(measuredHeight: 0) == .standard)
        #expect(HLSheetSize.content(measuredHeight: 0, fallback: .compact) == .compact)
    }

    @Test("measured content plus the bar, rounded up")
    func measured() {
        #expect(HLSheetSize.content(measuredHeight: 200) == .fitted(height: 200 + HLSheet.barAllowance))
        #expect(HLSheetSize.content(measuredHeight: 200.2) == .fitted(height: (200.2 + HLSheet.barAllowance).rounded(.up)))
    }

    @Test("the intake chooser fits its rows; a pushed page gets room to grow")
    func intakeChooser() {
        let empty = MedicationQuickIntakeOptions(due: [], asNeeded: [], later: [])
        #expect(MedicationQuickIntakeSheet.sheetSize(for: empty, chooserHeight: 0, isPushed: false) == .compact)
        #expect(MedicationQuickIntakeSheet.sheetSize(for: empty, chooserHeight: 300, isPushed: false)
            == .fitted(height: 300 + HLSheet.barAllowance))
        #expect(MedicationQuickIntakeSheet.sheetSize(for: empty, chooserHeight: 300, isPushed: true) == .standard)
    }
}

/// A stored panel key reads as its label in the editors and is written back
/// unchanged while the field still shows that label.
@MainActor
@Suite("Lab panel key in the editors")
struct F10bLabPanelSaveTests {
    @Test("an untouched label saves the stored key")
    func untouchedKeepsKey() throws {
        let shown = try #require(LabPanelName.display("coagulation"))
        #expect(LabPanelName.toSave(typed: shown, stored: "coagulation") == "coagulation")
        #expect(LabPanelName.toSave(typed: " \(shown) ", stored: "coagulation") == "coagulation")
    }

    @Test("a changed or new panel saves what was typed")
    func typedWins() {
        #expect(LabPanelName.toSave(typed: "Eigene Gruppe", stored: "coagulation") == "Eigene Gruppe")
        #expect(LabPanelName.toSave(typed: " Lipide ", stored: nil) == "Lipide")
        #expect(LabPanelName.toSave(typed: "", stored: "coagulation").isEmpty)
    }

    @Test("a range from zero starts at the scale's left end")
    func rangeFromZero() throws {
        let placement = try #require(LabRangeScale.placement(value: 2.1, previous: [], low: 0, high: 3))
        #expect(placement.bandStart == 0)
        #expect(placement.value > placement.bandStart)
        #expect(placement.value < placement.bandEnd)
        // A range below zero keeps its room on both sides.
        let negative = try #require(LabRangeScale.placement(value: -1, previous: [], low: -2, high: 2))
        #expect(negative.bandStart > 0)
    }
}

/// Open choices show their state on every row; settings pages show their
/// check mark only with something to save.
@MainActor
@Suite("Choice and confirm marks")
struct F10bChoiceAndConfirmTests {
    @Test("an open single choice shows an open circle, filled when chosen, at the trailing edge")
    func openChoice() {
        #expect(HLChoiceRow.symbol(mode: .singleOpen, isSelected: false) == "circle")
        #expect(HLChoiceRow.symbol(mode: .singleOpen, isSelected: true) == "checkmark.circle.fill")
        #expect(HLChoiceRow.edge(for: .singleOpen) == .trailing)
        #expect(HLChoiceRow.symbol(mode: .single, isSelected: false) == nil)
    }

    @Test("a settings page hides its idle check mark, a form keeps it")
    func confirmVisibility() {
        #expect(!HLConfirmBarModifier.showsConfirm(isEnabled: false, isRunning: false, hidesUntilChanged: true))
        #expect(HLConfirmBarModifier.showsConfirm(isEnabled: true, isRunning: false, hidesUntilChanged: true))
        #expect(HLConfirmBarModifier.showsConfirm(isEnabled: false, isRunning: true, hidesUntilChanged: true))
        #expect(HLConfirmBarModifier.showsConfirm(isEnabled: false, isRunning: false, hidesUntilChanged: false))
    }

    @Test("a lone note can stand centred")
    func emptyNoteAlignment() {
        #expect(HLEmptyNoteAlignment.center.text == .center)
        #expect(HLEmptyNoteAlignment.center.frame == .center)
        #expect(HLEmptyNoteAlignment.leading.text == .leading)
    }
}

/// Small text rules: no name said twice, no window named that is not shown.
@MainActor
@Suite("Repeated and misnamed labels")
struct F10bLabelTests {
    @Test("the records hero badge drops the streak length the value shows")
    func heroBadge() {
        #expect(HeroRecordCard.badgeText(slot: "Längste Serie ≥ 10.000 (12 Tage)") == "Längste Serie ≥ 10.000")
        #expect(HeroRecordCard.badgeText(slot: "Bester Tag") == "Bester Tag")
        #expect(HeroRecordCard.badgeText(slot: nil) == nil)
        #expect(HeroRecordCard.badgeText(slot: "  ") == nil)
        #expect(HeroRecordCard.badgeText(slot: "(12 Tage)") == "(12 Tage)")
    }

    @Test("a reminder's type badge is left out when it repeats the title")
    func reminderBadge() {
        #expect(VorsorgeReminderCardView.badge("Taillenumfang", title: "Taillenumfang") == nil)
        #expect(VorsorgeReminderCardView.badge("Taillenumfang", title: " taillenumfang ") == nil)
        #expect(VorsorgeReminderCardView.badge("Gewicht", title: "Wiegen am Morgen") == "Gewicht")
    }

    @Test("the folded intake track is headed by the window it shows")
    func verlaufHeader() {
        #expect(VerlaufGlyphTrack.headerKey(isExpanded: false, canExpand: true, isWeeklyCadence: false)
            == LocalizedStringKey("Last 7 days"))
        #expect(VerlaufGlyphTrack.headerKey(isExpanded: true, canExpand: true, isWeeklyCadence: false)
            == LocalizedStringKey("med.verlauf.section.header"))
        #expect(VerlaufGlyphTrack.headerKey(isExpanded: false, canExpand: false, isWeeklyCadence: false)
            == LocalizedStringKey("med.verlauf.section.header"))
        #expect(VerlaufGlyphTrack.headerKey(isExpanded: false, canExpand: true, isWeeklyCadence: true)
            == LocalizedStringKey("med.verlauf.section.header"))
    }

    @Test("an empty supply is one note in a card of its own")
    func emptySupply() {
        #expect(MedicationInventorySection.isEmpty(stockDosesRemaining: nil, summary: nil, itemCount: 0))
        #expect(!MedicationInventorySection.isEmpty(stockDosesRemaining: nil, summary: nil, itemCount: 1))
        #expect(!MedicationInventorySection.isEmpty(stockDosesRemaining: 12, summary: nil, itemCount: 0))
    }
}

/// Morning taken, evening due: the card, the list check and the intake
/// sheet read one rule, so they never contradict each other.
@MainActor
@Suite("Medication due rule")
struct F10bMedicationDueTests {
    private static let berlin = TimeZone(identifier: "Europe/Berlin") ?? .gmt

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = berlin
        return calendar
    }

    private static func at(_ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: hour, minute: minute)) ?? .distantPast
    }

    private static let naproxen = MedicationWireDTO(
        id: "med_naproxen_f10b",
        name: "Naproxen",
        dose: "250 mg",
        active: true,
        schedules: [MedicationScheduleDTO(windowStart: "08:00", timesOfDay: ["08:00", "20:00"])],
        asNeeded: false
    ).toDomain()

    private static func intake(_ id: String, _ hour: Int, _ status: IntakeStatus) -> MedicationIntake {
        MedicationIntake(
            id: id,
            medicationId: naproxen.id,
            scheduledAt: at(hour, 0),
            takenAt: status == .taken ? at(hour, 5) : nil,
            status: status
        )
    }

    @Test("the evening slot is due once its window opens, as the card says")
    func eveningDueWithWindow() {
        let evening = Self.at(20, 0)
        #expect(MedicationDueRule.dueFrom(scheduledAt: evening, medication: Self.naproxen, calendar: Self.calendar)
            == Self.at(19, 0))
        #expect(!MedicationDueRule.isDue(scheduledAt: evening, medication: Self.naproxen, now: Self.at(18, 4), calendar: Self.calendar))
        #expect(MedicationDueRule.isDue(scheduledAt: evening, medication: Self.naproxen, now: Self.at(19, 21), calendar: Self.calendar))
    }

    @Test("card window status and the due rule agree at 19:21 and at 18:04")
    func cardAgrees() {
        let late = MedicationWindowStatus.reduce(medication: Self.naproxen, now: Self.at(19, 21), timeZone: Self.berlin)
        let early = MedicationWindowStatus.reduce(medication: Self.naproxen, now: Self.at(18, 4), timeZone: Self.berlin)
        #expect(late == .inWindow)
        #expect(early != .inWindow)
    }

    @Test("morning taken, evening open: no check, and the sheet lists the evening dose as due in its window")
    func morningTakenEveningDue() {
        let intakes = [Self.intake("am", 8, .taken), Self.intake("pm", 20, .pending)]
        #expect(!MedicationDueRule.allDosesSettled(medicationId: Self.naproxen.id, todayIntakes: intakes))
        let inWindow = MedicationQuickIntakeOptions.resolve(
            medications: [Self.naproxen],
            intakes: intakes,
            now: Self.at(19, 21),
            timeZone: Self.berlin
        )
        #expect(inWindow.due.map(\.id) == ["pm"])
        #expect(inWindow.later.isEmpty)
        let before = MedicationQuickIntakeOptions.resolve(
            medications: [Self.naproxen],
            intakes: intakes,
            now: Self.at(18, 4),
            timeZone: Self.berlin
        )
        #expect(before.due.isEmpty)
        #expect(before.later.map(\.id) == ["pm"])
    }

    @Test("the check needs every dose taken or skipped", arguments: [
        IntakeStatus.pending, .snoozed, .missed, .unknown
    ])
    func openStatusesKeepTheCheckAway(evening: IntakeStatus) {
        let intakes = [Self.intake("am", 8, .taken), Self.intake("pm", 20, evening)]
        #expect(!MedicationDueRule.allDosesSettled(medicationId: Self.naproxen.id, todayIntakes: intakes))
    }

    @Test("a skipped day without any taken dose shows no check")
    func skippedOnly() {
        let intakes = [Self.intake("am", 8, .skipped), Self.intake("pm", 20, .skipped)]
        #expect(!MedicationDueRule.allDosesSettled(medicationId: Self.naproxen.id, todayIntakes: intakes))
    }

    @Test("the sheet reads the account's zone, not the device's")
    func accountZone() throws {
        // Device in UTC, account in Berlin: 19:21 Berlin is 18:21 UTC. In the
        // device zone the slot reads 19:00, a time no band names, and the
        // evening dose would only be due at 20:00.
        let intakes = [Self.intake("am", 8, .taken), Self.intake("pm", 20, .pending)]
        let berlinOptions = MedicationQuickIntakeOptions.resolve(
            medications: [Self.naproxen], intakes: intakes, now: Self.at(19, 21), timeZone: Self.berlin
        )
        #expect(berlinOptions.due.map(\.id) == ["pm"])
        let utc = try #require(TimeZone(identifier: "UTC"))
        let utcCalendar = MedicationDueRule.calendar(timeZone: utc)
        #expect(MedicationDueRule.dueFrom(scheduledAt: Self.at(20, 0), medication: Self.naproxen, calendar: utcCalendar)
            == Self.at(20, 0))
        // The card reads the same zone and agrees with the sheet.
        #expect(MedicationWindowStatus.reduce(medication: Self.naproxen, now: Self.at(19, 21), timeZone: Self.berlin) == .inWindow)
    }

    @Test("the window starts on the wall clock on the days the clocks change")
    func clockChange() throws {
        let calendar = Self.calendar
        // Berlin: clocks forward on 29 March 2026, back on 25 October 2026.
        for (month, day) in [(3, 29), (10, 25)] {
            func at(_ hour: Int) throws -> Date {
                try #require(calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour)))
            }
            #expect(try MedicationDueRule.dueFrom(scheduledAt: at(20), medication: Self.naproxen, calendar: calendar) == at(19))
            #expect(try MedicationDueRule.dueFrom(scheduledAt: at(8), medication: Self.naproxen, calendar: calendar) == at(7))
        }
    }

    @Test("card and sheet agree minute by minute around an evening dose")
    func cardAndSheetAgree() {
        let evening = MedicationWireDTO(
            id: "med_evening_f10b",
            name: "Lisinopril",
            dose: "5 mg",
            active: true,
            schedules: [MedicationScheduleDTO(windowStart: "20:00", timesOfDay: ["20:00"])],
            asNeeded: false
        ).toDomain()
        for minutes in stride(from: 18 * 60, through: 21 * 60, by: 5) {
            let now = Self.at(minutes / 60, minutes % 60)
            let card = MedicationWindowStatus.reduce(medication: evening, now: now, timeZone: Self.berlin) == .inWindow
            let sheet = MedicationDueRule.isDue(scheduledAt: Self.at(20, 0), medication: evening, now: now, calendar: Self.calendar)
            #expect(card == sheet, "disagree at \(minutes / 60):\(minutes % 60)")
        }
    }

    @Test("the check stands once every dose of the day is settled")
    func allSettled() {
        let done = [Self.intake("am", 8, .taken), Self.intake("pm", 20, .taken)]
        #expect(MedicationDueRule.allDosesSettled(medicationId: Self.naproxen.id, todayIntakes: done))
        let skipped = [Self.intake("am", 8, .taken), Self.intake("pm", 20, .skipped)]
        #expect(MedicationDueRule.allDosesSettled(medicationId: Self.naproxen.id, todayIntakes: skipped))
        #expect(!MedicationDueRule.allDosesSettled(medicationId: Self.naproxen.id, todayIntakes: []))
    }
}

/// A score on a fixed scale names the scale instead of a unit fragment.
@MainActor
@Suite("Measurement unit line")
struct F10bMeasurementUnitLineTests {
    @Test("day strain names its scale, a real unit stays")
    func unitLine() {
        #expect(MeasurementsPickerScreen.unitLine(String(localized: "metric.strain.ofTwentyOne"))
            == String(localized: "measurements.picker.scale21"))
        #expect(MeasurementsPickerScreen.unitLine("kg") == "kg")
    }
}

/// A long form sheet in a regular window keeps the form's width and takes
/// the page's height, never less than the form's own.
@MainActor
@Suite("Tall form sheet")
struct F10bTallFormTests {
    @Test("form width, the taller height")
    func tallForm() {
        let form = ProposedViewSize(width: 580, height: 820)
        let page = ProposedViewSize(width: 960, height: 1280)
        #expect(HLSheetPresentationSizing.tallForm(form: form, page: page) == ProposedViewSize(width: 580, height: 1280))
        let shortPage = ProposedViewSize(width: 960, height: 600)
        #expect(HLSheetPresentationSizing.tallForm(form: form, page: shortPage) == ProposedViewSize(width: 580, height: 820))
        #expect(HLSheetPresentationSizing.tallForm(form: ProposedViewSize(width: 580, height: nil), page: page).height == 1280)
    }
}
