import Foundation
import Testing

/// **UI-Standard R13-A1 / E14 — eine zentrierte Form für jede destruktive Frage.**
///
/// Der Betreiber hat die Rückfrage „generell zentriert und ordentlich designt"
/// verlangt — **generell** heißt app-weit. `STANDARD-ui.md` R13-A1 schreibt
/// deshalb einen einzigen Träger vor: `hlConfirmDestructive(…)`. Verboten ist
/// der **handgebaute** Dialog an der Aufrufstelle, und zwar in beiden Formen:
/// ein roher `.alert` mit destruktivem Knopf genauso wie ein roher
/// `confirmationDialog` mit destruktivem Knopf.
///
/// **Warum ausgerechnet ein `alert` das Substrat ist.** Zentriert und ankerlos
/// ist auf dem iPhone genau eine System-Präsentation. Ein
/// `confirmationDialog` ist per Konstruktion ein Anker — Aktionsblatt an der
/// Unterkante (iOS 18–25) bzw. Blase an der Interaktionsquelle (iOS 26) — und
/// kann „zentriert" gar nicht liefern. Genau daran ist **b174** gescheitert,
/// und der eigene Fix des Betreibers (`cf3f8777`, „Lösch-Bestätigung im
/// Med-Verlauf unten verankert statt Popover auf Zeilenhöhe", 2026-06-11) hat
/// die Blase deshalb absichtlich an die Unterkante genagelt. Ein `alert` hat
/// **keine** Präsentationsquelle, an der er fehl-ankern könnte; das ist der
/// Grund, warum diese Ersatzform b174 löst statt es erneut zu riskieren.
///
/// **Nicht-destruktive Dialoge sind nicht gemeint.** Eine Wahl zwischen
/// gleichrangigen Optionen bleibt ein `confirmationDialog`. Dieser Test zählt
/// nur Blöcke, die einen `role: .destructive`-Knopf enthalten.
@Suite("R13-A1 — destruktive Bestätigungen tragen genau eine geteilte Form")
struct DestructiveConfirmationShapeTests {
    // MARK: - Quellbaum

    private nonisolated static func repoRoot(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent() // DesignSystem
            .deletingLastPathComponent() // HealthLogTests
            .deletingLastPathComponent() // <repo>
            .resolvingSymlinksInPath()
    }

    /// Alle `*.swift` unter `HealthLog/`, als repo-relative Pfade.
    private nonisolated static func sourceFiles() -> [(relative: String, contents: String)] {
        let root = repoRoot()
        let scanRoot = root.appendingPathComponent("HealthLog")
        guard let enumerator = FileManager.default.enumerator(at: scanRoot, includingPropertiesForKeys: nil) else {
            return []
        }
        let rootPath = root.path
        var out: [(String, String)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            var rel = url.resolvingSymlinksInPath().path
            guard rel.hasPrefix(rootPath) else { continue }
            rel.removeFirst(rootPath.count)
            if rel.hasPrefix("/") { rel.removeFirst() }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            out.append((rel, text))
        }
        return out.sorted { $0.0 < $1.0 }
    }

    private nonisolated static func contents(of relative: String) -> String? {
        try? String(contentsOf: repoRoot().appendingPathComponent(relative), encoding: .utf8)
    }

    // MARK: - Blockweiser Scan

    /// Ein Präsentations-Modifier samt seiner **vollständigen** Argumentliste
    /// und Trailing-Closures.
    ///
    /// Ein Fenster fester Zeilenzahl reicht hier nicht, und das ist keine
    /// Theorie: 17-04 hat mit einem 30-Zeilen-Fenster gezählt und dabei die
    /// `role: .destructive` des Lösch-Dialogs in
    /// `IllnessEpisodeDetailScreen` dem **neutralen** Genesungs-Dialog neun
    /// Zeilen darüber zugeschlagen — 33 statt 32 destruktive Dialoge. Deshalb
    /// wird hier über balancierte Klammern gelaufen.
    struct Block {
        let file: String
        let line: Int
        let modifier: String
        let isDestructive: Bool
    }

