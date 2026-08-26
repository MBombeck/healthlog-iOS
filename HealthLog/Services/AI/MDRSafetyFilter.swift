import Foundation

/// Post-generation MDR safety filter.
///
/// Mirrors the server's `mdr_no_predictive_copy` / `mdr_no_clinical_recommendation`
/// SwiftLint families and the 15-pattern matrix in R4 §5. The model has been
/// instructed (system prompt) to avoid these patterns, but the filter is the
/// belt-and-braces guarantee: if any forbidden pattern still slips through,
/// the briefing is rewritten into a neutral refusal shell.
///
/// The filter operates on plain Swift strings so it works against both the
/// `@Generable OnDeviceBriefing` (iOS 26+) and the legacy server-AI surfaces
/// when reused (R4 §5.2). Logging stays PII-free — never log raw output text.
public actor MDRSafetyFilter {
    /// Regex pattern + the matrix row in R4 §5 it covers.
    private struct Pattern {
        let regex: NSRegularExpression
        let matrixRow: Int
        let label: String
    }

    /// 20-pattern matrix per R4 §5.1 (15 base rows from I-1 + 5 Mini-Coach
    /// extensions added in C2). Each entry is annotated with the pattern
    /// row in the safety matrix so reviewers can cross-reference.
    /// Patterns 1-6, 10, 12, 13, 15 are SAFE — no regex needed (positive
    /// allow-list lives in the prompt template). The base entries cover
    /// the 5 UNSAFE rows (7, 8, 9, 11, 14). The Mini-Coach extensions
    /// (matrixRow 0 = pan-row prompt-injection guard; 8 = implicit-advice
    /// softeners; 9 = reflective-suggestive condition floating) close
    /// gaps the conversational surface re-opens that the briefing
    /// (one-shot, no user echo) didn't have.
    private static let patterns: [Pattern] = // swiftlint:disable force_try
        [
            // Row 7 — Predictive language ("wird steigen", "wird morgen steigen", "will rise", "predicted peak")
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b(wird|werden|werde|wirst)\b[^.!?]{0,40}\b(steigen|sinken|peak|trough|ansteigen|abfallen)"#,
                    options: .caseInsensitive
                ),
                matrixRow: 7,
                label: "predictive_de"
            ),
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b(will\s+rise|will\s+fall|predicted\s+(peak|trough|level)|expected\s+to\s+(rise|fall|spike))\b"#,
                    options: .caseInsensitive
                ),
                matrixRow: 7,
                label: "predictive_en"
            ),
            // Row 8 — Dose / treatment advice
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b(empfehl(e|en|et)?|musst\s+\w+\s+nehmen|solltest\s+(deine|den|die)\s+(Dosis|Tablette|Spritze)|increase\s+your\s+dose|decrease\s+your\s+dose|step\s+up|escalate)\b"#,
                    options: .caseInsensitive
                ),
                matrixRow: 8,
                label: "prescriptive"
            ),
            // Row 9 — Diagnostic claim
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b(Hypertonie|Hypotonie|Diabetes|Arrhythmie|Vorhofflimmern|Hyperthyreose|Hypothyreose|hypertension|arrhythmia)\b"#
                        + #".{0,40}(deutet|hin|diagnose|leidest|hast\s+eine|suggests|indicates|diagnosed)"#,
                    options: .caseInsensitive
                ),
                matrixRow: 9,
                label: "diagnostic"
            ),
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b(Diagnose|du\s+leidest\s+an|du\s+hast\s+eine\s+Krankheit|you\s+have\s+(a\s+condition|hypertension|diabetes))\b"#,
                    options: .caseInsensitive
                ),
                matrixRow: 9,
                label: "diagnostic_direct"
            ),
            // Row 11 — Causal medical claim
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b(verursacht|kausal|hat\s+Schuld|liegt\s+an|because\s+of\s+your|caused\s+by\s+your)\b.{0,30}(Blutdruck|Stress|Puls|Schlaf|blood\s+pressure|stress|pulse|sleep)"#,
                    options: .caseInsensitive
                ),
                matrixRow: 11,
                label: "causal"
            ),
            // Row 14 — Drug-level interpretation (GROUND RULE 10/15 universal)
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b(Wirkstoffspiegel|Wirkspiegel|drug\s+level|peak\s+jetzt|aktuell\s+am\s+Peak|Trough\s+gerade|currently\s+peaking)\b"#,
                    options: .caseInsensitive
                ),
                matrixRow: 14,
                label: "drug_level"
            ),
            // Row 7 (extended) — German "krank"/"Krankheit" diagnostic shorthand
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b(du\s+bist\s+krank|you\s+are\s+(sick|ill)|Krankheitsbild)\b"#,
                    options: .caseInsensitive
                ),
                matrixRow: 9,
                label: "sick_claim"
            ),
            // Row 8 (extended) — therapy change suggestion
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b(Therapie\s+(ändern|anpassen|umstellen)|change\s+your\s+(therapy|medication|treatment))\b"#,
                    options: .caseInsensitive
                ),
                matrixRow: 8,
                label: "therapy_change"
            ),
            // Row 7 (extended) — future-tense risk claim
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b(Risiko\s+für|risk\s+of)\s+\w*(Schlaganfall|Herzinfarkt|stroke|heart\s+attack)"#,
                    options: .caseInsensitive
                ),
                matrixRow: 7,
                label: "future_risk"
            ),
            // Row 9 (extended) — symptom-to-diagnosis bridge
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b(deine\s+Werte|your\s+values?|your\s+readings?)\b.{0,30}(deuten\s+auf|indicate|suggest)\s+\w+"#,
                    options: .caseInsensitive
                ),
                matrixRow: 9,
                label: "values_indicate"
            ),
            // Row 11 (extended) — explicit causality verb between metrics
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b(führt\s+zu|leads\s+to)\b.{0,40}(höher(em|en)?|niedriger(em|en)?|Anstieg|Abfall|increase|decrease)"#,
                    options: .caseInsensitive
                ),
                matrixRow: 11,
                label: "leads_to"
            ),
            // Row 8 (extended) — "you need to take" prescriptive
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b(du\s+(musst|solltest)\s+jetzt|you\s+(must|should)\s+now\s+take)\b"#,
                    options: .caseInsensitive
                ),
                matrixRow: 8,
                label: "must_take_now"
            ),
            // Row 14 (extended) — interpret half-life / PK
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b(Halbwertszeit|half-life|pharmacokinetic|Plasmaspiegel)\b.{0,30}(deutet|interpretiert|indicates)"#,
                    options: .caseInsensitive
                ),
                matrixRow: 14,
                label: "pharmacokinetic"
            ),
            // Row 9 (extended) — direct condition assertion
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b(du\s+hast\s+(Bluthochdruck|Diabetes|Herzrhythmusstörungen)|you\s+have\s+(high\s+blood\s+pressure|diabetes))\b"#,
                    options: .caseInsensitive
                ),
                matrixRow: 9,
                label: "direct_condition"
            ),
            // Row 8 (Mini-Coach C2 extension) — implicit advice / "it
            // would be good if…" softener phrasing. The reflective
            // surface refuses recommendations even when wrapped in
            // counterfactual / softened language.
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b(es\s+w[äa]re\s+(gut|besser|sinnvoll|ratsam)\s+wenn\s+du|"#
                        + #"du\s+k[öo]nntest\s+(versuchen|probieren)\s+\w*\s*(weniger|mehr)|"#
                        + #"du\s+solltest\s+(mal|vielleicht|eventuell))\b"#,
                    options: .caseInsensitive
                ),
                matrixRow: 8,
                label: "implicit_advice_de"
            ),
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b(it\s+(would\s+be|might\s+be)\s+(good|better|wise)\s+(if\s+you|to)|you\s+could\s+(try|consider)\s+\w*\s*(less|more)|maybe\s+you\s+should|perhaps\s+you\s+ought)\b"#,
                    options: .caseInsensitive
                ),
                matrixRow: 8,
                label: "implicit_advice_en"
            ),
            // Row 9 (Mini-Coach C2 extension) — reflective-suggestive:
            // the model floats a condition as a *possibility* ("könnte
            // … sein") rather than asserting it directly. Still a
            // diagnostic claim under MDR.
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\bk[öo]nnte\b[^.!?]{0,60}\b"#
                        + #"(Hypertonie|Hypotonie|Diabetes|Arrhythmie|Apnoe|Erkrankung|Mangel)"#,
                    options: .caseInsensitive
                ),
                matrixRow: 9,
                label: "reflective_suggestive_de"
            ),
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b(m[öo]glicherweise\s+(hast\s+du|liegt\s+eine))\b"#,
                    options: .caseInsensitive
                ),
                matrixRow: 9,
                label: "reflective_possibly_de"
            ),
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b(could|might)\b[^.!?]{0,60}\b"#
                        + #"(hypertension|diabetes|arrhythmia|apnea|disorder|deficiency)\b"#,
                    options: .caseInsensitive
                ),
                matrixRow: 9,
                label: "reflective_suggestive_en"
            ),
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\bpossibly\s+(you\s+have|a\s+sign\s+of)\b"#,
                    options: .caseInsensitive
                ),
                matrixRow: 9,
                label: "reflective_possibly_en"
            ),
            // R4 §5 (Mini-Coach C2 extension) — prompt-injection
            // marker. If the *output* ever echoes "ignore previous
            // instructions" or similar role-override copy, the filter
            // refuses on principle: the model has been steered.
            // Symmetric to the deny-list in MiniCoachAskClassifier
            // (which guards inputs); this guards outputs.
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"(ignore\s+(previous|prior|all)\s+(instructions|rules|prompt)|"#
                        + #"ignoriere\s+(alle|die)\s+(anweisungen|regeln)|"#
                        + #"disregard\s+(your|the)\s+(rules|instructions)|"#
                        + #"vergiss\s+(deine|die)\s+(regeln|anweisungen))"#,
                    options: .caseInsensitive
                ),
                matrixRow: 0,
                label: "prompt_injection_marker"
            )
        ]
    // swiftlint:enable force_try

    public init() {}

    /// Number of patterns in the matrix. Used by tests to verify the matrix
    /// is complete (R4 §5.1 + AC13).
    public static var patternCount: Int {
        patterns.count
    }

    /// Returns the matrix row a hypothetical match would belong to. Used by
    /// tests to assert pattern coverage.
    public static func matrixRows() -> Set<Int> {
        Set(patterns.map(\.matrixRow))
    }

    /// Returns true if any forbidden pattern matches in the given text.
    /// Safe to call from anywhere (no PII surfaced — caller log is
    /// responsible).
    public func containsForbiddenPattern(in text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let range = NSRange(text.startIndex..., in: text)
        for pattern in Self.patterns where pattern.regex.firstMatch(in: text, range: range) != nil {
            // Static regulatory-matrix metadata (row id + label) — never model/user text.
            // swiftlint:disable:next hllog_public_privacy_interpolation
            HLLog.api.error(
                "MDRSafetyFilter blocked output (matrix row \(pattern.matrixRow, privacy: .public), label \(pattern.label, privacy: .public))"
            )
            return true
        }
        return false
    }

    /// Scrub a briefing in place. If any text field contains a forbidden
    /// pattern, replace the briefing with a neutral refusal shell rather
    /// than throwing — the caller (store) keeps rendering, the user sees a
    /// calm empty-state message, no flagged content reaches the view.
    public func scrub(_ briefing: BriefingTextProvider) -> ScrubResult {
        let texts = briefing.allTextFields
        for text in texts where containsForbiddenPattern(in: text) {
            return .refused(reason: .mdrPatternMatch)
        }
        return .passed
    }

    public enum ScrubResult: Sendable, Equatable {
        case passed
        case refused(reason: RefusalReason)
    }

    public enum RefusalReason: Sendable, Equatable {
        /// The model returned text that tripped one of the MDR patterns.
        case mdrPatternMatch
    }
}

/// Protocol allowing both `@Generable OnDeviceBriefing` (iOS 26+) and the
/// fallback shell (iOS 18-25) to feed the filter without conditional
/// compilation in callers.
public protocol BriefingTextProvider: Sendable {
    var allTextFields: [String] { get }
}

extension OnDeviceBriefing: BriefingTextProvider {
    public var allTextFields: [String] {
        [summary] + keyFindings + actionableNudges
    }
}
