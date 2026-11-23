import Foundation

/// **What the (i) of the special Insights pages explains.**
///
/// The web explainer that used to stand as a paragraph under each page title
/// is the sheet's "Was ist das?". A section joins
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

    /// The Workouts page: where the list comes from and how sources merge.
    static func workouts() -> HLInfoContent {
        HLInfoContent(
            title: String(localized: "Workouts"),
            identifier: "insights.workouts.info.sheet",
            about: String(localized: "insights.workouts.info.about")
        )
    }

    /// The ECG page: what is shown and whose result it is. The device
    /// makers' references stand behind the topic.
    static func ecg() -> HLInfoContent {
        HLInfoContent(
            title: String(localized: "insights.ecg.title"),
            identifier: "insights.ecg.info.sheet",
            about: String(localized: "insights.ecg.info.about"),
            topic: .ecgRhythm
        )
    }
}