    nonisolated static func blocks(in text: String, file: String) -> [Block] {
        let chars = Array(text)
        var out: [Block] = []
        for modifier in [".confirmationDialog(", ".alert("] {
            let needle = Array(modifier)
            var index = 0
            while index + needle.count <= chars.count {
                guard Array(chars[index ..< index + needle.count]) == needle else {
                    index += 1
                    continue
                }
                let open = index + needle.count - 1
                guard let close = endOfModifier(chars, from: open) else { break }
                let body = String(chars[index ... close])
                let line = chars[..<index].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
                out.append(Block(
                    file: file,
                    line: line,
                    modifier: String(modifier.dropFirst().dropLast()),
                    isDestructive: body.contains("role: .destructive")
                ))
                index = close
            }
        }
        return out.sorted { ($0.line, $0.modifier) < ($1.line, $1.modifier) }
    }

    /// Index des letzten Zeichens des Modifiers ab `chars[start] == "("` —
    /// inklusive angehängter Trailing-Closures (`) { … } message: { … }`).
    private nonisolated static func endOfModifier(_ chars: [Character], from start: Int) -> Int? {
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < chars.count {
            let character = chars[index]
            if inString {
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
                index += 1
                continue
            }
            switch character {
            case "\"": inString = true
            case "(", "[", "{": depth += 1
            case ")", "]", "}":
                depth -= 1
                if depth == 0 {
                    var peek = index + 1
                    while peek < chars.count, chars[peek] == " " || chars[peek] == "\n" || chars[peek] == "\t" {
                        peek += 1
                    }
                    let tail = String(chars[peek ..< min(peek + 9, chars.count)])
                    if peek < chars.count, chars[peek] == "{" || tail.hasPrefix("message:") || tail.hasPrefix("actions:") {
                        index = peek
                        continue
                    }
                    return index
                }
            default: break
            }
            index += 1
        }
        return nil
    }

    /// Der Träger selbst darf (und muss) einen `alert` bauen — er ist die
    /// Ausnahme, weil er die Form **ist**.
    private nonisolated static var carrierDirectory: String {
        "HealthLog/DesignSystem/"
    }

    nonisolated static func handBuiltDestructiveConfirmations() -> [Block] {
        sourceFiles()
            .filter { !$0.relative.hasPrefix(carrierDirectory) }
            .flatMap { blocks(in: $0.contents, file: $0.relative) }
            .filter(\.isDestructive)
    }

    // MARK: - Tests

    /// Ein zählender Test, der nichts zählt, ist grün, ohne etwas zu prüfen.
    @Test("Der Scan sieht den Quellbaum")
    func scanSeesTheSourceTree() {
        let files = Self.sourceFiles()
        #expect(files.count > 400, "Quellbaum-Scan lieferte nur \(files.count) Dateien — der Pfad stimmt nicht.")
        let blocks = files.flatMap { Self.blocks(in: $0.contents, file: $0.relative) }
        // Nach der Umstellung bleiben genau die **nicht**-destruktiven Fälle
        // übrig: zwei Dialoge und zwölf Alerts. Die Schwelle sichert nur, dass
        // der Blockscanner überhaupt greift — ein Zähler, der nichts findet,
        // wäre grün, ohne etwas geprüft zu haben. Sie ist bewusst keine exakte
        // Zahl, sonst wäre jeder neue neutrale Alert ein falsches Rot.
        #expect(blocks.count >= 10, "Nur \(blocks.count) Präsentationsblöcke gefunden — der Blockscanner greift nicht.")
    }

