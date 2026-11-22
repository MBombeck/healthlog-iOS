import Foundation
@testable import HealthLog
import Testing

/// **G3–G6 — the mental-wellbeing screen joins the family.**
///
/// Four operator statements landed on one screen: 247 characters of header prose
/// under a title that renders twice, „Starten" as a near-white
/// `.primary` plate where the medication twin is a quiet 44 pt tile action
/// (G4/G6), and an „i" that opens a popover of English licence prose too small
/// to read.
///
/// **The first case is the reason the order of this file matters.** G5 removes
/// the popover, and the popover carried the WHO-5 / SCI attribution. That
/// attribution is a **licence obligation** — WHO-5 is CC BY-NC-SA 3.0 IGO, SCI
/// is CC BY-NC — not decoration, and it is one of the few things on this screen
/// that may not be shortened, moved to a switch, or deleted for tidiness. It
/// already lives in the detail sheet, which is why the popover *can* go; the pin
/// below is what makes sure it goes on living there.
@Suite("G3–G6 — Seelisches Wohlbefinden, in einer Sprache mit dem Rest")
struct MentalWellbeingConsistencyTests {
    private static let screen = "HealthLog/Screens/MentalHealth/MentalWellbeingScreen.swift"

    // MARK: - 1. The licence obligation (GREEN now, GREEN forever)

    @Test("Die WHO-5-/SCI-Zuschreibung steht im Detail-Sheet — und bleibt dort")
    func attributionSurvivesInTheDetailSheet() throws {
        let source = try Phase8SourceScan.stripped(Self.screen)

        var violations: [String] = []
        if !source.contains("instrument.attribution") {
            violations.append("the detail sheet no longer renders instrument.attribution")
        }
        // The values themselves, so a refactor that keeps the call site but
        // empties the text is caught too.
        if !MentalHealthAttribution.who5.contains("CC BY-NC-SA") {
            violations.append("the WHO-5 attribution lost its licence clause")
        }
        if !MentalHealthAttribution.who5.contains("World Health Organization") {
            violations.append("the WHO-5 attribution lost its attribution")
        }
        if !MentalHealthAttribution.sci.contains("CC BY-NC") {
            violations.append("the SCI attribution lost its licence clause")
        }

        #expect(
            violations.isEmpty,
            """
            License obligation (CC BY-NC-SA): the WHO-5 attribution must survive any UI cleanup. \
            G5 removed the popover copy; this sheet is now the only carrier.

            WHO-5 is licensed CC BY-NC-SA 3.0 IGO and SCI CC BY-NC. The attribution is a \
            CONDITION of using the instruments, not a courtesy — an app that ships the \
            questionnaires without it is not tidy, it is unlicensed. It survived G5 precisely \
            because it already existed here; nothing may quietly finish the job the popover \
            removal started. Offen: \(violations)
            """
        )
    }
}
