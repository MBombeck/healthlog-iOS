import Foundation

/// **1.4 B2 — what the (i) of the Mood and Medications pages explains.**
///
/// The web explainer that used to stand as a paragraph under each page title
/// (`InsightsExplainerIntro`) is the sheet's "Was ist das?". A section joins
/// only for a card the page shows: the correlation method when the page has a
/// correlation card, and on Medications the method behind the adherence bars.
enum InsightsSpecialPageInfo {
    static func mood(showsCorrelation: Bool) -> HLInfoContent {
        HLInfoContent(
            title: String(localized: "Mood"),
            identifier: "insights.mood.info.sheet",
            about: InsightsExplainer.copy(slug: "mood")?.body,
            // The mood cards cite `.mood` at their foot; the page's guide
            // ("Mehr erfahren") lives here since the influence card dropped it.
            topic: .mood,
            sections: showsCorrelation ? [HLInfoContent.Section.method(topic: .correlations)].compactMap(\.self) : [],
            learnMoreConcept: "MOOD"
        )
    }

    /// 1.4 B4 — the Recovery page. The guide pointer and the literature behind
    /// the recovery score stood as a loose line under the title (1.4.1); they
    /// are the sheet's references and "Mehr erfahren" now, next to what the
    /// page shows and how the score is worked out. The score detail behind the
    /// first card keeps its own sources.
    static func recovery() -> HLInfoContent {
        HLInfoContent(
            title: String(localized: "Recovery"),
            identifier: "insights.recovery.info.sheet",
            about: String(localized: "insights.recovery.info.about"),
            topic: .derivedScore("RECOVERY_SCORE"),
            sections: [HLInfoContent.Section.method(topic: .derivedScore("RECOVERY_SCORE"))].compactMap(\.self),
            learnMoreConcept: "RESILIENCE"
        )
    }

    static func medications(showsCorrelation: Bool) -> HLInfoContent {
        HLInfoContent(
            title: String(localized: "Medications"),
            identifier: "insights.medications.info.sheet",
            about: InsightsExplainer.copy(slug: "medications")?.body,
            sections: [
                HLInfoContent.Section.method(topic: .medicationCompliance),
                showsCorrelation ? HLInfoContent.Section.method(topic: .correlations) : nil
            ].compactMap(\.self)
        )
    }
}
