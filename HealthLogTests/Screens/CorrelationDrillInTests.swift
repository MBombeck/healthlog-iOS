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
/// The two halves are tested separately on purpose. The mapping is pure data and
/// can be right while the surface still shows dead rows — which is exactly the
/// state this suite started in.
@Suite("C1 — jede Zusammenhangs-Zeile lässt sich verfolgen")
struct CorrelationDrillInTests {
    private static let block = "HealthLog/Screens/Insights/Sub/InsightsCorrelationsDiscoveryBlock.swift"

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

    // MARK: - The surface (the RED this plan closes)

    /// **EXPECTED_RED (C1): the card ends where the question begins.** Read as
    /// comment-stripped source, so the clause states what is missing without
    /// naming a symbol that does not exist yet.
    @Test("C1-Marker: keine Karte bietet einen Weg in das Paar hinein")
    func unmappedEntryHasAnHonestFallback() throws {
        let source = try Phase8SourceScan.stripped(Self.block)

        var violations: [String] = []
        if !source.contains("insights.correlations.discovery.followUp") {
            violations.append("no card offers a follow-up affordance")
        }
        // The clause is the SHAPE, not its type name. It was written against
        // `InsightsCorrelationDetailSheet` and the shape shipped as
        // `InsightsCorrelationFollowUpSection`, because a `.sheet` is a
        // presentation the frozen Phase-06 inventory counts and that inventory is
        // fail-closed against new hits — a later plan may record that a
        // presentation went away, never mint one. Same one shape, opened in place
        // instead of modally; the EXPECTED_RED marker below is unchanged.
        if !source.contains("InsightsCorrelationFollowUpSection") {
            violations.append("there is no one detail shape a card can open")
        }

        #expect(
            violations.isEmpty,
            """
            EXPECTED_RED: unmapped entries are dead rows with a live look

            C1. Jede Karte muss dieselbe eine Folge-Form anbieten — auch die, deren Kanäle \
            keine eigene Metrik-Seite haben; sonst bleibt genau der Rest übrig, dem der \
            Betreiber nicht nachgehen kann. Offen: \(violations)
            """
        )
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
