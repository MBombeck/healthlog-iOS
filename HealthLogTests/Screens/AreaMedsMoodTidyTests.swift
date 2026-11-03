import Foundation
@testable import HealthLog
import Testing

/// **iOS 1.4 B2-b — medications, mood, cycle and notifications without loose
/// texts.**
///
/// Pins the decisions that are logic rather than copy: which sections leave the
/// screen when they have nothing to show, what the two new (i) sheets carry,
/// the one-line captions that replaced sentences, and that the screenshot
/// fixtures still decode through the real DTOs.
@MainActor
@Suite("B2-b — medications, mood, cycle, notifications")
struct AreaMedsMoodTidyTests {
    // MARK: - Medication detail

    @Test("The adherence section is absent for a record and without a schedule, present otherwise")
    func complianceSectionHidesWithoutAdherence() {
        #expect(!ComplianceKPISection.hasContent(.notTracked))
        #expect(!ComplianceKPISection.hasContent(.notApplicable))
        #expect(ComplianceKPISection.hasContent(.pending))
        #expect(ComplianceKPISection.hasContent(.unavailable))
        #expect(ComplianceKPISection.hasContent(.server(.init(rate: 80, taken: 24, expected: 30))))
    }

    @Test("The unavailable adherence line names no server")
    func unavailableLineHasNoServer() {
        let value = String(localized: "med.compliance.unavailable")
        #expect(!value.localizedCaseInsensitiveContains("server"))
    }

    // MARK: - Mood

