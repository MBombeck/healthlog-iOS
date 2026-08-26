import Foundation
import Testing

/// **U10 — `NotificationDiagnosticsScreen` trägt keine rohen Literale mehr.**
///
/// Der Bildschirm ist über Einstellungen → Mitteilungen → „Erweiterte
/// Diagnose" für **jeden** Nutzer erreichbar, nicht nur unter DEBUG. Er war
/// trotzdem durchgehend unlokalisiert, und zwar in beide Richtungen gemischt:
/// deutsche Kartentitel („Berechtigung", „Kategorien", „Testbanner") neben
/// englischen Zeilen („Server status", „Active medications") — ein deutscher
/// Nutzer las englische Zeilen, ein englischer deutsche.
///
/// Zwei Ursachen, die dieser Test getrennt festnagelt:
///
/// 1. **Deutsche Quell-Literale.** Der Katalog ist `sourceLanguage: en`. Ein
///    deutsches Literal in einer Lokalisierungs-API leitet einen deutschen
///    Schlüssel ab, den es im Katalog nicht gibt — er rendert roh, in beiden
///    Sprachen. → `keineDeutschenLiterale`.
/// 2. **Literale in Nicht-Lokalisierungs-Positionen.** `LabeledRow.title` war
///    ein `String`, und `Text(_ content: some StringProtocol)` ist der
///    *nicht* lokalisierende Initializer. Elf Zeilenbeschriftungen wurden
///    wörtlich gerendert, obwohl ein Teil von ihnen sogar Katalogeinträge
///    hatte — sie wurden nur nie konsultiert. → `jederNutzertextIstEinKatalogschlüssel`.
///
/// Genau der zweite Fall ist schon einmal übersehen worden: R18 des
/// UI-Standards nannte die Datei namentlich und wies sie U6 zu, U6 hat sie
/// nicht behoben. Ein Grep nach „sieht deutsch aus" hätte ihn auch nicht
/// gefunden — die Hälfte der Fundstellen war englisch. Deshalb prüft dieser
/// Test die **Position** des Literals, nicht seine Sprache.
///
/// ## Warum ein Quelltext-Scan und kein Snapshot
///
/// `LocalizedStringKey` löst im Unit-Test nicht zu einem `String` auf (siehe
/// `ParityCatalogLoader`), und ein Snapshot zeigt nur die eine Sprache, in der
/// er aufgenommen wurde. Der Scan liest stattdessen die Datei, sammelt jedes
/// Literal aus einer nutzersichtbaren Argument-Position und schlägt es im
/// eingecheckten Katalog nach — inklusive `de`- **und** `en`-Einheit.
@Suite("U10 — NotificationDiagnosticsScreen: kein roher UI-String, alles de+en im Katalog")
struct NotificationDiagnosticsLiteralGuardTests {
    // MARK: - Dateien

    private static let screenPath = "HealthLog/Screens/Notifications/NotificationDiagnosticsScreen.swift"
    private static let entryPath = "HealthLog/Screens/Notifications/NotificationsScreen+ChannelCards.swift"
    /// **08-15.** The registration audit, the banner categories and the pending
    /// identifiers moved to the support screen. The guard follows them rather
    /// than shrinking: it now reads the diagnostics *surface* — both files —
    /// so the census threshold below keeps its meaning and every literal that
    /// moved is still required to be a catalogue key with `de` **and** `en`.
    /// A guard that lowered its own bar when the screen was split would have
    /// stopped noticing the case it exists for.
    private static let supportPath = "HealthLog/Screens/Settings/Sub/SettingsSupportDiagnosticsScreen.swift"

    /// Every file the diagnostics surface is spread across. Scanned one file at
    /// a time — `LiteralScanner` carries block-comment state, so concatenating
    /// sources would be correct only by accident.
    private static let surfacePaths = [screenPath, supportPath]

    /// Der Schlüssel, den die Einstiegszeile und der Seitentitel teilen (R3 —
    /// eine Aussage, ein Ort: die Zeile verspricht, was die Seite heißt).
    private static let entryKey = "Advanced diagnostics"

    private nonisolated static func repoRoot(file: String = #filePath) -> URL {
        // <repo>/HealthLogTests/i18n/NotificationDiagnosticsLiteralGuardTests.swift
        URL(fileURLWithPath: file)
            .deletingLastPathComponent() // i18n
            .deletingLastPathComponent() // HealthLogTests
            .deletingLastPathComponent() // <repo>
            .resolvingSymlinksInPath()
    }

