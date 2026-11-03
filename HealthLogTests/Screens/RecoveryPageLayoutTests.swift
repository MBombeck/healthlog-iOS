import Foundation
@testable import HealthLog
import Testing

/// **1.4 B3 — "Erholung ist auch in den Insights nur Zahlen, keine Graphen".**
///
/// The page used to be five number cards, one of them a cardio recovery value
/// from 2024 without a date, under a sentence in developer language. Now: two
/// trend cards with a 30-day line (recovery score, then strain or load), one
/// calm list for the rest, nothing that is not current, and an empty page
/// that says the server's reason.
@Suite("Recovery page layout — two trend cards and one list (1.4 B3)")
struct RecoveryPageLayoutTests {
    private static func item(_ type: String, _ latest: Double, _ average: Double) -> RecoveryInsightsDTO.Item {
        RecoveryInsightsDTO.Item(id: type, latest: latest, average30: average)
    }

    private static let whoop = RecoveryInsightsDTO(items: [
        item("RECOVERY_SCORE", 83, 71.4),
        item("DAY_STRAIN", 12.4, 11.8),
        item("AVERAGE_HEART_RATE", 66, 64.2),
        item("MAX_HEART_RATE", 158, 151.6),
        item("ENERGY_EXPENDITURE_KJ", 10460, 10203.5)
    ])

    @Test("WHOOP: recovery and day strain are cards, heart rate and energy the list")
    func whoopLayout() {
        let layout = RecoveryPageLayout(family: Self.whoop)
        #expect(layout.trends.map(\.kind) == [.recoveryScore, .dayStrain])
        #expect(layout.rows.map(\.kind) == [.averageHeartRate, .maxHeartRate, .energyExpenditureKJ])
        #expect(layout.empty == nil)
        // The server's numbers, unchanged.
        #expect(layout.rows.first?.latest == 66)
        #expect(layout.rows.first?.average30 == 64.2)
        #expect(layout.trends.first?.latest == 83)
    }

    @Test("without day strain the training load takes the second card; the rest stays a row")
    func loadTakesTheStrainSlot() {
        let polar = RecoveryInsightsDTO(items: [
            Self.item("ANS_CHARGE", 4.2, 3.1),
            Self.item("CARDIO_LOAD", 412, 398),
            Self.item("AVERAGE_HEART_RATE", 61, 60)
        ])
        let layout = RecoveryPageLayout(family: polar)
        #expect(layout.trends.map(\.kind) == [.cardioLoad])
        #expect(layout.rows.map(\.kind) == [.ansCharge, .averageHeartRate])
    }

    @Test("with both, day strain is the card and the training load a row")
    func strainBeatsLoad() {
        let both = RecoveryInsightsDTO(items: [Self.item("DAY_STRAIN", 9, 10), Self.item("CARDIO_LOAD", 300, 310)])
        let layout = RecoveryPageLayout(family: both)
        #expect(layout.trends.map(\.kind) == [.dayStrain])
        #expect(layout.rows.map(\.kind) == [.cardioLoad])
    }

    @Test("an empty page names the server's reason")
    func emptyReasons() {
        // The server says there is no wearable reading (any reason).
        #expect(RecoveryPageLayout(family: RecoveryInsightsDTO(emptyReason: "general")).empty == .noWearable)
        #expect(RecoveryPageLayout(family: RecoveryInsightsDTO(emptyReason: "oura_permission")).empty == .noWearable)
        // Gated or absent slice.
        #expect(RecoveryPageLayout(family: nil).empty == .noWearable)
        // The server has readings, none of them from the last 30 days.
        #expect(RecoveryPageLayout(family: RecoveryInsightsDTO(emptyReason: nil)).empty == .nothingRecent)
        // A current recovery score shows even where the server's list (which
        // does not count it) calls the page empty.
        let scoreOnly = RecoveryInsightsDTO(items: [Self.item("RECOVERY_SCORE", 70, 68)], emptyReason: "general")
        #expect(RecoveryPageLayout(family: scoreOnly).empty == nil)
    }

    @Test("the trend line is the last 30 days of the card's own readings, oldest first, values unchanged")
    func trendPointsWindow() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-21T08:00:00Z"))
        func reading(_ id: String, _ kind: MetricKind, daysAgo: Int, _ value: Double) -> HealthLog.Measurement {
            HealthLog.Measurement(id: id, kind: kind, recordedAt: now.addingTimeInterval(-Double(daysAgo) * 86400), value: .scalar(value))
        }
        let readings = [
            reading("today", .dayStrain, daysAgo: 0, 12.4),
            reading("old", .dayStrain, daysAgo: 45, 20.1),
            reading("week", .dayStrain, daysAgo: 7, 8.3),
            reading("other", .recoveryScore, daysAgo: 1, 80)
        ]
        let points = RecoveryPageLayout.trendPoints(from: readings, kind: .dayStrain, now: now)
        #expect(points.map(\.id) == ["week", "today"])
        #expect(points.map(\.value) == [8.3, 12.4])
    }

    @Test("energy reads in kcal, a unit choice on the server's kJ value")
    func energyInKilocalories() {
        let text = RecoveryValueText.value(10460, kind: .energyExpenditureKJ)
        #expect(text.filter(\.isNumber) == "2500")
        #expect(text.hasSuffix("kcal"))
        #expect(!text.contains("kJ"))
        // The recovery score is a percentage, written the way the locale does.
        let score = RecoveryValueText.value(83, kind: .recoveryScore)
        #expect(score == HLNumberFormat.percent(83))
    }

    @Test("day strain carries its 0 to 21 scale", arguments: ["de", "en"])
    func strainScaleCopy(_ language: String) throws {
        let catalog = try ParityCatalog.load()
        let entry = try #require(catalog.strings["insights.recovery.ofTwentyOne %@"])
        let value = try #require(ParityCatalog.value(entry, language: language))
        #expect(value == (language == "de" ? "%@ von 21" : "%@ of 21"))
    }

    @MainActor
    @Test("the page no longer renders a card per number or the developer sentence")
    func noBareNumberCards() throws {
        let page = try Phase8SourceScan.stripped("HealthLog/Screens/Insights/Sub/InsightsRecoveryPage.swift")
        #expect(!page.contains("InsightsMetricStatusCard"))
        #expect(!page.contains("insights.recovery.noAggregate"))
        #expect(page.contains("InsightsTrendCard"))
        #expect(page.contains("HLTileMetricChart(kind: kind, points: points)"))
        #expect(page.contains("accessibilityChartDescriptor"))
        #expect(page.contains("HLChartStyle.heightCompact"))
    }
}
