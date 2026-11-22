@testable import HealthLog
import Testing

/// The target band sheet keeps its saves in the form, so its bar only
/// closes. Closing asks first while something could still be lost.
@Suite("Insights target band sheet — closing asks while a band is unsaved or saving")
struct InsightsTargetBandEditorCloseTests {
    @Test("a typed, unsaved band asks before closing")
    func unsavedDraftAsks() {
        #expect(InsightsTargetBandEditorSheet.closeAsksFirst(hasUnsavedDraft: true, isSaving: false))
    }

    @Test("a running save asks before closing, even when the drafts already match")
    func runningSaveAsks() {
        #expect(InsightsTargetBandEditorSheet.closeAsksFirst(hasUnsavedDraft: false, isSaving: true))
    }

    @Test("nothing unsaved and nothing running closes at once")
    func idleCloses() {
        #expect(!InsightsTargetBandEditorSheet.closeAsksFirst(hasUnsavedDraft: false, isSaving: false))
    }
}