    private nonisolated static func source(_ relative: String) throws -> String {
        var url = repoRoot()
        for component in relative.split(separator: "/") {
            url.appendPathComponent(String(component))
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Literal-Extraktion

    /// Ein Literal mit seiner Zeilennummer.
    struct Literal: Equatable {
        let line: Int
        let value: String
    }

    /// Alle String-Literale einer Swift-Datei, Kommentare ausgenommen.
    ///
    /// Zeichenweise statt per Regex, weil ein `//` in einem Literal
    /// (`"POST /api/devices"`, URLs) sonst den Rest der Zeile verschluckt und
    /// ein `"` in einem Kommentar den Scanner aus dem Tritt bringt. Mehrzeilige
    /// `"""`-Literale kommen in dieser Datei nicht vor und werden bewusst nicht
    /// unterstützt — `enthältNurEinzeiligeLiterale` hält das fest.
    nonisolated static func literals(in text: String) -> [Literal] {
        var scanner = LiteralScanner()
        for character in text {
            scanner.consume(character)
        }
        return scanner.literals
    }

    /// Der Zustandsautomat hinter `literals(in:)` — vier Zustände, je eine
    /// kleine Übergangsfunktion, damit keine davon zu einem Knäuel wächst.
    struct LiteralScanner {
        private enum State { case code, lineComment, blockComment, string }

        private(set) var literals: [Literal] = []
        private var state: State = .code
        private var buffer = ""
        private var startLine = 0
        private var line = 1
        private var escaped = false
        private var previous: Character?

        mutating func consume(_ character: Character) {
            defer {
                if character == "\n" { line += 1 }
                previous = character
            }
            switch state {
            case .code:
                consumeCode(character)
            case .lineComment:
                if character == "\n" { state = .code }
            case .blockComment:
                if previous == "*", character == "/" { state = .code }
            case .string:
                consumeString(character)
            }
        }

        private mutating func consumeCode(_ character: Character) {
            guard previous == "/" else {
                if character == "\"" { openString() }
                return
            }
            switch character {
            case "/": state = .lineComment
            case "*": state = .blockComment
            case "\"": openString()
            default: break
            }
        }

        private mutating func consumeString(_ character: Character) {
            // Ein einzeiliges Swift-Literal kann keinen echten Umbruch tragen —
            // steht hier einer, hat sich der Scanner verlaufen. Abbrechen statt
            // den Rest der Datei zu verschlucken.
            if character == "\n" {
                state = .code
                buffer = ""
                return
            }
            if escaped {
                escaped = false
                buffer.append(character)
                return
            }
            switch character {
            case "\\":
                escaped = true
                buffer.append(character)
            case "\"":
                state = .code
                literals.append(Literal(line: startLine, value: buffer))
                buffer = ""
            default:
                buffer.append(character)
            }
        }

        private mutating func openString() {
            state = .string
            startLine = line
            buffer = ""
            escaped = false
        }
    }

    /// Zeilen mit angehängten Fortsetzungen: endet eine Zeile auf `(`, zieht
    /// sie die nächste an sich. Damit steht ein Literal immer bei dem Aufruf,
    /// zu dem es gehört — `accessibilityIdentifier(` und `HLLog…error(` setzen
    /// ihr Argument nämlich auf eine eigene Zeile und sähen sonst aus wie ein
    /// nackter `LocalizedStringKey`. Die Startzeile wird mitgeführt, damit die
    /// Fehlermeldung auf die Quelle zeigt.
    nonisolated static func logicalLines(in text: String) -> [(line: Int, text: String)] {
        var out: [(line: Int, text: String)] = []
        for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let piece = String(raw)
            if var last = out.last, last.text.hasSuffix("(") {
                last.text += piece.trimmingCharacters(in: .whitespaces)
                out[out.count - 1] = last
            } else {
                out.append((index + 1, piece.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)))
            }
        }
        return out
    }

