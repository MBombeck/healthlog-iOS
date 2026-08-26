import Foundation
@testable import HealthLog
import Testing

/// **v0.15.2 W-BUTTONS, neu gefasst am 2026-08-23 (Phase 17-01).**
///
/// Diese Suite pinnte ursprünglich die drei tragenden Werte der Variante
/// `HLButton(.restrained)`, die nach dem b198-Walkthrough entstand: der
/// Betreiber hatte die voll gefüllten `.tint`-CTAs („Jetzt messen",
/// „Export erstellen", Settings-Saves) als „too prominent / creepy"
/// abgelehnt und wollte das ruhige Paar der Medikamenten-Kachel
/// („Genommen"/„Übersprungen", `ActiveMedicationRow.monochromeActionButton`).
///
/// **Was sich am 2026-08-23 geändert hat — und was ausdrücklich nicht.**
///
/// `.restrained` ist unter R9 **verworfene Vokabel**: keine neue Fundstelle
/// darf entstehen, der Restbestand wird von `hl_button_legacy_variant` in
/// `UIStandardBaselineTests` nach unten gezählt. Der Research-Digest hielt
/// fest, diese Suite pinne „eine Variante, die keine Fläche mehr nutzt" —
/// das stimmt nicht: die Variante hat weiterhin Fundstellen (sie stehen
/// samt Zahl in der Ratschen-Baseline). Wahr ist das Gegenteil und darum
/// steht es jetzt hier: sie ist **zurückgezogen, nicht verschwunden**, und
/// genau so wird sie gepinnt.
///
/// Ihre drei Werte bleiben trotzdem tragend — aber in neuer Rolle. Das
/// Amendment **R9/E2-A1** (2026-08-23) schreibt die vierte Rolle
/// „Kachel-Aktion" fest: 44 pt Höhenklasse, `.hlSubhead`, monochrome
/// `HLText.secondary`-Tinte, keine Füllung. Das sind exakt die Werte, die
/// `HLButton.restrainedContract` seit W-BUTTONS trägt. Träger der neuen
/// Rolle ist aber **nicht** diese Variante, sondern das geteilte Primitive
/// `HLTileActionButton` (17-02) — die Variante bleibt die historische
/// Quelle der Zahlen, nicht ihr Vehikel.
///
/// Deshalb prüft diese Suite ab jetzt **zwei** Dinge:
///
/// 1. die Werte selbst (die alte W-BUTTONS-Regression bleibt gesperrt), und
/// 2. dass der **Standard-Text** dieselben Zahlen schreibt, die das
///    Designsystem rendert.
///
/// Punkt 2 ist die eigentliche Neuerung und der Grund, warum 17-01 vor allen
/// Flächen-Plänen läuft: `d06174e6` (2026-07-31) konnte die zweimal
/// gelieferte Parität still zerstören, weil Standard-Text und Fläche
/// auseinanderliefen und **niemand das messen konnte**. Ab jetzt ist genau
/// dieses Auseinanderlaufen rot — in beide Richtungen.
@Suite("HLButton .restrained — zurückgezogene Variante, gepinnte Kachel-Token (R9/E2-A1)")
struct HLButtonRestrainedContractTests {
    @Test("Restrained paints no fill, a monochrome label, and a 44pt floor")
    func restrainedContractIsCalm() {
        let contract = HLButton.restrainedContract
        #expect(contract.hasFill == false, "restrained must NOT paint a .tint fill slab")
        #expect(contract.monochromeLabel, "restrained label must stay monochrome, never the accent pick")
        #expect(contract.minHeight == 44, "restrained must hold the compact 44pt HIG floor")
    }

    // MARK: - Standard-Text ⇔ Designsystem

    /// `<repo>/HealthLogTests/DesignSystem/HLButtonRestrainedContractTests.swift`
    /// → `<repo>`. `resolvingSymlinksInPath()` aus demselben Grund wie in
    /// `UIStandardBaselineTests.repoRoot()`: `#filePath` und
    /// `FileManager`-URLs müssen auf derselben Seite von `/tmp` stehen.
    private nonisolated static func repoRoot(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent() // DesignSystem
            .deletingLastPathComponent() // HealthLogTests
            .deletingLastPathComponent() // <repo>
            .resolvingSymlinksInPath()
    }

    /// Der Abschnitt des Amendments R9/E2-A1 — von seiner Überschrift bis zur
    /// nächsten Regel-Überschrift.
    private nonisolated static func amendmentSection() throws -> String {
        let url = repoRoot()
            .appendingPathComponent(".planning")
            .appendingPathComponent("ux")
            .appendingPathComponent("STANDARD-ui.md")
        let text = try String(contentsOf: url, encoding: .utf8)
        let marker = "Amendment A1 — 2026-08-23 (v1-readiness, Walkthrough G2/G4/G6)"
        guard let start = text.range(of: marker) else {
            throw AmendmentMissing.header(marker)
        }
        let rest = text[start.upperBound...]
        if let next = rest.range(of: "\n### ") {
            return String(rest[..<next.lowerBound])
        }
        return String(rest)
    }