    @Test("Keine destruktive Bestätigung ist an einer Aufrufstelle handgebaut")
    func noHandBuiltDestructiveConfirmation() {
        let hits = Self.handBuiltDestructiveConfirmations()
        let listing = hits.map { "  \($0.file):\($0.line) — \($0.modifier)" }.joined(separator: "\n")
        #expect(hits.isEmpty, """
        EXPECTED_RED: 31 destructive confirmations are hand-built at their call sites
        R13-A1: \(hits.count) handgebaute destruktive Bestätigung(en) außerhalb von \
        \(Self.carrierDirectory):

        \(listing)

        Destruktive Rückfragen sind app-weit zentriert und ankerlos — Träger ist \
        `hlConfirmDestructive(…)`, nicht ein eigener Bau je Bildschirm. Ein roher \
        `confirmationDialog` kann zentriert gar nicht liefern (er ist per Konstruktion \
        ein Anker), und ein roher `alert` an der Aufrufstelle umgeht den Träger, ohne \
        das Problem zu lösen. Wer hier legitim etwas ändern will, bewegt STANDARD-ui.md \
        R13-A1, den Träger und diesen Test in einer Änderung.
        """)
    }

    @Test("Die geteilte Form existiert und präsentiert zentriert/ankerlos")
    func theSharedShapeIsAnAlert() throws {
        let path = "HealthLog/DesignSystem/HLConfirmDestructive.swift"
        let source = try #require(
            Self.contents(of: path),
            "EXPECTED_RED: HLConfirmDestructive.swift does not exist — \(path) fehlt, die geteilte Form gibt es nicht."
        )
        #expect(
            source.contains("func hlConfirmDestructive"),
            "EXPECTED_RED: HLConfirmDestructive.swift does not exist — der Träger deklariert `hlConfirmDestructive` nicht."
        )
        // Ohne führenden Punkt: der Träger ist selbst eine `View`-Extension und
        // ruft `alert(…)` unqualifiziert auf. Der Fließtext oben nennt `alert`
        // nur ohne Klammer, ein Doku-Treffer ist damit ausgeschlossen.
        #expect(source.contains("alert("), """
        Der Träger präsentiert nicht über `alert`. Zentriert und ankerlos ist auf dem \
        iPhone genau diese eine System-Präsentation, und sie ist die einzige ohne \
        Präsentationsquelle — deshalb kann die iOS-26-Fehlankerung aus b174 hier nicht \
        zurückkommen.
        """)
        #expect(!source.contains("confirmationDialog("), "Der Träger baut selbst einen Anker.")
        #expect(!source.contains("popover("), "Der Träger baut selbst einen Anker.")
        #expect(source.contains("cf3f8777"), """
        Der aufgehobene b174/b175-Fix des Betreibers muss dort benannt bleiben, wo seine \
        Ablösung wohnt — sonst ist die Blase in einem Jahr ein Versehen statt eine \
        Entscheidung.
        """)
    }

    @Test("Die beiden DesignSystem-Träger bauen nicht doppelt")
    func designSystemCarriersRouteThroughTheSharedShape() throws {
        var offenders: [String] = []
        for path in [
            "HealthLog/DesignSystem/HLDiscardGuard.swift",
            "HealthLog/DesignSystem/LogoutConfirmationModifier.swift"
        ] {
            let source = try #require(Self.contents(of: path), "\(path) fehlt.")
            if !source.contains(".hlConfirmDestructive(") { offenders.append("\(path): benutzt die geteilte Form nicht") }
            if source.contains(".confirmationDialog(") { offenders.append("\(path): baut weiterhin einen eigenen Anker") }
        }
        // Eine einzige Zusicherung, nicht vier: der Grund einer erwarteten
        // Rot-Phase muss im Protokoll **genau einmal** stehen, sonst kann
        // `assert-behavioral-red.sh` nicht zwischen „der erwartete Fehler" und
        // „derselbe Text zufällig mehrfach" unterscheiden.
        #expect(offenders.isEmpty, """
        EXPECTED_RED: both DesignSystem carriers still build their own anchor
        \(offenders.joined(separator: "\n"))

        `HLDiscardGuard` und `LogoutConfirmationModifier` sind zwei destruktive \
        Bestätigungen mit 14 Aufrufstellen. Wenn sie ihre eigene Präsentation bauen, \
        gibt es drei Formen statt einer — und die Verwerfen-Rückfrage bliebe die \
        untenverankerte Blase aus b174.
        """)
    }

    /// Die beiden neutralen Dialoge bleiben, was sie sind — und das steht hier,
    /// damit ihr Verbleib eine Entscheidung ist und kein Übersehen. Keiner von
    /// beiden trägt einen destruktiven Knopf: `CycleCaptureSheet` lässt zwischen
    /// zwei gleichrangigen Zyklus-Aktionen wählen, `IllnessEpisodeDetailScreen`
    /// bestätigt eine Genesung. R13-A1 spricht nur über destruktive Rückfragen.
    @Test("Die neutralen Dialoge bleiben Dialoge")
    func neutralDialogsStayDialogs() throws {
        for path in [
            "HealthLog/Screens/Cycle/CycleCaptureSheet.swift",
            "HealthLog/Screens/Illness/IllnessEpisodeDetailScreen.swift"
        ] {
            let source = try #require(Self.contents(of: path), "\(path) fehlt.")
            let neutral = Self.blocks(in: source, file: path).filter { !$0.isDestructive }
            #expect(
                neutral.contains { $0.modifier == "confirmationDialog" },
                "\(path) hat seinen neutralen confirmationDialog verloren — R13-A1 verlangt das nicht."
            )
        }
    }
}
