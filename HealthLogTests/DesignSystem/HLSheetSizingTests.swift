@testable import HealthLog
import SwiftUI
import Testing

/// A sheet follows the size class of the window that presents it: a bottom
/// sheet with detents in a compact window, a form sheet in a regular one,
/// nothing for a full screen cover.
@Suite("Sheet sizing by size class")
struct HLSheetSizingTests {
    static let sheetSizes: [HLSheetSize] = [.standard, .compact, .form, .fitted(height: 280)]

    @Test("compact keeps today's detents and grabber", arguments: sheetSizes)
    func compact(size: HLSheetSize) {
        let sizing = HLSheetSizing.resolve(size, sizeClass: .compact)
        #expect(sizing == .detents(size.detents))
        #expect(sizing.showsDragIndicator)
    }

    @Test("a window without a size class is treated as compact", arguments: sheetSizes)
    func unknownIsCompact(size: HLSheetSize) {
        #expect(HLSheetSizing.resolve(size, sizeClass: nil) == .detents(size.detents))
    }

    @Test("regular: a form at the form size, everything shorter fitted to its height")
    func regular() {
        #expect(HLSheetSizing.resolve(.form, sizeClass: .regular) == .form)
        #expect(HLSheetSizing.resolve(.standard, sizeClass: .regular) == .formFitted)
        #expect(HLSheetSizing.resolve(.compact, sizeClass: .regular) == .formFitted)
        // A sheet that measured itself keeps that height, bar included,
        // so its last row is not cut off under the form sheet's bar.
        #expect(HLSheetSizing.resolve(.fitted(height: 280), sizeClass: .regular) == .formHeight(280))
        for size in Self.sheetSizes {
            #expect(!HLSheetSizing.resolve(size, sizeClass: .regular).showsDragIndicator)
        }
    }

    @Test("a full screen cover gets no sizing in any size class")
    func cover() {
        #expect(HLSheetSizing.resolve(.cover, sizeClass: .compact) == HLSheetSizing.unset)
        #expect(HLSheetSizing.resolve(.cover, sizeClass: .regular) == HLSheetSizing.unset)
        #expect(HLSheetSizing.resolve(.cover, sizeClass: nil) == HLSheetSizing.unset)
        #expect(!HLSheetSizing.unset.showsDragIndicator)
    }

    @Test("the phone's detents are unchanged")
    func detentsUnchanged() {
        #expect(HLSheetSize.standard.detents == [.medium, .large])
        #expect(HLSheetSize.compact.detents == [.medium])
        #expect(HLSheetSize.form.detents == [.large])
        #expect(HLSheetSize.fitted(height: 280).detents == [.height(280)])
        #expect(HLSheet.detents == [.large])
    }

    @Test("a measured form is full height on the phone and as tall as its content in a form sheet")
    func measuredForm() {
        #expect(HLSheetSize.formMeasured(height: 540).detents == HLSheetSize.form.detents)
        #expect(HLSheetSizing.resolve(.formMeasured(height: 540), sizeClass: .compact) == .detents([.large]))
        #expect(HLSheetSizing.resolve(.formMeasured(height: 540), sizeClass: .regular) == .formHeight(540))
        // Before the first measure it stands at the form size.
        #expect(HLSheetSizing.resolve(.formMeasured(height: nil), sizeClass: .regular) == .form)
    }

    @Test("a form sheet holds the rows, the bar and the page insets")
    func formHeightFromScrollGeometry() {
        // The bar counted in the top inset: the insets win.
        #expect(HLSheet.formHeight(contentHeight: 400, topInset: 76) == 400 + 76 + HLLayout.pageBottom)
        // No bar in the inset: the bar allowance stands in for it.
        let floor = 400 + HLLayout.pageTop + HLSheet.barAllowance + HLLayout.pageBottom
        #expect(HLSheet.formHeight(contentHeight: 400, topInset: 12) == floor)
    }

    @Test("a measured form sheet stands at its own height, not at a large detent")
    func measuredFormSheetDetent() {
        let measured = HLSheetSizing.resolve(.formMeasured(height: 480), sizeClass: .regular)
        #expect(measured.detents(for: .formMeasured(height: 480)) == [.height(480)])
        // A bottom sheet keeps its detents; an unmeasured form sheet too.
        #expect(HLSheetSizing.resolve(.standard, sizeClass: .compact, grows: true).detents(for: .standard) == [.medium, .large])
        #expect(HLSheetSizing.resolve(.form, sizeClass: .regular).detents(for: .form) == [.large])
    }

    @Test("the keyboard comes up on open in a bottom sheet only")
    func focusOnOpen() {
        #expect(HLSheet.focusesOnOpen(presentingSizeClass: .compact))
        #expect(HLSheet.focusesOnOpen(presentingSizeClass: nil))
        #expect(!HLSheet.focusesOnOpen(presentingSizeClass: .regular))
    }
}
