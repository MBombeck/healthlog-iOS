import Foundation
import Testing

/// **UI-Standard E6 (=R21) + E7 (=R22)** — die zwei Katalog-Scans aus der
/// Erzwingungstabelle (`.planning/ux/STANDARD-ui.md` §4).
///
/// - **E6 / R4:** Wegweiser-Text („das änderst du woanders") ist verboten. An
///   seiner Stelle steht ein Absprung. Kein deutscher Katalogwert darf die
///   Wegweiser-Phrasen tragen — außer den Schlüsseln der Absprung-Allowlist.
/// - **E7 / R15–R17:** der Pauschal-Hinweis lebt an genau zwei Orten. Die
///   Disclaimer-Phrasen dürfen nur noch in den Schlüsseln der R16-Tabelle
///   (plus Klasse 4) vorkommen.
///
/// ## Warum die Allowlist nur schrumpfen kann
///
/// `HealthLogTests/Resources/UIStandardCopyAllowlist.json` hat pro Regel zwei
/// Töpfe:
///
/// - `protected` — die **abschließende** Ausnahmeliste aus R16. Sie bleibt.
/// - `pending` — Restschuld. Jeder Eintrag nennt die Arbeitseinheit (U1…U8),
///   die die Fundstelle aufräumt.
///
/// Beide Töpfe werden **exakt** abgeglichen, in beide Richtungen:
///
/// 1. Ein Katalogwert mit Phrase, dessen Schlüssel in **keinem** Topf steht →
///    Fehler. So kommt kein neuer Pauschaltext herein.
/// 2. Ein gelisteter Schlüssel, der die Phrase **nicht mehr** trägt → Fehler
///    mit der Aufforderung, den Eintrag zu streichen.
///
/// Regel 2 ist der eigentliche Trick: ein Eintrag ist nur dann eintragbar,
/// wenn die Verletzung schon existiert. Man kann die Liste also nicht auf
/// Vorrat füllen, um sich künftige Verstöße zu erlauben — und wer aufräumt,
/// **muss** seine Zeile löschen, sonst wird sein eigener Lauf rot. Die Liste
/// bewegt sich nur nach unten. U8 dampft den `pending`-Topf am Ende auf leer
/// ein; was dann noch steht, ist `protected` und damit der Zielzustand.
@Suite("UI-Standard — Wegweiser- und Disclaimer-Phrasen nur auf der Allowlist (schrumpfend)")
struct UIStandardCopyGuardTests {
    // MARK: - Allowlist-Modell

    struct Allowlist: Decodable {
        let wegweiser: Section
        let disclaimer: Section

        struct Section: Decodable {
            let phrases: [String]
            /// Optionale Regex-Phrasen (E7 kennt „Ärztin oder … Arzt").
            let phrasePatterns: [String]?
            /// Schlüssel → Grund. Bleibt (R16).
            let protected: [String: String]
            /// Schlüssel → zuständige Arbeitseinheit. Muss verschwinden.
            let pending: [String: String]

            var allKeys: Set<String> {
                Set(protected.keys).union(pending.keys)
            }
        }
    }

    private nonisolated static func loadAllowlist(file: String = #filePath) throws -> Allowlist {
        let url = URL(fileURLWithPath: file)
            .deletingLastPathComponent() // i18n
            .deletingLastPathComponent() // HealthLogTests
            .appendingPathComponent("Resources")
            .appendingPathComponent("UIStandardCopyAllowlist.json")
        return try JSONDecoder().decode(Allowlist.self, from: Data(contentsOf: url))
    }

    // MARK: - Scan

    /// Alle Schlüssel, deren deutscher Wert mindestens eine Phrase der Sektion trägt.
    private nonisolated static func offendingKeys(
        _ section: Allowlist.Section,
        in catalog: ParityCatalog.Root
    ) throws -> Set<String> {
        let regexes: [NSRegularExpression] = try (section.phrasePatterns ?? [])
            .map { try NSRegularExpression(pattern: $0) }
        var hits: Set<String> = []
        for (key, entry) in catalog.strings {
            guard let value = ParityCatalog.value(entry, language: "de"), !value.isEmpty else { continue }
            let literal = section.phrases.contains { value.contains($0) }
            let matched = literal || regexes.contains {
                $0.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
            }
            if matched { hits.insert(key) }
        }
        return hits
    }

    private nonisolated static func check(
        _ section: Allowlist.Section,
        in catalog: ParityCatalog.Root,
        rule: String
    ) throws {
        let hits = try offendingKeys(section, in: catalog)
        let listed = section.allKeys

        let unlisted = hits.subtracting(listed).sorted()
        #expect(
            unlisted.isEmpty,
            """
            \(rule): \(unlisted.count) deutsche Katalogwerte tragen eine verbotene Phrase, \
            ohne auf der Allowlist zu stehen:
            \(unlisted.map { "  • \($0)" }.joined(separator: "\n"))

            Richtig ist, den Text zu beheben (R4: Wegweiser → Absprung; R15–R17: Pauschal-Schwanz \
            fällt, Zuschreibung bleibt). Ein Eintrag in UIStandardCopyAllowlist.json ist nur dann \
            richtig, wenn R16 die Fundstelle namentlich schützt — dann gehört er nach `protected`, \
            mit Begründung.
            """
        )

        let stale = listed.subtracting(hits).sorted()
        #expect(
            stale.isEmpty,
            """
            \(rule): \(stale.count) Allowlist-Einträge tragen die Phrase nicht mehr — \
            bitte aus UIStandardCopyAllowlist.json STREICHEN:
            \(stale.map { "  • \($0)" }.joined(separator: "\n"))

            Die Allowlist ist eine Restschuld-Anzeige, keine Erlaubnis auf Vorrat. Ein Schlüssel \
            ohne Verletzung darf nicht darin stehen — sonst könnte die Liste wachsen, statt zu \
            schrumpfen.
            """
        )
    }

    // MARK: - Tests

    @Test("E6/R21 — keine Wegweiser-Phrase außerhalb der Absprung-Allowlist")
    func wegweiserPhrases() throws {
        let catalog = try ParityCatalog.load()
        try Self.check(Self.loadAllowlist().wegweiser, in: catalog, rule: "E6/R4 Wegweiser")
    }

    @Test("E7/R22 — Disclaimer-Phrasen nur in den von R16 geschützten Schlüsseln")
    func disclaimerAllowlist() throws {
        let catalog = try ParityCatalog.load()
        try Self.check(Self.loadAllowlist().disclaimer, in: catalog, rule: "E7/R15–R17 Disclaimer")
    }

    @Test("Die Allowlist überlappt sich nicht: kein Schlüssel steht gleichzeitig in `protected` und `pending`")
    func bucketsAreDisjoint() throws {
        let allowlist = try Self.loadAllowlist()
        for (name, section) in [("wegweiser", allowlist.wegweiser), ("disclaimer", allowlist.disclaimer)] {
            let overlap = Set(section.protected.keys).intersection(section.pending.keys).sorted()
            #expect(overlap.isEmpty, "\(name): Schlüssel in beiden Töpfen: \(overlap)")
        }
    }
}
