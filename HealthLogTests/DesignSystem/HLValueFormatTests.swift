import Foundation
@testable import HealthLog
import SwiftUI
import Testing

/// A number with its unit, and the way back from typed text to a number.
@Suite("Values, units and number entry")
struct HLValueFormatTests {
    private static let german = Locale(identifier: "de_DE")
    private static let english = Locale(identifier: "en_US")
    private static let gap = HLNumberFormat.narrowNoBreakSpace

    // MARK: - Unit

    @Test("a symbol as the models spell it becomes its unit", arguments: [
        ("kg", HLUnit.kilograms), (" mmHg ", .millimetersOfMercury), ("%", .percent), ("bpm", .beatsPerMinute),
        ("mL", .milliliters), ("ml", .milliliters), ("", .plain), ("  ", .plain),
        ("IU/L", .custom("IU/L")), ("Tassen", .custom("Tassen"))
    ])
    func unitFromSymbol(symbol: String, unit: HLUnit) {
        #expect(HLUnit(symbol: symbol) == unit)
    }

    @Test("a unit's symbol leads back to the unit", arguments: [
        HLUnit.percent, .kilograms, .pounds, .millimetersOfMercury, .beatsPerMinute, .milliseconds, .celsius,
        .fahrenheit, .milligramsPerDeciliter, .millimolesPerLiter, .kilocalories, .meters, .kilometers,
        .centimeters, .metersPerSecond, .milliliters, .milligrams, .custom("IU/L")
    ])
    func unitRoundTrip(unit: HLUnit) throws {
        let symbol = try #require(unit.symbol)
        #expect(HLUnit(symbol: symbol) == unit)
    }

    @Test("a bare number has no unit, and a unit that is a word has one in every language")
    func unitSymbols() {
        #expect(HLUnit.plain.symbol == nil)
        #expect(HLUnit.custom("").symbol == nil)
        for unit in [HLUnit.steps, .minutes, .hours] {
            #expect(unit.symbol?.isEmpty == false)
        }
    }

    // MARK: - Value with unit

    @Test("number and unit are joined by a narrow no-break space")
    func valueWithUnit() {
        #expect(HLValueFormat.string(72.4, unit: .kilograms, locale: Self.german) == "72,4\(Self.gap)kg")
        #expect(HLValueFormat.string(72.4, unit: .kilograms, locale: Self.english) == "72.4\(Self.gap)kg")
        #expect(HLValueFormat.string(5, unit: .custom("IU/L"), locale: Self.german) == "5\(Self.gap)IU/L")
    }

