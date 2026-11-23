import Foundation
@testable import HealthLog
import Testing

/// The condition journal in the app's two-line rows: an episode, a logged
/// day, the insights summary as a statistic raster, and the symptom page's
/// check mark.
@Suite("Beschwerden-Tagebuch in Zeilen aus einem Guss")
struct EP3DiaryIllnessTests {
    private static func episode(
        resolvedAt: String? = nil,
        note: String? = nil,
        lifecycle: IllnessLifecycle = .acute
    ) -> IllnessEpisodeDTO {
        IllnessEpisodeDTO(
            id: "ep-1",
            label: "Bronchitis",
            type: .infection,
            lifecycle: lifecycle,
            onsetAt: "2026-11-03T08:00:00Z",
            resolvedAt: resolvedAt,
            parentConditionId: nil,
            note: note,
            createdAt: "2026-11-03T08:00:00Z",
            updatedAt: "2026-11-03T08:00:00Z"
        )
    }

    // MARK: - Episode row

    @Test func runningEpisodeRowHasTitleOneDetailLineAndCourseAsStatus() {
        let episode = Self.episode()
        let content = IllnessEpisodeRowContent(episode: episode)
        #expect(content.title == "Bronchitis")
        #expect(content.status == IllnessLifecycle.acute.localizedLabel)
        #expect(content.symbol == IllnessType.infection.icon)
        let span = IllnessEpisodeRowContent.span(of: episode)
        #expect(content.detail == "\(IllnessType.infection.localizedLabel), \(span)")
        // One line: the side facts never break into a second line of their own.
        #expect(content.detail?.contains("\n") == false)
    }

    @Test func resolvedEpisodeSpanNamesBothDays() {
        let episode = Self.episode(resolvedAt: "2026-11-09T08:00:00Z")
        let span = IllnessEpisodeRowContent.span(of: episode)
        let onset = IllnessDateFormat.mediumDate(episode.onsetAt)
        let end = IllnessDateFormat.mediumDate("2026-11-09T08:00:00Z")
        #expect(span.contains(onset))
        #expect(span.contains(end))
    }

    @Test func flaresAndNoteJoinTheDetailLine() throws {
        let content = IllnessEpisodeRowContent(episode: Self.episode(note: "Husten"), childCount: 2)
        let flares = String(format: String(localized: "illness.journal.children.count"), 2)
        let detail = try #require(content.detail)
        #expect(detail.hasSuffix("\(flares), \(String(localized: "Note"))"))
        // The note's own text stays on the detail page.
        #expect(!detail.contains("Husten"))
    }

    @Test func spokenRowKeepsTheEarlierVoiceOverSentence() {
        let episode = Self.episode()
        let content = IllnessEpisodeRowContent(episode: episode)
        let expected = String(
            format: String(localized: "illness.row.a11y"),
            "Bronchitis",
            IllnessType.infection.localizedLabel,
            IllnessEpisodeRowContent.span(of: episode)
        )
        #expect(content.spoken == expected)
    }

    // MARK: - Day log row

    @Test func dayLogRowPutsSymptomsAndNoteOnOneLineAndImpactAsStatus() {
        let log = IllnessDayLogDTO(
            id: "d1",
            episodeId: "ep-1",
            date: "2026-11-04",
            functionalImpact: 2,
            feverC: 38.2,
            symptoms: [IllnessSymptom(key: "cough", severity: 2), IllnessSymptom(key: "made_up")],
            note: "Abends schlechter",
            updatedAt: "2026-11-04T20:00:00Z"
        )
        let content = IllnessDayLogRowContent(log: log)
        #expect(content.title == IllnessDateFormat.mediumDate("2026-11-04"))
        #expect(content.impact == IllnessPresentation.impactLabel(for: 2))
        let cough = IllnessDayLogRowContent.symptomLabel(IllnessSymptom(key: "cough", severity: 2))
        #expect(content.detail == "\(cough), Made Up, Abends schlechter")
    }

    @Test func emptyDayLogHasNoDetailLineAndNoStatus() {
        let log = IllnessDayLogDTO(
            id: "d2",
            episodeId: "ep-1",
            date: "2026-11-05",
            functionalImpact: nil,
            feverC: nil,
            symptoms: [],
            note: "",
            updatedAt: "2026-11-05T20:00:00Z"
        )
        let content = IllnessDayLogRowContent(log: log)
        #expect(content.detail == nil)
        #expect(content.impact == nil)
    }

    // MARK: - Insights summary

    @Test @MainActor func summaryCellsShowGapOnlyWhenTheServerSharesOne() {
        let withGap = IllnessInsightsDTO(
            windowDays: 365, episodeCount: 4, resolvedCount: 3, typicalRecoveryGapDays: 5.5,
            gapSampleSize: 3, byMonth: [:], byType: [:], gapDriverType: nil
        )
        let cells = IllnessInsightsScreen.summaryCells(withGap)
        #expect(cells.map(\.label) == [
            String(localized: "illness.insights.stat.episodes"),
            String(localized: "illness.status.resolved"),
            String(localized: "illness.correlation.recoveryGap.title")
        ])
        #expect(cells.first?.value == HLValueFormat.number(4, fractionDigits: 0 ... 0))
        #expect(cells.last?.value == HLValueFormat.number(5.5, fractionDigits: 0 ... 1))
        #expect(cells.last?.unit == String(localized: "illness.insights.stat.days"))

        let withoutGap = IllnessInsightsDTO(
            windowDays: 365, episodeCount: 1, resolvedCount: 0, typicalRecoveryGapDays: nil,
            gapSampleSize: 0, byMonth: [:], byType: [:], gapDriverType: nil
        )
        #expect(IllnessInsightsScreen.summaryCells(withoutGap).count == 2)
    }

    // MARK: - Symptom page

    @Test @MainActor func symptomPageConfirmsWithTheSheetCheckMark() {
        let complete = SymptomEventSheet.confirmAction(isEnabled: true) { true }
        #expect(complete.kind == .save)
        #expect(complete.isEnabled)
        #expect(complete.confirmLabel != nil)
        #expect(!SymptomEventSheet.confirmAction(isEnabled: false) { true }.isEnabled)
        #expect(SymptomEventSheet.saveIdentifier == "symptoms.edit.save")
    }
}
