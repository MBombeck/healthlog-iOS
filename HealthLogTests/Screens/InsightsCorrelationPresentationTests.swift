import Foundation
@testable import HealthLog
import Testing

@Suite("InsightsCorrelationPresentationTests")
struct InsightsCorrelationPresentationTests {
    @Test("correlations are collapsed by default with stable accessibility state")
    func defaultDisclosureState() {
        #expect(InsightsCorrelationsDiscoveryBlock.isInitiallyExpanded == false)
        #expect(
            InsightsCorrelationsDiscoveryBlock.disclosureAccessibilityValue(
                isExpanded: false,
                locale: Locale(identifier: "en")
            ) == "Collapsed"
        )
        #expect(
            InsightsCorrelationsDiscoveryBlock.disclosureAccessibilityValue(
                isExpanded: true,
                locale: Locale(identifier: "en")
            ) == "Expanded"
        )
        #expect(
            InsightsCorrelationsDiscoveryBlock.disclosureAccessibilityValue(
                isExpanded: false,
                locale: Locale(identifier: "de")
            ) == "Eingeklappt"
        )
    }

    /// **Amended 2026-08-23 (Plan 17-06, C2 / decision E6) — the clause stands,
    /// its expected copy moved.**
    ///
    /// This case was written for the special case in `channelLabel(…)` that
    /// caught the server's raw `environment: daylight` token and replaced it
    /// with presentation copy (`Tageslicht` / `Daylight`). What it is really
    /// about is that the raw token must never reach the screen — and that has
    /// not been weakened.
    ///
    /// What changed is which copy replaces it. E6 inverts the CU-33 precedence
    /// for the 17 curated channels, and `TIME_IN_DAYLIGHT` is one of them, so
    /// the curated table now answers first and the special case is never
    /// reached for this channel. The label is therefore the table's
    /// (`Zeit im Tageslicht` / `time in daylight`) rather than the special
    /// case's — one German name for one channel instead of two, which is the
    /// point of the inversion.
    ///
    /// The special case itself is deliberately kept in production for a channel
    /// OUTSIDE the curated table that arrives carrying the same token.
    @Test("raw environment daylight label never reaches the screen — now via the curated table (E6)")
    func environmentDaylightIsLocalized() {
        let deLabel = InsightsCorrelationsDiscoveryBlock.channelLabel(
            serverLabel: " Environment: Daylight ",
            channel: "TIME_IN_DAYLIGHT",
            locale: Locale(identifier: "de")
        )
        #expect(deLabel == "Zeit im Tageslicht")
        #expect(!deLabel.lowercased().contains("environment"), "the raw server token must never render")

        let enLabel = InsightsCorrelationsDiscoveryBlock.channelLabel(
            serverLabel: "environment: daylight",
            channel: "TIME_IN_DAYLIGHT",
            locale: Locale(identifier: "en")
        )
        #expect(enLabel == "time in daylight")
        #expect(!enLabel.lowercased().contains("environment"), "the raw server token must never render")

        // The special case still guards a NON-curated channel carrying the same
        // token — the inversion narrowed which channels reach it, it did not
        // delete it.
        #expect(
            InsightsCorrelationsDiscoveryBlock.channelLabel(
                serverLabel: "environment: daylight",
                channel: "SOME_FUTURE_DAYLIGHT_CHANNEL",
                locale: Locale(identifier: "de")
            ) == "Tageslicht"
        )
    }

    @Test("canonical daylight and unknown channels keep safe readable labels")
    func canonicalAndUnknownLabels() {
        #expect(
            InsightsCorrelationsDiscoveryBlock.channelLabel(
                serverLabel: nil,
                channel: "TIME_IN_DAYLIGHT",
                locale: Locale(identifier: "de")
            ) == "Zeit im Tageslicht"
        )
        #expect(
            InsightsCorrelationsDiscoveryBlock.channelLabel(
                serverLabel: "  My Custom Signal  ",
                channel: "CUSTOM_SIGNAL",
                locale: Locale(identifier: "de")
            ) == "My Custom Signal"
        )
        #expect(
            InsightsCorrelationsDiscoveryBlock.channelLabel(
                serverLabel: nil,
                channel: "FUTURE_CUSTOM_SIGNAL",
                locale: Locale(identifier: "en")
            ) == "future custom signal"
        )
    }
}
