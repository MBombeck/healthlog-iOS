// HealthLogTests/MedicalSources/SourcesLinkSurfaceCoverageTests.swift
//
// 1.0.3 / App Review audit row 17 — the two directly-reachable screens this
// task closed. Apple rejected 1.0 under 1.4.1 for medical-shaped statements
// without a stated basis, so "the link is mounted on this screen" is a shipping
// contract, not a styling detail. Asserted against the source text because the
// thing that can regress is the call site disappearing in a refactor, and a
// rendered-view test would not notice a link that was simply deleted.
import Foundation
@testable import HealthLog
import Testing

@Suite("Sources links on the surfaces audit row 17 named")
struct SourcesLinkSurfaceCoverageTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test("the lab result detail cites the reference ranges it judges against")
    func labResultDetailCarriesItsCitation() throws {
        let screen = try source("HealthLog/Screens/Labs/LabResultDetailScreen.swift")
        #expect(screen.contains("HLSourcesLink(topic: .labReferenceRanges)"))
        #expect(screen.contains("labs.detail.reference.caption"))
        #expect(HLSourcesLink.isRenderable(.labReferenceRanges))

        // The caption has to be real copy, not a key echoing itself.
        let caption = String(localized: "labs.detail.reference.caption")
        #expect(caption != "labs.detail.reference.caption")
    }

    @Test("the cycle prediction card cites what its estimate rests on")
    func cyclePredictionCarriesItsCitation() throws {
        let card = try source("HealthLog/Screens/Cycle/CycleSummaryCards.swift")
        #expect(card.contains("HLSourcesLink(topic: .cycle)"))
        // Once per screen: the disclaimer and the link are siblings in the one
        // prediction card, which `CycleScreen` mounts a single time.
        #expect(card.components(separatedBy: "HLSourcesLink(topic: .cycle)").count == 2)
        #expect(HLSourcesLink.isRenderable(.cycle))
    }
}
