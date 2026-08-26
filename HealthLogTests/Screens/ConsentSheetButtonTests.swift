import Foundation
import Testing

/// FW-COACH (v0.14.4) — locks the AI/LLM consent CTAs as FILLED primary buttons
/// whose fill is pinned to the monochrome `HLAccent.primary` token, so the
/// "Accept" button can never render white-on-white (the operator-reported bug
/// where the sheet's ambient `.tint` resolved near-white under the white label).
///
/// The sheet bodies are SwiftUI views with no testable hook for the resolved
/// colour, so this is a source-level contract test on the two consent sheets.
@Suite("Consent CTA contrast")
struct ConsentSheetButtonTests {
    private static func source(_ relativePath: String) -> String {
        let here = URL(fileURLWithPath: #filePath)
        let root = here
            .deletingLastPathComponent() // Screens
            .deletingLastPathComponent() // HealthLogTests
            .deletingLastPathComponent() // repo root
        let file = root.appendingPathComponent(relativePath)
        return (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    }

    @Test(
        "Both consent Accept CTAs are filled primary buttons pinned to HLAccent.primary",
        arguments: [
            "HealthLog/Screens/Settings/AIConsentSheet.swift",
            "HealthLog/Screens/Settings/BYOConsentSheet.swift"
        ]
    )
    func acceptCTAIsContrastingFilledPrimary(path: String) {
        let src = Self.source(path)
        #expect(!src.isEmpty)
        // Uses the design-system primitive (no hand-rolled button).
        #expect(src.contains("variant: .primary"))
        // Fill pinned to the monochrome token so it matches the WCAG label-clamp.
        #expect(src.contains(".tint(HLAccent.primary)"))
    }
}
