import Foundation
@testable import HealthLog
import ModelsR4
import Testing

private typealias Measurement = HealthLog.Measurement

/// **#115 B5 — the local doctor report prints glucose in the account's unit.**
///
/// The PDF wrote canonical mg/dL with an mg/dL label for every account. Not a
/// wrong value, but an mmol/L account handed its doctor a report in the one
/// unit it never reads. The PDF now converts at print time; the spec stays
/// canonical, because the FHIR bundle generated beside it must carry UCUM mg/dL.
@Suite("#115 B5 — doctor report glucose in the account unit")
struct DoctorReportGlucoseUnitTests {
    private static let at = Date(timeIntervalSince1970: 1_790_000_000)

    /// Parses the number the formatter printed, in the locale it printed it in.
    private func number(in text: String, suffix: String) throws -> Double {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let raw = String(text.dropLast(suffix.count + 1))
        return try #require(formatter.number(from: raw)).doubleValue
    }

    // MARK: - Vitals table

    @Test("an mmol/L account's glucose row prints in mmol/L with one decimal")
    func vitalsPrintInMmol() throws {
        let text = ValueFormatter.format(95.4, kind: .glucose, glucoseUnit: .mmolL)
        #expect(text.hasSuffix(" mmol/L"), "got \(text)")
        #expect(try number(in: text, suffix: "mmol/L") == 5.3)
    }

    @Test("an mg/dL account's glucose row is unchanged: whole mg/dL")
    func vitalsPrintInMgdl() throws {
        let text = ValueFormatter.format(95.4, kind: .glucose, glucoseUnit: .mgdL)
        #expect(text.hasSuffix(" mg/dL"), "got \(text)")
        #expect(try number(in: text, suffix: "mg/dL") == 95)
    }

    @Test("every other kind ignores the glucose unit")
    func otherKindsUntouched() {
        #expect(
            ValueFormatter.format(72.4, kind: .weight, glucoseUnit: .mmolL)
                == ValueFormatter.format(72.4, kind: .weight)
        )
    }

    // MARK: - Chart

    @Test("the glucose chart plots in the account unit, other series untouched")
    func chartSeriesConverted() {
        let glucose = DoctorReportSpec.ChartsBlock.Series(
            kind: .glucose,
            points: [.init(at: Self.at, value: 90.0909), .init(at: Self.at.addingTimeInterval(60), value: 180.182)]
        )
        let shown = DoctorReportGlucoseDisplay.series(glucose, glucoseUnit: .mmolL)
        #expect(shown.points.map { ($0.value * 10).rounded() / 10 } == [5.0, 10.0])
        #expect(shown.points.map(\.at) == glucose.points.map(\.at))

        let weight = DoctorReportSpec.ChartsBlock.Series(kind: .weight, points: [.init(at: Self.at, value: 72.4)])
        #expect(DoctorReportGlucoseDisplay.series(weight, glucoseUnit: .mmolL) == weight)
        #expect(DoctorReportGlucoseDisplay.series(glucose, glucoseUnit: .mgdL) == glucose)
    }

    // MARK: - Spec + FHIR

    @MainActor
    @Test("the spec carries the unit but keeps glucose values canonical mg/dL")
    func specStaysCanonical() throws {
        let spec = makeSpec(unit: .mmolL)
        #expect(spec.glucoseUnit == .mmolL)
        let row = try #require(spec.vitals?.rows.first { $0.kind == .glucose })
        #expect(row.mean == 95.4)
    }

    @MainActor
    @Test("the FHIR bundle beside an mmol/L PDF stays UCUM mg/dL")
    func fhirStaysMgdl() throws {
        let bundle = try DoctorReportToFHIRBundle.bundle(from: makeSpec(unit: .mmolL))
        let observations = try #require(bundle.entry).compactMap { entry -> Observation? in
            if case let .observation(observation) = entry.resource { return observation }
            return nil
        }
        let quantities = observations.compactMap { observation -> Quantity? in
            if case let .quantity(quantity) = observation.value { return quantity }
            return nil
        }
        let glucose = try #require(quantities.first { $0.unit?.value?.string == "mg/dL" })
        let value = try #require(glucose.value?.value?.decimal)
        #expect(abs(NSDecimalNumber(decimal: value).doubleValue - 95.4) < 0.0001)
        #expect(!quantities.contains { $0.unit?.value?.string == "mmol/L" })
    }

    @MainActor
    private func makeSpec(unit: GlucoseUnit) -> DoctorReportSpec {
        let snapshot = DoctorReportSpecBuilder.Snapshot(
            patientName: "Anna",
            appVersion: "1.1.0",
            measurements: [
                Measurement(id: "g-1", kind: .glucose, recordedAt: Self.at, value: .scalar(95.4), source: .manual)
            ],
            medications: [],
            moodEntries: [],
            glucoseUnit: unit
        )
        return DoctorReportSpecBuilder.build(
            snapshot: snapshot,
            periodStart: Self.at.addingTimeInterval(-86400),
            periodEnd: Self.at.addingTimeInterval(86400),
            generatedAt: Self.at,
            locale: .de
        )
    }
}

/// The report store hands the account unit to the builder.
@MainActor
@Suite("#115 B5 — LocalDoctorReportStore passes the account glucose unit")
struct LocalDoctorReportGlucoseUnitTests {
    @Test("the snapshot carries the settings store's glucose unit")
    func snapshotCarriesUnit() throws {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let defaults = try #require(UserDefaults(suiteName: "b5.report.\(UUID().uuidString)"))
        let settingsStore = SettingsStore(repo: SettingsRepository(api: api), defaults: defaults)
        settingsStore.glucoseUnit = .mmolL
        let store = LocalDoctorReportStore(
            measurementsStore: MeasurementsStore(repo: MeasurementsRepository(api: api, outbox: outbox)),
            medicationsStore: MedicationsStore(repo: MedicationsRepository(api: api, outbox: outbox)),
            moodStore: MoodStore(repo: MoodRepository(api: api, outbox: outbox)),
            settingsStore: settingsStore
        )
        #expect(store.makeSnapshot().glucoseUnit == .mmolL)
    }
}
