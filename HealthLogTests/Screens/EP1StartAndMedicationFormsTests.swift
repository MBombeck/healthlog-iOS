import Foundation
@testable import HealthLog
import Testing

/// The shared forms of the Start hints and the medication detail: one symbol
/// column for every hint, the history as its newest entries plus a row to the
/// full list, and the card menu that took over the card's corner symbols.
@Suite("Start and medication forms")
struct EP1StartAndMedicationFormsTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    // MARK: Hint cards

    @Test("Every known hint kind has a symbol for the fixed column")
    func everyKindHasASymbol() {
        let kinds: [DailyPriorityItem.Kind] = [
            .doseWindow, .preventiveCare, .syncIssue, .coachCheckin,
            .milestone, .ecgNewRecording, .tensionWindow, .sameTimeBaseline
        ]
        for kind in kinds {
            #expect(PriorityRailCard.symbol(for: kind) != nil, "no symbol for \(kind)")
        }
    }

    @Test("An unknown kind keeps the column empty instead of moving the text")
    func unknownKindHasNoSymbol() {
        #expect(PriorityRailCard.symbol(for: nil) == nil)
    }

    @Test("No hint card shows a chevron, whatever it offers")
    func noHintChevron() {
        let action = DailyPriorityItem.Action(labelKey: "daily.action.viewCheckups", intent: "checkup.view", href: nil)
        let forms: [PriorityRailCardAffordance] = [.none, .wholeCard(action), .buttons([action, action])]
        for form in forms {
            #expect(form.rowIndicator == .hidden)
        }
    }

    @Test("A hint keeps its title to one line and its sentence to two")
    func hintLineLimits() {
        let limits = PriorityRailCard.LineLimits.resolve(isAccessibilitySize: false)
        #expect(limits.title == 1)
        #expect(limits.body == 2)
    }

    @Test("At the accessibility sizes a hint is never cut")
    func hintLineLimitsAtAccessibilitySizes() {
        #expect(PriorityRailCard.LineLimits.resolve(isAccessibilitySize: true) == .init(title: nil, body: nil))
    }

    // MARK: Medication history

    private func row(hoursAgo: Int) -> MedicationDoseHistoryRow {
        MedicationDoseHistoryRow(
            kind: "slot",
            at: now.addingTimeInterval(Double(-hoursAgo) * 3600),
            timeOfDay: nil,
            statusRaw: "taken_on_time",
            intake: nil
        )
    }

    @Test("The detail page shows the five newest entries, newest first")
    func previewShowsNewestFive() {
        let rows = [30, 2, 50, 10, 1, 70, 5].map(row(hoursAgo:))
        let preview = LedgerHistorySection.previewRows(rows)
        #expect(preview.count == LedgerHistorySection.previewCount)
        #expect(preview.map(\.at) == [1, 2, 5, 10, 30].map { now.addingTimeInterval(Double(-$0) * 3600) })
    }

    @Test("The row to the full list appears whenever there is a history")
    func fullListRowWithAnyHistory() {
        let four = (1 ... 4).map(row(hoursAgo:))
        let six = (1 ... 6).map(row(hoursAgo:))
        #expect(!LedgerHistorySection.showsFullListRow([]))
        #expect(LedgerHistorySection.showsFullListRow(four))
        #expect(LedgerHistorySection.showsFullListRow(six))
    }

    // MARK: Medication card menu

    @Test("History opens from the card menu, ahead of edit, hide and archive")
    func cardMenuLeadsWithHistory() {
        let medication = medT3Domain(id: "m1", name: "Lisinopril", dose: "10 mg")
        let actions = MedicationCardActions.resolve(medication: medication, now: now)
        #expect(actions.contextMenu.first == .history)
        #expect(actions.contextMenu == [.history, .edit, .hide, .archive])
    }
}
