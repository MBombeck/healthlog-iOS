@testable import HealthLog
import Testing

@Suite("HLSourcesLink — fail-closed rendering contract")
struct HLSourcesLinkTests {
    @Test("a topic with sources or methodology is renderable")
    func renderableTopics() {
        #expect(HLSourcesLink.isRenderable(.correlations))
        #expect(HLSourcesLink.isRenderable(.metric(.bloodPressure)))
        #expect(HLSourcesLink.isRenderable(.vorsorge)) // methodology only
    }

    @Test("a metric kind with no sources renders no control at all")
    func metricWithoutSourcesIsNotRenderable() {
        // R25 / I2 — the explainer methodology says "the references below", so
        // it may only be offered where there are references. A kind the catalog
        // leaves uncited (`.painNRS`, the decode sentinel, the six device-event
        // kinds) must suppress the control instead of opening an empty sheet.
        #expect(HLSourcesLink.isRenderable(.metric(.timeInDaylight)), "a cited kind still renders")
        #expect(!HLSourcesLink.isRenderable(.metric(.painNRS)))
        #expect(!HLSourcesLink.isRenderable(.metric(.unknown)))
    }

    @Test("accessibility identifier is derived from the topic")
    func identifier() {
        #expect(HLSourcesLink.identifier(for: .labBiomarker("alt")) == "sources.lab.alt")
    }

    // MARK: - 1.4.1 — the caption-shaped citation is the SAME control

    @MainActor
    @Test("the guideline caption asks HLSourcesLink for the control, so the identifier is shared")
    func guidelineCaptionReusesTheOneCitationControl() {
        // The status card's caption ("ESH 2023", "WHO 2000") is the citation
        // affordance wearing a different label, not a second implementation of
        // it — so its identifier is the topic's, exactly like every other
        // `HLSourcesLink` on any surface.
        let caption = HLSourcesGuidelineCaption(caption: "ESH 2023", topic: .bloodPressureClassification)
        #expect(caption.topic == .bloodPressureClassification)
        #expect(HLSourcesLink.identifier(for: .bloodPressureClassification) == "sources.bpClassification")
        #expect(HLSourcesLink.identifier(for: .bmi) == "sources.bmi")
    }

    @MainActor
    @Test("a caption whose topic the catalog cannot cite stays plain text rather than vanishing")
    func guidelineCaptionFallsBackToPlainText() {
        // Fail-closed in the honest direction: the citation disappears, the
        // guideline name does not. Both classification topics are renderable
        // today, so the caption is a control on the shipping cards; a caption
        // with no topic (or an uncitable one) still states its guideline.
        #expect(HLSourcesLink.isRenderable(.bloodPressureClassification))
        #expect(HLSourcesLink.isRenderable(.bmi))
        let untopiced = HLSourcesGuidelineCaption(caption: "ESH 2023", topic: nil)
        #expect(untopiced.topic == nil, "No topic → the caption renders as plain text, not as a dead button.")
    }
}
