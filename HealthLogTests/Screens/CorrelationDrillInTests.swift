import Foundation
@testable import HealthLog
import Testing

/// **C1 (walkthrough 2026-08-22): „Zusammenhänge in deinen Daten ist
/// grundsätzlich gut, aber es gibt weiterhin Einträge, denen man nicht weiter
/// nachgehen kann."**
///
/// The block renders a card per surviving pair: a headline, the server's
/// interpretation, `n` and `r`, and — conditionally — a relevance statement and
/// an ask-the-coach link. What it never renders is a way **into** the pair. A
/// card states a relationship and then ends; there is nothing to open, nothing
/// to check, nothing to follow.
///
/// The fix has one shape, not two. Every entry offers the same follow-up (a
/// detail view of the pair), and the entries whose channels have an Insights
/// page of their own additionally reach it. Which means the affordance always
/// matches the behaviour: there is no chevron that does nothing, and no row that
/// looks inert while being tappable.
///
/// The mapping is pure data and is tested here as such.
@Suite("C1 — jede Zusammenhangs-Zeile lässt sich verfolgen")
struct CorrelationDrillInTests {
    // MARK: - The mapping (pure data)

    @Test("Ein kuratierter Kanal mit eigener Insights-Seite löst auf die richtige Metrik auf")
    func navigableChannelsResolveToTheirMetricPage() {
        let expected: [String: MetricKind] = [
            "MOOD": .mood,
            "STEPS": .steps,
            "ACTIVE_ENERGY": .activeEnergy,
            "TIME_IN_DAYLIGHT": .timeInDaylight,
            "SLEEP_DURATION": .sleep,
            "RESTING_HEART_RATE": .restingHeartRate,
            "HEART_RATE_VARIABILITY": .hrv,
            "RESPIRATORY_RATE": .respiratoryRate,
            "BODY_MASS": .weight,
            "VO2_MAX": .vo2Max
        ]
        for (channel, kind) in expected {
            #expect(
                InsightsCorrelationsDiscoveryBlock.drillInKind(for: channel) == kind,
                "\(channel) muss auf \(kind.rawValue) zeigen — sonst führt die Zeile woanders hin, als sie behauptet."
            )
        }
    }

    @Test("Was keine eigene Seite hat, verspricht auch keine")
    func channelsWithoutAPageResolveToNil() {
        // Curated, but no Insights page: a tap would degrade into the values
        // table, which is a step sideways rather than a follow-up.
        //
        // `SLEEP_EFFICIENCY` is the interesting one: it IS in the production
        // channel→kind table, and `MetricKind.sleepEfficiency` exists — but
        // `InsightsLayoutTileId.kindToSlug` has no slug for it, so no Insights
        // page can be reached. The reachability guard is what turns that into a
        // `nil` instead of a chevron into the values table, and the day a slug is
        // added the entry starts working without an edit here.
        for channel in [
            "EXERCISE_MINUTES", "STAND_HOURS", "SLEEP_EFFICIENCY",
            "MINDFUL_MINUTES", "CAFFEINE", "ALCOHOL", "WATER"
        ] {
            #expect(
                InsightsCorrelationsDiscoveryBlock.drillInKind(for: channel) == nil,
                "\(channel) hat keine Insights-Seite — ein Chevron dorthin wäre ein Versprechen ohne Ziel."
            )
        }
        // A custom metric is not in the curated vocabulary at all.
        #expect(InsightsCorrelationsDiscoveryBlock.drillInKind(for: "cmet_7f3a91") == nil)
    }

    @Test("Jedes gemeldete Ziel ist auch wirklich erreichbar — die Router-Vorbedingung, nicht die Wunschliste")
    func everyDrillInTargetIsActuallyReachable() {
        for channel in CorrelationLabelPrecedenceTests.curatedChannels {
            guard let kind = InsightsCorrelationsDiscoveryBlock.drillInKind(for: channel) else { continue }
            #expect(
                kind == .mood || InsightsTabSlug.slug(forKind: kind) != nil,
                """
                \(channel) zeigt auf \(kind.rawValue), aber AppRouter.selectInsightsMetric(_:) \
                findet dafür keinen Insights-Slug und fiele auf die Messwerte-Tabelle zurück. \
                Das ist der Fall, den C1 gerade abschafft: eine Zeile, die nach Vertiefung \
                aussieht und woanders landet.
                """
            )
        }
    }

    @Test("Ein Paar bietet jede Seite höchstens einmal an, Verhalten zuerst")
    func drillInsAreOrderedAndDeduplicated() {
        let pair = Self.pair(behaviour: "STEPS", outcome: "SLEEP_DURATION")
        #expect(InsightsCorrelationsDiscoveryBlock.drillIns(for: pair) == [.steps, .sleep])

        // Both channels live on the same page — offering it twice would read as
        // two different destinations.
        let sameKind = Self.pair(behaviour: "SLEEP_DURATION", outcome: "SLEEP_DURATION")
        #expect(InsightsCorrelationsDiscoveryBlock.drillIns(for: sameKind) == [.sleep])

        let unmapped = Self.pair(behaviour: "CAFFEINE", outcome: "cmet_7f3a91")
        #expect(InsightsCorrelationsDiscoveryBlock.drillIns(for: unmapped).isEmpty)
    }

    // MARK: - Fixtures

    private static func pair(behaviour: String, outcome: String) -> DiscoveredCorrelation {
        DiscoveredCorrelation(
            behaviour: behaviour,
            outcome: outcome,
            n: 42,
            r: 0.41,
            pValue: 0.004,
            qValue: 0.03,
            interpretation: "Mehr davon geht mit mehr davon einher.",
            lagDays: 1
        )
    }
}
