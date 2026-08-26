import Foundation

/// User-confirmable medication draft pre-filled from a photo.
///
/// **Not a clinical claim** — every field is a TEXT-EXTRACTION suggestion
/// the user must verify and accept before any persistence call. The UX
/// surface reads "Erkanntes Medikament: ..." / "Bitte überprüfe und
/// bestätige" so the operator-philosophy "no auto-confirm, no clinical
/// language" is honoured at the data-shape level (R4 §5 MDR posture
/// extended to extraction).
///
/// **Provenance tracking:** `source` records which path produced the draft
/// so callers + tests can branch on "heuristic-only" (iOS 18-25) vs
/// "FoundationModels-assisted" (iOS 26+). The MDR safety filter runs on
/// the latter; the former is purely lexical and carries no AI-generated
/// language so the filter is moot.
public struct MedicationDraft: Sendable, Equatable {
    /// Best-guess product name. Required field — heuristic fills with the
    /// most prominent line; FoundationModels may rewrite for spelling.
    public var name: String
    /// Best-guess dose-strength (e.g. "500 mg", "0,5 mg", "10 IE"). May be
    /// `nil` when the OCR didn't surface a recognisable quantity-unit pair.
    public var doseStrength: String?
    /// Best-guess dose form ("Tablette", "Spritze", "Kapsel"). Often
    /// derived from a packaging keyword; `nil` when the OCR text lacks
    /// one of the recognised keywords.
    public var doseForm: String?
    /// Optional manufacturer hint surfaced for the user to disambiguate
    /// (two products with the same name from different makers). `nil` when
    /// the OCR text didn't include a manufacturer line.
    public var manufacturerHint: String?
    /// Which extraction path produced this draft.
    public var source: Source

    public enum Source: String, Sendable, Equatable {
        /// Pure regex/heuristic extraction (iOS 18+, no AI).
        case heuristic
        /// Apple FoundationModels structured-extraction (iOS 26+).
        case foundationModels
    }

    public init(
        name: String,
        doseStrength: String? = nil,
        doseForm: String? = nil,
        manufacturerHint: String? = nil,
        source: Source = .heuristic
    ) {
        self.name = name
        self.doseStrength = doseStrength
        self.doseForm = doseForm
        self.manufacturerHint = manufacturerHint
        self.source = source
    }
}

/// Heuristic OCR-text → `MedicationDraft` extractor.
///
/// **iOS 18-25 path.** No AI involved. Pure lexical analysis of the OCR
/// transcript:
///
/// 1. **Name guess** — the longest alpha-token line that is not a known
///    auxiliary keyword (dose-form, manufacturer-suffix, "Wirkstoff" etc.).
///    Falls back to the first non-empty line.
/// 2. **Dose-strength guess** — regex match for `<number><unit>` where
///    `<unit>` is one of the documented medication units (mg, g, µg, mcg,
///    IE, IU, ml).
/// 3. **Dose-form guess** — substring match against a known-keyword set.
/// 4. **Manufacturer guess** — line that ends with a recognised
///    manufacturer-suffix (GmbH, AG, Inc, Ltd, KG, Pharma).
///
/// The extractor is a value-type (struct with static methods) — no actor
/// because there is no shared state and the work is pure CPU-bound regex
/// evaluation that runs in <1 ms on the longest realistic OCR transcript.
public enum MedicationDraftHeuristic {
    /// Map a normalised OCR transcript into a `MedicationDraft`. Returns
    /// `nil` when the transcript has no usable text — caller routes to the
    /// "type manually" fallback.
    public static func extract(from rawText: String) -> MedicationDraft? {
        let lines = sanitisedLines(from: rawText)
        guard !lines.isEmpty else { return nil }

        let name = guessName(lines: lines) ?? lines[0]
        let doseStrength = guessDoseStrength(text: rawText)
        let doseForm = guessDoseForm(lines: lines)
        let manufacturer = guessManufacturer(lines: lines)
        return MedicationDraft(
            name: name,
            doseStrength: doseStrength,
            doseForm: doseForm,
            manufacturerHint: manufacturer,
            source: .heuristic
        )
    }

    // MARK: - Internals

