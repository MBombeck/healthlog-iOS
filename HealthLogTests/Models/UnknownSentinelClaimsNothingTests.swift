import Foundation
import Testing

#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

// swiftlint:disable force_unwrapping

private typealias Measurement = HealthLog.Measurement

/// **Audit B-4, fix round 1 — the sentinel keeps its place in a list and makes
/// no claim anywhere else.**
///
/// Carrying an unknown row was the point of the change; letting it speak was
/// not. `.unknown` is a BUCKET, not a kind: two rows on it may carry two
/// different server types this build cannot name, so any figure derived across
/// them — a mean, a min/max band, a "your latest reading" headline — is a
/// number about nothing. These cases pin the four surfaces where it still spoke.
@Suite("Audit B-4 — the unknown sentinel claims nothing")
struct UnknownSentinelClaimsNothingTests {
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    private static func row(
        _ id: String,
        kind: MetricKind,
        value: Double,
        minutesAgo: Int,
        source: MeasurementSource = .manual
    ) -> Measurement {
        Measurement(
            id: id,
            kind: kind,
            recordedAt: now.addingTimeInterval(-Double(minutesAgo) * 60),
            value: .scalar(value),
            source: source
        )
    }

    // MARK: - The shared selection: a glance headline is a named reading

    @Test("The newest row overall may be unknown; the headline reading is the newest NAMED one")
    func latestNamedSkipsTheSentinel() {
        let rows = [
            Self.row("unknown-newest", kind: .unknown, value: 9000, minutesAgo: 1),
            Self.row("weight-older", kind: .weight, value: 72.4, minutesAgo: 30),
            Self.row("pulse-oldest", kind: .pulse, value: 61, minutesAgo: 90)
        ]
        let latest = Measurement.latestNamedReading(in: rows)
        #expect(latest?.id == "weight-older")
    }

    @Test("With nothing but unknown rows there is no headline reading at all")
    func latestNamedIsNilWhenEverythingIsUnknown() {
        let rows = [
            Self.row("u1", kind: .unknown, value: 1, minutesAgo: 1),
            Self.row("u2", kind: .unknown, value: 2, minutesAgo: 2)
        ]
        #expect(Measurement.latestNamedReading(in: rows) == nil)
    }

    @Test("An empty page has no headline reading")
    func latestNamedIsNilWhenEmpty() {
        #expect(Measurement.latestNamedReading(in: []) == nil)
    }

    // MARK: - The Watch glance

    @MainActor
    @Test("The watch complication shows the newest named reading, not a newer unknown row")
    func watchGlanceSkipsTheSentinel() throws {
        let store = try Self.makeStore()
        let coordinator = WatchSessionCoordinator()
        AppContainer.wireWatchGlances(
            coordinator: coordinator,
            healthScoreStore: HealthScoreStore(repo: AnalyticsRepository(api: Self.makeAPI())),
            measurementsStore: store,
            unitPreferences: { .standard }
        )

        store.recent = [
            Self.row("unknown-newest", kind: .unknown, value: 9000, minutesAgo: 1),
            Self.row("weight-older", kind: .weight, value: 72.4, minutesAgo: 30)
        ]

        let glance = try #require(coordinator.latestMeasurementProvider?())
        #expect(glance.kindRaw == MetricKind.weight.rawValue)
        #expect(glance.formattedValue == 72.4.formatted(.number.precision(.fractionLength(1))))
    }

    // MARK: - The Home-screen widget