    @Test("A pattern chip carries strength and days, or the days alone")
    func patternChip() throws {
        let json = """
        { "betterDays": [], "stabilityWindowDays": 30, "patterns": [
          { "id": "weekend", "kind": "weekend", "strength": "moderate", "direction": "higher",
            "values": { "subject": 7.2, "comparison": 6.4, "delta": 0.8 },
            "sampleSize": { "subject": 8, "comparison": 22 } },
          { "id": "notes", "kind": "notes", "strength": "zz_future", "direction": "higher",
            "values": { "subject": 7.0, "comparison": 6.0, "delta": 1.0 },
            "sampleSize": { "subject": 5, "comparison": 25 } } ] }
        """
        let response = try JSONDecoder.hlDefault.decode(MoodRelationsResponse.self, from: Data(json.utf8))
        let cards = try MoodPatternPresentation.cards(for: #require(response.patterns))
        #expect(cards.count == 2)
        #expect(cards[0].chip == "\(String(localized: "mood.patterns.strength.moderate")), \(cards[0].basedOn)")
        #expect(cards[1].strength == nil)
        #expect(cards[1].chip == cards[1].basedOn)
        #expect(cards[1].chip.contains("5") && cards[1].chip.contains("25"))
    }

    @Test("The stability line is the band in a word and the server's window")
    func stabilityCaption() {
        let caption = MoodStabilitySection.caption(for: MoodStability(score: 72, stdDev: 0.7, band: .steady, days: 28))
        #expect(caption.contains(MoodStabilitySection.bandLabel(for: .steady)))
        #expect(caption.contains("28"))
    }

    // MARK: - Cycle (i)

    @Test("The cycle (i) carries the phase in full, the method, the guide, and the patterns only when shown")
    func cycleInfo() {
        let withPhase = CycleInfo.content(phase: .follicular, showsPatterns: false)
        #expect(withPhase.identifier == "cycle.info.sheet")
        #expect(withPhase.sections.first?.title == String(localized: CyclePhaseExplainer.nameKey(for: .follicular)))
        #expect(withPhase.sections.first?.paragraphs == [String(localized: CyclePhaseExplainer.bodyKey(for: .follicular))])
        #expect(withPhase.learnMoreConcept == "CYCLE")
        #expect(!withPhase.references.isEmpty, "the .cycle references travel with the moved text")
        let patternsTitle = String(localized: "cycle.insights.title")
        #expect(!withPhase.sections.contains { $0.title == patternsTitle })

        let noPhase = CycleInfo.content(phase: nil, showsPatterns: true)
        #expect(noPhase.sections.contains { $0.title == patternsTitle })
        #expect(!noPhase.sections.contains { $0.title == String(localized: CyclePhaseExplainer.nameKey(for: .follicular)) })
    }

    @Test("A cycle pattern row names its days without a q-value")
    func cycleEvidenceHasNoQValue() {
        for language in ["de", "en"] {
            let value = Self.catalogValue("cycle.insights.evidence", language)
            #expect(!value.contains("q="))
            #expect(value.contains("%1$d") && value.contains("%2$d"))
        }
    }

    // MARK: - Notifications (i)

    @Test("The diagnostics (i) explains the two numbers whose footers left the cards")
    func diagnosticsInfo() {
        let info = NotificationDiagnosticsInfo.content
        #expect(info.sections.map(\.title) == [
            String(localized: "Medication data"),
            String(localized: "Scheduled notifications")
        ])
        #expect(!info.isEmpty)
    }

    // MARK: - Screenshot fixtures decode through the real DTOs

    @Test("The B2-b fixture overlay decodes: four medications, one kept as a record")
    func fixtureMedications() throws {
        let body = try #require(AreaMedsFixtures.response(forPath: "/api/medications", method: "GET")?.body)
        // The wire shape `MedicationsRepository.fetchMedications` decodes.
        let medications = try JSONDecoder.hlDefault.decode([MedicationWireDTO].self, from: body).map { $0.toDomain() }
        #expect(medications.count == 4)
        let record = try #require(medications.first { $0.id == AreaMedsFixtures.recordOnlyMedicationID })
        #expect(!record.tracksIntake)
        #expect(medications.first { $0.name == "Trulicity" }?.treatmentClass == "GLP1")
    }

    @Test("The B2-b fixture overlay decodes: mood entries, relations and check-ins")
    func fixtureMoodAndMentalHealth() throws {
        let entries = try JSONDecoder.hlDefault.decode(
            MoodListResponse.self,
            from: Data(AreaMedsFixtures.moodEntriesJSON.utf8)
        )
        #expect(entries.entries.count == 30)
        let relations = try JSONDecoder.hlDefault.decode(
            MoodRelationsResponse.self,
            from: Data(AreaMedsFixtures.moodInsightsJSON.utf8)
        )
        #expect(relations.stability != nil)
        #expect(relations.patterns?.count == 2)
        #expect(relations.tagInfluence.structured.count == 2)
        #expect(relations.betterDays.count == 2)
        #expect(relations.factorCrosstab.count == 1)
        let history = try JSONDecoder.hlDefault.decode(
            MentalHealthHistoryResponse.self,
            from: Data(AreaMedsFixtures.assessmentsJSON.utf8)
        )
        #expect(history.assessments.count == 2)
    }

    @Test("The B2-b cycle overlay decodes: an open cycle on day 10, five closed ones, phase comparisons")
    func fixtureCycle() throws {
        func body(_ path: String) throws -> Data {
            try #require(AreaCycleFixtures.response(forPath: path, method: "GET")?.body)
        }
        let decoder = JSONDecoder.hlDefault
        let calendar = try #require(
            decoder.decode(APIEnvelope<CycleCalendarResponse>.self, from: body("/api/cycle/calendar")).data
        )
        #expect(calendar.verdict?.dayOfCycle == 10)
        #expect(calendar.prediction?.stillLearning == false)
        #expect(calendar.days.count == 111)
        let list = try #require(decoder.decode(APIEnvelope<CycleListResponse>.self, from: body("/api/cycle/cycles")).data)
        #expect(list.cycles.count == 6)
        #expect(list.stats?.regularity == "REGULAR")
        let insights = try #require(
            decoder.decode(APIEnvelope<CycleInsightsDTO>.self, from: body("/api/cycle/insights")).data
        )
        #expect(!insights.isLearning)
        #expect(insights.headline != nil)
        #expect(AreaCycleFixtures.response(forPath: "/api/cycle/calendar", method: "POST") == nil)
    }

    @Test("The B2-b illness overlay decodes: four episodes, one reading, three logged days")
    func fixtureIllness() throws {
        func body(_ path: String, _ query: [URLQueryItem] = []) throws -> Data {
            try #require(AreaIllnessFixtures.response(forPath: path, method: "GET", query: query)?.body)
        }
        let decoder = JSONDecoder.hlDefault
        let episodes = try #require(
            decoder.decode(APIEnvelope<[IllnessEpisodeDTO]>.self, from: body("/api/illness/episodes")).data
        )
        #expect(episodes.count == 4)
        #expect(episodes.count(where: \.isActive) == 1)
        let episode = "/api/illness/episodes/\(AreaIllnessFixtures.influenzaID)"
        let reading = try #require(
            decoder.decode(APIEnvelope<IllnessCorrelationDTO>.self, from: body("\(episode)/correlation")).data
        )
        #expect(reading.status == .ok)
        #expect(reading.value?.recoveryGapDays == 3)
        let logs = try #require(decoder.decode(
            APIEnvelope<IllnessDayLogList>.self,
            from: body("/api/illness/episodes/\(AreaIllnessFixtures.bronchitisID)/day-logs")
        ).data)
        #expect(logs.dayLogs.count == 3)
        let insights = try #require(
            decoder.decode(APIEnvelope<IllnessInsightsDTO>.self, from: body("/api/illness/insights")).data
        )
        #expect(insights.episodeCount == 4)
        #expect(insights.typicalRecoveryGapDays == 3)
    }

    // MARK: - Helpers

    private static func catalogValue(_ key: String, _ language: String) -> String {
        guard let path = Bundle.main.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return "" }
        return bundle.localizedString(forKey: key, value: "MISSING", table: nil)
    }
}