    enum AmendmentMissing: Error, CustomStringConvertible {
        case header(String)

        var description: String {
            switch self {
            case let .header(marker):
                """
                .planning/ux/STANDARD-ui.md enthält den Amendment-Block „\(marker)" nicht mehr.

                Dieses Amendment ist die geschriebene Form der Kachel-Aktion (R9/E2-A1). Ohne \
                sie ist die Vorsorge-/Medikamenten-Parität wieder das, was sie vor Phase 17 war: \
                eine Fläche ohne Regel — und der nächste Standard-Durchlauf dreht sie zurück, \
                genau wie d06174e6 am 2026-07-31.

                Wer das Amendment umbenennt oder verschiebt, zieht diesen Test mit.
                """
            }
        }
    }

    @Test("Der Amendment-Text R9/E2-A1 schreibt exakt die Zahlen, die das Designsystem rendert")
    func standardAmendmentMatchesTheDesignSystem() throws {
        let section = try Self.amendmentSection()
        let contract = HLButton.restrainedContract

        let drift = """
        Der Amendment-Text R9/E2-A1 in .planning/ux/STANDARD-ui.md und die Werte des \
        Designsystems (HLButton.restrainedContract) sagen nicht mehr dasselbe.

        Das ist der Zustand, aus dem d06174e6 (2026-07-31) entstanden ist: der Standard sagte \
        eine Sache, die Fläche eine andere, und der nächste Standard-Durchlauf gab dem Standard \
        recht — korrekt, und trotzdem war die zweimal gelieferte Parität (b210 4c11938b, \
        b215 b84adbe0) weg.

        Wenn die Kachel-Token sich legitim ändern sollen, ändern sich STANDARD-ui.md R9/E2-A1, \
        das Primitive HLTileActionButton und BEIDE Flächen in EINER Änderung — nie eine Seite \
        allein.
        """

        // Höhenklasse: die erste fett gesetzte Punkt-Zahl der Token-Tabelle.
        let heights = section.matches(of: /\*\*(\d+) pt\*\*/)
        #expect(!heights.isEmpty, "\(drift)\n\nFehlt: die fett gesetzte Höhenklasse (**44 pt**).")
        if let written = heights.first.flatMap({ Double($0.output.1) }) {
            #expect(
                CGFloat(written) == contract.minHeight,
                "\(drift)\n\nHöhenklasse: Standard schreibt \(written) pt, Designsystem rendert \(contract.minHeight) pt."
            )
        }

        // Schrift-Token.
        #expect(
            section.contains("`.hlSubhead`"),
            "\(drift)\n\nFehlt: das Schrift-Token `.hlSubhead` — die Kachel-Aktion darf nie über der Kartenüberschrift liegen."
        )

        // Tinte: monochrom, HLText.secondary.
        let saysMonochrome = section.contains("`HLText.secondary`") && section.contains("monochrom")
        #expect(
            saysMonochrome == contract.monochromeLabel,
            "\(drift)\n\nTinte: Standard schreibt monochrom=\(saysMonochrome), Designsystem rendert monochromeLabel=\(contract.monochromeLabel)."
        )

        // Fläche: keine Füllung.
        let saysNoFill = section.contains("keine Füllung")
        #expect(
            saysNoFill == !contract.hasFill,
            "\(drift)\n\nFläche: Standard schreibt keine-Füllung=\(saysNoFill), Designsystem rendert hasFill=\(contract.hasFill)."
        )
    }

    @Test("Der Amendment-Text benennt den Träger, die Referenz-Instanz und den Vorfall")
    func standardAmendmentKeepsItsHistory() throws {
        let section = try Self.amendmentSection()

        for needle in ["HLTileActionButton", "ActiveMedicationRow", "4c11938b", "b84adbe0", "d06174e6"] {
            #expect(
                section.contains(needle),
                """
                Der Amendment-Block R9/E2-A1 nennt „\(needle)" nicht mehr.

                Der Block trägt absichtlich seine Vorgeschichte: den Träger (HLTileActionButton), \
                die Referenz-Instanz (ActiveMedicationRow) und die drei Commits, die erklären, \
                warum es ihn gibt — zwei Lieferungen (4c11938b b210, b84adbe0 b215) und die \
                Regression (d06174e6). Eine Umformulierung, die die Geschichte fallen lässt, \
                nimmt dem nächsten Standard-Durchlauf genau die Information, die ihn beim \
                letzten Mal gefehlt hat.
                """
            )
        }
    }
}
