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
/// single carrier; and this suite asserts that both surfaces render from it and
/// that the shape still carries the values the standard claims.
///
/// **The failure message is part of the deliverable.** It names the two
/// deliveries, the regression, and what a legitimate future change has to move
/// together. A rewording that drops that history fails review: the next person
/// to touch this shape gets the same information the last one did not have.
@Suite("G2 — Vorsorge-Kachel und Medikamenten-Kachel, unter Vertrag")
struct VorsorgeMedicationTileParityTests {
    private static let medicationTile = "HealthLog/Screens/Medications/ActiveMedicationRow.swift"
    private static let vorsorgeScreen = "HealthLog/Screens/Notifications/MeasurementRemindersScreen.swift"
    private static let ledgerActions = "HealthLog/Screens/Notifications/VorsorgeReminderLedgerActions.swift"

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
    func actionTokensMatchTheMedicationTwin() throws {
        let medication = try Phase8SourceScan.stripped(Self.medicationTile)
        let vorsorge = try Phase8SourceScan.stripped(Self.vorsorgeScreen)
        let tokens = HLTileAction.tokens

        var violations: [String] = []

        // The carrier, on both surfaces. This is the structural half: two
        // surfaces that render from one type cannot drift apart one at a time,
        // which is exactly how b210's mirrored copy came undone.
        if !medication.contains("HLTileActionButton") {
            violations.append("MedicationCard does not render its quiet actions through HLTileActionButton")
        }
        if !vorsorge.contains("HLTileActionButton") {
            violations.append("the Vorsorge tile does not render its actions through HLTileActionButton")
        }

        // Neither surface may keep a full-width flow CTA where a tile action
        // belongs — that IS the d06174e6 shape.
        if vorsorge.contains("HLButton(") {
            violations.append("the Vorsorge tile still builds an HLButton (the 48pt/.hlHeadline flow CTA shape)")
        }

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
            EXPECTED_RED: the Vorsorge button still wears the d06174e6 shape

            \(Self.contract)

            Offen: \(violations)
            """
        )
    }

    // MARK: - 2. The functions

    @Test("Überspringen und Snoozen sind auf der Kachel erreichbar, nicht nur im Detail-Sheet")
    func skipAndSnoozeAreTileLevel() throws {
        let vorsorge = try Phase8SourceScan.stripped(Self.vorsorgeScreen)
        // The affordances themselves live in the type BOTH placements mount —
        // that sharing is half the deliverable, so the clause reads the mount on
        // the tile and the affordances where they are implemented, rather than
        // demanding a second copy of them on the screen.
        let actions = try Phase8SourceScan.stripped(Self.ledgerActions)

        var violations: [String] = []
        if !vorsorge.contains("VorsorgeReminderLedgerActions") || !vorsorge.contains("placement: .tile") {
            violations.append("the tile does not mount the accepted cycle actions")
        }
        if !actions.contains("vorsorge.card.action.skip") {
            violations.append("the tile offers no skip affordance")
        }
        if !actions.contains("vorsorge.card.action.snooze") {
            violations.append("the tile offers no snooze affordance")
        }

        #expect(
            violations.isEmpty,
            """
            EXPECTED_RED: skip/snooze exist only in the detail sheet

            G2's second half. Skip and snooze were built in 08-18/08-19/08-22 and mounted in the \
            detail sheet only — tile placement was never a criterion, and „Skip/Snooze \
            funktionieren ordentlich" was read as sheet-only. The medication tile marks a dose \
            taken or skipped WITHOUT opening anything, and that reachability is the parity the \
            operator means. Offen: \(violations)
            """
        )
    }

    // MARK: - 3. G1

    @Test("Die Adhärenz-Kopfkarte ist weg — Betreiber-Ansage vom 2026-08-22")
    func adherenceHeaderIsGone() throws {
        let vorsorge = try Phase8SourceScan.stripped(Self.vorsorgeScreen)
        let cardFile = Phase8SourceScan.repositoryRoot
            .appendingPathComponent("HealthLog/Screens/Notifications/VorsorgeAdherenceSummaryCard.swift")

        var violations: [String] = []
        if vorsorge.contains("VorsorgeAdherenceSummaryCard") {
            violations.append("the reminders screen still mounts the adherence summary card")
        }
        if FileManager.default.fileExists(atPath: cardFile.path) {
            violations.append("VorsorgeAdherenceSummaryCard.swift still exists")
        }

        #expect(
            violations.isEmpty,
            """
            EXPECTED_RED: 4 von 4 im Plan still renders

            G1 is an operator statement („soll komplett raus"), and it removes something he \
            himself asked for at b215 (b84adbe0). Both dates belong to the record: requested \
            2026-07-07, withdrawn 2026-08-22. Restoring it needs a NEW request, not the old one. \
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
