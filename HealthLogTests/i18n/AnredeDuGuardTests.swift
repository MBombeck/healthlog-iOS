import Foundation
import Testing

/// Build-8 (b239) coherence guard — pins the **du-Anrede** convention across the
/// whole German catalog.
///
/// HealthLog addresses the user informally ("du"), matching the web client. A
/// stray "Sie"/"Ihre"/"Ihnen" reads as a jarring register switch. This guard
/// parses the raw `Localizable.xcstrings` (via `ParityCatalog`) and fails on any
/// German value that uses the formal address — with two **named** exception
/// lists carried in code (not regex magic) so the intent stays auditable.
///
/// ## The rule (per REST-PLAN §2, item 8.9.3)
/// For every German value whose key is not exempt, a violation is any of:
///  - `\b(Ihnen|Ihrem|Ihren|Ihrer|Ihres)\b` **anywhere** — these dative/genitive
///    forms are unambiguously formal address.
///  - `\bSie\b` / `\bIhr(e)?\b` that is **not at a sentence start**. German
///    capitalises the anaphoric pronoun "Sie" ("it/they", referring back to a
///    feminine/plural noun) identically to the formal "Sie", but the anaphoric
///    reading only occurs sentence-initially ("… Die Strecke. **Sie** ergänzt
///    die Schritte."). A mid-sentence "Sie"/"Ihre" is therefore the formal
///    address we forbid. The heuristic is deliberately conservative: false
///    positives land on `anaphoraAllowlist` (visible + reviewed), false
///    negatives are caught by the device walkthrough.
///
/// ## ⚠️ UNVERHANDELBAR — validated instruments are exempt
/// The German PHQ-9 / GAD-7 (and, per Operator decision E-4, WHO-5 / SCI) items,
/// their shared answer options, and the shared question stems are the
/// **validated** clinical instrument wording. They siez *by design* — identical
/// to the web keys `items.phq9.*` / `items.gad7.*` — and changing them would
/// invalidate the screening. `validatedInstrumentKeys` names them explicitly;
/// the Anrede-Guard must NEVER treat their "Sie" as a violation.
@Suite("Anrede-Guard — du-Konvention über den DE-Katalog (validierte Instrumente ausgenommen)")
struct AnredeDuGuardTests {
    // MARK: - Exception list 1 — validated clinical instruments (UNVERHANDELBAR)

    /// Key prefixes whose German wording is a validated screening instrument and
    /// therefore exempt from the du-sweep. PHQ-9 / GAD-7 / their shared options
    /// and stem are the plan's hard requirement; WHO-5 / SCI / their options and
    /// stems are added per Operator decision E-4 (same class of validated
    /// instrument — a blanket rewrite over them would be the same mistake).
    static let validatedInstrumentKeyPrefixes: [String] = [
        "mentalHealth.items.phq9.",
        "mentalHealth.items.gad7.",
        "mentalHealth.items.who5.",
        "mentalHealth.items.sci.",
        "mentalHealth.options.",
        "mentalHealth.who5Options.",
        "mentalHealth.sciOptions.",
        "mentalHealth.stems."
    ]

    /// Exact validated-instrument keys that are not covered by a prefix.
    static let validatedInstrumentExactKeys: Set<String> = [
        "mentalHealth.stem",
        "mentalHealth.stem.who5"
    ]

    // MARK: - Exception list 2 — curated anaphora allowlist

    /// Keys whose German value contains a **legitimate anaphoric "Sie/Ihre"**
    /// ("it/they", not formal address) that the sentence-start heuristic already
    /// tolerates — listed explicitly so the intent is reviewed, per the plan's
    /// curated seed. Any new false positive from the heuristic is added here
    /// (visible in review), never worked around by loosening the rule.
    static let anaphoraAllowlist: Set<String> = [
        "insights.metric.distanceWalkingRunning.description",
        "insights.metric.walkingSpeed.description",
        "insights.subPage.explainer.walkingDistanceBody",
        "insights.subPage.explainer.walkingSpeedBody",
        "med.layout.order.section.footer",
        "nightscout.formIntro",
        "settings.applehealth_import.privacy_upload"
    ]

    // MARK: - Regexes

