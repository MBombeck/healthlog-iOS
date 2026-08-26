import Foundation
@testable import HealthLog
import Testing

/// **C3 — Erholung joins the family, and says what it cannot show.**
///
/// „Vereinbart war, dass es überall gleich aussieht: letzte Messungen,
/// 30-Tage-Durchschnitt mit Pfeil, ‚on target'." The canonical shape he means is
/// `InsightsMetricScreen` + `InsightsMetricStatusCard`, and it exists because of
/// an *earlier, identical* complaint („Puls sieht anders aus als Blutdruck") —
/// which is why answering this one with a bespoke recovery layout would be the
/// wrong answer twice.
///
/// The second case is the one that matters more than the first. Recovery's
/// payload has no series and no labelled aggregate, so two of the three things he
/// listed cannot be backed. Consistency achieved by rendering a 30-day arrow over
/// data that does not cover thirty days would look like the fix and be a lie, and
/// it is the kind of lie a UI can tell for a year before anyone notices.
@Suite("C3 — Erholung im Familien-Schema, so weit die Daten es hergeben")
struct RecoverySchemaAdoptionTests {
    private static let page = "HealthLog/Screens/Insights/Sub/InsightsRecoveryPage.swift"
    private static let dto = "HealthLog/Models/RecoveryInsightsDTO.swift"

    private static func item(
        id: String = "CARDIO_LOAD",
        value: Double? = 412,
        unit: String? = "pts",
        score: Double? = nil,
        band: String? = nil,
        trendDelta: Double? = nil
    ) -> RecoveryInsightsDTO.Item {
        RecoveryInsightsDTO.Item(
            id: id, label: nil, value: value, unit: unit,
            score: score, band: band, trendDelta: trendDelta, reason: nil
        )
    }

    // MARK: - 1. The family vocabulary

    @MainActor
    @Test("Die Seite rendert die Familien-Karte, nicht mehr nur nackte Werte")
    func recoveryRendersTheFamilySchema() throws {
        let source = try Phase8SourceScan.stripped(Self.page)

        var violations: [String] = []
        if !source.contains("InsightsMetricStatusCard") {
            violations.append("the page renders no canonical status card")
        }
        if !source.contains("RecoverySchema") {
            violations.append("the page builds no canonical descriptor")
        }

        // The vocabulary itself must actually fill: a latest value, a unit and —
        // where the server sends a band — the family's "on target" chip.
        let onTarget = Self.item(band: "green")
        let descriptor = try #require(RecoverySchema.descriptor(for: onTarget))
        if descriptor.headlineValue != "412" { violations.append("headline is \(descriptor.headlineValue ?? "nil")") }
        if descriptor.unitCaption != "pts" { violations.append("unit caption is \(descriptor.unitCaption)") }
        if descriptor.chipLabel == nil { violations.append("a green band produced no on-target chip") }
        if !descriptor.hasAnyContent { violations.append("the descriptor renders nothing at all") }

        #expect(
            violations.isEmpty,
            """
            EXPECTED_RED: recovery still renders naked momentary values

            C3. The canonical card is not a nicer layout, it is the app's agreed vocabulary for \
            „what is this number and how am I doing" — and Erholung is the one family page that \
            never spoke it. Offen: \(violations)
            """
        )
    }

    // MARK: - 2. The honesty gate

    @MainActor
    @Test("Kein Fenster-Anspruch ohne Datenquelle — und die Seite sagt, was fehlt")
    func noUnbackedWindowClaims() throws {
        let source = try Phase8SourceScan.stripped(Self.page)
        let dtoSource = try Phase8SourceScan.stripped(Self.dto)

        var violations: [String] = []

        // (a) The page states what it cannot show, rather than leaving the gap
        //     to be read as an oversight.
        if !source.contains("insights.recovery.noAggregate") {
            violations.append("the page never says that no windowed aggregate exists")
        }

        // (b) No descriptor may carry a windowed slot, for any shape of item.
        for probe in [
            Self.item(band: "green", trendDelta: 4),
            Self.item(id: "STRAIN", value: nil, unit: nil, score: 71, band: "yellow"),
            Self.item(id: "ANS_CHARGE", value: nil, unit: nil, score: 12, band: "red", trendDelta: -9)
        ] {
            guard let descriptor = RecoverySchema.descriptor(for: probe) else { continue }
            if descriptor.pctInTarget != nil {
                violations.append("\(probe.id): claims an in-target share the server never sent")
            }
            if descriptor.inTargetWindowLabel != nil {
                violations.append("\(probe.id): names a window that does not exist")
            }
            if descriptor.targetBandCaption != nil {
                violations.append("\(probe.id): claims a target band the server never sent")
            }
            if descriptor.sparklineValues != nil {
                violations.append("\(probe.id): draws a series out of a single reading")
            }
        }

        // (c) The structural claim is pinned against the DTO itself: the day the
        //     server publishes an aggregate and the field lands, this flips.
        let aggregateFields = ["average", "aggregate", "series", "window", "history", "baselineWindow"]
        let dtoGrewOne = aggregateFields.contains { dtoSource.localizedCaseInsensitiveContains("let \($0)") }
        if RecoverySchema.publishesWindowedAggregate != dtoGrewOne {
            violations.append(
                "publishesWindowedAggregate=\(RecoverySchema.publishesWindowedAggregate) but the DTO says \(dtoGrewOne)"
            )
        }

        #expect(
            violations.isEmpty,
            """
            EXPECTED_RED: nothing yet gates window claims on a data source

            C3's honesty half. Recovery's payload carries `score`, `value`, `unit`, `band`, \
            `trendDelta` and `reason` — no series, no labelled aggregate. Two of the three \
            things the operator listed therefore cannot be backed, and a 30-day arrow over \
            data that does not cover thirty days would look exactly like the fix. What is \
            missing is asked once, in the C3/C4 server ask that covers both clients. Offen: \
            \(violations)
            """
        )
    }

    // MARK: - 3. Control — the shared component is not forked

    @MainActor
    @Test("Kontrolle: die kanonische Karte ist unverändert und kann weiterhin alles")
    func canonicalCardIsNotForked() {
        // A curated metric's full anatomy still builds — chip, headline, the
        // in-target bar WITH its window label, a band caption and a sparkline.
        // If recovery had forked the component to drop slots it cannot fill,
        // this is what would have broken.
        let curated = InsightsMetricStatusCard.Descriptor(
            title: "Blutdruck",
            guidelineCaption: "ESH 2023",
            chipLabel: "Hoch-normal",
            chipTone: .warning,
            headlineValue: "128/82",
            unitCaption: "mmHg",
            pctInTarget: 64,
            inTargetWindowLabel: "90 T",
            targetBandCaption: "Ziel: 120–129 mmHg",
            sparklineValues: nil,
            identifierSuffix: "bloodPressure"
        )
        #expect(curated.hasAnyContent)
        #expect(curated.pctInTarget == 64)
        #expect(curated.inTargetWindowLabel == "90 T")
        #expect(curated.showsSparkline == false, "a targeted kind carries the bar, not a redundant trend line")
    }
}
