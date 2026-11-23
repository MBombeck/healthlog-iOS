@testable import HealthLog
import SwiftUI
import Testing

/// The mood check-in grows from half height to full once an entry is made,
/// on the phone. In a regular window (iPad, the open Duo) it is a form sheet
/// at the system's form size from the start, centred: nothing grows.
@Suite("Mood sheet sizing")
struct MoodSheetSizingTests {
    @Test("compact: the mood sheet keeps its two detents and the grabber")
    func compactKeepsDetents() {
        let sizing = HLSheetSizing.resolve(.standard, sizeClass: .compact, grows: true)
        #expect(sizing == .detents([.medium, .large]))
        #expect(sizing.showsDragIndicator)
        #expect(HLSheetSizing.resolve(.standard, sizeClass: nil, grows: true) == .detents([.medium, .large]))
    }

    @Test("regular: the growing sheet is a centred form sheet at the system's form size, one detent")
    func regularIsFinalForm() {
        let sizing = HLSheetSizing.resolve(.standard, sizeClass: .regular, grows: true)
        #expect(sizing == .formSystem)
        #expect(!sizing.showsDragIndicator)
        // A half detent set the form sheet low in the window.
        #expect(sizing.detents(for: .standard) == [.large])
        #expect(sizing.formDetent == .large)
    }

    @Test("the close button shows exactly where the sheet cannot be dragged away")
    func closeWhereNotDraggable() {
        // `hlBarlessSheetClose` shows the bar with the close button when the
        // presentation has no grabber.
        #expect(HLSheetSizing.resolve(.standard, sizeClass: .compact, grows: true).showsDragIndicator)
        #expect(!HLSheetSizing.resolve(.standard, sizeClass: .regular, grows: true).showsDragIndicator)
        #expect(EnvironmentValues().hlSheetIsDraggable)
    }

    @Test("a sheet that does not grow keeps its fitted form sheet")
    func otherSheetsUnchanged() {
        #expect(HLSheetSizing.resolve(.standard, sizeClass: .regular) == .formFitted)
        #expect(HLSheetSizing.resolve(.form, sizeClass: .regular) == .form)
        #expect(HLSheetSizing.resolve(.cover, sizeClass: .regular, grows: true) == .unset)
    }
}
