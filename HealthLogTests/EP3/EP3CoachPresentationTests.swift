import Foundation
@testable import HealthLog
import SwiftUI
import Testing

/// The Coach's cards and chips in the app's building blocks: the provenance
/// capsule reads as one line, and the reworked cards still draw.
@MainActor
@Suite("E-P3 coach: provenance badge and card forms")
struct EP3CoachPresentationTests {
    #if canImport(SpeziChat)
        @Test("the provenance badge joins metric, window and count with commas")
        func provenanceTitleJoinsParts() {
            let model = ProvenanceChipModel(metricToken: "ep3_metric", windowToken: "ep3_window", count: 12)
            #expect(ProvenanceChip.title(model) == "ep3_metric, ep3_window, n=12")
        }

        @Test("a window-only provenance badge has no stray separator")
        func provenanceTitleWindowOnly() {
            let model = ProvenanceChipModel(metricToken: "", windowToken: "ep3_window", count: nil)
            #expect(ProvenanceChip.title(model) == "ep3_window")
        }
    #endif

    @Test("the reworked coach card and suggestion chip draw")
    func cardsRender() {
        let views: [AnyView] = [
            AnyView(CoachReengageCard {}),
            AnyView(AskCoachSuggestionChip(text: "How is my sleep?", icon: "moon.zzz.fill") {})
        ]
        for view in views {
            let renderer = ImageRenderer(content: view.frame(width: 360))
            renderer.scale = 1
            #expect(renderer.uiImage != nil)
        }
    }
}