    /// Literale in einer **nutzersichtbaren** Position.
    ///
    /// Die Positionen sind die Teilmenge der i18n-Guard-API-Fläche, die dieser
    /// Bildschirm tatsächlich benutzt, plus `LabeledRow(title:)` — das lokale
    /// Zeilen-Primitive, dessen `title` seit U10 ein `LocalizedStringKey` ist.
    /// Eine `value:`-Zuweisung steht bewusst **nicht** darin: sie trägt Zahlen,
    /// Zeitstempel und bereits übersetzten Text, nie einen Katalogschlüssel.
    ///
    /// Der Sonderfall ist der **nackte** Rückgabewert eines `switch`-Zweigs
    /// (`case .requestPrompt: "Enable notifications"`). Er zählt nur, wenn die
    /// umgebende Eigenschaft als `LocalizedStringKey` deklariert ist — die
    /// gleich gebaute `var symbol: String` daneben liefert SF-Symbol-Namen und
    /// darf nicht im Katalog landen.
    nonisolated static func userFacingKeys(in text: String) -> [Literal] {
        let patterns: [String] = [
            #"\btitle:\s*"((?:[^"\\]|\\.)*)""#,
            #"\bfooter:\s*"((?:[^"\\]|\\.)*)""#,
            #"\bText\(\s*"((?:[^"\\]|\\.)*)""#,
            #"\bLabel\(\s*"((?:[^"\\]|\\.)*)""#,
            // Deckt `String(localized: "…")` in einer Zeile **und** die über
            // drei Zeilen umbrochene Form, bei der `localized:` allein steht.
            #"\blocalized:\s*"((?:[^"\\]|\\.)*)""#
        ]
        let regexes = patterns.compactMap { try? NSRegularExpression(pattern: $0) }
        let bareLiteral = try? NSRegularExpression(pattern: #"^\s*(?:case\s+[^:]+:\s*)?"((?:[^"\\]|\\.)*)"\s*$"#)
        let declaration = try? NSRegularExpression(pattern: #"\bvar\s+\w+:\s*([A-Za-z]+\??)"#)

        var out: [Literal] = []
        var seen: Set<String> = []
        var declaredType: String?

        func capture(_ regex: NSRegularExpression, in line: String, at lineNumber: Int) {
            let range = NSRange(line.startIndex..., in: line)
            for match in regex.matches(in: line, range: range) {
                guard let captured = Range(match.range(at: 1), in: line) else { continue }
                let value = String(line[captured])
                guard !value.isEmpty, seen.insert("\(lineNumber)|\(value)").inserted else { continue }
                out.append(Literal(line: lineNumber, value: value))
            }
        }

        for entry in logicalLines(in: text) {
            let line = entry.text
            guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { continue }
            if let declaration,
               let match = declaration.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let captured = Range(match.range(at: 1), in: line)
            {
                declaredType = String(line[captured])
            }
            for regex in regexes {
                capture(regex, in: line, at: entry.line)
            }
            if let bareLiteral, declaredType?.hasPrefix("LocalizedStringKey") == true {
                capture(bareLiteral, in: line, at: entry.line)
            }
        }
        return out
    }

    /// Übersetzt ein Quell-Literal in den Katalogschlüssel, den Swift daraus
    /// ableitet: jede `\(…)`-Interpolation wird zu einem Formatspezifizierer.
    /// `%@` deckt `String`; `%lld` ist die Int-Variante, die als Rückfallweg
    /// probiert wird.
    /// Index **hinter** der schließenden Klammer einer `\(…)`-Interpolation,
    /// die bei `openParenthesis` beginnt. Verschachtelte Klammern werden
    /// mitgezählt (`\(LogSanitizer.redact(raw))`); bei unbalancierter Klammer
    /// endet die Suche am Stringende.
    nonisolated static func endOfInterpolation(
        in literal: String,
        openParenthesis: String.Index
    ) -> String.Index {
        var depth = 0
        var cursor = openParenthesis
        while cursor < literal.endIndex {
            if literal[cursor] == "(" { depth += 1 }
            if literal[cursor] == ")" {
                depth -= 1
                if depth == 0 { return literal.index(after: cursor) }
            }
            cursor = literal.index(after: cursor)
        }
        return literal.endIndex
    }

    nonisolated static func derivedKeyCandidates(_ literal: String) -> [String] {
        guard literal.contains("\\(") else { return [literal] }
        var out = ""
        var index = literal.startIndex
        var specifiers = 0
        while index < literal.endIndex {
            if literal[index] == "\\", literal.index(after: index) < literal.endIndex,
               literal[literal.index(after: index)] == "("
            {
                out.append("%@")
                specifiers += 1
                index = Self.endOfInterpolation(in: literal, openParenthesis: literal.index(after: index))
                continue
            }
            out.append(literal[index])
            index = literal.index(after: index)
        }
        guard specifiers > 0 else { return [literal] }
        return [out, out.replacingOccurrences(of: "%@", with: "%lld")]
    }

    // MARK: - Deutsch-Erkennung

    /// Deutsche Funktionswörter ohne englische Homographen („die", „war",
    /// „hat", „an", „so" fehlen absichtlich) — dazu Umlaute und ß.
    private static let germanWords: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"\b(?:und|oder|nicht|noch|kein|keine|keinen|wird|werden|wurde|sind|"#
            + #"dein|deine|deinem|einen|einer|eines|mehr|von|mit|zum|zur|den|dem|des|"#
            + #"heute|bitte|jede|jeder|jedes|nach|vor|aus|ohne|erst|erneut|tippen|"#
            + #"drücken|öffnen|aktivieren|starten|sieht|Anzahl|Berechtigung|Diagnose|"#
            + #"Kategorien|Versuch|Einnahmen|Testbanner|Geplante|Benachrichtigungen|"#
            + #"Medikamenten|Erweiterte)\b"#,
        options: [.caseInsensitive]
    )

    nonisolated static func looksGerman(_ literal: String) -> Bool {
        if literal.rangeOfCharacter(from: CharacterSet(charactersIn: "äöüÄÖÜß")) != nil { return true }
        guard let regex = germanWords else { return false }
        return regex.firstMatch(in: literal, range: NSRange(literal.startIndex..., in: literal)) != nil
    }

    // MARK: - Tests

    @Test("Der Scan sieht die Dateien überhaupt — ein Zähler, der nichts zählt, ist kein Test")
    func scanSeesTheScreen() throws {
        #expect(try Self.source(Self.screenPath).contains("struct NotificationDiagnosticsScreen"))
        #expect(try Self.source(Self.supportPath).contains("struct SettingsSupportDiagnosticsScreen"))

        var all = 0
        var keys = 0
        for path in Self.surfacePaths {
            let text = try Self.source(path)
            all += Self.literals(in: text).count
            keys += Self.userFacingKeys(in: text).count
        }
        #expect(
            all > 40,
            "Nur \(all) Literale gefunden — der Scanner ist kaputt, nicht die Fläche sauber."
        )
        #expect(
            keys >= 45,
            """
            Nur \(keys) nutzersichtbare Literale über die ganze Diagnose-Fläche extrahiert \
            (U10 hat 50 auf einem Bildschirm gezählt; 08-15 hat die Fläche auf zwei \
            aufgeteilt, ohne Text zu verlieren). Entweder ist wieder etwas verschoben \
            worden — dann `surfacePaths` nachziehen — oder der Extraktor greift nicht \
            mehr; in beiden Fällen prüft der Test darunter nichts mehr.
            """
        )
    }

    @Test("Jeder nutzersichtbare Text der Diagnose-Fläche ist ein Katalogschlüssel mit de UND en")
    func jederNutzertextIstEinKatalogschlüssel() throws {
        let catalog = try ParityCatalog.load()
        var missing: [String] = []
        var halfTranslated: [String] = []

        for path in Self.surfacePaths {
            for literal in try Self.userFacingKeys(in: Self.source(path)) {
                let candidates = Self.derivedKeyCandidates(literal.value)
                guard let key = candidates.first(where: { catalog.strings[$0] != nil }),
                      let entry = catalog.strings[key] else
                {
                    missing.append("  • \(path):\(literal.line)  \"\(literal.value)\"")
                    continue
                }
                let de = ParityCatalog.value(entry, language: "de")
                let en = ParityCatalog.value(entry, language: "en")
                if de == nil || en == nil {
                    halfTranslated
                        .append("  • \(key)  (de: \(de == nil ? "FEHLT" : "ok"), en: \(en == nil ? "FEHLT" : "ok"))")
                }
            }
        }

        #expect(
            missing.isEmpty,
            """
            \(missing.count) nutzersichtbare Literale ohne Katalogeintrag:
            \(missing.joined(separator: "\n"))

            PROJECT_GUIDE.md: keine hardcodierten UI-Strings. Der Text gehört als englischer \
            Quellschlüssel mit de+en nach HealthLog/Resources/Localizable.xcstrings — \
            nicht in eine Allowlist.
            """
        )
        #expect(
            halfTranslated.isEmpty,
            """
            \(halfTranslated.count) Schlüssel dieses Bildschirms sind nur halb übersetzt:
            \(halfTranslated.joined(separator: "\n"))

            DE ist primär, EN Parität (PROJECT_GUIDE.md). Ein halb übersetzter Schlüssel \
            rendert auf der fehlenden Seite den rohen Schlüssel.
            """
        )
    }

    @Test("Kein deutsches Quell-Literal — der Katalog ist sourceLanguage: en")
    func keineDeutschenLiterale() throws {
        var offenders: [String] = []
        for path in Self.surfacePaths {
            try offenders.append(contentsOf: Self.literals(in: Self.source(path))
                .filter { Self.looksGerman($0.value) }
                .map { "  • \(path):\($0.line)  \"\($0.value)\"" })
        }
        #expect(
            offenders.isEmpty,
            """
            \(offenders.count) deutsche Quell-Literale:
            \(offenders.joined(separator: "\n"))

            Der Katalog ist `sourceLanguage: en`. Ein deutsches Literal leitet einen \
            deutschen Schlüssel ab, den der Katalog nicht kennt — er rendert roh, und \
            zwar in BEIDEN Sprachen. Englischen Quellschlüssel verwenden, DE im Katalog.
            """
        )
    }

    @Test("Die Zeilenbeschriftungen laufen über LocalizedStringKey, nicht über den verbatim-Text-Initializer")
    func labeledRowTitleIstLokalisiert() throws {
        // 08-15: `SupportDetailRow` is the same primitive on the other half of
        // the surface and inherits the same defect if its `title` regresses.
        for path in Self.surfacePaths {
            let text = try Self.source(path)
            #expect(
                text.contains("let title: LocalizedStringKey"),
                """
                Das Zeilen-Primitive in \(path) trägt keinen `LocalizedStringKey`-Titel mehr. \
                `Text(_ content: some StringProtocol)` lokalisiert NICHT — jede \
                Zeilenbeschriftung würde ihr Quell-Literal wörtlich rendern, auch wenn ein \
                Katalogeintrag existiert. Genau das war der U10-Befund.
                """
            )
            #expect(
                !text.contains("let title: String"),
                "Das Zeilen-Primitive in \(path) trägt wieder einen `String`-Titel — siehe oben."
            )
        }
    }

    @Test("Die Einstiegszeile und der Seitentitel teilen einen Schlüssel, der de UND en trägt")
    func einstiegszeileIstLokalisiert() throws {
        let catalog = try ParityCatalog.load()
        let entry = try #require(
            catalog.strings[Self.entryKey],
            "Der Schlüssel \"\(Self.entryKey)\" fehlt im Katalog."
        )
        #expect(ParityCatalog.value(entry, language: "de") != nil, "\(Self.entryKey): keine deutsche Fassung.")
        #expect(ParityCatalog.value(entry, language: "en") != nil, "\(Self.entryKey): keine englische Fassung.")

        let entrySource = try Self.source(Self.entryPath)
        #expect(
            entrySource.contains("Label(\"\(Self.entryKey)\", systemImage: \"stethoscope\")"),
            "Die Einstiegszeile in \(Self.entryPath) nennt \"\(Self.entryKey)\" nicht mehr."
        )
        let screen = try Self.source(Self.screenPath)
        #expect(
            screen.contains("HLSettingsPage(title: \"\(Self.entryKey)\")"),
            """
            Seitentitel und Einstiegszeile sind auseinandergelaufen. R3: die Zeile \
            verspricht, wie die Seite heißt — beide hängen an einem Schlüssel.
            """
        )
    }

    @Test("Die Fläche enthält keine mehrzeiligen Literale — der Scanner unterstützt sie nicht")
    func enthältNurEinzeiligeLiterale() throws {
        let text = try Self.surfacePaths.map { try Self.source($0) }.joined(separator: "\n")
        #expect(
            !text.contains("\"\"\""),
            """
            Ein `\"\"\"`-Literal ist dazugekommen. `literals(in:)` zerlegt es in \
            Bruchstücke, und die Prüfungen darüber werden still unscharf. Entweder das \
            Literal einzeilig halten oder den Scanner erweitern (Vorlage: die \
            `multiline_value`-Rekonstruktion in scripts/check-strings.sh).
            """
        )
    }
}
