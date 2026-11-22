import Foundation
@testable import HealthLog
import Testing

/// The symptom editor is a pushed page. Leaving it with input asks first,
/// leaving it untouched goes at once, and while it saves it does not go.
@Suite("Symptom editor asks before input is lost")
struct N2DiarySymptomEditorGuardTests {
    private let start = SymptomEventSheet.Draft(
        definitionId: nil,
        intensity: nil,
        occurredAt: Date(timeIntervalSince1970: 1_800_000_000),
        episodeId: "episode-1",
        note: ""
    )

    @Test func untouchedPageLeavesOnBack() {
        #expect(SymptomEventSheet.backStep(initial: start, current: start, isWorking: false) == .leaves)
        #expect(!SymptomEventSheet.holdsBack(initial: start, current: start, isWorking: false))
    }

    @Test func chosenIntensityAsksOnBack() {
        var edited = start
        edited.intensity = 6
        #expect(SymptomEventSheet.backStep(initial: start, current: edited, isWorking: false) == .asksFirst)
        #expect(SymptomEventSheet.holdsBack(initial: start, current: edited, isWorking: false))
    }

    @Test func typedNoteAsksOnBack() {
        var edited = start
        edited.note = "Kopfschmerz am Abend"
        #expect(SymptomEventSheet.backStep(initial: start, current: edited, isWorking: false) == .asksFirst)
    }

    @Test func movedTimeOrEpisodeAsksOnBack() {
        var moved = start
        moved.occurredAt = start.occurredAt.addingTimeInterval(-3600)
        #expect(SymptomEventSheet.backStep(initial: start, current: moved, isWorking: false) == .asksFirst)
        var unlinked = start
        unlinked.episodeId = nil
        #expect(SymptomEventSheet.backStep(initial: start, current: unlinked, isWorking: false) == .asksFirst)
    }

    @Test func savingPageStays() {
        var edited = start
        edited.intensity = 3
        #expect(SymptomEventSheet.backStep(initial: start, current: edited, isWorking: true) == .locked)
        #expect(SymptomEventSheet.backStep(initial: start, current: start, isWorking: true) == .locked)
        #expect(SymptomEventSheet.holdsBack(initial: start, current: start, isWorking: true))
    }

    @Test func revertedInputLeavesAgain() {
        var edited = start
        edited.intensity = 4
        edited.intensity = nil
        #expect(SymptomEventSheet.backStep(initial: start, current: edited, isWorking: false) == .leaves)
    }
}