    @Test("a whole number shows no decimal place, anything else one")
    func defaultFractionDigits() {
        #expect(HLValueFormat.defaultFractionDigits == 0 ... 1)
        #expect(HLValueFormat.string(72, unit: .kilograms, locale: Self.german) == "72\(Self.gap)kg")
        #expect(HLValueFormat.string(72.46, unit: .kilograms, locale: Self.german) == "72,5\(Self.gap)kg")
        #expect(HLValueFormat.string(72.4, unit: .kilograms, fractionDigits: 2 ... 2, locale: Self.german)
            == "72,40\(Self.gap)kg")
        #expect(HLValueFormat.string(5.6, unit: .millimolesPerLiter, fractionDigits: 0 ... 0, locale: Self.german)
            == "6\(Self.gap)mmol/L")
    }

    @Test("large numbers carry the language's separators")
    func grouping() {
        #expect(HLValueFormat.string(1234.5, unit: .kilocalories, locale: Self.german) == "1.234,5\(Self.gap)kcal")
        #expect(HLValueFormat.string(1234.5, unit: .kilocalories, locale: Self.english) == "1,234.5\(Self.gap)kcal")
        #expect(HLValueFormat.number(1234.5, locale: Self.german) == "1.234,5")
    }

    @Test("a number for a field carries no grouping in any language", arguments: ["de_DE", "en_US", "nl_NL"])
    func ungrouped(identifier: String) {
        let locale = Locale(identifier: identifier)
        let typed = HLValueFormat.number(8000, grouping: .never, locale: locale)
        #expect(typed == "8000")
        #expect(HLNumberEntry.value(from: typed, locale: locale) == 8000)
        // The same number for reading keeps the language's grouping.
        #expect(HLValueFormat.number(8000, locale: locale) != "8000")
    }

    @Test("without grouping the decimal places stay the caller's")
    func ungroupedDecimals() {
        #expect(HLValueFormat.number(84, fractionDigits: 1 ... 1, grouping: .never, locale: Self.german) == "84,0")
        #expect(HLValueFormat.number(12345.5, grouping: .never, locale: Self.german) == "12345,5")
        #expect(HLValueFormat.number(12345.5, grouping: .never, locale: Self.english) == "12345.5")
    }

    @Test("the percent sign stands where the language puts it")
    func percent() {
        #expect(HLValueFormat.string(83, unit: .percent, locale: Self.german) == "83\(Self.gap)%")
        #expect(HLValueFormat.string(83, unit: .percent, locale: Self.english) == "83%")
    }

    @Test("a bare number is the number alone")
    func plain() {
        #expect(HLValueFormat.string(72, unit: .plain, locale: Self.german) == "72")
        #expect(HLValueFormat.string(7.5, unit: .custom(""), locale: Self.german) == "7,5")
    }

    @Test("a value that is not there is a dash, never a zero")
    func placeholder() {
        let missing: Double? = nil
        let present: Double? = 72.4
        #expect(HLValueFormat.string(missing, unit: .kilograms, locale: Self.german) == HLValueFormat.placeholder)
        #expect(HLValueFormat.string(present, unit: .kilograms, locale: Self.german) == "72,4\(Self.gap)kg")
        #expect(!HLValueFormat.placeholder.contains("0"))
    }

    @Test("the parts put together are the whole", arguments: [
        HLUnit.kilograms, .percent, .plain, .custom("IU/L")
    ])
    func partsJoin(unit: HLUnit) {
        for locale in [Self.german, Self.english] {
            let parts = HLValueFormat.parts(72.4, unit: unit, locale: locale)
            #expect(parts.joined == HLValueFormat.string(72.4, unit: unit, locale: locale))
            #expect(parts.number == HLValueFormat.number(72.4, locale: locale))
        }
    }

    @Test("the unit is its own part, so a view can set it smaller than the number")
    func partsSplit() {
        let weight = HLValueFormat.parts(72.4, unit: .kilograms, locale: Self.german)
        #expect(weight == HLValueParts(leading: "", number: "72,4", trailing: "\(Self.gap)kg"))

        let share = HLValueFormat.parts(83, unit: .percent, locale: Self.german)
        #expect(share == HLValueParts(leading: "", number: "83", trailing: "\(Self.gap)%"))

        let count = HLValueFormat.parts(12, unit: .plain, locale: Self.german)
        #expect(count == HLValueParts(leading: "", number: "12", trailing: ""))
    }

    // MARK: - Pair, span, change

    private static let dutch = Locale(identifier: "nl_NL")

    @Test("a pair carries its unit once at the end", arguments: ["de_DE", "en_US", "nl_NL"])
    func pair(identifier: String) {
        let locale = Locale(identifier: identifier)
        #expect(HLValueFormat.pair(128, 82, unit: .millimetersOfMercury, locale: locale) == "128/82\(Self.gap)mmHg")
        let parts = HLValueFormat.pairParts(128, 82, unit: .millimetersOfMercury, locale: locale)
        #expect(parts == HLValueParts(leading: "", number: "128/82", trailing: "\(Self.gap)mmHg"))
    }

    @Test("the numbers of a pair carry the language's decimal separator")
    func pairDecimals() {
        #expect(HLValueFormat.pair(5.6, 7.8, unit: .millimolesPerLiter, locale: Self.german)
            == "5,6/7,8\(Self.gap)mmol/L")
        #expect(HLValueFormat.pair(5.6, 7.8, unit: .millimolesPerLiter, locale: Self.english)
            == "5.6/7.8\(Self.gap)mmol/L")
        #expect(HLValueFormat.pair(5.6, 7.8, unit: .millimolesPerLiter, locale: Self.dutch)
            == "5,6/7,8\(Self.gap)mmol/L")
    }

    @Test("a span is written in words and carries its unit once", arguments: ["de_DE", "en_US", "nl_NL"])
    func span(identifier: String) {
        let locale = Locale(identifier: identifier)
        let words = HLNumberFormat.range("60", "100")
        #expect(HLValueFormat.range(60, 100, unit: .beatsPerMinute, locale: locale) == words + "\(Self.gap)bpm")
        #expect(HLValueFormat.range(60, 100, unit: .plain, locale: locale) == words)
        #expect(!HLValueFormat.range(60, 100, unit: .beatsPerMinute, locale: locale).contains("\u{2013}"))
    }

    @Test("the word between the ends of a span exists in every language", arguments: [
        ("de", "bis"), ("en", "to"), ("nl", "tot")
    ])
    func spanWord(language: String, word: String) throws {
        let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        let pattern = bundle.localizedString(forKey: "%@ to %@", value: "MISSING", table: nil)
        #expect(String(format: pattern, "60", "100") == "60 \(word) 100")
    }

    @Test("a change carries its sign, and no sign where nothing changed")
    func delta() {
        #expect(HLValueFormat.delta(1.2, unit: .kilograms, locale: Self.german) == "+1,2\(Self.gap)kg")
        #expect(HLValueFormat.delta(-0.4, unit: .kilograms, locale: Self.german) == "-0,4\(Self.gap)kg")
        #expect(HLValueFormat.delta(1.2, unit: .kilograms, locale: Self.english) == "+1.2\(Self.gap)kg")
        #expect(HLValueFormat.delta(-0.4, unit: .kilograms, locale: Self.english) == "-0.4\(Self.gap)kg")
        #expect(HLValueFormat.delta(1.2, unit: .kilograms, locale: Self.dutch) == "+1,2\(Self.gap)kg")
        #expect(HLValueFormat.delta(-0.4, unit: .kilograms, locale: Self.dutch) == "-0,4\(Self.gap)kg")
        #expect(HLValueFormat.delta(0, unit: .kilograms, locale: Self.german) == "0\(Self.gap)kg")
        #expect(HLValueFormat.delta(3, unit: .percent, locale: Self.german) == "+3\(Self.gap)%")
        #expect(HLValueFormat.delta(3, unit: .percent, locale: Self.english) == "+3%")
    }

    // MARK: - Number entry

    @Test("typed text becomes a number in the language's spelling")
    func entryParses() {
        #expect(HLNumberEntry.value(from: "72,4", fractionDigits: 0 ... 1, locale: Self.german) == 72.4)
        #expect(HLNumberEntry.value(from: "72.4", fractionDigits: 0 ... 1, locale: Self.english) == 72.4)
        #expect(HLNumberEntry.value(from: " 72 ", locale: Self.german) == 72)
    }

    @Test("more decimal places than the field has are rounded away")
    func entryRounds() {
        #expect(HLNumberEntry.value(from: "72,46", fractionDigits: 0 ... 1, locale: Self.german) == 72.5)
        #expect(HLNumberEntry.value(from: "72,6", fractionDigits: 0 ... 0, locale: Self.german) == 73)
        #expect(HLNumberEntry.value(from: "72,44", fractionDigits: 0 ... 1, locale: Self.german) == 72.4)
    }

    @Test("an empty field and text that is no number give no value")
    func entryRejectsText() {
        #expect(HLNumberEntry.value(from: "", locale: Self.german) == nil)
        #expect(HLNumberEntry.value(from: "abc", locale: Self.german) == nil)
        #expect(!HLNumberEntry.isRejected("", locale: Self.german))
        #expect(!HLNumberEntry.isRejected("   ", locale: Self.german))
        #expect(HLNumberEntry.isRejected("abc", locale: Self.german))
        #expect(!HLNumberEntry.isRejected("72", locale: Self.german))
    }

    @Test("a number outside the range gives no value; it is not pulled to the nearest bound")
    func entryRange() {
        let range = 20.0 ... 300.0
        #expect(HLNumberEntry.value(from: "500", range: range, locale: Self.german) == nil)
        #expect(HLNumberEntry.value(from: "5", range: range, locale: Self.german) == nil)
        #expect(HLNumberEntry.value(from: "20", range: range, locale: Self.german) == 20)
        #expect(HLNumberEntry.value(from: "300", range: range, locale: Self.german) == 300)
        #expect(HLNumberEntry.isRejected("500", range: range, locale: Self.german))
        #expect(!HLNumberEntry.isRejected("120", range: range, locale: Self.german))
    }

    @Test("a value is shown for editing without grouping and without spare decimal places")
    func entryText() {
        #expect(HLNumberEntry.text(for: 72.4, fractionDigits: 0 ... 1, locale: Self.german) == "72,4")
        #expect(HLNumberEntry.text(for: 72, fractionDigits: 0 ... 1, locale: Self.german) == "72")
        #expect(HLNumberEntry.text(for: 72.46, fractionDigits: 0 ... 1, locale: Self.german) == "72,5")
        #expect(HLNumberEntry.text(for: 12345, locale: Self.german) == "12345")
        #expect(HLNumberEntry.text(for: 12345.5, fractionDigits: 0 ... 1, locale: Self.english) == "12345.5")
        #expect(HLNumberEntry.text(for: nil, fractionDigits: 0 ... 1, locale: Self.german).isEmpty)
    }

    @Test("what the field shows reads back as the same value", arguments: [0.0, 5.5, 72.4, 120.0, 12345.5])
    func entryRoundTrip(value: Double) {
        for locale in [Self.german, Self.english] {
            let text = HLNumberEntry.text(for: value, fractionDigits: 0 ... 1, locale: locale)
            #expect(HLNumberEntry.value(from: text, fractionDigits: 0 ... 1, locale: locale) == value)
        }
    }

    @Test("the field tells apart nothing, a number, a number out of range and no number")
    func entryStates() {
        let range = 20.0 ... 300.0
        #expect(HLNumberEntry.state(of: "", range: range, locale: Self.german) == .empty)
        #expect(HLNumberEntry.state(of: "  ", range: range, locale: Self.german) == .empty)
        #expect(HLNumberEntry.state(of: "72,4", range: range, locale: Self.german) == .valid(72.4))
        #expect(HLNumberEntry.state(of: "500", range: range, locale: Self.german) == .outOfRange)
        #expect(HLNumberEntry.state(of: "abc", range: range, locale: Self.german) == .unreadable)

        #expect(HLNumberEntry.State.valid(72.4).value == 72.4)
        #expect(HLNumberEntry.State.empty.value == nil)
        #expect(!HLNumberEntry.State.empty.isRejected)
        #expect(!HLNumberEntry.State.valid(1).isRejected)
        #expect(HLNumberEntry.State.outOfRange.isRejected)
        #expect(HLNumberEntry.State.unreadable.isRejected)
    }

    @Test("entry and display mean the same by their decimal places")
    func entryDigitsMatchDisplay() {
        #expect(HLNumberEntry.mostDigits(nil) == HLValueFormat.defaultFractionDigits.upperBound)
        #expect(HLNumberEntry.mostDigits(0 ... 0) == 0)
        #expect(HLNumberEntry.mostDigits(1 ... 2) == 2)
        #expect(HLNumberEntry.value(from: "72,46", locale: Self.german) == 72.5)
    }

    @Test("a field says what is wrong only where something is wrong")
    func entryMessage() throws {
        let range = 20.0 ... 300.0
        #expect(HLNumberEntry.message(for: .empty, range: range, locale: Self.german) == nil)
        #expect(HLNumberEntry.message(for: .valid(72), range: range, locale: Self.german) == nil)

        let outside = try #require(HLNumberEntry.message(for: .outOfRange, range: range, locale: Self.german))
        #expect(outside.contains(HLNumberFormat.range("20", "300")))
        let unreadable = try #require(HLNumberEntry.message(for: .unreadable, range: range, locale: Self.german))
        #expect(!unreadable.isEmpty)
        #expect(unreadable != outside)
    }

    @Test("the field's messages exist in every language", arguments: [
        ("de", "Liegt außerhalb von 20 bis 300", "Das ist keine Zahl"),
        ("en", "Outside the range of 20 to 300", "This is not a number"),
        ("nl", "Ligt buiten 20 tot 300", "Dit is geen getal")
    ])
    func entryMessageWords(language: String, outside: String, unreadable: String) throws {
        let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        let span = String(format: bundle.localizedString(forKey: "%@ to %@", value: "MISSING", table: nil), "20", "300")
        let pattern = bundle.localizedString(forKey: "numberfield.error.outOfRange", value: "MISSING", table: nil)
        #expect(String(format: pattern, span) == outside)
        #expect(bundle.localizedString(forKey: "numberfield.error.unreadable", value: "MISSING", table: nil) == unreadable)
    }

    // MARK: - Example and focus

    @Test("an empty field's example says that it is one, and a zero is no example")
    func entryExample() throws {
        #expect(HLNumberEntry.exampleText(for: nil, locale: Self.german) == nil)
        #expect(HLNumberEntry.exampleText(for: 0, locale: Self.german) == nil)

        let example = try #require(HLNumberEntry.exampleText(for: 30, locale: Self.german))
        #expect(example.hasSuffix("30"))
        #expect(example != "30", "a bare grey number reads as a value")

        let large = try #require(HLNumberEntry.exampleText(for: 8000.5, fractionDigits: 0 ... 1, locale: Self.german))
        #expect(large.hasSuffix("8000,5"))
    }

    @Test("the example's words exist in every language", arguments: [
        ("de", "z. B. 30"),
        ("en", "e.g. 30"),
        ("nl", "bijv. 30")
    ])
    func entryExampleWords(language: String, expected: String) throws {
        let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        let pattern = bundle.localizedString(forKey: "numberfield.example", value: "MISSING", table: nil)
        #expect(String(format: pattern, "30") == expected)
    }

    @MainActor
    @Test("an example changes nothing about the row the field takes")
    func exampleKeepsTheRow() throws {
        let plain = try DesignContractMeasure.size(
            of: HLNumberField("Weight", value: .constant(nil), unit: .kilograms)
        )
        let withExample = try DesignContractMeasure.size(
            of: HLNumberField("Weight", value: .constant(nil), unit: .kilograms, example: 72)
        )
        #expect(plain.height == HLLayout.rowMinHeight)
        #expect(withExample == plain)
    }

    private enum FormField: Hashable {
        case weight
    }

    @MainActor
    @Test("a form binds the field to its focus state the way it binds a text field")
    func formFocus() throws {
        @FocusState var flag: Bool
        @FocusState var place: FormField?
        let field = HLNumberField("Weight", value: .constant(72), unit: .kilograms)
        #expect(!field.followsFormFocus)
        #expect(field.focused($flag).followsFormFocus)
        #expect(field.focused($place, equals: .weight).followsFormFocus)

        let free = try DesignContractMeasure.size(of: field)
        let bound = try DesignContractMeasure.size(of: field.focused($place, equals: .weight))
        #expect(bound == free)
    }

    // MARK: - Largest type

    @MainActor
    @Test("at the largest type a reading that is too wide moves its unit under the number")
    func readingWrapsInsteadOfBeingCut() throws {
        let narrow: CGFloat = 220
        let short = try DesignContractMeasure.size(
            of: HLValueText(1, unit: .plain), width: narrow, typeSize: .accessibility5
        )
        let pair = try DesignContractMeasure.size(
            of: HLValueText(128, 82, unit: .millimetersOfMercury), width: narrow, typeSize: .accessibility5
        )
        #expect(pair.height > short.height * 1.3, "\(pair.height) pt against \(short.height) pt for one line")

        let regularShort = try DesignContractMeasure.size(of: HLValueText(1, unit: .plain), width: narrow)
        let regularPair = try DesignContractMeasure.size(
            of: HLValueText(128, 82, unit: .millimetersOfMercury), width: narrow
        )
        #expect(regularPair.height == regularShort.height, "one line at the regular size")
    }
}
