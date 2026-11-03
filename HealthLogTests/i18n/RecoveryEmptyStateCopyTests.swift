import Foundation
import Testing

/// **K1 — „Erholung 83" neben „Noch keine Erholungsdaten".**
///
/// H2 photographed the Insights overview with a recovery score of 83 and, one
/// swipe away, the recovery page saying there was no recovery data at all.
/// Both halves are server truth: the overview's score can be computed from
/// resting heart rate, HRV and sleep, while the recovery page lists
/// device-native wearable readings. An Apple Watch user without WHOOP, Polar or
/// Oura sees exactly this pair in production.
///
/// The contradiction was the copy, so the copy is pinned: the title names what
/// is missing (wearable readings, not recovery data).
///
/// **1.4 B3.** The body no longer explains the overview score (R2: it explained
/// another surface). It names what the page shows instead, in one sentence, and
/// does not mention the recovery score at all, so it cannot deny it. The second
/// empty case (readings exist, none from the last 30 days) has its own title.
@Suite("K1 — recovery empty state does not deny the overview's recovery score")
struct RecoveryEmptyStateCopyTests {
    @Test("The title no longer claims there is no recovery data", arguments: ["de", "en"])
    func titleNamesWhatIsMissing(_ language: String) throws {
        let catalog = try ParityCatalog.load()
        let title = try #require(catalog.strings["insights.recovery.empty.title"])
        let value = try #require(ParityCatalog.value(title, language: language))
        let denial = language == "de" ? "Erholungsdaten" : "recovery data"
        #expect(!value.localizedCaseInsensitiveContains(denial), "\(language): \(value)")
    }

    @Test("The body is one sentence about the wearable and never mentions the recovery score", arguments: ["de", "en"])
    func bodyNamesTheWearable(_ language: String) throws {
        let catalog = try ParityCatalog.load()
        let body = try #require(catalog.strings["insights.recovery.empty.body"])
        let value = try #require(ParityCatalog.value(body, language: language))
        let score = language == "de" ? "Erholung" : "recovery"
        #expect(!value.localizedCaseInsensitiveContains(score), "\(language): \(value)")
        #expect(value.contains("WHOOP"), "\(language): \(value)")
        #expect(value.filter { $0 == "." }.count == 1, "\(language): \(value)")
    }

    @Test("The quiet-month title and the action exist in both languages", arguments: ["de", "en"])
    func secondCaseAndAction(_ language: String) throws {
        let catalog = try ParityCatalog.load()
        for key in ["insights.recovery.empty.recentTitle", "insights.recovery.empty.action"] {
            let entry = try #require(catalog.strings[key], "\(key)")
            let value = try #require(ParityCatalog.value(entry, language: language), "\(key)")
            #expect(!value.isEmpty, "\(key) \(language)")
        }
    }
}
