import Foundation
@testable import HealthLog
import Testing

/// Numbers and times in the forms follow the device's region (de, en-US, nl),
/// a stored lab value survives an edit of another field, and an unreadable
/// entry is refused instead of clearing a stored value.
@Suite("Form input formatting")
struct FormInputFormattingTests {
    private static let german = Locale(identifier: "de_DE")
    private static let american = Locale(identifier: "en_US")
    private static let dutch = Locale(identifier: "nl_NL")

    /// The en-US clock puts a narrow no-break space before AM/PM; compare on
    /// plain spaces.
    private static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    // MARK: - Clock times

    /// A locale with the account's forced hour cycle, built the way
    /// `HLTimeFormat.formattingLocale` builds it.
    private static func forcing(_ cycle: Locale.HourCycle, on identifier: String) -> Locale {
        var components = Locale.Components(locale: Locale(identifier: identifier))
        components.hourCycle = cycle
        return Locale(components: components)
    }

    @Test("A reminder hour reads like the system clock")
    func reminderHourFollowsRegion() {
        #expect(ClockTimeText.text(hour: 8, locale: Self.german) == "08:00")
        #expect(ClockTimeText.text(hour: 8, locale: Self.dutch) == "08:00")
        #expect(Self.plain(ClockTimeText.text(hour: 8, locale: Self.american)) == "8:00 AM")
        #expect(ClockTimeText.text(hour: 8, locale: Locale(identifier: "en_GB")) == "08:00")
        #expect(Self.plain(ClockTimeText.text(hour: 21, locale: Self.american)) == "9:00 PM")
    }

    @Test("A forced hour cycle wins over the region")
    func forcedCycleWins() {
        let germanTwelve = ClockTimeText.text(hour: 8, locale: Self.forcing(.oneToTwelve, on: "de_DE"))
        #expect(Self.plain(germanTwelve) == "8:00 AM")
        #expect(ClockTimeText.text(hour: 8, locale: Self.forcing(.zeroToTwentyThree, on: "en_US")) == "08:00")
    }

    @Test("Midnight reads 00:00, never 24:00")
    func midnight() {
        #expect(ClockTimeText.text(hour: 0, locale: Self.german) == "00:00")
        #expect(ClockTimeText.text(hour: 0, locale: Self.forcing(.zeroToTwentyThree, on: "en_US")) == "00:00")
    }

    @Test("Medication times read like the system clock, earliest first")
    func medicationTimesFollowRegion() {
        let times = [TimeOfDay(hour: 20, minute: 0), TimeOfDay(hour: 8, minute: 30)]
        #expect(ClockTimeText.list(times, locale: Self.german) == "08:30, 20:00")
        #expect(Self.plain(ClockTimeText.list(times, locale: Self.american)) == "8:30 AM, 8:00 PM")
        #expect(ClockTimeText.list(times, locale: Self.dutch) == "08:30, 20:00")
    }

    // MARK: - Measurement placeholders

    @Test("The example in the measurement field uses the region's decimal mark")
    func placeholderFollowsRegion() {
        #expect(MeasurePlaceholder.text(.weight, locale: Self.german) == "72,4")
        #expect(MeasurePlaceholder.text(.weight, locale: Self.american) == "72.4")
        #expect(MeasurePlaceholder.text(.weight, locale: Self.dutch) == "72,4")
        #expect(MeasurePlaceholder.text(.bodyTemperature, locale: Self.american) == "36.8")
        #expect(MeasurePlaceholder.text(.gripStrength, locale: Self.german) == "38,0")
        #expect(MeasurePlaceholder.text(.glucose, locale: Self.german) == "92")
    }

    // MARK: - Lab value round trip

    @Test("A lab value with four decimals shows in full")
    func labValueShowsEveryDigit() {
        #expect(EditLabResultSheet.editableValueText(0.0042, locale: Self.german) == "0,0042")
        #expect(EditLabResultSheet.editableValueText(0.0042, locale: Self.american) == "0.0042")
        #expect(EditLabResultSheet.editableValueText(5.1, locale: Self.german) == "5,1")
        #expect(EditLabResultSheet.editableValueText(1234.5678, locale: Self.american) == "1234.5678")
        #expect(EditLabResultSheet.editableValueText(nil).isEmpty)
    }

    @Test("Editing another field leaves a four-decimal lab value untouched")
    func untouchedLabValueIsNotSent() {
        let seeded = EditLabResultSheet.editableValueText(0.0042, locale: Self.german)
        #expect(EditLabResultSheet.valueToSend(valueText: seeded, initialValueText: seeded, locale: Self.german) == nil)
    }

    @Test("A changed lab value is sent as typed")
    func changedLabValueIsSent() {
        let seeded = EditLabResultSheet.editableValueText(0.0042, locale: Self.german)
        let sent = EditLabResultSheet.valueToSend(valueText: "0,0051", initialValueText: seeded, locale: Self.german)
        #expect(abs((sent ?? 0) - 0.0051) < 1e-12)
    }

    // MARK: - Injection site names

    @Test("A logged injection site reads in words, not as the server's code")
    func injectionSiteReadsInWords() {
        #expect(IntakeHistoryRow.injectionSiteLabel("ABDOMEN_UPPER_LEFT") == InjectionSite.abdomenLeftUpper.localizedLabel)
        #expect(IntakeHistoryRow.injectionSiteLabel("thigh_right") == InjectionSite.thighRight.localizedLabel)
        #expect(IntakeHistoryRow.injectionSiteLabel("SOMEWHERE_NEW") == InjectionSite.unknown.localizedLabel)
    }

    // MARK: - Custom metric editor

    @Test("A target that is not a number is refused instead of clearing the band")
    func unreadableTargetIsRefused() {
        let result = CustomMetricEditorSheet.unreadableInput(
            targetLowText: "abc", targetHighText: "", decimalsText: "", locale: Self.german
        )
        #expect(result?.key == "customMetric.validation.targetNotNumber")
        let decimals = CustomMetricEditorSheet.unreadableInput(
            targetLowText: "", targetHighText: "", decimalsText: "2,5", locale: Self.german
        )
        #expect(decimals?.key == "customMetric.validation.decimals")
    }

    @Test("Blank and readable fields pass")
    func readableFieldsPass() {
        #expect(CustomMetricEditorSheet.unreadableInput(
            targetLowText: "", targetHighText: "", decimalsText: "", locale: Self.german
        ) == nil)
        #expect(CustomMetricEditorSheet.unreadableInput(
            targetLowText: "4,5", targetHighText: "7", decimalsText: "1", locale: Self.german
        ) == nil)
    }

    // MARK: - Mood tag icons

    @Test("Every custom mood-tag icon has a spoken name")
    func everyIconHasAName() {
        for icon in MoodTagCatalog.customIconAllowList {
            #expect(MoodTagIconName.names[icon] != nil, "\(icon) has no name")
        }
    }
}