    /// Dative / genitive formal-address forms — forbidden anywhere.
    private nonisolated(unsafe) static let dativeGenitive = #/\b(?:Ihnen|Ihrem|Ihren|Ihrer|Ihres)\b/#
    /// Nominative/accusative "Sie" and possessive "Ihr"/"Ihre" — forbidden only
    /// away from a sentence start (anaphoric use is sentence-initial).
    private nonisolated(unsafe) static let sieOrIhr = #/\b(?:Sie|Ihre|Ihr)\b/#

    // MARK: - Helpers (nonisolated for @Sendable test closures)

    private nonisolated static func isExempt(_ key: String) -> Bool {
        if validatedInstrumentExactKeys.contains(key) { return true }
        if anaphoraAllowlist.contains(key) { return true }
        for prefix in validatedInstrumentKeyPrefixes where key.hasPrefix(prefix) {
            return true
        }
        return false
    }

    /// True when the character run immediately before `index` marks a sentence
    /// boundary (string start, or terminal punctuation `. ! ? … :` / bullet /
    /// newline followed by whitespace), so a "Sie" there reads as anaphoric.
    private nonisolated static func isAtSentenceStart(_ text: String, _ index: String.Index) -> Bool {
        var i = index
        while i > text.startIndex {
            let prev = text.index(before: i)
            if text[prev].isWhitespace { i = prev
                continue
            }
            return ".!?…:•\n".contains(text[prev])
        }
        return true // reached string start
    }

    /// Returns a short reason string when `value` violates the du-convention,
    /// else `nil`.
    private nonisolated static func violation(in value: String) -> String? {
        if let match = value.firstMatch(of: dativeGenitive) {
            return "formal dative/genitive: '\(match.output)'"
        }
        for match in value.matches(of: sieOrIhr)
            where !isAtSentenceStart(value, match.range.lowerBound)
        {
            return "mid-sentence formal address: '\(match.output)'"
        }
        return nil
    }

    // MARK: - Tests

    @Test("Kein deutscher Katalog-Wert siezt (außer validierte Instrumente + Anaphora-Allowlist)")
    func germanCatalogUsesDuAddress() throws {
        let catalog = try ParityCatalog.load()
        var offenders: [String] = []
        for (key, entry) in catalog.strings {
            if Self.isExempt(key) { continue }
            guard let value = ParityCatalog.value(entry, language: "de") else { continue }
            if let reason = Self.violation(in: value) {
                let snippet = value.prefix(72)
                offenders.append("\(key) — \(reason) :: \(snippet)")
            }
        }
        #expect(
            offenders.isEmpty,
            "Deutsche Werte mit Sie-Anrede (\(offenders.count)): \(offenders.sorted().prefix(20))"
        )
    }

    @Test("Validierte Instrument-Keys existieren + dürfen weiter siezen (Ausnahmeliste nicht verrottet)")
    func validatedInstrumentsRemainExempt() throws {
        let catalog = try ParityCatalog.load()
        // Sanity: the exact stem keys and at least the PHQ-9/GAD-7 item prefixes
        // still resolve to catalog entries — so the exemption list cannot silently
        // point at renamed/removed keys while the guard "passes" vacuously.
        for key in Self.validatedInstrumentExactKeys {
            #expect(catalog.strings[key] != nil, "Validated-instrument exempt key vanished: \(key)")
        }
        let hasPhq9 = catalog.strings.keys.contains { $0.hasPrefix("mentalHealth.items.phq9.") }
        let hasGad7 = catalog.strings.keys.contains { $0.hasPrefix("mentalHealth.items.gad7.") }
        #expect(hasPhq9, "PHQ-9 item keys vanished — exemption list is stale")
        #expect(hasGad7, "GAD-7 item keys vanished — exemption list is stale")
    }

    @Test("Heuristik-Selbsttest: anaphorisches sentence-initial 'Sie' ist erlaubt, mid-sentence nicht")
    func heuristicSelfCheck() {
        // Anaphoric — allowed (sentence-initial after a period).
        #expect(Self.violation(in: "Die Strecke zählt. Sie ergänzt die Schritte.") == nil)
        // Formal address — forbidden (mid-sentence "Sie").
        #expect(Self.violation(in: "Der Wert ordnet Sie einer Kategorie zu.") != nil)
        // Formal possessive — forbidden.
        #expect(Self.violation(in: "spiegelt Ihren Zustand wider") != nil)
        // Substring is not a word boundary — "Familie"/"Sieb" must not trip it.
        #expect(Self.violation(in: "Deine Familie und ein Sieb.") == nil)
    }
}