    /// Normalises the OCR transcript: splits on newlines, trims whitespace,
    /// drops empty + single-character lines, drops pure-digit lines (lot
    /// numbers / expiry-date fragments often confuse the name picker).
    static func sanitisedLines(from rawText: String) -> [String] {
        rawText
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count > 1 && !$0.allSatisfy(\.isNumber) }
    }

    /// Heuristic: the medication name is typically the longest line whose
    /// tokens are mostly letters, *excluding* lines that look like a
    /// dose-form / manufacturer / metadata keyword.
    static func guessName(lines: [String]) -> String? {
        let candidates = lines.filter { line in
            let lower = line.lowercased()
            return !Self.doseFormKeywords.contains(where: { lower.contains($0.lowercased()) })
                && !Self.manufacturerSuffixes.contains(where: { lower.hasSuffix($0.lowercased()) })
                && !Self.metadataKeywords.contains(where: { lower.contains($0.lowercased()) })
                && line.contains(where: \.isLetter)
        }
        return candidates.max(by: { $0.count < $1.count })
    }

    /// Match the first `<number>[,.]<number>?<unit>` pattern in the
    /// transcript. Supports both `0,5 mg` (DE comma decimal) and `0.5 mg`
    /// (EN dot decimal). Units are case-insensitive but the returned
    /// substring preserves the original casing.
    static func guessDoseStrength(text: String) -> String? {
        // Allow optional whitespace between number + unit.
        let units = ["mg", "g", "µg", "mcg", "ug", "ie", "iu", "ml", "%"]
        let unitPattern = units.joined(separator: "|")
        // (?i) for case-insensitive on units; the number capture is
        // explicit-digit + optional decimal so we don't grab phone numbers.
        let pattern = #"(?i)\b(\d{1,4}([.,]\d{1,3})?)\s*("# + unitPattern + #")\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let r = Range(match.range, in: text) else { return nil }
        // Normalise inner whitespace: "10  mg" → "10 mg". Preserve the
        // original number-format ("0,5" stays "0,5", "0.5" stays "0.5") so
        // the de/en locale split downstream stays honest.
        let chunk = String(text[r])
        return chunk.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
    }

    /// Substring-scan: if any known dose-form keyword appears anywhere in
    /// the transcript, return the canonical form ("Tablette", "Spritze",
    /// "Kapsel", ...). The first match in keyword-priority order wins so
    /// "Tablette" beats "Filmtablette" beats "Retard".
    static func guessDoseForm(lines: [String]) -> String? {
        let combined = lines.joined(separator: " ").lowercased()
        return Self.doseFormKeywords.first { combined.contains($0.lowercased()) }
    }

    /// Manufacturer guess: any line ending in one of the recognised
    /// corporate suffixes. Returns the full line (so the user sees both
    /// the company name and the suffix). Returns `nil` when no line ends
    /// in a recognised suffix.
    static func guessManufacturer(lines: [String]) -> String? {
        lines.first { line in
            let lower = line.lowercased()
            return Self.manufacturerSuffixes.contains { lower.hasSuffix($0.lowercased()) }
        }
    }

    // MARK: - Lexicons

    /// Canonical dose-form keywords. Ordered: most-specific first so the
    /// `first { contains }` match in `guessDoseForm(...)` returns the
    /// finest-grain hit available.
    static let doseFormKeywords: [String] = [
        "Retardtablette",
        "Filmtablette",
        "Brausetablette",
        "Tablette",
        "Kapsel",
        "Spritze",
        "Injektion",
        "Tropfen",
        "Saft",
        "Salbe",
        "Pflaster",
        "Inhalation",
        "Suppositorium"
    ]

    /// Corporate suffixes that hint a manufacturer line (DE-primary, EN-secondary).
    static let manufacturerSuffixes: [String] = [
        "GmbH",
        "AG",
        "KG",
        "OHG",
        "Pharma",
        "Pharmaceuticals",
        "Inc",
        "Inc.",
        "Ltd",
        "Ltd.",
        "Corp",
        "Corp."
    ]

    /// Lexical noise: dose-strength + lot-number + expiry-date prefixes
    /// that should never be picked as the drug name. The picker drops any
    /// line containing one of these substrings.
    static let metadataKeywords: [String] = [
        "Wirkstoff",
        "PZN",
        "Charge",
        "Verfall",
        "verwendbar",
        "Lot",
        "EXP",
        "MFG",
        "Apotheker",
        "Reg.-Nr",
        "Zul.-Nr"
    ]
}
