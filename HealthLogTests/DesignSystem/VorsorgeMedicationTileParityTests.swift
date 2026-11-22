import Foundation
@testable import HealthLog
import Testing

/// **The G2 contract — the deliverable, not a side effect.**
///
/// The Vorsorge tiles were matched to the medication tiles twice, both times on
/// the operator's own request: b210 (`4c11938b`, 2026-07-05, whose commit title
/// is „Vorsorge-Kacheln exakt wie die Medikamenten-Karten") and b215
/// (`b84adbe0`, 2026-07-07). On 2026-07-31 the UI-standards refactor `d06174e6`
/// (unit U6, rule R9/E2) translated three `.restrained` call sites to
/// `.secondary` and the Vorsorge button silently went from
/// 44 pt/`.hlSubhead`/monochrome to 48 pt/`.hlHeadline`/`HLText.primary`. The
/// code comment on that screen went on claiming the parity for another three
/// weeks.
///
/// Nobody was careless. The refactor was **correct** under the wording that
/// existed — R9 knew two homes for a retired `.restrained` and the Vorsorge
/// button was a full-width action, so `.secondary` was the right translation.
/// The standard had no shape for „a quiet action inside a tile", and the two
/// surfaces were mirrored rather than shared, so nothing held them together and
/// nothing could report that they had come apart.
///
/// Both of those are now fixed, and this suite is the second half. R9/E2-A1
/// (2026-08-23) writes the tile-action shape down; `HLTileActionButton` is its
/// single carrier; and this suite asserts that the shape still carries the
/// values the standard claims.
///
/// **The failure message is part of the deliverable.** It names the two
/// deliveries, the regression, and what a legitimate future change has to move
/// together. A rewording that drops that history fails review: the next person
/// to touch this shape gets the same information the last one did not have.
@Suite("G2 — Vorsorge-Kachel und Medikamenten-Kachel, unter Vertrag")
struct VorsorgeMedicationTileParityTests {
    /// **The permanent contract message.** Verbatim in the assertion, by design.
    static let contract = """
    PARITY CONTRACT (G2): Vorsorge tiles and MedicationCard must render from the same tokens. \
    This parity was delivered twice (b210, b215) and silently broken once by a UI-standards \
    refactor (d06174e6, R9/E2, 2026-07-31) whose comment claimed otherwise. If a standards \
    change legitimately moves the shared shape, amend STANDARD-ui.md R9/E2, BOTH surfaces, and \
    this test in one change — never one surface alone.
    """

    // MARK: - 1. The tokens

    @Test("Beide Kacheln rendern ihre Aktionen aus demselben Token-Satz")
    func actionTokensMatchTheMedicationTwin() {
        let tokens = HLTileAction.tokens

        var violations: [String] = []

        // The value half: the shape still carries what R9/E2-A1 says it carries.
        if tokens.minHeight != 44 {
            violations.append("tile-action height class is \(tokens.minHeight), not the 44pt HIG floor")
        }
        if tokens.font != .hlSubhead {
            violations.append("tile-action font token is \(tokens.font.rawValue), not .hlSubhead")
        }
        if tokens.ink != .textSecondary {
            violations.append("tile-action ink token is \(tokens.ink.rawValue), not monochrome HLText.secondary")
        }
        if tokens.hasFill {
            violations.append("the tile action paints a fill — the .tint slab the operator rejected at b198")
        }

        #expect(
            violations.isEmpty,
            """
            the Vorsorge button still wears the d06174e6 shape

            \(Self.contract)

            Offen: \(violations)
            """
        )
    }

    // MARK: - 4. The message itself

    @Test("Die Vertragsmeldung trägt ihre Geschichte — eine Umformulierung ohne sie fällt durch")
    func contractMessageKeepsItsHistory() {
        for needle in ["b210", "b215", "d06174e6", "R9/E2", "2026-07-31", "STANDARD-ui.md"] {
            #expect(
                Self.contract.contains(needle),
                """
                Die permanente Vertragsmeldung nennt „\(needle)" nicht mehr.

                Diese Meldung ist der eigentliche Liefergegenstand von 17-02. Sie steht dort, \
                damit die Person, die diesen Test das nächste Mal rot sieht, in derselben \
                Sekunde erfährt, was sie gerade zu wiederholen im Begriff ist und wie es \
                richtig geht — die Information, die dem Autor von d06174e6 gefehlt hat. \
                Wer sie kürzt, nimmt sie ihm wieder weg.
                """
            )
        }
    }
}
