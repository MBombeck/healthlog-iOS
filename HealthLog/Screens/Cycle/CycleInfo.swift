import Foundation

/// **1.4 B2 — what the cycle screen's (i) explains.**
///
/// The phase card keeps its picture and headline; the longer text about the
/// current phase stands here, with the method behind phases and predictions,
/// how the cycle patterns are chosen (only when the screen shows them) and the
/// public guide. The references are the `.cycle` set the cards cite.
enum CycleInfo {
    static func content(phase: CyclePhasePalette.Phase?, showsPatterns: Bool) -> HLInfoContent {
        var sections: [HLInfoContent.Section] = []
        if let phase {
            sections.append(HLInfoContent.Section(
                title: String(localized: CyclePhaseExplainer.nameKey(for: phase)),
                paragraphs: [String(localized: CyclePhaseExplainer.bodyKey(for: phase))]
            ))
        }
        if let method = HLInfoContent.Section.method(topic: .cycle) {
            sections.append(method)
        }
        if showsPatterns {
            sections.append(HLInfoContent.Section(
                title: String(localized: "cycle.insights.title"),
                paragraphs: [String(localized: "cycle.info.patterns")]
            ))
        }
        return HLInfoContent(
            title: String(localized: "cycle.home.title"),
            identifier: "cycle.info.sheet",
            topic: .cycle,
            sections: sections,
            learnMoreConcept: "CYCLE"
        )
    }
}
