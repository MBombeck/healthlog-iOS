import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **#115 P2 — the surfaces the sweep routed through the account unit.**
///
/// One case per surface that printed a canonical value (or a hard-coded
/// "kg" / "°C" / "km") on an imperial account before P2. Every case runs the
/// same canonical input through the imperial account and the metric one, so a
/// surface that stops converting fails here, and a metric account that starts
/// converting fails too.
@Suite("#115 P2 — surfaces in the account's unit")
struct AccountUnitSurfaceTests {
    private let imperial = AccountUnitDisplayTests.imperial
    private let metric = AccountUnitDisplayTests.metric
    private let posix = Locale(identifier: "en_US_POSIX")

    /// The account signed in "now", switchable mid-test.
    final class SignedIn: @unchecked Sendable {
        var id = "u1"
    }

    private func measurement(_ kind: MetricKind, _ value: Double, daysAgo: Int = 1) -> HealthLog.Measurement {
        HealthLog.Measurement(
            id: "\(kind.rawValue)-\(daysAgo)-\(value)",
            kind: kind,
            recordedAt: Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date(),
            value: .scalar(value)
        )
    }

    private func record(_ type: String, value: Double, unit: String) -> PersonalRecordDTO {
        PersonalRecordDTO(
            id: "r-\(type)", userId: "u1", metricType: type, metricSlot: nil, direction: .max,
            value: value, unit: unit, achievedAt: Date(timeIntervalSince1970: 1_780_000_000),
            sourceMeasurementId: nil, source: "MANUAL", externalId: nil,
            createdAt: Date(timeIntervalSince1970: 1_780_000_000)
        )
    }

    // MARK: - Entry paths

    @Test("Measure/Edit sheet: a typed °F / lb / in value stores canonical")
    func entryInvertsToCanonical() {
        #expect(abs(MeasureEntryConversion.canonicalScalar(98.6, kind: .bodyTemperature, units: imperial) - 37) < 1e-9)
        #expect(abs(MeasureEntryConversion.canonicalScalar(33.0709, kind: .waistCircumference, units: imperial) - 84) < 1e-3)
        #expect(abs(MeasureEntryConversion.canonicalScalar(66.1387, kind: .muscleMass, units: imperial) - 30) < 1e-3)
        #expect(MeasureEntryConversion.entrySuffix(kind: .bodyTemperature, units: imperial) == "°F")
        #expect(MeasureEntryConversion.canonicalScalar(37, kind: .bodyTemperature, units: metric) == 37)
    }

    @Test("Illness fever: °F typed, °C stored at 2 decimals; metric verbatim")
    func feverEntry() {
        #expect(LogDaySheet.canonicalFeverC(101.3, units: imperial) == 38.5)
        #expect(LogDaySheet.canonicalFeverC(38.45, units: metric) == 38.45)
    }

    @Test("Siri: a spoken lb / °F value is stored as kg / °C and spoken back in its unit")
    func siriWeightAndTemperature() {
        #expect(abs(MeasurableKindAppEnum.weight.canonicalValue(180, units: imperial) - 81.6466) < 1e-3)
        #expect(abs(MeasurableKindAppEnum.bodyTemperature.canonicalValue(100.4, units: imperial) - 38) < 1e-9)
        #expect(MeasurableKindAppEnum.weight.spokenUnit(units: imperial).key == "intents.unit.lb")
        #expect(MeasurableKindAppEnum.bodyTemperature.spokenUnit(units: imperial).key == "intents.unit.fahrenheit")
        #expect(MeasurableKindAppEnum.weight.canonicalValue(80, units: metric) == 80)
        #expect(MeasurableKindAppEnum.weight.spokenUnit(units: metric).key == "intents.unit.kg")
        #expect(MeasurableKindAppEnum.pulse.canonicalValue(72, units: imperial) == 72)
    }

