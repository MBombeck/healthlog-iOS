import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

private typealias Measurement = HealthLog.Measurement

/// The doctor report takes the server's figures:
/// pulse per the v1.40.1 rule (a day is the mean of its hours, a window the
/// mean of its days), and adherence from `GET /api/medications/compliance`
/// with `meta.aggregate` and `?days=`. Fixtures follow
/// `MedicationComplianceAggregate` / `ListMedicationComplianceResponse` and
/// `MeasurementsSeriesBatchResponse` in `docs/api/openapi.yaml` on
/// `release/v1.43.0` (`d06ce3604`).
@MainActor
@Suite("Doctor report takes the server's pulse and adherence figures (#119, #126)")
struct DoctorReportServerFiguresTests {
    private static var utc: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        return cal
    }

    private static let day = Date(timeIntervalSince1970: 1_760_000_000) // 2025-10-09
    private static let periodEnd = day.addingTimeInterval(86400 * 2)
    private static let periodStart = day.addingTimeInterval(-86400 * 88)

    private static func pulse(_ value: Double, at offset: TimeInterval) -> Measurement {
        Measurement(
            id: UUID().uuidString,
            kind: .pulse,
            recordedAt: utc.startOfDay(for: day).addingTimeInterval(offset),
            value: .scalar(value),
            source: .manual
        )
    }

    /// One busy hour (60 readings at 120) and one quiet hour (one reading at
    /// 60) on the same day: the raw mean is about 119, the day is 90.
    private static var busyAndQuiet: [Measurement] {
        (0 ..< 60).map { pulse(120, at: 10 * 3600 + Double($0) * 60) } + [pulse(60, at: 3 * 3600)]
    }

    private func pulseRow(_ spec: DoctorReportSpec) -> DoctorReportSpec.VitalsSummary.Row? {
        spec.vitals?.rows.first { $0.kind == .pulse }
    }

    // MARK: - Pulse

    @Test("Without server days the pulse row follows the rule: hour means, then the day, not the raw mean")
    func pulseRuleOverReadings() throws {
        let snapshot = DoctorReportSpecBuilder.Snapshot(
            patientName: "P", appVersion: "1", measurements: Self.busyAndQuiet, medications: [], moodEntries: []
        )
        let spec = DoctorReportSpecBuilder.build(
            snapshot: snapshot, periodStart: Self.periodStart, periodEnd: Self.periodEnd, calendar: Self.utc
        )
        let row = try #require(pulseRow(spec))
        #expect(row.mean == 90)
        #expect(row.count == 61)
        #expect(row.min == 60)
        #expect(row.max == 120)
    }

    @Test("With the server's day values the row uses them: mean and median of days, min and max of the days")
    func pulseFromServerDays() throws {
        let days = [
            DailyPulseValue(day: Self.day, mean: 70, count: 400, min: 48, max: 150),
            DailyPulseValue(day: Self.day.addingTimeInterval(86400), mean: 80, count: 300, min: 52, max: 131)
        ]
        let snapshot = DoctorReportSpecBuilder.Snapshot(
            patientName: "P", appVersion: "1", measurements: Self.busyAndQuiet, medications: [],
            serverPulseDays: days, moodEntries: []
        )
        let spec = DoctorReportSpecBuilder.build(
            snapshot: snapshot, periodStart: Self.periodStart, periodEnd: Self.periodEnd, calendar: Self.utc
        )
        let row = try #require(pulseRow(spec))
        #expect(row.mean == 75)
        #expect(row.median == 75)
        #expect(row.min == 48)
        #expect(row.max == 150)
        #expect(row.count == 700)
    }

    @Test("The series-batch PULSE rows decode; an unreadable row is dropped")
    func seriesBatchDecodes() throws {
        let json = """
        {"series": {"PULSE": [
          {"type": "PULSE", "value": 71.5, "measuredAt": "2026-10-01T22:00:00.000Z", "count": 288, "minValue": 51, "maxValue": 140},
          {"type": "PULSE", "value": "x", "measuredAt": "2026-10-02T22:00:00.000Z"},
          {"type": "PULSE", "value": 68, "measuredAt": "2026-10-02T22:00:00Z", "count": 12, "minValue": null, "maxValue": null}
        ], "WEIGHT": []}}
        """
        let wire = try JSONDecoder.hlDefault.decode(SeriesBatchPulseWire.self, from: Data(json.utf8))
        #expect(wire.days.map(\.mean) == [71.5, 68])
        #expect(wire.days.first?.count == 288)
        #expect(wire.days.first?.max == 140)
        #expect(wire.days.last?.min == nil)
    }

    // MARK: - Adherence

    private static let complianceJSON = """
    {"data": [
      {"medicationId": "m1", "compliance7": {"totalExpected": 7, "taken": 7, "skipped": 0, "missed": 0, "rate": 100, "streak": 7},
       "compliance30": {"totalExpected": 30, "taken": 27, "skipped": 0, "missed": 3, "rate": 90, "streak": 4},
       "compliance90": {"totalExpected": 90, "taken": 80, "skipped": 1, "missed": 9, "rate": 90, "streak": 4},
       "complianceDisplay": null, "applicable": true, "notApplicableReason": null},
      {"medicationId": "m2", "compliance7": {"totalExpected": 1, "taken": 0, "skipped": 0, "missed": 1, "rate": 0, "streak": 0},
       "compliance30": {"totalExpected": 4, "taken": 3, "skipped": 0, "missed": 1, "rate": 75, "streak": 0},
       "compliance90": {"totalExpected": 13, "taken": 12, "skipped": 0, "missed": 1, "rate": 92, "streak": 0},
       "complianceDisplay": null, "applicable": true, "notApplicableReason": null}
    ], "error": null, "meta": {"aggregate": {
       "compliance7": {"totalExpected": 8, "taken": 7, "skipped": 0, "missed": 1, "rate": 88, "streak": 0},
       "compliance30": {"totalExpected": 34, "taken": 30, "skipped": 0, "missed": 4, "rate": 88, "streak": 0},
       "compliance90": {"totalExpected": 103, "taken": 92, "skipped": 1, "missed": 10, "rate": 90, "streak": 0},
       "medicationCount": 2}, "days": 90}}
    """

    private static func report(_ json: String = complianceJSON) throws -> MedicationComplianceReport {
        try JSONDecoder.hlDefault.decode(MedicationComplianceListWire.self, from: Data(json.utf8)).report
    }

    private static func medication(_ id: String) -> Medication {
        Medication(
            id: id, name: "Med \(id)", dose: "1",
            schedule: MedicationSchedule(times: [TimeOfDay(hour: 8, minute: 0)])
        )
    }

    @Test("meta.aggregate and the ?days= blocks decode beside the rows")
    func complianceMetaDecodes() throws {
        let report = try Self.report()
        #expect(report.entries.count == 2)
        #expect(report.days == 90)
        #expect(report.rowWindows["m1"]?.rate == 90)
        #expect(report.rowWindows["m2"]?.taken == 12)
        #expect(report.aggregate?.medicationCount == 2)
        #expect(report.aggregate?.window(days: 90)?.rate == 90)
        #expect(report.aggregate?.window(days: 7)?.rate == 88)
    }

    @Test("A server before v1.42.0 (no meta) decodes the rows with no aggregate")
    func complianceWithoutMeta() throws {
        let report = try Self.report(#"{"data": [], "error": null}"#)
        #expect(report.aggregate == nil)
        #expect(report.days == nil)
    }

    @Test("The report covers its own period with the server's rows and account figure")
    func adherenceUsesReportWindow() throws {
        let report = try Self.report()
        let block = try #require(DoctorReportSpecBuilder.makeAdherenceBlock(
            medications: [Self.medication("m1"), Self.medication("m2")],
            serverCompliance: report.entries,
            periodDays: 90,
            report: report
        ))
        #expect(block.windowDays == 90)
        #expect(block.windowMatchesPeriod)
        #expect(block.perMedication.map(\.rate) == [90, 92])
        #expect(block.perMedication.map(\.expected) == [89, 13])
        let account = try #require(block.account)
        #expect(account.rate == 90)
        #expect(account.taken == 92)
        #expect(account.expected == 102)
        let notes = LocaleText.adherenceNotes(for: block, locale: .en)
        #expect(notes.count == 2)
        #expect(notes[1].hasPrefix("All medications (2): 92 of 102 taken"))
    }

    @Test("A window the server did not answer for falls back to 30 days and says so")
    func adherenceFallsBackTo30() throws {
        let report = try Self.report()
        let block = try #require(DoctorReportSpecBuilder.makeAdherenceBlock(
            medications: [Self.medication("m1"), Self.medication("m2")],
            serverCompliance: report.entries,
            periodDays: 180,
            report: report
        ))
        #expect(block.windowDays == 30)
        #expect(!block.windowMatchesPeriod)
        #expect(block.perMedication.map(\.rate) == [90, 75])
        #expect(block.account?.rate == 88)
    }

    // MARK: - Widget

    @Test("The widget ring takes the account figure for several medications, only for the ids it covered")
    func widgetUsesAggregate() throws {
        let report = try Self.report()
        let snapshots: [String: MedicationsStore.ComplianceCardSnapshot] = [
            "m1": .init(rate7: 100, rate30: 90),
            "m2": .init(rate7: 0, rate30: 75)
        ]
        #expect(AppContainer.serverCompliancePercent(activeIDs: ["m1", "m2"], snapshots: snapshots) == nil)
        #expect(AppContainer.serverCompliancePercent(
            activeIDs: ["m1", "m2"], snapshots: snapshots, aggregate: report.aggregate
        ) == 88)
        let mirror = MedicationComplianceAggregateMirror()
        mirror.record(report)
        #expect(mirror.aggregate(matching: ["m1", "m2"]) == report.aggregate)
        #expect(mirror.aggregate(matching: ["m1", "m3"]) == nil)
        #expect(mirror.aggregate(matching: []) == nil)
        mirror.clear()
        #expect(mirror.aggregate(matching: ["m1", "m2"]) == nil)
    }
}
