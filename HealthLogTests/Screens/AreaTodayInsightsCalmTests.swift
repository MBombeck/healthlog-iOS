import Foundation
@testable import HealthLog
import Testing

/// **iOS 1.4 B2-a — Today, Measurements and Insights explain themselves.**
///
/// The area unit applied R2's verdicts with the info pattern: what a card says
/// is in the card, an empty card is not there, a screen's explanations sit
/// behind its one (i). These tests pin the decisions that are behaviour: pure
/// resolvers, info content and the retired catalog keys.
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
    func specialPagesCarryTheirInfo() {
        let mood = InsightsSpecialPageInfo.mood(showsCorrelation: false)
        #expect(mood.about == InsightsExplainer.copy(slug: "mood")?.body)
        #expect(mood.about != nil)
        #expect(mood.sections.isEmpty)
        #expect(mood.learnMoreConcept == "MOOD")
        #expect(InsightsSpecialPageInfo.mood(showsCorrelation: true).referenceTopics == [.mood, .correlations])

        let medications = InsightsSpecialPageInfo.medications(showsCorrelation: false)
        #expect(medications.about != nil)
        #expect(medications.sections.map(\.topic) == [.medicationCompliance])
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
