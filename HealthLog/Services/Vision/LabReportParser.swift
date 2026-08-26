import Foundation

/// One candidate lab reading extracted from a single OCR'd line of a paper lab
/// report. **A suggestion, never a commitment** — every field is shown to the
/// user in the scan-review screen and is editable + rejectable before anything
/// reaches the repository.
///
/// Deliberately mirrors the `LabResultCreate` shape (analyte / value /
/// valueText / unit / referenceLow / referenceHigh) so the review screen's
/// commit step is a field-for-field copy with no second interpretation layer.
///
/// **Qualitative rows stay qualitative.** Build 1 made `LabsDTO.value` optional
/// and added `valueText`; a row reading "negativ" therefore carries
/// `value == nil` + `valueText == "negativ"` and is NEVER coerced into a number.
public struct LabScanCandidate: Sendable, Equatable, Hashable {
    /// The analyte / test name as printed ("Ferritin", "Vitamin D (25-OH)").
    public var analyte: String
    /// The numeric reading, or `nil` for a qualitative / comparator row.
    public var value: Double?
    /// The qualitative result text ("negativ", "< 0,01"), or `nil` for a
    /// numeric row. Mutually exclusive with ``value``.
    public var valueText: String?
    /// The printed unit ("mg/dl", "µg/l", "%"), or `nil` when the line carried
    /// none (which is itself a review signal — see ``needsReview``).
    public var unit: String?
    public var referenceLow: Double?
    public var referenceHigh: Double?
    /// The verbatim OCR line this candidate came from. Kept so the review
    /// screen can show the user what was actually read off the paper.
    public var rawLine: String
    /// `true` when the parse was structurally weaker than a clean
    /// `analyte value unit range` row — no unit, a comparator result, or a
    /// suspiciously short analyte. The review screen flags these with
    /// `labs.scan.flag.lowConfidence`; it does NOT reject them, because a
    /// unit-less row (e.g. an index or a ratio) is perfectly legitimate.
    public var needsReview: Bool

    public init(
        analyte: String,
        value: Double? = nil,
        valueText: String? = nil,
        unit: String? = nil,
        referenceLow: Double? = nil,
        referenceHigh: Double? = nil,
        rawLine: String = "",
        needsReview: Bool = false
    ) {
        self.analyte = analyte
        self.value = value
        self.valueText = valueText
        self.unit = unit
        self.referenceLow = referenceLow
        self.referenceHigh = referenceHigh
        self.rawLine = rawLine
        self.needsReview = needsReview
    }

    /// `true` when this candidate carries a qualitative result rather than a
    /// number.
    public var isQualitative: Bool {
        !(valueText?.isEmpty ?? true)
    }
}

/// Pure, on-device parser turning the OCR transcript of a paper lab report into
/// candidate readings.
///
/// **Why this exists as a separate, pure type.** The scan pipeline has exactly
/// one risky component and it is this one: OCR reliably misreads decimal
/// separators, confuses `,` with `.`, and drops or mangles units. Everything
/// else in the flow (VisionKit capture, Vision text recognition, the repository
/// write) is Apple's code or already-shipped code. So the parser is separated
/// from every side effect — no image handling, no I/O, no actor, no `Locale`
/// dependency — and is covered by `LabReportParserTests`.
///
/// **Locale independence is deliberate.** `LocaleDecimalParser` (the entry-sheet
/// seam) parses against `Locale.current`, which is right for a field the *user
/// types into*. It is wrong here: a German lab report is read the same way on a
/// phone set to en-US, and the number on the paper does not change because of a
/// device setting. ``number(from:)`` therefore disambiguates from the token's own
/// shape only.
///
/// **The conservative separator rule.** A single `.` or `,` is ALWAYS read as a
/// decimal separator — so "250.000" parses as `250.0`, not `250000`. That is a
/// deliberate asymmetry: reading a grouping mark as a decimal understates a
/// value by 1000×, which is glaring in the review screen and gets corrected;
/// reading a decimal mark as grouping would silently inflate a value by 1000×
/// and look plausible. When both separators appear ("1.234,5") the LAST one is
/// the decimal mark and the other is grouping — that case is unambiguous.
/// Repeated separators of one kind ("1.234.567") are unambiguously grouping.
///
/// **Scope.** Single-line parsing only. A report that splits the analyte and its
/// value across two OCR lines (some two-column layouts) yields no candidate for
/// that reading — the user adds it by hand. Detecting that reliably needs
/// bounding-box geometry, which would trade a bounded miss for an unbounded
/// mis-association.
public enum LabReportParser {
    // MARK: - Public API

