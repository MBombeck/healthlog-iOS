import Foundation
@testable import HealthLog
import Testing

/// **iOS 1.4 B2-a — Today, Measurements and Insights explain themselves.**
///
/// The area unit applied R2's verdicts with the info pattern: what a card says
/// is in the card, an empty card is not there, a screen's explanations sit
/// behind its one (i). These tests pin the decisions that are behaviour (pure
/// resolvers, info content) and, read against the source, the lines that went
/// away, so a later refactor cannot quietly bring them back.
@Suite("B2-a — Today, Measurements, Insights explain themselves")
struct AreaTodayInsightsCalmTests {
    // MARK: - Today

    @Test("the update card never asks to connect while the banner already does")
    func updateCardLeavesTheConnectAskToTheBanner() throws {
        let defaults = try #require(UserDefaults(suiteName: "b2a.updateNotice.\(UUID().uuidString)"))
        defaults.set(HealthKitUpdateNotice.Arming.armed.rawValue, forKey: HealthKitUpdateNotice.armingDefaultsKey)
        let banner = HealthKitUpdateNotice.visibleVariant(
            state: .notRequested, statuses: [:], bannerAsksToConnect: true, defaults: defaults
        )
        #expect(banner == nil, "the banner owns the connect request")
        let latch = HealthKitUpdateNotice.visibleVariant(
            state: .notRequested, statuses: [:], bannerAsksToConnect: false, defaults: defaults
        )
        #expect(latch == .connect, "where the banner refuses, the card still asks")
        let newTypes = HealthKitUpdateNotice.visibleVariant(
            state: .partiallyGranted(missing: ["x"]),
            statuses: ["HKQuantityTypeIdentifierBodyMass": .sharingAuthorized],
            bannerAsksToConnect: true,
            defaults: defaults
        )
        #expect(newTypes == .newTypes, "the new-types notice is not the banner's")
    }

    @Test("Today's adherence card has no loose Sources row and no onboarding sentence")
    func adherenceCardIsCalm() throws {
        let card = try code(of: "HealthLog/Screens/Dashboard/ComplianceRingCard.swift")
        #expect(!card.contains("HLSourcesLink("))
        #expect(!card.contains("No reminders scheduled yet"))
        #expect(!card.contains("No intakes scheduled for today."))
        #expect(card.contains("if !isFullyEmpty"))
    }

    // MARK: - Records

    @Test("the time-range picker offers only ranges that hold a record, narrowest first")
    func recordBucketsWithRecordsOnly() {
        #expect(PersonalRecordsScreen.availableBuckets([]).isEmpty)
        let month = Self.record(id: "m", bucket: .month)
        #expect(PersonalRecordsScreen.availableBuckets([month]) == [.month, .year, .allTime])
        let streak = Self.record(id: "s", bucket: .week, slot: "streak")
        #expect(PersonalRecordsScreen.availableBuckets([streak]).isEmpty, "a streak lives in the rail, not the grid")
    }

    // MARK: - Nutrition

