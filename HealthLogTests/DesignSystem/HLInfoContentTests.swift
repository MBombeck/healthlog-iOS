import Foundation
@testable import HealthLog
import Testing

/// **1.4 B2 — the info pattern.** `HLInfoContent` is what a screen's one (i)
/// explains; the 1.0.3 "Sources & method" sheet is the same content with one
/// method section. The metric page is the reference migration.
@Suite("Info pattern — HLInfoContent and the metric page's (i)")
struct HLInfoContentTests {
    // MARK: - The sources sheet keeps its 1.0.3 shape

    @Test("a Sources link opens the same sheet: method under \"So wird das berechnet\", then the topic's references")
    func sourcesContentKeepsItsShape() {
        let content = HLInfoContent.sources(.correlations)
        #expect(content.identifier == "sources.sheet.correlations")
        #expect(content.title == String(localized: "sources.sheet.title"))
        #expect(content.about == nil)
        #expect(content.sections.count == 1)
        #expect(content.sections.first?.title == String(localized: "sources.sheet.methodTitle"))
        #expect(content.sections.first?.paragraphs == [String(localized: "sources.method.correlations")])
        #expect(content.references == MedicalSourceCatalog.sources(for: .correlations))
        #expect(content.isMedical)
        #expect(!content.showsHubLink)
        #expect(HLInfoContent.sources(.aiAssistant).showsHubLink)
    }

    @Test("a method-only topic keeps its medical footer even without references")
    func methodOnlyTopicIsStillMedical() {
        let content = HLInfoContent.sources(.vorsorge)
        #expect(content.references.isEmpty)
        #expect(content.isMedical)
        #expect(!content.isEmpty)
    }

    // MARK: - Building blocks

    @Test("a method section is titled by the catalog's method title and leads with the screen's own words")
    func methodSection() throws {
        let section = try #require(HLInfoContent.Section.method(topic: .pulsePressureMAP, lead: "Lead."))
        #expect(section.title == String(localized: "sources.methodTitle.pulsePressureMAP"))
        #expect(section.paragraphs == ["Lead.", String(localized: "sources.method.pulsePressureMAP")])
        #expect(section.topic == .pulsePressureMAP)
        #expect(HLInfoContent.Section.method(topic: .metric(.painNRS)) == nil, "no method, no section")
    }

    @Test("references are listed once even when two sections cite the same source")
    func referencesAreDeduplicated() {
        let content = HLInfoContent(
            title: "T",
            identifier: "t",
            topic: .metric(.bloodPressure),
            sections: [HLInfoContent.Section.method(topic: .bloodPressureClassification)].compactMap(\.self)
        )
        let ids = content.references.map(\.id)
        #expect(ids.count == Set(ids).count)
        #expect(ids.contains(.esh2023Hypertension))
    }

    @Test("a glossary of app terms is not medical, and nothing at all renders no (i)")
    func glossaryAndEmpty() {
        let glossary = HLInfoContent(
            title: "T",
            identifier: "t",
            sections: [HLInfoContent.Section(title: "A", paragraphs: ["B"])]
        )
        #expect(!glossary.isMedical)
        #expect(!glossary.isEmpty)
        #expect(HLInfoContent(title: "T", identifier: "t").isEmpty)
    }

    // MARK: - The reference screen

