@testable import HealthLog
import SwiftUI
import Testing

/// The quick-intake sheet stands at a fixed height in a regular window, where
/// a form sheet fitted to its scrolling page found no height; compact keeps
/// the bottom sheet's detents.
@Suite("Quick intake sheet presentation")
struct QuickIntakeSheetPresentationTests {
    @Test("The form height applies in a regular window only")
    func formHeightOnlyWhenRegular() {
        #expect(QuickIntakeSheetPresentation.formHeight(sizeClass: .regular) == QuickIntakeSheetPresentation.regularFormHeight)
        #expect(QuickIntakeSheetPresentation.formHeight(sizeClass: .compact) == nil)
        #expect(QuickIntakeSheetPresentation.formHeight(sizeClass: nil) == nil)
    }

    @Test("Compact keeps the sizes it had")
    func compactSizesUnchanged() {
        let empty = MedicationQuickIntakeOptions(due: [], asNeeded: [], later: [])
        #expect(MedicationQuickIntakeSheet.size(for: empty, showsFreeIntake: false, formHeight: nil) == .compact)
        #expect(MedicationQuickIntakeSheet.size(for: empty, showsFreeIntake: true, formHeight: nil) == .standard)
    }

    @Test("Regular fits the measured chooser under the host's height; a pushed page stands at that height")
    func regularSizes() {
        let empty = MedicationQuickIntakeOptions(due: [], asNeeded: [], later: [])
        #expect(MedicationQuickIntakeSheet.size(for: empty, showsFreeIntake: false, formHeight: 520) == .fitted(height: 520))
        let measured = MedicationQuickIntakeSheet.size(for: empty, showsFreeIntake: false, formHeight: 520, chooserHeight: 300)
        #expect(measured == .fitted(height: 300 + HLSheet.barAllowance))
        let tall = MedicationQuickIntakeSheet.size(for: empty, showsFreeIntake: false, formHeight: 520, chooserHeight: 900)
        #expect(tall == .fitted(height: 520))
        #expect(MedicationQuickIntakeSheet
            .size(for: empty, showsFreeIntake: true, formHeight: 520, chooserHeight: 300) == .fitted(height: 520))
        #expect(HLSheetSizing.resolve(.fitted(height: 520), sizeClass: .regular) == .formHeight(520))
    }
}