    /// Parse a whole OCR transcript (lines in reading order) into candidate
    /// readings. Lines that are not readings — headers, page markers, dates,
    /// addresses — yield nothing.
    public static func parse(lines: [String]) -> [LabScanCandidate] {
        lines.compactMap { parseLine($0) }
    }

    /// Convenience over the newline-joined transcript `MedicationOCRResult`
    /// (the shared on-device recogniser) produces.
    public static func parse(transcript: String) -> [LabScanCandidate] {
        parse(lines: transcript.components(separatedBy: .newlines))
    }

    /// Parse ONE line. Returns `nil` when the line is not a lab reading.
    ///
    /// The line is read left-to-right as `analyte… value [unit] [range]`, which
    /// is the layout every German and English lab report shares. Name tokens
    /// accumulate until the first token that is a bare number or a qualitative
    /// keyword; that token decides which of the two row shapes applies.
    public static func parseLine(_ line: String) -> LabScanCandidate? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return nil }
        guard !isHeaderLine(trimmed) else { return nil }
        guard !containsDate(trimmed) else { return nil }

        let tokens = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.count >= 2 else { return nil }

        var nameTokens: [String] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if qualitativePhrase(tokens, at: index) != nil { break }
            if numericPrefix(of: token) != nil { break }
            if comparatorResult(tokens: tokens, at: index) != nil { break }
            nameTokens.append(token)
            index += 1
            // A name longer than this is prose, not an analyte label.
            if nameTokens.count > 6 { return nil }
        }
        guard index < tokens.count else { return nil }

        let analyte = cleanAnalyte(nameTokens.joined(separator: " "))
        guard isPlausibleAnalyte(analyte) else { return nil }

        if let phrase = qualitativePhrase(tokens, at: index) {
            return LabScanCandidate(
                analyte: analyte,
                valueText: phrase,
                rawLine: trimmed,
                needsReview: false
            )
        }
        return numericCandidate(analyte: analyte, tokens: tokens, valueIndex: index, rawLine: trimmed)
    }

    // MARK: - Number parsing

    /// Parse a numeric token into a `Double`, disambiguating decimal vs.
    /// grouping separators from the token's own shape (see the type doc for the
    /// rule and why it leans the way it does). Returns `nil` for anything that
    /// is not a well-formed number.
    public static func number(from token: String) -> Double? {
        var body = token.trimmingCharacters(in: CharacterSet(charactersIn: "()[]{}:;"))
        guard !body.isEmpty else { return nil }

        var sign = 1.0
        if body.hasPrefix("-") {
            sign = -1
            body.removeFirst()
        } else if body.hasPrefix("+") {
            body.removeFirst()
        }
        guard let first = body.first, let last = body.last,
              first.isNumber, last.isNumber else { return nil }
        guard body.allSatisfy({ $0.isNumber || $0 == "." || $0 == "," }) else { return nil }
        // No "1..2" / "1,,2" and no "1.,2".
        var previousWasSeparator = false
        for character in body {
            let isSeparator = character == "." || character == ","
            if isSeparator, previousWasSeparator { return nil }
            previousWasSeparator = isSeparator
        }

        let dots = body.filter { $0 == "." }.count
        let commas = body.filter { $0 == "," }.count
        let normalized: String
        if dots > 0, commas > 0 {
            // Mixed: the LAST separator is the decimal mark, the other groups.
            let lastDot = body.lastIndex(of: ".")
            let lastComma = body.lastIndex(of: ",")
            let decimalIsComma = (lastComma.flatMap { comma in lastDot.map { comma > $0 } }) ?? true
            let grouping: Character = decimalIsComma ? "." : ","
            let decimal: Character = decimalIsComma ? "," : "."
            normalized = String(body.compactMap { character -> Character? in
                if character == grouping { return nil }
                return character == decimal ? "." : character
            })
        } else if dots + commas > 1 {
            // Repeated separators of ONE kind — unambiguously grouping.
            normalized = body.filter(\.isNumber)
        } else {
            // A single separator is always the decimal mark (see type doc).
            normalized = body.replacingOccurrences(of: ",", with: ".")
        }
        guard let magnitude = Double(normalized) else { return nil }
        return sign * magnitude
    }

    // MARK: - Numeric row assembly

    /// Build the numeric-row candidate from the token at `valueIndex` onwards.
    private static func numericCandidate(
        analyte: String,
        tokens: [String],
        valueIndex: Int,
        rawLine: String
    ) -> LabScanCandidate? {
        // A comparator result ("< 0,01") is NOT a number — dropping the "<"
        // would turn "below the assay limit" into a measured value. It is kept
        // verbatim as a qualitative result and flagged for review.
        if let comparator = comparatorResult(tokens: tokens, at: valueIndex) {
            return LabScanCandidate(
                analyte: analyte,
                valueText: comparator.text,
                unit: unitToken(tokens, at: comparator.nextIndex),
                rawLine: rawLine,
                needsReview: true
            )
        }
        guard let split = numericPrefix(of: tokens[valueIndex]),
              let value = number(from: split.number) else { return nil }

        var cursor = valueIndex + 1
        // `numericPrefix` only returns a suffix when it already IS a unit.
        var unit = split.suffix
        if unit == nil, let candidate = unitToken(tokens, at: cursor) {
            unit = candidate
            cursor += 1
        }
        let range = referenceRange(tokens: tokens, from: cursor)
        return LabScanCandidate(
            analyte: analyte,
            value: value,
            unit: unit,
            referenceLow: range?.low,
            referenceHigh: range?.high,
            rawLine: rawLine,
            needsReview: unit == nil
        )
    }

    /// `"< 0,01"` / `"<0,01"` starting at `index`, or `nil`.
    private static func comparatorResult(tokens: [String], at index: Int) -> (text: String, nextIndex: Int)? {
        let token = tokens[index]
        let comparators: Set<Character> = ["<", ">", "≤", "≥"]
        if let first = token.first, comparators.contains(first) {
            let rest = String(token.dropFirst())
            if rest.isEmpty {
                guard index + 1 < tokens.count, number(from: tokens[index + 1]) != nil else { return nil }
                return ("\(first) \(tokens[index + 1])", index + 2)
            }
            guard number(from: rest) != nil else { return nil }
            return (token, index + 1)
        }
        return nil
    }

    // MARK: - Reference range

    /// Scan the tail of the line for a reference range in any of the printed
    /// forms: `3,9-5,5`, `3,9 - 5,5`, `3,9 bis 5,5`, `< 200`, `> 40`.
    static func referenceRange(tokens: [String], from start: Int) -> (low: Double?, high: Double?)? {
        var index = max(0, start)
        while index < tokens.count {
            let token = tokens[index]
            // "3,9-5,5" / "0,27–4,20" as a single token.
            if let pair = splitRangeToken(token) { return (pair.low, pair.high) }
            // "3,9 - 5,5" / "3,9 bis 5,5" across three tokens.
            if let low = number(from: token), index + 2 < tokens.count,
               isRangeSeparator(tokens[index + 1]),
               let high = number(from: tokens[index + 2])
            {
                return (low, high)
            }
            // "< 200" / ">40".
            if let bound = boundToken(tokens: tokens, at: index) { return bound }
            index += 1
        }
        return nil
    }

    /// A one-token range like `3,9-5,5`. Splits on the first separator that sits
    /// between two digits so a leading minus sign is never mistaken for one.
    private static func splitRangeToken(_ token: String) -> (low: Double, high: Double)? {
        let separators: Set<Character> = ["-", "–", "—", "‒", "−"]
        let characters = Array(token)
        for position in 1 ..< max(1, characters.count) where separators.contains(characters[position]) {
            guard characters[position - 1].isNumber, position + 1 < characters.count else { continue }
            let low = String(characters[..<position])
            let high = String(characters[(position + 1)...])
            if let lowValue = number(from: low), let highValue = number(from: high) {
                return (lowValue, highValue)
            }
        }
        return nil
    }

    /// `"< 200"` → an upper bound; `"> 40"` → a lower bound.
    private static func boundToken(tokens: [String], at index: Int) -> (low: Double?, high: Double?)? {
        let token = tokens[index]
        let upper: Set<Character> = ["<", "≤"]
        let lower: Set<Character> = [">", "≥"]
        guard let first = token.first, upper.contains(first) || lower.contains(first) else { return nil }
        let rest = String(token.dropFirst())
        let numeric: Double? = if rest.isEmpty {
            index + 1 < tokens.count ? number(from: tokens[index + 1]) : nil
        } else {
            number(from: rest)
        }
        guard let bound = numeric else { return nil }
        return upper.contains(first) ? (nil, bound) : (bound, nil)
    }

    private static func isRangeSeparator(_ token: String) -> Bool {
        let folded = token.lowercased()
        return ["-", "–", "—", "‒", "−", "bis", "to", "..."].contains(folded)
    }

    // MARK: - Token classification

    /// Split a token into its leading number and an optional attached unit
    /// ("7,4mg/dl" → `("7,4", "mg/dl")`). Returns `nil` when the token does not
    /// start with a number — which is what keeps analyte names carrying digits
    /// ("Vitamin B12", "HbA1c", "Freies T4", "Omega-3-Index") out of the value
    /// slot: they start with a letter.
    static func numericPrefix(of token: String) -> (number: String, suffix: String?)? {
        let characters = Array(token)
        guard let first = characters.first else { return nil }
        var cursor = 0
        if first == "+" || first == "-" || first == "<" || first == ">" || first == "≤" || first == "≥" {
            cursor = 1
        }
        guard cursor < characters.count, characters[cursor].isNumber else { return nil }
        var end = cursor
        while end < characters.count,
              characters[end].isNumber || characters[end] == "." || characters[end] == ","
        {
            end += 1
        }
        // Trim a trailing separator ("45," at a line break) off the number part.
        var numberEnd = end
        while numberEnd > cursor, characters[numberEnd - 1] == "." || characters[numberEnd - 1] == "," {
            numberEnd -= 1
        }
        let numberPart = String(characters[..<numberEnd])
        let suffix = numberEnd < characters.count ? String(characters[numberEnd...]) : nil
        // "25-OH" / "12:30" are name tokens, not values: their suffix is not a unit.
        if let suffix, !suffix.isEmpty, !isUnitToken(suffix) { return nil }
        return (numberPart, suffix)
    }

    /// A unit token: printable unit characters only, at least one letter or `%`,
    /// never a bare number, never longer than a real unit is.
    static func isUnitToken(_ token: String) -> Bool {
        guard !token.isEmpty, token.count <= 14 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/%^*.·µμ°‰")
        guard token.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        return token.contains { $0.isLetter || $0 == "%" || $0 == "‰" }
    }

    /// The unit token at `index`, or `nil` when there is none there.
    private static func unitToken(_ tokens: [String], at index: Int) -> String? {
        guard index < tokens.count else { return nil }
        let token = tokens[index]
        guard isUnitToken(token) else { return nil }
        // A range word ("bis") sitting where the unit would be is not a unit.
        guard !isRangeSeparator(token) else { return nil }
        return token
    }

    // MARK: - Qualitative results

    /// The qualitative phrase starting at `index` ("negativ", "nicht
    /// nachweisbar", "schwach positiv"), or `nil`.
    private static func qualitativePhrase(_ tokens: [String], at index: Int) -> String? {
        guard index < tokens.count else { return nil }
        let head = fold(tokens[index])
        if Self.qualitativeModifiers.contains(head), index + 1 < tokens.count,
           Self.qualitativeTerms.contains(fold(tokens[index + 1]))
        {
            return "\(tokens[index]) \(tokens[index + 1])"
        }
        guard Self.qualitativeTerms.contains(head) else { return nil }
        return tokens[index]
    }

    /// Single-word qualitative results, diacritic- and case-folded.
    private static let qualitativeTerms: Set<String> = [
        "negativ", "negative", "positiv", "positive",
        "grenzwertig", "borderline", "fraglich",
        "nachweisbar", "reaktiv", "reactive", "detected",
        "unauffallig", "auffallig", "normal",
        "spuren", "trace", "none", "keine"
    ]

    /// Modifiers that bind to a following term ("nicht nachweisbar").
    private static let qualitativeModifiers: Set<String> = [
        "nicht", "non", "not", "schwach", "weak", "leicht", "stark", "strongly"
    ]

    // MARK: - Line rejection

    /// Header / metadata lines that carry no reading. Matched on the folded
    /// line so "Referenzbereich" and "REFERENZBEREICH" both hit.
    static func isHeaderLine(_ line: String) -> Bool {
        let folded = fold(line, keepSpaces: true)
        return Self.headerKeywords.contains { folded.contains($0) }
    }

    /// `true` when the line carries a printed date — `12.03.2026`, `2026-03-12`,
    /// `12/03/2026`, `12.03.26`. Such a line is a sampling / report date, not a
    /// reading, and its dotted form would otherwise be read as a number.
    static func containsDate(_ line: String) -> Bool {
        for token in line.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            let cleaned = String(token).trimmingCharacters(in: CharacterSet(charactersIn: "()[],;:"))
            for separator in ["." as Character, "/", "-"] {
                let parts = cleaned.split(separator: separator, omittingEmptySubsequences: false)
                guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { continue }
                let lengths = parts.map(\.count)
                // dd.mm.yyyy / dd.mm.yy / yyyy-mm-dd
                if lengths == [2, 2, 4] || lengths == [2, 2, 2] || lengths == [4, 2, 2] || lengths == [1, 1, 4] {
                    return true
                }
            }
        }
        return false
    }

    /// An analyte label has to look like one: at least two characters, at least
    /// one letter, and not a lone punctuation run.
    static func isPlausibleAnalyte(_ analyte: String) -> Bool {
        guard analyte.count >= 2 else { return false }
        guard analyte.contains(where: \.isLetter) else { return false }
        return analyte.filter(\.isLetter).count >= 2
    }

    /// Strip the trailing column punctuation lab printers add (":", "…", "|").
    private static func cleanAnalyte(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t:|.…-<>≤≥"))
            .trimmingCharacters(in: .whitespaces)
    }

    /// Case- and diacritic-folded lookup form.
    private static func fold(_ raw: String, keepSpaces: Bool = false) -> String {
        let folded = raw
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased()
        return folded.filter { $0.isLetter || $0.isNumber || (keepSpaces && $0 == " ") }
    }

    /// Report chrome. Kept deliberately broad on the metadata side — a rejected
    /// line costs the user one manual entry, an accepted junk line costs a
    /// wrong value in their record.
    private static let headerKeywords: [String] = [
        "laborbericht", "laboratory report", "befund", "patient", "geburtsdatum",
        "date of birth", "auftrag", "probenentnahme", "probeneingang", "eingang",
        "material", "seite", "page", "blatt", "referenzbereich", "reference range",
        "einheit", "unit", "ergebnis", "result", "analyse", "parameter", "labor",
        "praxis", "datum", "date", "untersuchung", "methode", "method", "validiert",
        "unterschrift", "signature", "arzt", "doctor", "telefon", "phone", "fax",
        "strasse", "street", "vorbefund", "kommentar", "comment", "bemerkung"
    ]
}
