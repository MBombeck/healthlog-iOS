import Foundation
@testable import HealthLog
import Testing

/// #191 QoL — the capture sheet's assistance, pinned against the web's rules
/// on server `release/v1.49.0`: the last-value deviation thresholds
/// (`last-value-deviation.ts`), the recent entry kinds and "Save and next"
/// (`recent-entry-types.ts`), the glucose context default
/// (`glucose-context-default.ts`) and the edit prefill at the label's
/// precision.
@Suite("Measure entry assist — web parity")
struct MeasureEntryAssistTests {
    private static let berlin: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .gmt
        return calendar
    }()

    private static func at(_ hour: Int, _ minute: Int = 0, day: Int = 20) -> Date {
        berlin.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute)) ?? .distantPast
    }

    private static func row(
        _ kind: MetricKind,
        _ value: MeasurementValue,
        at date: Date = at(8),
        source: MeasurementSource = .manual,
        context: GlucoseContext? = nil,
        id: String = UUID().uuidString
    ) -> HealthLog.Measurement {
        HealthLog.Measurement(id: id, kind: kind, recordedAt: date, value: value, source: source, glucoseContext: context)
    }

    // MARK: - Deviation thresholds

    @Test("the threshold table is the web's, kind by kind")
    func thresholdTable() {
        let table = MeasureLastValueDeviation.thresholds
        #expect(table[.weight] == .relative(0.1))
        #expect(table[.bodyWater] == .relative(0.15))
        #expect(table[.boneMass] == .relative(0.15))
        #expect(table[.fatMass] == .relative(0.15))
        #expect(table[.fatFreeMass] == .relative(0.15))
        #expect(table[.leanBodyMass] == .relative(0.15))
        #expect(table[.muscleMass] == .relative(0.15))
        #expect(table[.bodyFat] == .absolute(8))
        #expect(table[.pulse] == .relative(0.5))
        #expect(table[.restingHeartRate] == .relative(0.3))
        #expect(table[.spo2] == .absolute(6))
        #expect(table[.bodyTemperature] == .absolute(1.5))
        #expect(table[.waistCircumference] == .relative(0.1))
        #expect(table[.gripStrength] == .relative(0.3))
        #expect(MeasureLastValueDeviation.bloodPressure == .relative(0.3))
        // Glucose, pain and HRV move by large amounts as a matter of course.
        #expect(table[.glucose] == nil)
        #expect(table[.painNRS] == nil)
        #expect(table[.hrv] == nil)
        #expect(table.count == 14)
    }

    @Test("a relative threshold counts strictly above the share", arguments: [
        (82.3, 8.23, true), (82.3, 90.0, false), (80.0, 88.0, false), (80.0, 88.1, true)
    ])
    func relativeWeight(last: Double, typed: Double, expected: Bool) {
        let reading = Self.row(.weight, .scalar(last))
        #expect(MeasureLastValueDeviation.deviates(kind: .weight, canonical: typed, last: reading) == expected)
    }

    @Test("an absolute threshold counts strictly above the step")
    func absoluteThresholds() {
        let temperature = Self.row(.bodyTemperature, .scalar(36.5))
        #expect(!MeasureLastValueDeviation.deviates(kind: .bodyTemperature, canonical: 38, last: temperature))
        #expect(MeasureLastValueDeviation.deviates(kind: .bodyTemperature, canonical: 38.25, last: temperature))
        let fat = Self.row(.bodyFat, .scalar(22))
        #expect(MeasureLastValueDeviation.deviates(kind: .bodyFat, canonical: 30.5, last: fat))
        #expect(!MeasureLastValueDeviation.deviates(kind: .bodyFat, canonical: 30, last: fat))
    }

    @Test("no hint without a threshold, a last value, a typed value, or on a zero last value")
    func noHint() {
        #expect(!MeasureLastValueDeviation.deviates(kind: .glucose, canonical: 300, last: Self.row(.glucose, .scalar(90))))
        #expect(!MeasureLastValueDeviation.deviates(kind: .weight, canonical: 8, last: nil))
        #expect(!MeasureLastValueDeviation.deviates(kind: .weight, canonical: nil, last: Self.row(.weight, .scalar(80))))
        #expect(!MeasureLastValueDeviation.deviates(kind: .pulse, canonical: 60, last: Self.row(.pulse, .scalar(0))))
        #expect(!MeasureLastValueDeviation.deviates(.nan, from: 80, threshold: .relative(0.1)))
    }

    @Test("blood pressure: either leg far from its own last leg; an empty leg says nothing")
    func bloodPressureLegs() {
        let last = Self.row(.bloodPressure, .bloodPressure(systolic: 120, diastolic: 80))
        #expect(MeasureLastValueDeviation.deviates(systolic: 12, diastolic: nil, last: last))
        #expect(MeasureLastValueDeviation.deviates(systolic: 125, diastolic: 110, last: last))
        #expect(!MeasureLastValueDeviation.deviates(systolic: 150, diastolic: 100, last: last))
        #expect(!MeasureLastValueDeviation.deviates(systolic: nil, diastolic: nil, last: last))
        #expect(!MeasureLastValueDeviation.deviates(systolic: 12, diastolic: 8, last: nil))
    }

    // MARK: - Last reading

    @Test("the last reading is the newest of the kind, any source, never an unsaved local row")
    func lastReading() {
        let rows = [
            Self.row(.weight, .scalar(71), id: "local-1"),
            Self.row(.pulse, .scalar(60)),
            Self.row(.weight, .scalar(72.4), source: .appleHealth, id: "scale"),
            Self.row(.weight, .scalar(73), id: "older")
        ]
        #expect(MeasureLastValue.reading(of: .weight, in: rows)?.id == "scale")
        #expect(MeasureLastValue.reading(of: .glucose, in: rows) == nil)
        #expect(MeasureLastValue.reading(of: .sleep, in: [Self.row(.sleep, .scalar(7.5))]) == nil)
    }

    // MARK: - Recent kinds and "Save and next"

    @Test("recent kinds: manual rows only, newest first, distinct, offered, at most three")
    func recentKinds() {
        let rows = [
            Self.row(.weight, .scalar(72), at: Self.at(9)),
            Self.row(.hrv, .scalar(40), at: Self.at(8, 50), source: .appleHealth),
            Self.row(.glucose, .scalar(95), at: Self.at(8, 40)),
            Self.row(.weight, .scalar(72), at: Self.at(8, 30)),
            Self.row(.vo2Max, .scalar(40), at: Self.at(8, 20)),
            Self.row(.spo2, .scalar(97), at: Self.at(8, 10)),
            Self.row(.pulse, .scalar(60), at: Self.at(8))
        ]
        let offered: [MetricKind] = [.weight, .glucose, .spo2, .pulse, .hrv]
        #expect(MeasureRecentEntryKinds.kinds(from: rows, offered: offered) == [.weight, .glucose, .spo2])
    }

    @Test("a pulse at a blood pressure reading's instant folds into blood pressure; a lone pulse stays")
    func pulseFoldsIntoBloodPressure() {
        let rows = [
            Self.row(.pulse, .scalar(64), at: Self.at(7)),
            Self.row(.bloodPressure, .bloodPressure(systolic: 120, diastolic: 80), at: Self.at(7)),
            Self.row(.pulse, .scalar(70), at: Self.at(6))
        ]
        let offered: [MetricKind] = [.bloodPressure, .pulse]
        #expect(MeasureRecentEntryKinds.kinds(from: rows, offered: offered) == [.bloodPressure, .pulse])
    }

    @Test("only the newest sixty manual rows count")
    func manualWindow() {
        let newer = (0 ..< 60).map { Self.row(.weight, .scalar(72), at: Self.at(23).addingTimeInterval(Double(-$0) * 60)) }
        let rows = newer + [Self.row(.glucose, .scalar(90), at: Self.at(1))]
        #expect(MeasureRecentEntryKinds.kinds(from: rows, offered: [.weight, .glucose]) == [.weight])
    }

    @Test("Save and next moves to the most recent other kind, or stays")
    func nextKind() {
        #expect(MeasureRecentEntryKinds.next(after: .weight, recent: [.weight, .bloodPressure]) == .bloodPressure)
        #expect(MeasureRecentEntryKinds.next(after: .glucose, recent: [.weight, .bloodPressure]) == .weight)
        #expect(MeasureRecentEntryKinds.next(after: .weight, recent: [.weight]) == nil)
    }

    // MARK: - Glucose context default

    @Test("without a habit the hour decides: before ten fasting, from ten after a meal")
    func glucoseByHour() {
        #expect(GlucoseContextDefault.context(at: Self.at(9, 59), history: [], calendar: Self.berlin) == .fasting)
        #expect(GlucoseContextDefault.context(at: Self.at(10), history: [], calendar: Self.berlin) == .afterMeal)
        #expect(GlucoseContextDefault.context(at: Self.at(21), history: [], calendar: Self.berlin) == .afterMeal)
    }

    @Test("the person's habit within ninety minutes of the clock time wins, the newest first")
    func glucoseByHabit() {
        let history = [
            Self.row(.glucose, .scalar(110), at: Self.at(22, 30, day: 19), context: .bedtime),
            Self.row(.glucose, .scalar(90), at: Self.at(7, day: 18), context: .random),
            Self.row(.glucose, .scalar(90), at: Self.at(7, 10, day: 17), context: .fasting)
        ]
        #expect(GlucoseContextDefault.context(at: Self.at(21, 0), history: history, calendar: Self.berlin) == .bedtime)
        #expect(GlucoseContextDefault.context(at: Self.at(20, 59), history: history, calendar: Self.berlin) == .afterMeal)
        #expect(GlucoseContextDefault.context(at: Self.at(8, 30), history: history, calendar: Self.berlin) == .random)
        // A reading without a context is no habit.
        let unmarked = [Self.row(.glucose, .scalar(90), at: Self.at(21, day: 19))]
        #expect(GlucoseContextDefault.context(at: Self.at(21), history: unmarked, calendar: Self.berlin) == .afterMeal)
    }

    @Test("clock distance goes the short way round midnight")
    func clockDistance() {
        #expect(GlucoseContextDefault.clockDistance(Self.at(23, 30), Self.at(0, 30), calendar: Self.berlin) == 60)
        #expect(GlucoseContextDefault.clockDistance(Self.at(12), Self.at(13, 31), calendar: Self.berlin) == 91)
    }

    // MARK: - Edit prefill

    @Test("an edit opens in the label's unit and precision, never grouped")
    func editPrefill() {
        let de = Locale(identifier: "de_DE")
        let mmol = UnitPreferences(glucose: .mmolL)
        #expect(MeasureEditPrefill.text(100, kind: .glucose, units: mmol, locale: de) == "5,5")
        #expect(MeasureEditPrefill.text(100, kind: .glucose, units: UnitPreferences(), locale: de) == "100")
        let pounds = UnitPreferences(weight: .lb, system: .imperial)
        #expect(MeasureEditPrefill.text(72.4, kind: .weight, units: pounds, locale: de) == "159,6")
        #expect(MeasureEditPrefill.text(72.46, kind: .weight, units: UnitPreferences(), locale: de) == "72,5")
        // A kind without a fixed precision keeps up to two decimals, ungrouped.
        #expect(MeasureEditPrefill.text(1234.5, kind: .vo2Max, units: UnitPreferences(), locale: de) == "1234,5")
        #expect(MeasureEditPrefill.bloodPressureText(120, units: UnitPreferences(), locale: de) == "120")
        #expect(MeasureEditPrefill.bloodPressureText(120, units: UnitPreferences(bloodPressure: .kPa), locale: de) == "16,0")
    }
}