    @Test("Siri reads the account's units from the App-Group mirror, per account")
    func siriAccountUnitsFromSharedMirror() throws {
        let suite = "p2.units.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let user = SignedIn()
        let shared = SharedAccountPrefs(defaults: defaults, currentUserID: { user.id })
        let appDefaults = try #require(UserDefaults(suiteName: suite + ".app"))
        defer { appDefaults.removePersistentDomain(forName: suite + ".app") }

        #expect(IntentDependencies.accountUnits(shared: shared, appDefaults: appDefaults).system == .metric)
        shared.setAccountUnits(system: .imperial, weight: .lb)
        let units = IntentDependencies.accountUnits(shared: shared, appDefaults: appDefaults)
        #expect(units.system == .imperial)
        #expect(units.weight == .lb)
        user.id = "u2"
        #expect(shared.unitSystem() == nil, "another account never reads the previous account's units")
        shared.clear()
        #expect(defaults.string(forKey: SharedAccountPrefs.unitSystemKey) == nil)
    }

    #if DEBUG
        @Test("The imperial hermetic overlay decodes through the app's real DTOs")
        func imperialFixturesDecode() throws {
            let targets = try JSONDecoder().decode(
                InsightsTargetsResponseDTO.self,
                from: Data(ImperialUnitFixtures.targetsJSON.utf8)
            )
            #expect(targets.targets.first?.range == .init(min: 61.9, max: 83.3))
            #expect(targets.targets.first?.unit == "kg")
            let prefs = try JSONDecoder().decode(AuthMeServerPrefs.self, from: Data(ImperialUnitFixtures.meJSON.utf8))
            #expect(prefs.unitPreference == "imperial")
        }
    #endif

    // MARK: - Display surfaces

    @Test("Personal record: canonical row prints in lb; a foreign stamp is left alone")
    func personalRecords() {
        let weight = record("WEIGHT", value: 73.5, unit: "kg")
        #expect(weight.displayUnit(imperial) == "lb")
        #expect(abs(weight.displayValue(imperial) - 162.04) < 0.01)
        #expect(CelebrationOverlay.valueText(for: weight, units: imperial).hasSuffix(" lb"))
        #expect(weight.displayUnit(metric) == "kg")
        #expect(weight.displayValue(metric) == 73.5)
        let temp = record("BODY_TEMPERATURE", value: 37, unit: "°C")
        #expect(temp.displayUnit(imperial) == "°F")
        let foreign = record("WEIGHT", value: 160, unit: "lbs")
        #expect(foreign.displayValue(imperial) == 160)
        #expect(foreign.displayUnit(imperial) == "lbs")
    }

    @Test("Insights vitals tiles: weight and temperature in the account's unit")
    func vitalsTiles() {
        let pool = [
            DashboardMetric(
                id: "w", kind: .weight, title: "", latestValue: 73.5, secondaryValue: nil,
                unit: "kg", trend: .flat, sparkline: [], updatedAt: nil
            ),
            DashboardMetric(
                id: "t", kind: .bodyTemperature, title: "", latestValue: 37, secondaryValue: nil,
                unit: "°C", trend: .flat, sparkline: [], updatedAt: nil
            )
        ]
        let tiles = InsightsVitalsDashboard.tiles(from: pool, units: imperial)
        let weight = tiles.first { $0.kind == .weight }
        let temp = tiles.first { $0.kind == .bodyTemperature }
        #expect(weight?.valueText.hasSuffix(" lb") == true)
        #expect(temp?.valueText.hasSuffix(" °F") == true)
        let metricTiles = InsightsVitalsDashboard.tiles(from: pool, units: metric)
        #expect(metricTiles.first { $0.kind == .weight }?.valueText.hasSuffix(" kg") == true)
    }

    @Test("Insights trends row: latest value in lb")
    func trendsRow() throws {
        let rows = [measurement(.weight, 74, daysAgo: 5), measurement(.weight, 73.5, daysAgo: 1)]
        let chart = try #require(InsightsTrendsRow.chart(for: .weight, in: rows, units: imperial))
        #expect(chart.valueText.hasSuffix(" lb"))
        #expect(chart.valueText.hasPrefix(162.04.formatted(.number.precision(.fractionLength(1)))))
    }

