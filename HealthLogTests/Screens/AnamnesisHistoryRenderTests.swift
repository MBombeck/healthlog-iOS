import Foundation
@testable import HealthLog
import SnapshotTesting
import Testing

/// **CU-32 — Render-Beweis für den Verlauf.**
///
/// Hauspraxis: nicht der Pixel-Snapshot, sondern der **Zustandsdeskriptor**,
/// der den Render-Pfad speist (`MedicationsRowSnapshotTests`-Idiom) — SDK-Drift
/// erzeugt sonst Rauschen, das echte Regressionen verdeckt.
/// ``AnamnesisHistoryRow`` ist genau diese Eingabe; sie trägt Schlüssel und
/// Rohdaten, nie aufgelöste Texte, damit der Snapshot nicht an Locale oder
/// Zeitzone hängt.
///
/// Der Verlauf ist der eigentliche Zweck dieser Fläche — deshalb wird hier
/// festgenagelt, dass er entsteht, in welcher Reihenfolge, mit welcher
/// Provenienz und mit welchem Gültigkeitsfenster.
@Suite("AnamnesisHistoryRow — Verlaufs-Render")
struct AnamnesisHistoryRenderTests {
    /// Mirror-Dump statt Pixel: stabil über SDK-Bumps hinweg.
    private func dump(of value: some Any) -> String {
        var output = ""
        Swift.dump(value, to: &output)
        return output
    }

    private static func revision(
        id: String,
        kind: AnamnesisFactKind,
        value: AnamnesisFactValue?,
        unreadable: Bool = false,
        from: TimeInterval,
        until: TimeInterval? = nil,
        provenance: AnamnesisFactProvenance,
        supersededBy: String? = nil
    ) -> AnamnesisFactRevision {
        AnamnesisFactRevision(
            id: id,
            kind: kind,
            value: value,
            unreadable: unreadable,
            validFrom: Date(timeIntervalSince1970: from),
            validUntil: until.map { Date(timeIntervalSince1970: $0) },
            provenance: provenance,
            supersededByRevisionId: supersededBy,
            createdAt: Date(timeIntervalSince1970: from)
        )
    }

    /// Erstangabe → Korrektur: die Zeitleiste, um die es dieser Fläche geht.
    private static let smokingHistory: [AnamnesisFactRevision] = [
        revision(
            id: "rev-1", kind: .smokingStatus, value: .current,
            from: 1_700_000_000, until: 1_705_000_000,
            provenance: .userReported, supersededBy: "rev-2"
        ),
        revision(
            id: "rev-2", kind: .smokingStatus, value: .former,
            from: 1_705_000_000, provenance: .userCorrection
        ),
        // Fremde Art — darf im Verlauf des Rauchens nicht auftauchen.
        revision(
            id: "rev-alc", kind: .alcoholPattern, value: .declaredNone,
            from: 1_706_000_000, provenance: .userReported
        )
    ]

    @Test("Snapshot — the smoking history projection (newest first, per kind)")
    func smokingHistorySnapshot() {
        let rows = AnamnesisHistoryRow.rows(for: .smokingStatus, from: Self.smokingHistory)
        assertSnapshot(of: dump(of: rows), as: .lines, named: "anamnesis-history-smoking")
    }

    @Test("the history renders newest-validity-first and only for the asked kind")
    func historyOrderAndFiltering() {
        let rows = AnamnesisHistoryRow.rows(for: .smokingStatus, from: Self.smokingHistory)

        #expect(rows.count == 2)
        #expect(rows.map(\.id) == ["rev-2", "rev-1"])
        // Die aktuelle Fassung ist die einzige offene.
        #expect(rows[0].isCurrent)
        #expect(rows[0].validUntil == nil)
        #expect(!rows[1].isCurrent)
        #expect(rows[1].validUntil != nil)
    }

    /// Eine Korrektur ist etwas anderes als eine Änderung — das Abzeichen muss
    /// an der Zeile hängen und darf nicht verschluckt werden.
    @Test("provenance is carried per row, correction distinguishable from first entry")
    func provenanceIsShownPerRow() {
        let rows = AnamnesisHistoryRow.rows(for: .smokingStatus, from: Self.smokingHistory)

        #expect(rows[0].provenanceKey == "anamnesis.provenance.userCorrection")
        #expect(rows[0].isCorrection)
        #expect(rows[1].provenanceKey == "anamnesis.provenance.userReported")
        #expect(!rows[1].isCorrection)
        #expect(rows[0].provenanceKey != rows[1].provenanceKey)
    }

    /// Die unlesbare Fassung bekommt eine eigene Beschriftung und verschwindet
    /// **nicht** aus dem Verlauf — eine Lücke wäre die unehrlichere Anzeige.
    @Test("an unreadable revision still renders, with its own label")
    func unreadableRowIsShown() {
        let rows = AnamnesisHistoryRow.rows(
            for: .alcoholPattern,
            from: [Self.revision(
                id: "rev-x", kind: .alcoholPattern, value: nil, unreadable: true,
                from: 1_700_000_000, provenance: .userReported
            )]
        )

        #expect(rows.count == 1)
        #expect(rows[0].labelKey == AnamnesisCopy.unreadable)
        // Ausdrücklich NICHT der NONE-Schlüssel — unlesbar ist nicht „keine".
        #expect(rows[0].labelKey != AnamnesisFactKind.alcoholPattern.labelKey(for: .declaredNone))
    }

    /// `NONE` bekommt die Beschriftung **seiner Art** — der geteilte
    /// Wire-Literal darf im Verlauf nicht als eine Aussage erscheinen.
    @Test("the shared NONE literal renders through its kind's label key")
    func noneRendersPerKind() {
        let alcohol = AnamnesisHistoryRow.rows(
            for: .alcoholPattern,
            from: [Self.revision(
                id: "a", kind: .alcoholPattern, value: .declaredNone,
                from: 1, provenance: .userReported
            )]
        )
        let shift = AnamnesisHistoryRow.rows(
            for: .shiftSchedule,
            from: [Self.revision(
                id: "s", kind: .shiftSchedule, value: .declaredNone,
                from: 1, provenance: .userReported
            )]
        )

        #expect(alcohol[0].labelKey == "anamnesis.value.ALCOHOL_PATTERN.NONE")
        #expect(shift[0].labelKey == "anamnesis.value.SHIFT_SCHEDULE.NONE")
        #expect(alcohol[0].labelKey != shift[0].labelKey)
    }

    @Test("an empty history projects to no rows — the view then shows its own copy")
    func emptyHistoryProjectsEmpty() {
        #expect(AnamnesisHistoryRow.rows(for: .shiftSchedule, from: Self.smokingHistory).isEmpty)
        #expect(AnamnesisHistoryRow.rows(for: .smokingStatus, from: []).isEmpty)
    }

    /// Die Gültigkeitszeile ist eine Quelle für Karte und Verlauf — offen und
    /// geschlossen müssen sich sichtbar unterscheiden.
    @Test("the validity line differs between an open and a closed revision")
    func validityTextDistinguishesOpenAndClosed() {
        let rows = AnamnesisHistoryRow.rows(for: .smokingStatus, from: Self.smokingHistory)
        let open = rows[0].validityText
        let closed = rows[1].validityText

        #expect(!open.isEmpty)
        #expect(!closed.isEmpty)
        #expect(open != closed)
        // Kein durchgereichter Katalog-Schlüssel.
        #expect(!open.hasPrefix("anamnesis."))
        #expect(!closed.hasPrefix("anamnesis."))
    }
}