    @Test("the checked window rides in the empty state's own sentence")
    func nutrientWindowInTheSentence() {
        let message = NutrientEmptyStateView.message("nutrients.list.empty.subtitle", windowDays: 7)
        #expect(message.hasPrefix(String(localized: "nutrients.list.empty.subtitle")))
        #expect(message.hasSuffix(String(localized: "nutrients.list.empty.window \(7)")))
        #expect(NutrientEmptyStateView.message("nutrients.list.empty.subtitle", windowDays: nil)
            == String(localized: "nutrients.list.empty.subtitle"))
    }

    // MARK: - Insights special pages

    @Test("Mood and Medications explain themselves behind one (i)")
    func specialPagesCarryTheirInfo() throws {
        let mood = InsightsSpecialPageInfo.mood(showsCorrelation: false)
        #expect(mood.about == InsightsExplainer.copy(slug: "mood")?.body)
        #expect(mood.about != nil)
        #expect(mood.sections.isEmpty)
        #expect(mood.learnMoreConcept == "MOOD")
        #expect(InsightsSpecialPageInfo.mood(showsCorrelation: true).referenceTopics == [.mood, .correlations])

        let medications = InsightsSpecialPageInfo.medications(showsCorrelation: false)
        #expect(medications.about != nil)
        #expect(medications.sections.map(\.topic) == [.medicationCompliance])

        for path in [
            "HealthLog/Screens/Insights/Sub/InsightsMoodPage.swift",
            "HealthLog/Screens/Insights/Sub/InsightsMedicationsPage.swift"
        ] {
            let page = try code(of: path)
            #expect(page.components(separatedBy: "HLInfoButton(").count == 2, "\(path): exactly one (i)")
            #expect(!page.contains("InsightsExplainerIntro("), "\(path): the intro paragraph is back")
        }
    }

    // MARK: - Correlations

    @Test("a correlation card is headline, reading and one foot line; the rest opens with Details")
    func correlationCardIsThreeLines() throws {
        let block = try code(of: "HealthLog/Screens/Insights/Sub/InsightsCorrelationsDiscoveryBlock.swift")
        #expect(
            block.components(separatedBy: "HLSourcesLink(topic: .correlations)").count == 3,
            "one citation per card, in its foot line (fit and stacked variant)"
        )
        for retired in ["resurfacedNote", "dismissedNote", "askCoachLink("] {
            #expect(!block.contains(retired), "\(retired) is back on the card")
        }
        let details = try code(of: "HealthLog/Screens/Insights/Sub/InsightsCorrelationFollowUpSection.swift")
        #expect(details.contains("statLine(for: pair)"))
        #expect(!details.contains("HLSourcesLink("), "the card above already cites")
        #expect(!details.contains("insights.correlations.detail.noPage"))
    }

    // MARK: - ECG

    @Test("the ECG attribution sits at the foot of the card it attributes")
    func ecgAttributionInTheCard() throws {
        let page = try code(of: "HealthLog/Screens/Insights/Sub/InsightsEcgPage.swift")
        let detail = try code(of: "HealthLog/Screens/Insights/Sub/EcgDetailScreen.swift")
        #expect(page.contains("EcgAttributionFooter()"))
        #expect(detail.contains("EcgAttributionFooter()"))
        #expect(!page.contains("insights.ecg.intro"))
        #expect(detail.components(separatedBy: "HLSourcesLink(").count == 1, "the footer cites once")
    }

    // MARK: - Catalog

    /// Keys the unit retired. They must not come back as loose lines; the
    /// catalog guard would also flag them as unreferenced.
    static let retiredKeys = [
        "daily.today.sleepPending",
        "daily.today.allClear",
        "dashboard.rhythmEvents.tile.title",
        "dashboard.intakesSheet.subtitle.empty",
        "insights.overview.description",
        "insights.correlations.detail.noPage",
        "insights.ecg.intro",
        "insights.ecg.subtitle",
        "insights.ecg.empty.hardwareNote",
        "insights.empty.ai.title",
        "clinicalSignals.healthStatus.caption",
        "clinicalSignals.breathing.caption",
        "feature_disabled.subtitle",
        "nutrients.detail.empty.subtitle",
        "records.empty.bucket",
        "workouts.paging.end",
        "measurement.form.backdateHint",
        "insights.bp.derived.info"
    ]

    @Test("retired hint keys stay out of the catalog")
    func retiredKeysStayGone() throws {
        let catalog = try ParityCatalog.load()
        for key in Self.retiredKeys {
            #expect(catalog.strings[key] == nil, "\(key) is back in the catalog")
        }
    }

    // MARK: - Helpers

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Screens
        .deletingLastPathComponent() // HealthLogTests
        .deletingLastPathComponent() // repo root

    /// A file's source without whole-line comments, so "X must not appear"
    /// reads declarations rather than the prose explaining why X went.
    private func code(of path: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private static func record(id: String, bucket: TimeBucket, slot: String? = nil) -> PersonalRecord {
        let dto = PersonalRecordDTO(
            id: id,
            userId: "u1",
            metricType: "STEPS",
            metricSlot: slot,
            direction: .max,
            value: 12000,
            unit: "steps",
            achievedAt: Date(),
            sourceMeasurementId: nil,
            source: "HEALTHKIT",
            externalId: nil,
            createdAt: Date(),
            benchmark: nil
        )
        return PersonalRecord(
            id: id,
            base: dto,
            kind: .steps,
            sparklineValues: [],
            peakIndex: nil,
            previousValue: nil,
            bucket: bucket,
            impressiveness: 0.5
        )
    }
}
