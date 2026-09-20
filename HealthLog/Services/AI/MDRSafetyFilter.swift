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
        /// **R19b (1.0.3)** — the ways a match of this pattern can fail to
        /// count. Empty for every row that has no exemption, which is most.
        /// A match is excused if ANY of them excuses it.
        var exemptions: [Exemption] = []

        init(regex: NSRegularExpression, matrixRow: Int, label: String, exemptions: [Exemption] = []) {
            self.regex = regex
            self.matrixRow = matrixRow
            self.label = label
            self.exemptions = exemptions
        }
    }

    /// **R19b (1.0.3, App Review 1.4.1)** — the two ways a match can be the
    /// thing the app *wants* rather than the thing the matrix forbids.
    ///
    /// Both are deliberately different in scope, because the two false
    /// positives are different in kind. A citation's verb is forbidden only
    /// because of who its subject is, so the exemption has to attach to that
    /// verb — `overlapping`. A possibility handed to a clinician is forbidden
    /// only because of what stands next to it, so that exemption reads the
    /// sentence — `sentenceCarries`.
    private struct Exemption {
        enum Scope {
            /// The flagged token is itself part of the exempting phrase — the
            /// cited body IS the subject of the recommendation. Scoped to the
            /// match, so a second recommendation in the same sentence (this
            /// time addressed to the reader) is untouched.
            case overlappingMatch
            /// The sentence around the match carries the exempting phrase.
            case sentence
        }

        let scope: Scope
        let phrase: NSRegularExpression
        /// **Anti-laundering.** Never excuse when the sentence ALSO names one
        /// of these. Without it, "talk to your doctor" becomes a suffix that
        /// launders any advice at all — "Ich empfehle dir eine höhere Dosis,
        /// besprich das mit deiner Ärztin" would walk straight through. A
        /// hand-off is a substitute for advice, never a wrapper around it.
        var blockedBy: NSRegularExpression?
    }

    /// The concrete objects that make a recommendation a clinical instruction
    /// rather than a route to a clinician. Present in the sentence, no hand-off
    /// exemption applies.
    private static let concreteIntervention =
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"\b(Dosis|Dosierung|Tablette|Spritze|Therapie|Medikament\w*|"#
                + #"dose|dosage|tablet|medication|therapy|treatment)\b"#,
            options: .caseInsensitive
        )

    /// A recommendation whose subject is a named guideline body. The 1.4.1
    /// citation policy relies on these bodies; a filter
    /// that calls "Die ESH-Leitlinien empfehlen …" prescriptive advice refuses
    /// the citation itself.
    ///
    /// `recommends?` is what R23's `bare_recommend_en` row fires on, so this
    /// exemption is what keeps "WHO recommends 150 minutes …" out of the
    /// refusal path. `empfiehlt`/`empfehlen` guard nothing today (the German
    /// row-8 regex matches `empfehl` + e/en/et only); they are listed so the
    /// exemption stays correct if a later row widens.
    private static let citedBodyRecommends =
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"\b(Leitlinien?|ESH|ESC|AHA|ACC|ADA|WHO|EMA|guidelines?)\s+"#
                + #"(empfiehlt|empfehlen|recommends?|recommend)\b"#,
            options: .caseInsensitive
        )

    /// The clinician hand-off. **R21 widened it** with "talk to your doctor":
    /// the two new bare-prescriptive rows below are built from the same words as
    /// the hand-off sentence the prompt actually wants, so the exemption has to
    /// know every ordinary way of naming that route, not just "ask" and
    /// "discuss".
    ///
    /// R11 asks the model for "1-3 questions or
    /// observations the person can discuss with their doctor", so the sentence
    /// "ask your doctor whether this could point to hypertension" is not a
    /// diagnostic claim leaking through — it is the requested output shape.
    /// Without the possibility word the sentence never reaches the row-9
    /// patterns at all, so this exemption can only ever soften the pairing.
    private static let clinicianHandOff =
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"(ask\s+your\s+doctor|talk\s+to\s+your\s+(doctor|clinician)|"#
                + #"discuss(ing)?\s+(this\s+)?with\s+your\s+(doctor|clinician)|"#
                + #"mit\s+(deiner|Ihrer)\s+Ärztin|mit\s+(deinem|Ihrem)\s+Arzt|"#
                + #"ärztlich\s+(abklären|besprechen))"#,
            options: .caseInsensitive
        )

    /// The two row-8 exemptions, named once. Every recommendation row carries
    /// the same pair, so spelling the struct out at each call site only invited
    /// them to drift apart — which is precisely the bug fix round 1 found (the
    /// old `prescriptive` row had one of the two and behaved differently from
    /// its English twin as a result).
    private static var citationExemption: Exemption {
        Exemption(scope: .overlappingMatch, phrase: citedBodyRecommends, blockedBy: concreteIntervention)
    }

    private static var handOffExemption: Exemption {
        Exemption(scope: .sentence, phrase: clinicianHandOff, blockedBy: concreteIntervention)
    }

    /// The row-9 hand-off, WITHOUT the concrete-intervention guard: "this could
    /// point to hypertension, ask your doctor" names no intervention, and
    /// blocking on those words there would refuse ordinary talking points.
    private static var handOffExemptionUnguarded: Exemption {
        Exemption(scope: .sentence, phrase: clinicianHandOff)
    }

    /// 25-pattern matrix per R4 §5.1.
    ///
    /// **Arithmetic, corrected in fix round 2.** The header used to say
    /// "20-pattern matrix (15 base rows from I-1 + 5 Mini-Coach extensions)".
    /// The base was never 20: I-1 contributed 15 rows and C2 added **7**
    /// (`implicit_advice_de/en`, `reflective_suggestive_de/en`,
    /// `reflective_possibly_de/en`, `prompt_injection_marker`), so the matrix
    /// stood at **22** before 1.0.3. From there: R19b added **no** rows (it
    /// added exemptions to three existing ones), R21 added the two
    /// bare-prescriptive rows, and R23 added `bare_recommend_en` → **25**.
    /// `MDRSafetyFilterExemptionsTests.matrixSizeUnchanged` pins the total.
    /// Each entry is annotated with the pattern row in the safety matrix so
    /// reviewers can cross-reference.
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
                label: "prescriptive",
                // R19b — "Die ESH-Leitlinien empfehlen …" is a citation, not an
                // instruction. Scoped to the verb, so "…, und ich empfehle dir
                // eine höhere Dosis" in the same sentence still fires.
                // R23 — a citation cannot launder an instruction ("Die
                // Leitlinien empfehlen, deine Dosis zu erhöhen"). Fix round 1 —
                // this row also catches a bare "ich empfehle", so without the
                // hand-off exemption the German hand-off sentence was refused
                // while its English twin passed.
                exemptions: [citationExemption, handOffExemption]
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
                label: "reflective_suggestive_de",
                // R19b — paired with the clinician hand-off this IS the
                // talking-point form R11 asks the model to produce.
                exemptions: [handOffExemptionUnguarded]
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
                label: "reflective_suggestive_en",
                // R19b — see `reflective_suggestive_de`.
                exemptions: [handOffExemptionUnguarded]
            ),
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\bpossibly\s+(you\s+have|a\s+sign\s+of)\b"#,
                    options: .caseInsensitive
                ),
                matrixRow: 9,
                label: "reflective_possibly_en"
            ),
            // Row 8 (R23) — bare English "recommend(s)". R23 requires
            // "Guidelines recommend increasing your medication." to fire, and
            // adding `blockedBy` to the citation exemption could not achieve
            // that on its own: no row matched the sentence in the first place.
            // The row-8 regex has a bare German `empfehl…` but never had an
            // English twin, so every third-person English recommendation — the
            // shape a model reaches for when it attributes advice to someone —
            // walked through untouched. Carries both row-8 exemptions, so a
            // citation that names no intervention ("WHO recommends 150 minutes
            // of moderate activity per week.") still passes.
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\brecommends?\b"#,
                    options: .caseInsensitive
                ),
                matrixRow: 8,
                label: "bare_recommend_en",
                exemptions: [citationExemption, handOffExemption]
            ),
            // Row 8 (R21) — the bare imperative. Until 1.0.3 the matrix caught
            // "maybe you should" and "you should now take" but not the plain
            // "You should reduce your salt", and had no bare "I recommend" at
            // all — the simplest way of telling someone what to do was the one
            // shape that walked through. Both rows carry the R19b hand-off
            // exemption: the same words pointed at a clinician are the output
            // R11 asks for, not the output it forbids.
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b(you\s+should|you\s+need\s+to|you\s+ought\s+to|"#
                        + #"I(?:'d| would)?\s+recommend|I\s+suggest)\b"#,
                    options: .caseInsensitive
                ),
                matrixRow: 8,
                label: "bare_prescriptive_en",
                exemptions: [handOffExemption]
            ),
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b(du\s+solltest|Sie\s+sollten|ich\s+empfehle|ich\s+rate|"#
                        + #"ich\s+würde\s+.{0,40}empfehlen)\b"#,
                    options: .caseInsensitive
                ),
                // R21 amendment — the window between "würde" and "empfehlen" is
                // 40 characters, not 20: "Ich würde dir eine zweite Messung
                // empfehlen" needs 24, and an object of that length is ordinary
                // German rather than an edge case.
                matrixRow: 8,
                label: "bare_prescriptive_de",
                exemptions: [handOffExemption]
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
        for pattern in Self.patterns {
            guard hasCountingMatch(of: pattern, in: text, range: range) else { continue }
            // Static regulatory-matrix metadata (row id + label) — never model/user text.
            // swiftlint:disable:next hllog_public_privacy_interpolation
            HLLog.api.error(
                "MDRSafetyFilter blocked output (matrix row \(pattern.matrixRow, privacy: .public), label \(pattern.label, privacy: .public))"
            )
            return true
        }
        return false
    }

    /// Does this pattern have a match that its exemption does not excuse?
    ///
    /// **R19b (1.0.3).** A pattern with no exemption keeps the exact behaviour
    /// it had before — one `firstMatch` and done. Only the two exempted rows
    /// pay for enumerating their matches, and they have to: a single text can
    /// hold both an exempt occurrence and a real one ("Die Leitlinien empfehlen
    /// unter 135/85 mmHg, und ich empfehle dir eine höhere Dosis"), so the
    /// question is not "does the text match" but "is there a match left once
    /// the excused ones are removed".
    private func hasCountingMatch(of pattern: Pattern, in text: String, range: NSRange) -> Bool {
        guard !pattern.exemptions.isEmpty else {
            return pattern.regex.firstMatch(in: text, range: range) != nil
        }
        let matches = pattern.regex.matches(in: text, range: range)
        return matches.contains { match in
            !pattern.exemptions.contains { isExcused(match: match, by: $0, in: text, range: range) }
        }
    }

    private func isExcused(
        match: NSTextCheckingResult,
        by exemption: Exemption,
        in text: String,
        range: NSRange
    ) -> Bool {
        let sentence = Self.sentenceRange(around: match.range, in: text)
        if let blockedBy = exemption.blockedBy,
           blockedBy.firstMatch(in: text, range: sentence) != nil
        {
            return false
        }
        switch exemption.scope {
        case .overlappingMatch:
            // The flagged token must sit INSIDE the exempting phrase — the
            // cited body is the subject of this very verb.
            return exemption.phrase.matches(in: text, range: range).contains { candidate in
                NSIntersectionRange(candidate.range, match.range).length > 0
            }
        case .sentence:
            return exemption.phrase.firstMatch(in: text, range: sentence) != nil
        }
    }

    /// The sentence the match sits in, bounded by `.`, `!`, `?` or a line
    /// break. Deliberately crude — it only has to keep an exemption from
    /// reaching over a full stop into the next claim, which is exactly the
    /// case `handOffDoesNotExemptANeighbouringSentence` pins.
    private static func sentenceRange(around match: NSRange, in text: String) -> NSRange {
        let ns = text as NSString
        let terminators = CharacterSet(charactersIn: ".!?\n\r")
        var start = match.location
        while start > 0 {
            let scalar = ns.substring(with: NSRange(location: start - 1, length: 1))
            if scalar.unicodeScalars.allSatisfy(terminators.contains) { break }
            start -= 1
        }
        var end = match.location + match.length
        while end < ns.length {
            let scalar = ns.substring(with: NSRange(location: end, length: 1))
            if scalar.unicodeScalars.allSatisfy(terminators.contains) { break }
            end += 1
        }
        return NSRange(location: start, length: end - start)
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
