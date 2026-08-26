import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// Disambiguate from Foundation.Measurement<Unit> — HealthLog ships its own
/// domain Measurement type.
private typealias Measurement = HealthLog.Measurement

/// T-7 Commit 1 — `DoctorReportSpec` + `DoctorReportSpecBuilder`.
///
/// Covers the snapshot → spec contract: in-window filtering, per-section
/// data shaping, empty-data skipping, section toggles, and the verbatim
/// disclaimer copy (MDR / Class-IIa boundary).
@MainActor
@Suite("DoctorReportSpec — local snapshot → spec")
struct DoctorReportLocalSpecTests {
    // MARK: - Fixtures

    private static let calendar = Calendar(identifier: .gregorian)
    private static let periodEnd = makeDate(2026, 5, 16, 12)
    private static let periodStart = calendar.date(byAdding: .day, value: -30, to: periodEnd) ?? periodEnd

    private static func makeDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 9) -> Date {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = hour
        comps.timeZone = TimeZone(identifier: "Europe/Berlin")
        // swiftlint:disable:next force_unwrapping
        return Calendar(identifier: .gregorian).date(from: comps)!
    }

    private static func snapshot(
        measurements: [Measurement] = [],
        medications: [Medication] = [],
        compliance: [ComplianceDay] = [],
        intakes: [MedicationIntake] = [],
        moodEntries: [MoodEntry] = []
    ) -> DoctorReportSpecBuilder.Snapshot {
        DoctorReportSpecBuilder.Snapshot(
            patientName: "Anna Fischer",
            appVersion: "0.5.0",
            measurements: measurements,
            medications: medications,
            compliance: compliance,
            intakes: intakes,
            moodEntries: moodEntries
        )
    }

    // MARK: - Cover

    @Test("cover carries patient name + period + app version + locale")
    func coverPopulatedFromSnapshot() {
        let spec = DoctorReportSpecBuilder.build(
            snapshot: Self.snapshot(),
            periodStart: Self.periodStart,
            periodEnd: Self.periodEnd,
            generatedAt: Self.periodEnd,
            locale: .de
        )
        #expect(spec.cover.patientName == "Anna Fischer")
        #expect(spec.cover.appVersion == "0.5.0")
        #expect(spec.cover.locale == .de)
        #expect(spec.cover.periodStart == Self.periodStart)
        #expect(spec.cover.periodEnd == Self.periodEnd)
        #expect(spec.cover.generatedAt == Self.periodEnd)
    }

    // MARK: - Footer / Disclaimer (MDR boundary)

    @Test("footer disclaimer (DE) is verbatim and locked")
    func footerDisclaimerDE() {
        let spec = DoctorReportSpecBuilder.build(
            snapshot: Self.snapshot(),
            periodStart: Self.periodStart,
            periodEnd: Self.periodEnd,
            locale: .de
        )
        #expect(spec.footer.disclaimer == "Lokaler Export · kein Server beteiligt · auf-Geraet erzeugt · kein medizinisches Dokument")
    }

    @Test("footer disclaimer (EN) is verbatim and locked")
    func footerDisclaimerEN() {
        let spec = DoctorReportSpecBuilder.build(
            snapshot: Self.snapshot(),
            periodStart: Self.periodStart,
            periodEnd: Self.periodEnd,
            locale: .en
        )
        #expect(spec.footer.disclaimer == "Local export · no server involved · generated on-device · not a medical document")
    }

    @Test("disclaimer matches DoctorReportDisclaimer.text(for:) for both locales")
    func disclaimerLookupIsStable() {
        #expect(DoctorReportDisclaimer.text(for: .de) == DoctorReportDisclaimer.de)
        #expect(DoctorReportDisclaimer.text(for: .en) == DoctorReportDisclaimer.en)
    }

    // MARK: - In-window filtering

    @Test("out-of-window measurements are dropped before aggregation")
    func outOfWindowMeasurementsDropped() {
        let outside = Measurement(
            id: "m-outside",
            kind: .pulse,
            recordedAt: Self.makeDate(2025, 1, 1),
            value: .scalar(72)
        )
        let inside = Measurement(
            id: "m-inside",
            kind: .pulse,
            recordedAt: Self.makeDate(2026, 5, 10),
            value: .scalar(80)
        )
        let spec = DoctorReportSpecBuilder.build(
            snapshot: Self.snapshot(measurements: [outside, inside]),
            periodStart: Self.periodStart,
            periodEnd: Self.periodEnd
        )
        let pulseRow = spec.vitals?.rows.first(where: { $0.kind == .pulse })
        #expect(pulseRow != nil)
        #expect(pulseRow?.count == 1)
        #expect(pulseRow?.mean == 80)
    }

    // MARK: - Vitals summary

    @Test("vitals row computes mean / median / min / max correctly")
    func vitalsMeanMedianMinMax() {
        let pulses = [60.0, 70, 80, 90, 100].enumerated().map { offset, value in
            Measurement(
                id: "p\(offset)",
                kind: .pulse,
                recordedAt: Self.makeDate(2026, 5, 10 + offset),
                value: .scalar(value)
            )
        }
        let spec = DoctorReportSpecBuilder.build(
            snapshot: Self.snapshot(measurements: pulses),
            periodStart: Self.periodStart,
            periodEnd: Self.periodEnd
        )
        let row = spec.vitals?.rows.first(where: { $0.kind == .pulse })
        #expect(row?.mean == 80)
        #expect(row?.median == 80)
        #expect(row?.min == 60)
        #expect(row?.max == 100)
        #expect(row?.count == 5)
    }

    @Test("blood-pressure vitals row carries diastolic secondary mean")
    func bloodPressureSecondaryMean() {
        let bps = [
            (120.0, 80.0),
            (130.0, 85.0),
            (140.0, 90.0)
        ].enumerated().map { offset, pair in
            Measurement(
                id: "bp\(offset)",
                kind: .bloodPressure,
                recordedAt: Self.makeDate(2026, 5, 10 + offset),
                value: .bloodPressure(systolic: pair.0, diastolic: pair.1)
            )
        }
        let spec = DoctorReportSpecBuilder.build(
            snapshot: Self.snapshot(measurements: bps),
            periodStart: Self.periodStart,
            periodEnd: Self.periodEnd
        )
        let row = spec.vitals?.rows.first(where: { $0.kind == .bloodPressure })
        #expect(row?.mean == 130)
        #expect(row?.secondaryMean == 85)
    }

    @Test("vitals block is nil when no in-window measurements exist")
    func vitalsNilOnEmptyWindow() {
        let spec = DoctorReportSpecBuilder.build(
            snapshot: Self.snapshot(),
            periodStart: Self.periodStart,
            periodEnd: Self.periodEnd
        )
        #expect(spec.vitals == nil)
        #expect(spec.charts == nil)
    }

    // MARK: - Charts

    @Test("charts block sorts points chronologically per kind")
    func chartsSortChronologically() {
        let weights = [
            (Self.makeDate(2026, 5, 15), 80.0),
            (Self.makeDate(2026, 5, 5), 82.0),
            (Self.makeDate(2026, 5, 10), 81.0)
        ].enumerated().map { offset, pair in
            Measurement(
                id: "w\(offset)",
                kind: .weight,
                recordedAt: pair.0,
                value: .scalar(pair.1)
            )
        }
        let spec = DoctorReportSpecBuilder.build(
            snapshot: Self.snapshot(measurements: weights),
            periodStart: Self.periodStart,
            periodEnd: Self.periodEnd
        )
        let weightSeries = spec.charts?.series.first(where: { $0.kind == .weight })
        #expect(weightSeries?.points.count == 3)
        #expect(weightSeries?.points.first?.value == 82.0)
        #expect(weightSeries?.points.last?.value == 80.0)
    }

    @Test("blood-pressure chart point carries diastolic secondary")
    func chartsBloodPressureSecondary() {
        let bp = Measurement(
            id: "bp-1",
            kind: .bloodPressure,
            recordedAt: Self.makeDate(2026, 5, 12),
            value: .bloodPressure(systolic: 125, diastolic: 82)
        )
        let spec = DoctorReportSpecBuilder.build(
            snapshot: Self.snapshot(measurements: [bp]),
            periodStart: Self.periodStart,
            periodEnd: Self.periodEnd
        )
        let point = spec.charts?.series.first(where: { $0.kind == .bloodPressure })?.points.first
        #expect(point?.value == 125)
        #expect(point?.secondary == 82)
    }

    // MARK: - Medications

    @Test("medications block splits active vs archived rows")
    func medicationsActiveArchivedSplit() {
        let active = Medication(
            id: "med-active",
            name: "Lisinopril",
            dose: "5 mg",
            treatmentClass: "ACE-Hemmer",
            schedule: MedicationSchedule(times: [TimeOfDay(hour: 8, minute: 0)]),
            active: true
        )
        let archived = Medication(
            id: "med-archived",
            name: "Metoprolol",
            dose: "50 mg",
            treatmentClass: "Beta-Blocker",
            schedule: MedicationSchedule(times: [TimeOfDay(hour: 20, minute: 0)]),
            active: false
        )
        let spec = DoctorReportSpecBuilder.build(
            snapshot: Self.snapshot(medications: [active, archived]),
            periodStart: Self.periodStart,
            periodEnd: Self.periodEnd
        )
        #expect(spec.medications?.active.count == 1)
        #expect(spec.medications?.archived.count == 1)
        #expect(spec.medications?.active.first?.name == "Lisinopril")
        #expect(spec.medications?.active.first?.schedule == "08:00")
        #expect(spec.medications?.archived.first?.name == "Metoprolol")
    }

    @Test("medications block is nil when snapshot has zero meds")
    func medicationsNilOnEmpty() {
        let spec = DoctorReportSpecBuilder.build(
            snapshot: Self.snapshot(),
            periodStart: Self.periodStart,
            periodEnd: Self.periodEnd
        )
        #expect(spec.medications == nil)
    }

    // MARK: - Adherence

    @Test("adherence per-med rate is computed from in-window intakes")
    func adherencePerMedRate() {
        let med = Medication(
            id: "med-1",
            name: "Levothyroxin",
            dose: "75 mcg",
            schedule: MedicationSchedule(times: [TimeOfDay(hour: 7, minute: 0)])
        )
        let intakes: [MedicationIntake] = (0 ..< 4).map { offset in
            MedicationIntake(
                id: "i-\(offset)",
                medicationId: "med-1",
                scheduledAt: Self.makeDate(2026, 5, 10 + offset),
                takenAt: offset < 3 ? Self.makeDate(2026, 5, 10 + offset, 8) : nil,
                status: offset < 3 ? .taken : .skipped
            )
        }
        let spec = DoctorReportSpecBuilder.build(
            snapshot: Self.snapshot(medications: [med], intakes: intakes),
            periodStart: Self.periodStart,
            periodEnd: Self.periodEnd
        )
        let row = spec.adherence?.perMedication.first
        #expect(row?.scheduled == 4)
        #expect(row?.taken == 3)
        #expect(row?.rate == 0.75)
        #expect(spec.adherence?.overall == 0.75)
    }

    @Test("adherence falls back to ComplianceDay aggregate when intakes missing")
    func adherenceFallbackToCompliance() {
        let med = Medication(
            id: "med-1",
            name: "Levothyroxin",
            dose: "75 mcg",
            schedule: MedicationSchedule(times: [TimeOfDay(hour: 7, minute: 0)])
        )
        let compliance: [ComplianceDay] = (0 ..< 3).map { offset in
            ComplianceDay(date: Self.makeDate(2026, 5, 10 + offset), scheduled: 2, taken: 1)
        }
        let spec = DoctorReportSpecBuilder.build(
            snapshot: Self.snapshot(medications: [med], compliance: compliance),
            periodStart: Self.periodStart,
            periodEnd: Self.periodEnd
        )
        #expect(spec.adherence?.perMedication.isEmpty == true)
        #expect(spec.adherence?.overall == 0.5)
    }

    @Test("adherence block is nil when no meds and no compliance")
    func adherenceNilOnEmpty() {
        let spec = DoctorReportSpecBuilder.build(
            snapshot: Self.snapshot(),
            periodStart: Self.periodStart,
            periodEnd: Self.periodEnd
        )
        #expect(spec.adherence == nil)
    }

    // MARK: - Mood

    @Test("mood block aggregates score average + dominant tags")
    func moodDominantTags() {
        let entries: [MoodEntry] = [
            MoodEntry(id: "m1", recordedAt: Self.makeDate(2026, 5, 10), score: 4, tags: ["energetic", "happy"]),
            MoodEntry(id: "m2", recordedAt: Self.makeDate(2026, 5, 11), score: 3, tags: ["tired", "happy"]),
            MoodEntry(id: "m3", recordedAt: Self.makeDate(2026, 5, 12), score: 2, tags: ["tired"])
        ]
        let spec = DoctorReportSpecBuilder.build(
            snapshot: Self.snapshot(moodEntries: entries),
            periodStart: Self.periodStart,
            periodEnd: Self.periodEnd
        )
        #expect(spec.mood?.count == 3)
        #expect(spec.mood?.averageScore == 3)
        let dominant = spec.mood?.dominantTags.map(\.tag)
        #expect(dominant?.first == "happy" || dominant?.first == "tired")
        #expect(dominant?.count == 3)
    }

    @Test("mood block is nil when no in-window entries")
    func moodNilOnEmpty() {
        let outOfWindow = MoodEntry(
            id: "old",
            recordedAt: Self.makeDate(2025, 1, 1),
            score: 4,
            tags: ["happy"]
        )
        let spec = DoctorReportSpecBuilder.build(
            snapshot: Self.snapshot(moodEntries: [outOfWindow]),
            periodStart: Self.periodStart,
            periodEnd: Self.periodEnd
        )
        #expect(spec.mood == nil)
    }

    // MARK: - Locale

    @Test("Spec.cover.locale flips disclaimer language")
    func localeDrivesDisclaimer() {
        let specDE = DoctorReportSpecBuilder.build(
            snapshot: Self.snapshot(),
            periodStart: Self.periodStart,
            periodEnd: Self.periodEnd,
            locale: .de
        )
        let specEN = DoctorReportSpecBuilder.build(
            snapshot: Self.snapshot(),
            periodStart: Self.periodStart,
            periodEnd: Self.periodEnd,
            locale: .en
        )
        #expect(specDE.footer.disclaimer.contains("Lokaler Export"))
        #expect(specEN.footer.disclaimer.contains("Local export"))
    }
}