    @Test("Statistik briefing floor: weight finding in lb")
    func briefingFloor() throws {
        let briefing = try #require(StatistikModeBriefingService.compose(
            measurements: [measurement(.weight, 73.5, daysAgo: 1)],
            moodEntries: [],
            compliance: nil,
            healthScore: nil,
            locale: posix,
            units: imperial
        ))
        let finding = try #require(briefing.keyFindings.first { $0.sourceMetric == "weight" })
        #expect(finding.detail.hasSuffix(" lb"))
        #expect(!finding.detail.contains("kg"))
    }

    @Test("Cycle phase board: °C average → °F, a phase DELTA by the factor alone")
    func cyclePhaseBoard() {
        let level = CycleInsightFormatting.formatted(36.5, display: .celsius, units: imperial, isDelta: false)
        let delta = CycleInsightFormatting.formatted(0.3, display: .celsius, units: imperial, isDelta: true)
        #expect(level == "\(97.7.formatted(.number.precision(.fractionLength(1)))) °F")
        #expect(delta == "\(0.54.formatted(.number.precision(.fractionLength(1)))) °F")
        let weight = CycleInsightFormatting.formatted(73.5, display: .kilograms, units: imperial, isDelta: false)
        #expect(weight.hasSuffix(" lb"))
    }

    @Test("Cycle BBT capture label reads °F on an imperial account")
    func cycleBBTLabel() {
        #expect(CycleCaptureSheet.bbtFormatted(36.5, units: imperial).hasSuffix(" °F"))
    }

    @Test("Workouts: distance and pace follow the account, not the device locale")
    func workouts() {
        #expect(WorkoutFormatter.distanceLabel(metres: 5000, locale: posix, system: .imperial) == "3.11 mi")
        #expect(WorkoutFormatter.distanceLabel(metres: 5000, locale: posix, system: .metric) == "5.0 km")
        #expect(WorkoutFormatter.paceLabel(secondsPerKm: 330, system: .imperial) == "8:51 /mi")
        #expect(WorkoutFormatter.paceLabel(secondsPerKm: 330, system: .metric) == "5:30 /km")
    }

    @Test("About me: 180 cm reads 5 ft 11 in")
    func heightFeetInches() throws {
        let height = try #require(UnitPreferences.feetAndInches(fromCentimetres: 180))
        #expect(height.feet == 5)
        #expect(height.inches == 11)
        #expect(UnitPreferences.feetAndInches(fromCentimetres: .nan) == nil)
    }

    #if canImport(UIKit)
        @Test("Doctor report PDF: weight / temperature in the account's unit, BP stays mmHg")
        func doctorReport() {
            let units = UnitPreferences(weight: .lb, bloodPressure: .mmHg, glucose: .mgdL, system: .imperial)
            #expect(ValueFormatter.format(73.5, kind: .weight, units: units).hasSuffix(" lb"))
            #expect(ValueFormatter.format(37, kind: .bodyTemperature, units: units).hasSuffix(" °F"))
            #expect(ValueFormatter.format(120, kind: .bloodPressure, units: units).hasSuffix(" mmHg"))
            #expect(ValueFormatter.format(73.5, kind: .weight, units: metric).hasSuffix(" kg"))
            #expect(ValueFormatter.format(73.5, kind: .weight) == ValueFormatter.format(73.5, kind: .weight, units: metric))
        }

        @Test("Doctor report spec: prints in the account's units, glucose from the spec, BP always mmHg")
        func doctorReportPrintUnits() {
            let spec = DoctorReportSpec(
                cover: DoctorReportSpec.Cover(
                    patientName: "Test",
                    periodStart: Date(timeIntervalSince1970: 1_700_000_000),
                    periodEnd: Date(timeIntervalSince1970: 1_702_592_000),
                    generatedAt: Date(timeIntervalSince1970: 1_702_600_000),
                    appVersion: "1.1.0",
                    locale: .en
                ),
                vitals: nil, charts: nil, medications: nil, adherence: nil, mood: nil,
                footer: .init(disclaimer: DoctorReportDisclaimer.en),
                glucoseUnit: .mmolL,
                accountUnits: UnitPreferences(weight: .lb, bloodPressure: .kPa, glucose: .mgdL, system: .imperial)
            )
            let units = spec.printUnits
            #expect(units.weight == .lb)
            #expect(units.system == .imperial)
            #expect(units.glucose == .mmolL)
            #expect(units.bloodPressure == .mmHg)
            #expect(ValueFormatter.format(37, kind: .bodyTemperature, units: units).hasSuffix(" °F"))
        }
    #endif
}