    @Test("blood pressure: the explainer, pulse pressure with its values explained, the classification, the guide")
    func bloodPressureInfo() throws {
        let content = InsightsMetricInfo.content(for: .bloodPressure, canShowCloudInsights: true, showsCorrelation: false)
        #expect(content.identifier == "insights.metric.info.sheet.bloodPressure")
        #expect(content.title == MetricKind.bloodPressure.displayName)
        #expect(content.about == InsightsExplainer.resolve(for: .bloodPressure)?.body)
        #expect(content.sections.map(\.title) == [
            String(localized: "sources.methodTitle.pulsePressureMAP"),
            String(localized: "sources.methodTitle.bpClassification")
        ])
        // 1.4 B2 — one paragraph: what both are, how they are derived, their
        // typical values (the lead that repeated it is gone).
        let pulsePressure = try #require(content.sections.first)
        #expect(pulsePressure.paragraphs == [String(localized: "sources.method.pulsePressureMAP")])
        let ids = content.references.map(\.id)
        #expect(ids.contains(.statpearlsPulsePressure))
        #expect(ids.contains(.esh2023Hypertension))
        #expect(content.learnMoreConcept == "bloodPressure")
    }

    @Test("sleep explains the debt and chronotype cards only where the server can show them")
    func sleepInfoFollowsTheCards() {
        let cloud = InsightsMetricInfo.content(for: .sleep, canShowCloudInsights: true, showsCorrelation: false)
        #expect(cloud.sections.map(\.title).contains(String(localized: "sleep.debt.title")))
        #expect(cloud.sections.map(\.title).contains(String(localized: "sleep.chronotype.title")))
        #expect(cloud.referenceTopics.contains(.sleepRhythm))
        // App Review 1.4.1, audit row 17: the "own estimate" sentence stays with
        // the references that back it.
        #expect(cloud.sections.contains { $0.paragraphs.contains(String(localized: "sleep.debt.computedInfo")) })
        let standalone = InsightsMetricInfo.content(for: .sleep, canShowCloudInsights: false, showsCorrelation: false)
        #expect(standalone.sections.isEmpty)
        #expect(standalone.about != nil)
    }

    @Test("the same-time comparison and the correlation card get a section only when they can be on the page")
    func cardDependentSections() {
        let title = String(localized: "insights.sameTimeBaseline.title")
        #expect(InsightsMetricInfo.content(for: .steps, canShowCloudInsights: true, showsCorrelation: false)
            .sections.map(\.title).contains(title))
        #expect(!InsightsMetricInfo.content(for: .steps, canShowCloudInsights: false, showsCorrelation: false)
            .sections.map(\.title).contains(title))
        let correlation = String(localized: "sources.methodTitle.correlations")
        #expect(InsightsMetricInfo.content(for: .weight, canShowCloudInsights: true, showsCorrelation: true)
            .sections.map(\.title).contains(correlation))
        #expect(!InsightsMetricInfo.content(for: .weight, canShowCloudInsights: true, showsCorrelation: false)
            .sections.map(\.title).contains(correlation))
    }

    @Test("every metric with a web explainer has a \"Was ist das?\" behind its (i)")
    func explainersMoved() {
        for kind in [MetricKind.weight, .pulse, .glucose, .hrv, .spo2, .vo2Max, .restingHeartRate] {
            #expect(InsightsMetricInfo.about(for: kind) == InsightsExplainer.resolve(for: kind)?.body)
            #expect(InsightsMetricInfo.about(for: kind) != nil, "\(kind.rawValue)")
        }
    }

    @Test("1.4 B4: the RMSSD page explains RMSSD, cites HRV and reads the HRV guide")
    func rmssdHasItsOwnInfo() {
        let info = InsightsMetricInfo.content(for: .hrvRMSSD, canShowCloudInsights: true, showsCorrelation: false)
        #expect(info.about != nil)
        #expect(info.about != InsightsMetricInfo.about(for: .hrv), "RMSSD is not described as SDNN")
        #expect(info.learnMoreConcept == MetricKind.hrv.rawValue)
        #expect(!info.references.isEmpty)
    }

    @Test("1.4 B4: the recovery page's guide and references sit behind its (i), not under its title")
    func recoveryPageInfo() throws {
        let info = InsightsSpecialPageInfo.recovery()
        #expect(info.about != nil)
        #expect(info.learnMoreConcept == "RESILIENCE")
        #expect(info.referenceTopics.contains(.derivedScore("RECOVERY_SCORE")))
        let page = try source("HealthLog/Screens/Insights/Sub/InsightsRecoveryPage.swift")
        #expect(page.components(separatedBy: "HLInfoButton(").count == 2, "exactly one (i)")
        #expect(!page.contains("HLLearnMoreLink("))
        #expect(!page.contains("HLSourcesLink("))
    }

    // MARK: - Source contracts

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // DesignSystem
        .deletingLastPathComponent() // HealthLogTests
        .deletingLastPathComponent() // repo root

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test("the metric page carries one (i) and no loose explainer, link row or BP sentences")
    func metricPageIsMigrated() throws {
        let page = try source("HealthLog/Screens/Insights/InsightsMetricScreen.swift")
            + source("HealthLog/Screens/Insights/InsightsMetricScreen+Sections.swift")
        #expect(page.components(separatedBy: "HLInfoButton(").count == 2, "exactly one (i)")
        #expect(page.contains("accessibilityIdentifier: \"insights.metric.info.\\(kind.rawValue)\""))
        for retired in ["descriptionSlot", "bpDerivedBlock", "rangeDeltaSlot", "HLLearnMoreLink(", "insights.bp.derived.caveat"] {
            #expect(!page.contains(retired), "\(retired) is back on the metric page")
        }
    }

    @Test("a Sources link or (i) inside the three sheets pushes instead of stacking a sheet")
    func sheetsPushInPlace() throws {
        for path in [
            "HealthLog/Screens/Insights/Sub/WellnessScoreDetailSheet.swift",
            "HealthLog/Screens/Coach/AskCoachSheet.swift",
            "HealthLog/Screens/Labs/BiomarkerEditorSheet.swift"
        ] {
            #expect(try source(path).contains(".hlSheetStack()"), "\(path) must mark its stack")
        }
        let link = try source("HealthLog/DesignSystem/Sources/HLSourcesLink.swift")
        #expect(link.contains("if insideSheetStack {"))
        let button = try source("HealthLog/DesignSystem/Sources/HLInfoButton.swift")
        #expect(button.contains("if insideSheetStack {"))
    }
}
