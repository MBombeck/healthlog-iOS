import Foundation

/// **1.4 B2 — what the metric page's (i) explains.**
///
/// The reference screen of the info pattern (the 1.4 design
/// notes). The page keeps its cards and their one line each; the
/// explanations that used to stand between them live here: the metric's own
/// explainer ("Was ist das?"), one section per card with a method of its own,
/// the references behind all of it and the public guide.
///
/// A section only appears for a card the page can actually show: the day
/// curve and the same-time comparison are server compute, the correlation
/// card needs its pairing.
enum InsightsMetricInfo {
    static func content(
        for kind: MetricKind,
        canShowCloudInsights: Bool,
        showsCorrelation: Bool
    ) -> HLInfoContent {
        HLInfoContent(
            title: kind.displayName,
            identifier: "insights.metric.info.sheet.\(kind.rawValue)",
            about: about(for: kind),
            // The explainer's typical ranges rest on these references.
            topic: HLSourcesLink.isRenderable(.metric(kind)) ? .metric(kind) : nil,
            sections: sections(
                for: kind,
                canShowCloudInsights: canShowCloudInsights,
                showsCorrelation: showsCorrelation
            ),
            // RMSSD is a way of measuring HRV: it reads the HRV guide.
            learnMoreConcept: kind == .hrvRMSSD ? MetricKind.hrv.rawValue : kind.rawValue
        )
    }

    /// The ported web explainer body, else the legacy per-metric description.
    /// `nil` when neither exists: the sheet never invents copy.
    static func about(for kind: MetricKind) -> String? {
        if let explainer = InsightsExplainer.resolve(for: kind) {
            return explainer.body
        }
        // INVARIANT (W22-audit Finding #7): a `insights.metric.<rawvalue>.description`
        // key carries plain copy (no `%@`) in DE and EN, or does not exist. A
        // missing entry resolves to the key itself, read here as "no copy".
        let key = "insights.metric.\(kind.rawValue).description"
        let resolved = String(localized: String.LocalizationValue(key))
        return resolved == key || resolved.isEmpty ? nil : resolved
    }

    private static func sections(
        for kind: MetricKind,
        canShowCloudInsights: Bool,
        showsCorrelation: Bool
    ) -> [HLInfoContent.Section] {
        var sections: [HLInfoContent.Section?] = []
        switch kind {
        case .bloodPressure:
            // 1.4 B2 — the method text says what both are, how they are
            // derived and their typical values, once; a lead in front of it
            // made the section say it twice.
            sections.append(.method(topic: .pulsePressureMAP))
            sections.append(.method(topic: .bloodPressureClassification))
        case .bmi:
            sections.append(.method(topic: .bmi))
        case .pulse where canShowCloudInsights:
            sections.append(.method(
                topic: .healthStatus,
                title: String(localized: "insights.intraday.title"),
                lead: String(localized: "insights.intraday.caption")
            ))
        case .sleep where canShowCloudInsights:
            sections.append(HLInfoContent.Section(
                title: String(localized: "sleep.debt.title"),
                paragraphs: [String(localized: "sleep.debt.computedInfo")]
            ))
            sections.append(HLInfoContent.Section(
                title: String(localized: "sleep.chronotype.title"),
                paragraphs: [String(localized: "sleep.chronotype.info")]
            ))
            // The two cards above say what the figures mean; the catalog's
            // method text is how they are worked out.
            sections.append(.method(topic: .sleepRhythm, title: String(localized: "sources.sheet.methodTitle")))
        default:
            break
        }
        if SameTimeBaselineBlock.supportedType(for: kind, canShowCloudInsights: canShowCloudInsights) != nil {
            sections.append(HLInfoContent.Section(
                title: String(localized: "insights.sameTimeBaseline.title"),
                paragraphs: [String(localized: "insights.sameTimeBaseline.info")]
            ))
        }
        if showsCorrelation {
            sections.append(.method(topic: .correlations))
        }
        return sections.compactMap(\.self)
    }
}
