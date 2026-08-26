import Foundation
@testable import HealthLog
import Testing

/// **G3–G6 — the mental-wellbeing screen joins the family.**
///
/// Four operator statements landed on one screen: 247 characters of header prose
/// (G3) under a title that renders twice (G3), „Starten" as a near-white
/// `.primary` plate where the medication twin is a quiet 44 pt tile action
/// (G4/G6), and an „i" that opens a popover of English licence prose too small
/// to read (G5).
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

    /// The copy budget for the page description, stated here rather than in a
    /// review comment so it is enforceable. 247 characters of German prose under
    /// a title is a paragraph; a page description is one sentence.
    static let pageDescriptionBudget = 120

    private static func localized(_ key: String, _ language: String) -> String {
        String(
            localized: LocalizedStringResource(
                String.LocalizationValue(key),
                locale: Locale(identifier: language)
            )
        )
    }

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

    // MARK: - 2. G5 — the popover goes, without replacement

    @Test("Das i-Popover ist ersatzlos entfallen (E5)")
    func infoPopoverIsGone() throws {
        let source = try Phase8SourceScan.stripped(Self.screen)

        var violations: [String] = []
        if source.contains("info.circle") {
            violations.append("the info.circle trigger still renders")
        }
        if source.contains(".popover(") {
            violations.append("the popover presentation is still mounted")
        }
        if source.contains("attributionPopover") {
            violations.append("the popover body still exists")
        }

        #expect(
            violations.isEmpty,
            """
            EXPECTED_RED: the i popover still renders its unreadable license prose

            G5, decision E5 (answered 2026-08-22): „das ,i' entfällt ersatzlos" — no \
            replacement affordance, because the content it carried is a licence attribution \
            that already has a home in the detail sheet and does not belong on a card. Offen: \
            \(violations)
            """
        )
    }

    // MARK: - 3. G3 — the header prose

    @Test("Die Seitenbeschreibung passt in ihr Budget, in beiden Sprachen")
    func pageDescriptionIsShort() {
        var violations: [String] = []
        for language in ["de", "en"] {
            let value = Self.localized("mentalHealth.pageDescription", language)
            if value.count > Self.pageDescriptionBudget {
                violations.append("\(language): \(value.count) chars (budget \(Self.pageDescriptionBudget))")
            }
        }

        #expect(
            violations.isEmpty,
            """
            EXPECTED_RED: 247 characters of header prose

            G3. A page description is one sentence that says what the screen is for. The four \
            instrument names, their parenthesised domains and the trend caveat are all \
            legitimate content — they are just not header content; the instrument cards name \
            themselves and the detail sheet carries the rest. Offen: \(violations)
            """
        )
    }

    @Test("Der Titel erscheint genau einmal")
    func titleRendersOnce() throws {
        let source = try Phase8SourceScan.stripped(Self.screen)

        // The screen sets a navigation title AND used to repeat the same words as
        // a header line directly under it.
        let hasNavigationTitle = source.contains("navigationTitle(Text(\"more.mentalWellbeing.title\"))")
        let hasHeaderTitle = source.contains("Text(\"mentalHealth.pageTitle\")")

        var violations: [String] = []
        if !hasNavigationTitle {
            violations.append("the navigation title is gone — that is not the duplicate to remove")
        }
        if hasHeaderTitle {
            violations.append("the header repeats the navigation title as body copy")
        }

        #expect(
            violations.isEmpty,
            """
            EXPECTED_RED: the title appears twice

            G3. `more.mentalWellbeing.title` and `mentalHealth.pageTitle` are the same words \
            („Seelisches Wohlbefinden"), rendered one under the other — the navigation title \
            and then a `.hlTitle2` line repeating it. The navigation title is the one that \
            stays: it survives scrolling and it is what every other screen in the app titles \
            itself with. Offen: \(violations)
            """
        )
    }

    // MARK: - 4. G4/G6 — the Starten shape

    @Test("Starten trägt die Kachel-Form, nicht die fast weiße Primary-Platte")
    func startButtonsWearTheMedicationShape() throws {
        let source = try Phase8SourceScan.stripped(Self.screen)

        var violations: [String] = []
        if !source.contains("HLTileActionButton(\"mentalHealth.start\"") {
            violations.append("the instrument card's Starten is not a tile action")
        }
        // The detail sheet's own Starten is a full-screen flow CTA and stays
        // `.primary` under R9 — exactly one `.primary` may remain on this screen.
        let primaryCount = source.components(separatedBy: "variant: .primary").count - 1
        if primaryCount != 1 {
            violations.append("expected exactly one .primary on this screen (the sheet's commit), found \(primaryCount)")
        }

        #expect(
            violations.isEmpty,
            """
            EXPECTED_RED: Starten is still a near-white primary plate

            G4/G6. `HLButton(.primary)` paints `AnyShapeStyle(.tint)`, and the scene tint is \
            the monochrome ink `HLText.primary` — so on the instrument cards it reads as the \
            near-white slab the `.restrained` doc comment was written to describe. The \
            medication twin is 44 pt/`.hlSubhead`/hairline, and since R9/E2-A1 that shape has \
            a name and a carrier. The sheet's own Starten keeps `.primary`: it is the \
            screen's one commit action, which is what R9 reserves the variant for. Offen: \
            \(violations)
            """
        )
    }
}