/// The chart detail: plot, y-axis unit, audio graph, fullscreen.
@Suite("#115 P2 — chart detail in the account's unit", .serialized, .mockURLSession)
@MainActor
struct AccountUnitChartTests {
    private func makeStore(kind: MetricKind) throws -> ChartDetailStore {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.5.0",
            buildNumber: "1"
        )
        let keychain = InMemoryKeychain()
        try? keychain.setString("token", forKey: KeychainKey.authToken)
        let api = APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock())
        return try ChartDetailStore(
            kind: kind,
            measurementsRepo: MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true)),
            insightsRepo: MetricInsightsRepository(api: api),
            resolveLocale: { "en" }
        )
    }

    private func series(_ kind: MetricKind, _ values: [Double], unit: String) -> MeasurementSeries {
        let base = Date(timeIntervalSince1970: 1_780_000_000)
        let points = values.enumerated().map { index, value in
            SeriesPoint(id: "\(index)", at: base.addingTimeInterval(Double(index) * 86400), value: value, secondary: nil)
        }
        let stats = SeriesStats(
            mean: values.reduce(0, +) / Double(values.count),
            min: values.min() ?? 0,
            max: values.max() ?? 0,
            stdDev: 1,
            count: values.count
        )
        return MeasurementSeries(kind: kind, points: points, stats: stats, unit: unit)
    }

    @Test("Weight chart plots lb on a lb axis; the metric chart is untouched")
    func weightPlot() throws {
        let store = try makeStore(kind: .weight)
        store.series = series(.weight, [73, 73.5, 74], unit: "kg")
        let imperial = AccountUnitDisplayTests.imperial
        let plotted = store.plotPoints(units: imperial)
        #expect(abs(plotted[1].value - 162.04) < 0.01)
        #expect(plotted.map(\.id) == store.chartPoints.map(\.id))
        #expect(store.displayUnit(units: imperial) == "lb")
        let described = store.accessibilitySeries(units: imperial)
        #expect(abs(described.stats.max - 163.14) < 0.01)
        #expect(abs(described.stats.stdDev - 2.2046) < 0.001, "a spread converts by the factor")
        #expect(store.plotPoints(units: AccountUnitDisplayTests.metric).map(\.value) == [73, 73.5, 74])
        #expect(store.displayUnit(units: AccountUnitDisplayTests.metric) == "kg")
    }

    @Test("Temperature chart: °F points, a delta without the +32")
    func temperaturePlot() throws {
        let store = try makeStore(kind: .bodyTemperature)
        store.series = series(.bodyTemperature, [36.5, 37], unit: "°C")
        let imperial = AccountUnitDisplayTests.imperial
        #expect(abs(store.plotPoints(units: imperial)[1].value - 98.6) < 1e-9)
        #expect(store.displayUnit(units: imperial) == "°F")
        #expect(abs(store.convertDelta(0.5, units: imperial) - 0.9) < 1e-9)
    }

    @Test("Glucose series is server-converted: plotted as received")
    func glucoseSeriesPassesThrough() throws {
        let store = try makeStore(kind: .glucose)
        store.series = series(.glucose, [5.2, 5.6], unit: "mmol/L")
        let units = store.effectiveUnits(AccountUnitDisplayTests.imperial)
        #expect(store.plotPoints(units: units).map(\.value) == [5.2, 5.6])
        #expect(store.displayUnit(units: units) == "mmol/L")
    }
}
