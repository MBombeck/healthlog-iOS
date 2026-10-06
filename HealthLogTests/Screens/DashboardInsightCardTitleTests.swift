import Foundation
@testable import HealthLog
import Testing

/// **#115 B6 — the dashboard insight card no longer claims an assistant.**
///
/// Since server v1.39 `GET /api/insights/cards` answers `provider: "rules"`:
/// the cards are rule-based. The tile still said "Assistant insight" beside a
/// sparkles symbol, the app's mark for AI-written text.
@MainActor
@Suite("#115 B6 — dashboard insight card title")
struct DashboardInsightCardTitleTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    @Test("the card uses a neutral symbol and title")
    func neutralSymbolAndTitle() {
        #expect(HighlightInsightCard.symbolName != "sparkles")
        #expect(!HighlightInsightCard.title.localizedCaseInsensitiveContains("assistant"))
        #expect(!HighlightInsightCard.title.localizedCaseInsensitiveContains("assistent"))
    }

    @Test("the title is translated in both locales: Insight / Hinweis")
    func titleIsTranslated() throws {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("HealthLog/Resources/Localizable.xcstrings"))
        let catalog = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: Any])
        let entry = try #require(strings["Insight"] as? [String: Any])
        let locs = try #require(entry["localizations"] as? [String: [String: [String: String]]])
        #expect(locs["en"]?["stringUnit"]?["value"] == "Insight")
        #expect(locs["de"]?["stringUnit"]?["value"] == "Hinweis")
    }
}
