import Foundation
@testable import HealthLog
import Testing

/// Two answers of the hermetic world the picture walks depend on, decoded the
/// way the app decodes them.
@Suite("Hermetic sweep fixtures")
struct HermeticSweepFixtureTests {
    /// Logging a mood must come back as one entry the app's own decoder
    /// accepts; the bare `{}` default made every capture fail with a read error
    /// before the sheet could reach its annotate step.
    @Test("POST /api/mood-entries answers one decodable entry")
    func moodPostAnswersOneEntry() throws {
        let response = HermeticFixtures.response(forPath: "/api/mood-entries", method: "POST")
        #expect(response.status == 200)

        let entry = try JSONDecoder.hlDefault.decode(MoodEntry.self, from: response.body)
        #expect(entry.id == "hermetic-mood-new")
        #expect(entry.mood == .good)

        let object = try JSONSerialization.jsonObject(with: response.body)
        #expect(object is [String: Any])
    }

    @Test("Mood reads and item writes keep their own answer")
    func moodReadsAreUntouched() {
        #expect(HermeticFixtures.moodWriteResponse(forPath: "/api/mood-entries", method: "GET") == nil)
        #expect(HermeticFixtures.moodWriteResponse(forPath: "/api/mood-entries/abc", method: "POST") == nil)
    }

    /// Today without medications must say so: nothing scheduled, nothing taken,
    /// so the adherence card stays away.
    @Test("The no-medication summary schedules nothing today")
    func noMedicationSummary() throws {
        let summary = try JSONDecoder.hlDefault.decode(
            DashboardSummary.self,
            from: Data(SweepFixtures.nothingScheduledSummaryJSON.utf8)
        )
        #expect(summary.compliance.scheduledToday == 0)
        #expect(summary.compliance.takenToday == 0)
        #expect(!summary.metrics.isEmpty)
    }

    /// The Assistant settings show the key row only for a provider the app can
    /// name; an unknown provider is the server-managed "External AI" state.
    @Test("The provider fixture is the account's own Anthropic key")
    func aiProviderIsOwnKey() throws {
        let config = try JSONDecoder.hlDefault.decode(
            AIProviderConfig.self,
            from: Data(CitationFixtures.aiProviderJSON.utf8)
        )
        #expect(config.resolvedProvider == .anthropic)
        #expect(config.managedByResolved == .user)
        #expect(!config.usesProviderOpaqueAIConsent)
        #expect(config.aiConsentTarget == .provider(.anthropic))
        #expect(config.activeKeyPreview == "sk-ant-…hermetic")
    }
}