    @MainActor
    @Test("The widget headline shows the newest named reading, not a newer unknown row")
    func widgetHeadlineSkipsTheSentinel() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("widget-b4-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let snapshotStore = WidgetSnapshotStore(url: url)
        let writer = WidgetSnapshotWriter(
            store: snapshotStore,
            reloader: WidgetTimelineReloader(reload: { _ in }, reloadAll: {})
        )
        let store = try Self.makeStore()
        AppContainer.wireLatestMeasurementWidgetSnapshot(
            writer: writer,
            measurementsStore: store,
            unitPreferences: { .standard }
        )

        store.recent = [
            Self.row("unknown-newest", kind: .unknown, value: 9000, minutesAgo: 1),
            Self.row("weight-older", kind: .weight, value: 72.4, minutesAgo: 30)
        ]
        await writer.drainPendingWrites()

        let latest = try #require(snapshotStore.read()?.latestMeasurement)
        #expect(latest.kindRaw == MetricKind.weight.rawValue)
    }

    /// **Audit B-4 (fix round 1) — the glance's window had a bare constant in
    /// it.**
    ///
    /// The mood glance skips forward to the latest NAMEABLE entry, which is
    /// right; it did so over `recents(limit: 20)`, which is not. A person whose
    /// twenty newest entries all carry a level this build cannot name lost the
    /// glance entirely — silently, and for no reason the code stated. The whole
    /// loaded window is already in memory and the scan is linear over it.
    @MainActor
    @Test("The mood glance reaches past a long unnameable streak, not just twenty rows")
    func widgetMoodGlanceHasNoUndocumentedWindow() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("widget-b4-mood-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let snapshotStore = WidgetSnapshotStore(url: url)
        let writer = WidgetSnapshotWriter(
            store: snapshotStore,
            reloader: WidgetTimelineReloader(reload: { _ in }, reloadAll: {})
        )
        let moodStore = try Self.makeMoodStore()
        AppContainer.wireMoodWidgetSnapshot(writer: writer, moodStore: moodStore)

        // Twenty-five unnameable entries, newest first, and one real reading
        // behind them — a plausible week for anyone on a server that grew the
        // mood vocabulary.
        var entries = (0 ..< 25).map { index in
            MoodEntry(
                id: "unknown-\(index)",
                mood: .unknown,
                tags: [],
                moodLoggedAt: Self.now.addingTimeInterval(TimeInterval(-60 * index))
            )
        }
        entries.append(MoodEntry(id: "named", recordedAt: Self.now.addingTimeInterval(-60 * 30), score: 2))
        moodStore.replaceEntriesForTesting(entries)
        moodStore.onEntriesDidChange?()
        await writer.drainPendingWrites()

        let mood = try #require(
            snapshotStore.read()?.recentMood,
            "a longer unnameable streak than the old cap must not cost the person their glance"
        )
        #expect(mood.score == 2)
    }

    // MARK: - The doctor report

    /// Audit B-4 (fix round 1) — `.unknown` is a bucket, not a kind: two rows
    /// on it may carry two different server types this build cannot name. The
    /// doctor report averaged them anyway, because both aggregators walk
    /// `MetricKind.allCases` over whatever the store holds. A mean across
    /// readings of unknown, possibly unrelated types is a number that means
    /// nothing, printed in the one export a clinician reads.
    @MainActor
    @Test("Audit B-4 — unknown rows are aggregated into neither a vitals row nor a chart")
    func unknownRowsAreNotAggregated() {
        let unknownA = Measurement(
            id: "u-1",
            kind: .unknown,
            recordedAt: Self.reportDay(10),
            value: .scalar(42)
        )
        let unknownB = Measurement(
            id: "u-2",
            kind: .unknown,
            recordedAt: Self.reportDay(11),
            value: .scalar(9000)
        )
        let known = Measurement(
            id: "k-1",
            kind: .pulse,
            recordedAt: Self.reportDay(12),
            value: .scalar(72)
        )
        let spec = DoctorReportSpecBuilder.build(
            snapshot: Self.reportSnapshot(measurements: [unknownA, unknownB, known]),
            periodStart: Self.reportPeriodStart,
            periodEnd: Self.reportPeriodEnd,
            locale: .de
        )

        #expect(spec.vitals?.rows.contains { $0.kind == .unknown } == false)
        #expect(spec.charts?.series.contains { $0.kind == .unknown } == false)
        // The known reading is untouched — this skips a sentinel, not data.
        #expect(spec.vitals?.rows.contains { $0.kind == .pulse } == true)
        #expect(spec.charts?.series.contains { $0.kind == .pulse } == true)
    }

    @MainActor
    @Test("Audit B-4 — a report holding only unknown rows has no vitals block and no charts")
    func unknownOnlySnapshotHasNoAggregates() {
        let spec = DoctorReportSpecBuilder.build(
            snapshot: Self.reportSnapshot(measurements: [
                Measurement(id: "u-1", kind: .unknown, recordedAt: Self.reportDay(10), value: .scalar(42)),
                Measurement(id: "u-2", kind: .unknown, recordedAt: Self.reportDay(11), value: .scalar(9000))
            ]),
            periodStart: Self.reportPeriodStart,
            periodEnd: Self.reportPeriodEnd,
            locale: .de
        )
        #expect(spec.vitals == nil)
        #expect(spec.charts == nil)
    }

    // MARK: - The list bucket summary

    /// This one's RED is a COMPILE failure by construction: "carries no
    /// mean/min/max" cannot be expressed while those fields are non-optional
    /// `Double`, so the type change and the assertion land together.
    @Test("A bucket of unknown rows reports how many there are and nothing else")
    func bucketSummaryOfUnknownRowsCarriesCountOnly() {
        let stats = SummaryStats.compute(items: [
            Self.row("u1", kind: .unknown, value: 42, minutesAgo: 10),
            Self.row("u2", kind: .unknown, value: 9000, minutesAgo: 20)
        ])
        #expect(stats.count == 2)
        #expect(stats.mean == nil, "a mean across two unrelated unknown types is a number about nothing")
        #expect(stats.min == nil)
        #expect(stats.max == nil)
        #expect(stats.secondaryMean == nil)
    }

    @Test("A named bucket keeps its aggregates unchanged")
    func bucketSummaryOfNamedRowsIsUnchanged() {
        let stats = SummaryStats.compute(items: [
            Self.row("w1", kind: .weight, value: 80, minutesAgo: 10),
            Self.row("w2", kind: .weight, value: 84, minutesAgo: 20)
        ])
        #expect(stats.count == 2)
        #expect(stats.mean == 82)
        #expect(stats.min == 80)
        #expect(stats.max == 84)
    }

    // MARK: - Doctor-report fixtures

    private static let reportPeriodEnd = reportDay(16, hour: 12)
    private static let reportPeriodStart = Calendar(identifier: .gregorian)
        .date(byAdding: .day, value: -30, to: reportPeriodEnd) ?? reportPeriodEnd

    private static func reportDay(_ day: Int, hour: Int = 9) -> Date {
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 5
        comps.day = day
        comps.hour = hour
        comps.timeZone = TimeZone(identifier: "Europe/Berlin")
        return Calendar(identifier: .gregorian).date(from: comps)!
    }

    private static func reportSnapshot(measurements: [Measurement]) -> DoctorReportSpecBuilder.Snapshot {
        DoctorReportSpecBuilder.Snapshot(
            patientName: "Anna Fischer",
            appVersion: "0.5.0",
            measurements: measurements,
            medications: [],
            compliance: [],
            intakes: [],
            moodEntries: []
        )
    }

    // MARK: - Fixtures

    @MainActor
    private static func makeMoodStore() throws -> MoodStore {
        try MoodStore(repo: MoodRepository(api: makeAPI(), outbox: OutboxQueue(inMemory: true)))
    }

    @MainActor
    private static func makeStore() throws -> MeasurementsStore {
        try MeasurementsStore(repo: makeRepo())
    }

    private static func makeRepo() throws -> MeasurementsRepository {
        try MeasurementsRepository(api: makeAPI(), outbox: OutboxQueue(inMemory: true))
    }

    private static func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
    }
}

// swiftlint:enable force_unwrapping
