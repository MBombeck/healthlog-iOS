import Foundation
@testable import HealthLog
import SwiftUI
import Testing

/// **v0.8.5 WFIX-COMPLIANCE (2026-05-30).** Two operator on-device findings
/// on the per-medication Verlauf track drove this suite:
///
///  - **fix 2 — status recolor.** The per-day circles still rendered on the
///    monochrome `HLText` ramp ("die Kreise sind immer noch monochrom").
///    They now fill with the app's green/yellow/red status tokens, matching
///    the recoloured heatmap squares. `statusColor(for:)` locks that map.
///  - **fix 3 — 7-day collapse.** The 90-day track dominated the screen on
///    open. It now defaults to the trailing 7 days with a "Mehr"/"More"
///    toggle to the full window. `visibleGlyphs(_:isExpanded:)` +
///    `canExpand(_:)` lock the slice + toggle-visibility contract.
///
/// Both seams are pure `nonisolated static` so they assert without a SwiftUI
/// render harness, mirroring the `ComplianceHeatmapSection.hasEnoughHistory`
/// + `ComplianceStatusPalette.status` test pattern in the sibling suite.
@Suite("VerlaufGlyphTrack — WFIX status-recolor + 7-day collapse")
struct VerlaufGlyphTrackTests {
    // MARK: - fix 2: green/yellow/red status colour

    @Test("on-time glyph fills green (statusOK)")
    func onTimeIsGreen() {
        #expect(VerlaufGlyphTrack.statusColor(for: .onTime) == HLColor.statusOK)
    }

    @Test("late glyph fills yellow (statusWarn)")
    func lateIsYellow() {
        #expect(VerlaufGlyphTrack.statusColor(for: .late) == HLColor.statusWarn)
    }

    @Test("missed glyph fills red (statusBad)")
    func missedIsRed() {
        #expect(VerlaufGlyphTrack.statusColor(for: .missed) == HLColor.statusBad)
    }

    @Test("no-schedule off-day stays muted neutral, not a false-green statusOK")
    func noScheduleIsNeutral() {
        let color = VerlaufGlyphTrack.statusColor(for: .noSchedule)
        #expect(color != HLColor.statusOK)
        #expect(color != HLColor.statusWarn)
        #expect(color != HLColor.statusBad)
    }

    @Test("each actioned status maps to a distinct hue (no two share a token)")
    func statusesAreDistinct() {
        let green = VerlaufGlyphTrack.statusColor(for: .onTime)
        let yellow = VerlaufGlyphTrack.statusColor(for: .late)
        let red = VerlaufGlyphTrack.statusColor(for: .missed)
        #expect(green != yellow)
        #expect(yellow != red)
        #expect(green != red)
    }

    // MARK: - fix 3: 7-day collapse + "Mehr" toggle

    @Test("collapsed window default is 7 days")
    func collapsedWindowIsSeven() {
        #expect(VerlaufGlyphTrack.collapsedDays == 7)
    }

    @Test("collapsed 90-day track shows only the trailing 7 days, oldest-first preserved")
    func collapsedShowsTrailingSeven() {
        // 90 glyphs oldest-first: index 0 = oldest, 89 = today. Mark the
        // last 7 with a recognisable pattern so we can assert the suffix.
        var glyphs = Array(repeating: MedicationDetailStore.VerlaufGlyph.missed, count: 83)
        let tail: [MedicationDetailStore.VerlaufGlyph] =
            [.onTime, .late, .missed, .onTime, .late, .missed, .onTime]
        glyphs.append(contentsOf: tail)

        let shown = VerlaufGlyphTrack.visibleGlyphs(glyphs, isExpanded: false)
        #expect(shown.count == 7)
        #expect(shown == tail)
    }

    @Test("expanded track shows the full hydrated window")
    func expandedShowsFullWindow() {
        let glyphs = Array(repeating: MedicationDetailStore.VerlaufGlyph.onTime, count: 90)
        let shown = VerlaufGlyphTrack.visibleGlyphs(glyphs, isExpanded: true)
        #expect(shown.count == 90)
    }

    @Test("a window of ≤ 7 days renders whole even when collapsed (no empty slice)")
    func shortWindowRendersWhole() {
        let glyphs = Array(repeating: MedicationDetailStore.VerlaufGlyph.onTime, count: 5)
        let shown = VerlaufGlyphTrack.visibleGlyphs(glyphs, isExpanded: false)
        #expect(shown.count == 5)
    }

    @Test("exactly 7 days does not offer a 'Mehr' toggle (nothing behind the collapse)")
    func exactlySevenHasNoToggle() {
        let glyphs = Array(repeating: MedicationDetailStore.VerlaufGlyph.onTime, count: 7)
        #expect(VerlaufGlyphTrack.canExpand(glyphs) == false)
    }

    @Test("8+ days offers the 'Mehr' toggle")
    func eightDaysOffersToggle() {
        let glyphs = Array(repeating: MedicationDetailStore.VerlaufGlyph.onTime, count: 8)
        #expect(VerlaufGlyphTrack.canExpand(glyphs) == true)
        let ninety = Array(repeating: MedicationDetailStore.VerlaufGlyph.onTime, count: 90)
        #expect(VerlaufGlyphTrack.canExpand(ninety) == true)
    }
}
