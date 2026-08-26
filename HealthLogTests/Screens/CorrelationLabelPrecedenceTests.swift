import Foundation
@testable import HealthLog
import Testing

/// **C2 (walkthrough 2026-08-22): die Variablennamen sind noch englisch und
/// damit unbrauchbar.**
///
/// The German table is not missing — it is complete for all 17 curated channels
/// (`InsightsCorrelationsDiscoveryBlock.channelKeys`). What overruled it was
/// CU-33's precedence: the server's `behaviourLabel` / `outcomeLabel` won
/// whenever it was present, on the reasoning that the server label is the only
/// thing that can name a **custom metric** and that it is the wording the
/// server's own `interpretation` prose uses.
///
/// That reasoning holds for custom metrics and fails for the curated set, where
/// the server's label is an English token (`heart rate variability`) and the app
/// already owns a translated one. Decision **E6** (answered 2026-08-22, beides —
/// Mapping jetzt, Issue parallel) inverts the precedence for exactly the curated
/// set and leaves custom metrics to the server, whose localization is the filed
/// C2-Rest ask.
///
/// This suite pins both halves of that split, because getting the inversion
/// right is easy and getting it too wide would make the C2-Rest ask incoherent.
@Suite("C2 — kuratierte Kanäle sprechen Deutsch, Custom-Metriken bleiben Server-Sache")
struct CorrelationLabelPrecedenceTests {
    private static let german = Locale(identifier: "de_DE")

    /// The 17 curated channel ids (`channelKeys`' key set, restated here so the
    /// suite fails loudly if one silently leaves the production table).
    static let curatedChannels = [
        "TIME_IN_DAYLIGHT", "MOOD", "STEPS", "ACTIVE_ENERGY", "EXERCISE_MINUTES",
        "STAND_HOURS", "SLEEP_DURATION", "SLEEP_EFFICIENCY", "RESTING_HEART_RATE",
        "HEART_RATE_VARIABILITY", "RESPIRATORY_RATE", "BODY_MASS", "VO2_MAX",
        "MINDFUL_MINUTES", "CAFFEINE", "ALCOHOL", "WATER"
    ]

    @Test("Ein kuratierter Kanal rendert die deutsche Tabelle, auch wenn der Server ein Label mitschickt")
    func curatedChannelRendersGerman() {
        var violations: [String] = []
        for channel in Self.curatedChannels {
            let curated = InsightsCorrelationsDiscoveryBlock.label(for: channel, locale: Self.german)
            // The server's own wording for the curated set is the lower-cased
            // English channel name — exactly what the operator read on screen.
            let serverLabel = InsightsCorrelationsDiscoveryBlock.prettify(channel)
            let rendered = InsightsCorrelationsDiscoveryBlock.channelLabel(
                serverLabel: serverLabel,
                channel: channel,
                locale: Self.german
            )
            if rendered != curated {
                violations.append("\(channel) -> [\(rendered)] statt [\(curated)]")
            }
        }

        #expect(
            violations.isEmpty,
            """
            EXPECTED_RED: the server label overrules the complete German table

            C2. Fuer kuratierte Kanaele gewinnt ab E6 die lokale deutsche Tabelle, nicht das \
            Server-Label. \(violations.count) von \(Self.curatedChannels.count) Kanaelen \
            rendern noch die Server-Fassung: \(violations)
            """
        )
    }

    @Test("Eine Custom-Metrik behält ihr Server-Label — ihre Übersetzung ist der C2-Rest-Ask")
    func customMetricKeepsTheServerLabel() {
        let rendered = InsightsCorrelationsDiscoveryBlock.channelLabel(
            serverLabel: "Rückenschmerz-Score",
            channel: "cmet_7f3a91",
            locale: Self.german
        )
        #expect(
            rendered == "Rückenschmerz-Score",
            """
            Ein Kanal ausserhalb der kuratierten Tabelle ist eine Custom-Metrik. Sein Name \
            existiert nur serverseitig — die App hat dafuer keine Uebersetzung und darf keine \
            erfinden. Greift die E6-Inversion auch hier, verliert der Nutzer den einzigen \
            lesbaren Namen, den es fuer diese Metrik gibt, und der gefilterte C2-Rest-Ask \
            (localized labels for custom-metric correlation channels) wird unbeantwortbar.
            """
        )
    }

    @Test("Ohne Server-Label bleibt die kuratierte Tabelle die Quelle — unverändert seit CU-33")
    func absentServerLabelStillUsesTheCuratedTable() {
        let expected = InsightsCorrelationsDiscoveryBlock.label(for: "STEPS", locale: Self.german)

        #expect(
            InsightsCorrelationsDiscoveryBlock.channelLabel(
                serverLabel: nil,
                channel: "STEPS",
                locale: Self.german
            ) == expected
        )
        #expect(
            InsightsCorrelationsDiscoveryBlock.channelLabel(
                serverLabel: "   ",
                channel: "STEPS",
                locale: Self.german
            ) == expected
        )
    }
}