/// Section-toggle tests split off so the main suite stays under the
/// `type_body_length` ceiling.
@MainActor
@Suite("DoctorReportSpec — section toggles")
struct DoctorReportLocalSpecSelectionTests {
    private static let calendar = Calendar(identifier: .gregorian)
    private static let periodEnd = makeDate(2026, 5, 16, 12)
    private static let periodStart = calendar.date(byAdding: .day, value: -30, to: periodEnd) ?? periodEnd

    private static func makeDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 9) -> Date {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = hour
        comps.timeZone = TimeZone(identifier: "Europe/Berlin")
        // swiftlint:disable:next force_unwrapping
        return Calendar(identifier: .gregorian).date(from: comps)!
    }

    private static func snapshot(
        measurements: [Measurement] = [],
        medications: [Medication] = [],
        compliance: [ComplianceDay] = [],
        intakes: [MedicationIntake] = [],
        moodEntries: [MoodEntry] = []
    ) -> DoctorReportSpecBuilder.Snapshot {
        DoctorReportSpecBuilder.Snapshot(
            patientName: "Anna Fischer",
            appVersion: "0.5.0",
            measurements: measurements,
            medications: medications,
            compliance: compliance,
            intakes: intakes,
            moodEntries: moodEntries
        )
    }

    @Test("toggling a section off zeros out that field even with data")
    func selectionDropsToggledSections() {
        let pulse = Measurement(
            id: "p1",
            kind: .pulse,
            recordedAt: Self.makeDate(2026, 5, 12),
            value: .scalar(72)
        )
        let med = Medication(
            id: "med-1",
            name: "Lisinopril",
            dose: "5 mg",
            schedule: MedicationSchedule(times: [TimeOfDay(hour: 8, minute: 0)])
        )
        let entries = [MoodEntry(id: "m1", recordedAt: Self.makeDate(2026, 5, 11), score: 4, tags: ["ok"])]
        let snapshot = Self.snapshot(measurements: [pulse], medications: [med], moodEntries: entries)
        let selection = DoctorReportSectionSelection(
            vitals: false,
            charts: false,
            medications: true,
            adherence: false,
            mood: false
        )
        let spec = DoctorReportSpecBuilder.build(
            snapshot: snapshot,
            periodStart: Self.periodStart,
            periodEnd: Self.periodEnd,
            selection: selection
        )
        #expect(spec.vitals == nil)
        #expect(spec.charts == nil)
        #expect(spec.medications != nil)
        #expect(spec.adherence == nil)
        #expect(spec.mood == nil)
    }

    @Test("`.all` selection retains every populated section")
    func selectionAllRetainsEverything() {
        let pulse = Measurement(
            id: "p1",
            kind: .pulse,
            recordedAt: Self.makeDate(2026, 5, 12),
            value: .scalar(72)
        )
        let med = Medication(
            id: "med-1",
            name: "Lisinopril",
            dose: "5 mg",
            schedule: MedicationSchedule(times: [TimeOfDay(hour: 8, minute: 0)])
        )
        let intake = MedicationIntake(
            id: "i1",
            medicationId: "med-1",
            scheduledAt: Self.makeDate(2026, 5, 12),
            takenAt: Self.makeDate(2026, 5, 12, 8),
            status: .taken
        )
        let entries = [MoodEntry(id: "m1", recordedAt: Self.makeDate(2026, 5, 11), score: 4, tags: ["ok"])]
        let snapshot = Self.snapshot(
            measurements: [pulse],
            medications: [med],
            intakes: [intake],
            moodEntries: entries
        )
        let spec = DoctorReportSpecBuilder.build(
            snapshot: snapshot,
            periodStart: Self.periodStart,
            periodEnd: Self.periodEnd,
            selection: .all
        )
        #expect(spec.vitals != nil)
        #expect(spec.charts != nil)
        #expect(spec.medications != nil)
        #expect(spec.adherence != nil)
        #expect(spec.mood != nil)
    }

    @Test("`.none` selection drops every section regardless of data")
    func selectionNoneDropsEverything() {
        let pulse = Measurement(
            id: "p1",
            kind: .pulse,
            recordedAt: Self.makeDate(2026, 5, 12),
            value: .scalar(72)
        )
        let med = Medication(
            id: "med-1",
            name: "Lisinopril",
            dose: "5 mg",
            schedule: MedicationSchedule(times: [TimeOfDay(hour: 8, minute: 0)])
        )
        let snapshot = Self.snapshot(measurements: [pulse], medications: [med])
        let spec = DoctorReportSpecBuilder.build(
            snapshot: snapshot,
            periodStart: Self.periodStart,
            periodEnd: Self.periodEnd,
            selection: .none
        )
        #expect(spec.vitals == nil)
        #expect(spec.charts == nil)
        #expect(spec.medications == nil)
        #expect(spec.adherence == nil)
        #expect(spec.mood == nil)
        // Cover + Footer always present.
        #expect(spec.cover.patientName == "Anna Fischer")
        #expect(!spec.footer.disclaimer.isEmpty)
    }
}
