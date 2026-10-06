import Foundation
import Testing

/// **K1 — „Erholung 83" neben „Noch keine Erholungsdaten".**
///
/// H2 photographed the Insights overview with a recovery score of 83 and, one
/// swipe away, the recovery page saying there was no recovery data at all.
/// Both halves are server truth and neither is a fixture artefact: v1.39.2 keeps
/// the composite `RECOVERY_SCORE` (resting heart rate, HRV, sleep) on the
/// overview and fills the recovery page only from device-native wearable
/// signals (`recovery-section.tsx`, „a non-wearable account sees only the calm
/// empty note"). An Apple Watch user without WHOOP, Polar or Oura sees exactly
/// this pair in production.
///
/// The contradiction was the copy, so the copy is what is pinned: the empty
/// title names what is missing (wearable readings, not recovery data), and the
/// body says why the overview score can exist anyway.
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

    @Test("The body explains where the overview's score comes from", arguments: ["de", "en"])
    func bodyPointsAtTheOverviewScore(_ language: String) throws {
        let catalog = try ParityCatalog.load()
        let body = try #require(catalog.strings["insights.recovery.empty.body"])
        let value = try #require(ParityCatalog.value(body, language: language))
        let overview = language == "de" ? "Überblick" : "overview"
        #expect(value.localizedCaseInsensitiveContains(overview), "\(language): \(value)")
        #expect(value.contains("HRV"), "\(language): \(value)")
    }
}
