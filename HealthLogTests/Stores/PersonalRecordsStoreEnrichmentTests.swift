import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// v0.5.5.6 POLISH-PR — `PersonalRecordsStore` enrichment contract tests.
///
/// Pins the view-model derivation pipeline that powers the redesigned
/// `PersonalRecordsScreen`: `enrichedRecords`, `heroRecord`,
/// `visibleRecords` (bucket-filtered), `streakRecords` (slot match),
/// `clearOnLogout` (also clears `selectedBucket`).
@Suite("PersonalRecordsStore — enrichment + bucket selection", .serialized)
@MainActor
struct PersonalRecordsStoreEnrichmentTests {
    private let now = Date(timeIntervalSince1970: 1_716_854_400) // 28 May 2024

    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.5.5",
            buildNumber: "1"
        )
        let kc = InMemoryKeychain()
        return APIClient(environment: env, keychain: kc, sessionConfiguration: .mock())
    }

    @Test("Enrichment maps DTO → PersonalRecord, classifies bucket, resolves kind")
    func enrichmentResolvesKindAndBucket() async {
        let dto = makeRecord(id: "weight.1", metricType: "WEIGHT", value: 78.2, achievedAt: now)
        let enriched = await PersonalRecordsStore.enrich(
            record: dto,
            previousValue: 81.0,
            provider: nil,
            now: now
        )
        #expect(enriched.kind == .weight)
        #expect(enriched.bucket == .week)
        #expect(enriched.previousValue == 81.0)
        // Delta absolute: 78.2 - 81.0 = -2.8; percent ≈ -3.45%.
        // `78.2 - 81.0` is `-2.799999999999997` in IEEE-754 double precision,
        // not exactly `-2.8` — so compare with tolerance (as the percent
        // assertion below already does). The raw double is the correct stored
        // value; `RecordCard.deltaLabel` formats it to 1 fraction digit ("-2,8")
        // and `deltaChip` only reads its sign, so the displayed celebration
        // value is correct. Rounding at the source would be wrong (format at
        // the display, not in the model).
        let expectedAbsolute = -2.8
        #expect(abs((enriched.delta?.absolute ?? 0) - expectedAbsolute) < 0.0001)
        #expect(abs((enriched.delta?.percent ?? 0) - (-2.8 / 81.0)) < 0.0001)
    }

    @Test("Unknown metric-type passes through with nil kind + empty sparkline")
    func enrichmentTolerantOfUnknownTypes() async {
        let dto = makeRecord(id: "x.1", metricType: "UNKNOWN_METRIC", value: 1, achievedAt: now)
        let enriched = await PersonalRecordsStore.enrich(
            record: dto,
            previousValue: nil,
            provider: nil,
            now: now
        )
        #expect(enriched.kind == nil)
        #expect(enriched.sparklineValues.isEmpty)
        #expect(enriched.peakIndex == nil)
        #expect(enriched.delta == nil) // No previous → "Neuer Rekord"
    }

    @Test("Hero pick prefers the most recent bucket (week beats all-time)")
    func heroPicksFreshestBucket() async {
        MockURLProtocol.handler = { req in
            let body = Data(#"{"data":[],"error":null}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let repo = PersonalRecordsRepository(api: makeAPI())
        let freshThisWeek = makeRecord(id: "w1", metricType: "WEIGHT", value: 80, achievedAt: now)
        let staleAllTime = makeRecord(
            id: "w2",
            metricType: "ACTIVITY_STEPS",
            value: 23000,
            achievedAt: now.addingTimeInterval(-3 * 365 * 86400)
        )
        let derived = StubDerivedSource(records: [freshThisWeek, staleAllTime])
        let store = PersonalRecordsStore(
            repo: repo,
            derivedSource: derived,
            sparklineProvider: nil,
            clock: { now }
        )
        await store.load()
        #expect(store.heroRecord?.id == "w1")
    }

    @Test("visibleRecords narrows by selectedBucket downward-inclusive")
    func bucketFilter() async {
        MockURLProtocol.handler = { req in
            let body = Data(#"{"data":[],"error":null}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let repo = PersonalRecordsRepository(api: makeAPI())
        let thisWeek = makeRecord(id: "w-this", metricType: "WEIGHT", value: 80, achievedAt: now)
        // A record from 6 months earlier — same year, different month.
        let calendar = Calendar.current
        let monthsBack = calendar.date(byAdding: .month, value: -6, to: now) ?? now
        let earlierYear = makeRecord(id: "w-year", metricType: "PULSE", value: 64, achievedAt: monthsBack)
        // 3 years back → falls to allTime.
        let allTime = makeRecord(id: "w-all", metricType: "HRV", value: 60, achievedAt: now.addingTimeInterval(-3 * 365 * 86400))
        let derived = StubDerivedSource(records: [thisWeek, earlierYear, allTime])
        let store = PersonalRecordsStore(
            repo: repo,
            derivedSource: derived,
            sparklineProvider: nil,
            clock: { now }
        )
        await store.load()
        // allTime selected → all three visible.
        store.selectedBucket = .allTime
        #expect(store.visibleRecords.count == 3)
        // week selected → only the week record visible.
        store.selectedBucket = .week
        #expect(store.visibleRecords.map(\.id) == ["w-this"])
    }

    @Test("Streak records are surfaced into the rail by metricSlot pattern")
    func streakSurfacing() async {
        MockURLProtocol.handler = { req in
            let body = Data(#"{"data":[],"error":null}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let repo = PersonalRecordsRepository(api: makeAPI())
        let plain = makeRecord(id: "p1", metricType: "ACTIVITY_STEPS", value: 23000, achievedAt: now)
        let streak = PersonalRecordDTO(
            id: "s1",
            userId: "u1",
            metricType: "ACTIVITY_STEPS",
            metricSlot: "Längste Serie ≥ 10.000 (14 Tage)",
            direction: .max,
            value: 14,
            unit: "Tage",
            achievedAt: now,
            sourceMeasurementId: nil,
            source: "HEALTHLOG_CLIENT",
            externalId: nil,
            createdAt: now
        )
        let derived = StubDerivedSource(records: [plain, streak])
        let store = PersonalRecordsStore(
            repo: repo,
            derivedSource: derived,
            sparklineProvider: nil,
            clock: { now }
        )
        await store.load()
        #expect(store.streakRecords.map(\.id) == ["s1"])
    }

    @Test("clearOnLogout resets selectedBucket + enrichedRecords")
    func clearOnLogoutResetsBucket() async {
        MockURLProtocol.handler = { req in
            let body = Data(#"{"data":[],"error":null}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let repo = PersonalRecordsRepository(api: makeAPI())
        let derived = StubDerivedSource(records: [
            makeRecord(id: "p1", metricType: "WEIGHT", value: 80, achievedAt: now)
        ])
        let store = PersonalRecordsStore(
            repo: repo,
            derivedSource: derived,
            sparklineProvider: nil,
            clock: { now }
        )
        await store.load()
        // Move OFF the new default (.week) so the logout reset is observable.
        store.selectedBucket = .allTime
        #expect(!store.enrichedRecords.isEmpty)
        store.clearOnLogout()
        #expect(store.enrichedRecords.isEmpty)
        // v0.14.1 (#139) — logout resets to the new `.week` default, not `.allTime`.
        #expect(store.selectedBucket == .week)
    }

    // MARK: - TimeBucket pure helpers

    @Test("TimeBucket.classify is downward-narrowest")
    func timeBucketClassify() {
        // Same week → week.
        #expect(TimeBucket.classify(achievedAt: now, now: now) == .week)
        let calendar = Calendar.current
        if let earlierMonth = calendar.date(byAdding: .day, value: -20, to: now) {
            // 20 days back still inside the same month in most reference times.
            let bucket = TimeBucket.classify(achievedAt: earlierMonth, now: now)
            // Either .month or .year — never .week (>= 7 days back).
            #expect(bucket != .week)
        }
        // 4 years back → allTime.
        let fourYearsBack = now.addingTimeInterval(-4 * 365 * 86400)
        #expect(TimeBucket.classify(achievedAt: fourYearsBack, now: now) == .allTime)
    }

    @Test("TimeBucket.includes is downward-inclusive")
    func timeBucketInclusion() {
        #expect(TimeBucket.week.includes(.week))
        #expect(!TimeBucket.week.includes(.month))
        #expect(TimeBucket.month.includes(.week))
        #expect(TimeBucket.year.includes(.month))
        #expect(TimeBucket.allTime.includes(.week))
        #expect(TimeBucket.allTime.includes(.allTime))
    }

    @Test("previousValuesByType picks the runner-up by achievedAt")
    func previousValuesPerType() {
        let calendar = Calendar.current
        let recent = now
        let older = calendar.date(byAdding: .day, value: -30, to: now) ?? now
        let oldest = calendar.date(byAdding: .day, value: -90, to: now) ?? now
        let records: [PersonalRecordDTO] = [
            makeRecord(id: "w1", metricType: "WEIGHT", value: 78, achievedAt: recent),
            makeRecord(id: "w2", metricType: "WEIGHT", value: 80, achievedAt: older),
            makeRecord(id: "w3", metricType: "WEIGHT", value: 82, achievedAt: oldest)
        ]
        let map = PersonalRecordsStore.previousValuesByType(records: records)
        // Runner-up for WEIGHT bucket is the 2nd-newest = 80.
        #expect(map["WEIGHT"] == 80)
    }

    @Test("MetricTypeKindResolver maps canonical types + tolerates unknowns")
    func resolverHandlesCanonicalAndUnknown() {
        #expect(MetricTypeKindResolver.kind(forMetricType: "WEIGHT") == .weight)
        #expect(MetricTypeKindResolver.kind(forMetricType: "BLOOD_PRESSURE_SYS") == .bloodPressure)
        #expect(MetricTypeKindResolver.kind(forMetricType: "ACTIVITY_STEPS") == .steps)
        #expect(MetricTypeKindResolver.kind(forMetricType: "SLEEP_DURATION") == .sleep)
        #expect(MetricTypeKindResolver.kind(forMetricType: "UNKNOWN_FUTURE") == nil)
    }

    // MARK: - Fixtures

    private func makeRecord(
        id: String,
        metricType: String,
        value: Double,
        achievedAt: Date
    ) -> PersonalRecordDTO {
        PersonalRecordDTO(
            id: id,
            userId: "u1",
            metricType: metricType,
            metricSlot: nil,
            direction: .max,
            value: value,
            unit: "",
            achievedAt: achievedAt,
            sourceMeasurementId: nil,
            source: "TEST",
            externalId: nil,
            createdAt: achievedAt
        )
    }

    private final class StubDerivedSource: PersonalRecordsDerivedSource, @unchecked Sendable {
        let records: [PersonalRecordDTO]

        init(records: [PersonalRecordDTO]) {
            self.records = records
        }

        func derivedRecords(
            metricTypeFilter: String?,
            excluding serverMetricTypes: Set<String>
        ) async -> [PersonalRecordDTO] {
            records.filter { !serverMetricTypes.contains($0.metricType) }
        }
    }
}

// swiftlint:enable force_unwrapping
