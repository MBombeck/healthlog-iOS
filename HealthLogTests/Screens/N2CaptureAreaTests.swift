import Foundation
@testable import HealthLog
import Testing

/// The weekday chips of the dose plan: a tap adds or removes a day, and the
/// last chosen day cannot be taken away, because the server needs one.
@Suite("Dose plan weekday chips")
struct N2CaptureWeekdayChipsTests {
    @Test("a tap on an unchosen day adds it")
    func tapAddsDay() {
        let next = CadenceWeekdayChips.toggled([.mon], .wed)
        #expect(next == [.mon, .wed])
    }

    @Test("a tap on a chosen day removes it while another stays")
    func tapRemovesDay() {
        let next = CadenceWeekdayChips.toggled([.mon, .wed], .mon)
        #expect(next == [.wed])
    }

    @Test("the last chosen day stays chosen")
    func lastDayStays() {
        let next = CadenceWeekdayChips.toggled([.fri], .fri)
        #expect(next == [.fri])
    }

    @Test("the chips run from Monday to Sunday")
    func weekRunsMondayToSunday() {
        #expect(CadenceWeekdayChips.order == [.mon, .tue, .wed, .thu, .fri, .sat, .sun])
    }
}

/// A dose prefilled into an input field carries no thousands separator, or
/// the parser would read "8.000" as eight.
@Suite("Titration dose input format")
struct N2CaptureInputFormatTests {
    @Test("a large dose stands without grouping")
    func largeDoseHasNoGrouping() {
        let text = TitrationStepEditSheet.formatInputDose(8000)
        #expect(text == "8000")
    }

    @Test("trailing zeros fall away")
    func trailingZerosFallAway() {
        #expect(TitrationStepEditSheet.formatInputDose(5) == "5")
    }
}
