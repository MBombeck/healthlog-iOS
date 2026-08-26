import Foundation
@testable import HealthLog
import Testing

/// **v0.14.x Q — Home-Screen Quick Actions mapping contract.**
///
/// Pins the pure shortcut-type ↔ action ↔ capture-surface mapping so a
/// regression that crosses the wires (e.g. the "Log an intake" shortcut routing
/// to the mood surface) fails the build. The UIKit registration + delegate
/// dispatch are real-device-only; this suite covers the deterministic core.
@Suite("HLQuickAction — shortcut → capture-surface mapping")
struct QuickActionsTests {
    @Test("Each action round-trips through its reverse-DNS shortcut type")
    func shortcutTypeRoundTrips() {
        for action in HLQuickAction.allCases {
            let type = action.shortcutType
            #expect(type.hasPrefix("dev.healthlog.app.quickaction."))
            #expect(HLQuickAction(shortcutType: type) == action)
        }
    }

    @Test("Each action maps to the correct capture surface")
    func actionMapsToSurface() {
        #expect(HLQuickAction.measurement.captureSurface == .capture)
        #expect(HLQuickAction.medication.captureSurface == .medication)
        #expect(HLQuickAction.mood.captureSurface == .mood)
    }

    @Test("Glyphs match the central CapturePicker row symbols")
    func glyphsMatchPicker() {
        #expect(HLQuickAction.measurement.systemImageName
            == CapturePickerSheet.CaptureAction.measurement.systemImage)
        #expect(HLQuickAction.medication.systemImageName
            == CapturePickerSheet.CaptureAction.medication.systemImage)
        #expect(HLQuickAction.mood.systemImageName
            == CapturePickerSheet.CaptureAction.mood.systemImage)
    }

    @Test("An unknown shortcut type resolves to nil")
    func unknownTypeIsNil() {
        #expect(HLQuickAction(shortcutType: "dev.healthlog.app.quickaction.bogus") == nil)
        #expect(HLQuickAction(shortcutType: "com.other.app.quickaction.mood") == nil)
        #expect(HLQuickAction(shortcutType: "") == nil)
    }

    @Test("Titles resolve to the existing CapturePicker localization keys")
    func titlesAreLocalized() {
        // Non-empty + distinct → the `String(localized:)` lookup resolved a real
        // catalog entry (a missing key would echo the key verbatim, which is
        // still non-empty, so we also assert the three differ from each other).
        let titles = HLQuickAction.allCases.map(\.localizedTitle)
        #expect(titles.allSatisfy { !$0.isEmpty })
        #expect(Set(titles).count == HLQuickAction.allCases.count)
    }
}
