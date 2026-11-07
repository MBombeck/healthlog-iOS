import Foundation

/// Pre-flight classifier that gates user input to the Mini-Coach (C1).
///
/// The classifier runs **before** the model is invoked. Anything that
/// doesn't fit one of the four ``MiniCoachPrompt/AllowedCategory`` rows
/// is refused immediately — no token spend, no inference call. This is
/// the first of the three safety lines around Mini-Coach:
///
/// 1. **Classifier (pre-flight)** — refuses out-of-scope asks (this file).
/// 2. **System prompt (mid-flight)** — instructs the contributor to refuse
///    out-of-scope asks itself.
/// 3. **MDR safety filter (post-flight)** — scrubs any prediction /
///    diagnostic / prescription that still slips through.
///
/// The classifier is **deliberately lexical** (NSRegularExpression on
/// `lowercased()` ask + locale-aware verb stems) — we explicitly do
/// **not** use the model to classify, because that would double the
/// inference cost per turn and re-open the prompt-injection surface
/// we are trying to close.
public actor MiniCoachAskClassifier {
    /// Classification verdict. `.allowed` carries the matched category
    /// for downstream telemetry / prompt-building; `.refused` carries a
    /// reason so the report layer can surface why.
    public enum Verdict: Sendable, Equatable {
        case allowed(MiniCoachPrompt.AllowedCategory)
        case refused(reason: RefusalReason)
    }

    public enum RefusalReason: String, Sendable, Equatable {
        /// The ask doesn't fit any allowlist category. Default refusal.
        case outOfScope
        /// The ask asks for advice ("what should I do?", "soll ich…").
        case adviceRequest
        /// The ask asks for prediction ("will my…", "wird mein…").
        case predictionRequest
        /// The ask looks like a prompt-injection attempt.
        case promptInjection
        /// The ask is empty after trimming.
        case emptyAsk
    }

    // MARK: - Pattern groups

    //
    // Each pattern is annotated with the allowed category it gates
    // *into*; the classifier scans the deny-list first (advice /
    // prediction / injection), then the allow-list. The deny-list rules
    // are intentionally permissive — when in doubt, refuse, because
    // the Mini-Coach is operator-locked to data lookup.

    private struct Pattern {
        let regex: NSRegularExpression
        let category: MiniCoachPrompt.AllowedCategory
        let label: String
    }

    private struct DenyPattern {
        let regex: NSRegularExpression
        let reason: RefusalReason
        let label: String
    }

    private static let denyPatterns: [DenyPattern] = // swiftlint:disable force_try
        [
            // Advice requests (ground rule — Mini-Coach never advises).
            DenyPattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b(was\s+soll(te)?\s+ich|soll\s+ich|was\s+w[üu]rdest\s+du|empfiehlst\s+du|wie\s+kann\s+ich\s+(besser|gesünder))"#,
                    options: .caseInsensitive
                ),
                reason: .adviceRequest,
                label: "advice_de"
            ),
            DenyPattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b(what\s+should\s+i|should\s+i|recommend|advice|what\s+would\s+you|how\s+can\s+i\s+(improve|be\s+healthier))"#,
                    options: .caseInsensitive
                ),
                reason: .adviceRequest,
                label: "advice_en"
            ),
            // Dutch advice + dose asks ("moet ik", "mag ik mijn dosis …",
            // "wat raad je aan"). "zal ik" sits here, not under prediction:
            // "Zal ik meer drinken?" asks what to do.
            DenyPattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b(wat\s+moet\s+ik|moet\s+ik|zal\s+ik|zou\s+ik\s+(moeten|beter)|wat\s+zou\s+(jij|je|u)|"#
                        + #"wat\s+raad\s+(je|jij|u)|raad\s+(je|jij|u)\s+(me|mij|aan)|adviseer\s+(je|jij|u)|advies|aanbevel\w*|"#
                        + #"mag\s+ik\s+[^.!?]{0,30}(dosis|dosering|medicatie|medicijn\w*|tablet\w*|pil\w*|innemen|nemen|stoppen|overslaan)|"#
                        + #"kan\s+ik\s+[^.!?]{0,30}(verhogen|verlagen|stoppen|overslaan|minderen|innemen)|"#
                        + #"hoe\s+kan\s+ik\s+(beter|gezonder|mijn\s+\w+\s+(verlagen|verhogen|verbeteren)))"#,
                    options: .caseInsensitive
                ),
                reason: .adviceRequest,
                label: "advice_nl"
            ),
            // Dutch diagnosis asks. German needs no twin: "Bluthochdruck" is
            // one word the metric fallback never matches, but Dutch "hoge
            // bloeddruk" contains "bloeddruk", so "Heb ik hoge bloeddruk?"
            // would otherwise be waved through as a data lookup.
            DenyPattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b(heb\s+ik\s+(\w+\s+)?(hoge\s+bloeddruk|hypertensie|diabetes|suikerziekte|(slaap)?apneu|"#
                        + #"boezemfibrilleren|hartritmestoornis\w*|een\s+(ziekte|aandoening|tekort))|ben\s+ik\s+ziek|"#
                        + #"lijd\s+ik\s+aan|diagnose|(wijst|duidt)\s+(dit|dat|het|mijn\s+\w+)\s+op)"#,
                    options: .caseInsensitive
                ),
                reason: .outOfScope,
                label: "diagnosis_nl"
            ),
            // Prediction requests.
            DenyPattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b(wird\s+[^.!?]{1,40}\b(steigen|sinken|ansteigen|abfallen)|"#
                        + #"werde\s+ich\s+\w+|wie\s+wird\s+mein|prognose|vorhersage)\b"#,
                    options: .caseInsensitive
                ),
                reason: .predictionRequest,
                label: "prediction_de"
            ),
            DenyPattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b(will\s+my\s+[^.!?]{1,40}?\b(rise|fall|go\s+up|go\s+down|increase|decrease|drop)|forecast|predict\s+my|"#
                        + #"what\s+will\s+(happen|my))\b"#,
                    options: .caseInsensitive
                ),
                reason: .predictionRequest,
                label: "prediction_en"
            ),
            DenyPattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b((zal|zullen|gaat|gaan)\s+[^.!?]{1,40}\b(stijgen|dalen|toenemen|afnemen|oplopen|zakken)|"#
                        + #"word\s+ik\s+\w+|hoe\s+(zal|gaat)\s+mijn|voorspel\w*|prognose|verwachting)\b"#,
                    options: .caseInsensitive
                ),
                reason: .predictionRequest,
                label: "prediction_nl"
            ),
            // Prompt-injection markers — bracketed instructions, role
            // overrides, "ignore previous". Same shape as the
            // MDRSafetyFilter row added in C2 but checked earlier on
            // the *input* side.
            DenyPattern(
                regex: try! NSRegularExpression(
                    pattern: #"(ignore\s+(previous|prior|all)\s+(instructions|rules|prompt)|disregard\s+(your|the)\s+(rules|instructions)|act\s+as\s+(if\s+you\s+are|a\s+different))"#,
                    options: .caseInsensitive
                ),
                reason: .promptInjection,
                label: "injection_en"
            ),
            DenyPattern(
                regex: try! NSRegularExpression(
                    pattern: #"(ignoriere\s+(alle|die)\s+(anweisungen|regeln)|vergiss\s+(deine|die)\s+(regeln|anweisungen)|tue\s+so\s+als\s+w[äa]rest\s+du)"#,
                    options: .caseInsensitive
                ),
                reason: .promptInjection,
                label: "injection_de"
            ),
            DenyPattern(
                regex: try! NSRegularExpression(
                    pattern: #"(negeer\s+(alle|de|je|jouw|vorige|eerdere)\s+((vorige|eerdere)\s+)?(instructies|regels|opdrachten|prompt)|"#
                        + #"vergeet\s+(je|jouw|alle|de)\s+((vorige|eerdere)\s+)?(regels|instructies|opdrachten)|"#
                        + #"doe\s+alsof\s+(je|jij)|gedraag\s+je\s+als)"#,
                    options: .caseInsensitive
                ),
                reason: .promptInjection,
                label: "injection_nl"
            )
        ]
    // swiftlint:enable force_try

    private static let allowPatterns: [Pattern] = // swiftlint:disable force_try
        [
            // Comparison — explicit "vs", "versus", "verglichen", "compared".
            // Listed BEFORE period-summary because period words ("woche",
            // "month") can also appear inside a comparison phrase, and
            // we want comparison to win.
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b(vergleich(e|en|t)?|verglichen\s+mit|gegen[üu]ber|vs\.?|versus|compared\s+to|compare\s+\w+\s+(with|to))\b"#,
                    options: .caseInsensitive
                ),
                category: .comparison,
                label: "compare"
            ),
            // Each Dutch twin sits directly after its German/English row, so
            // the first-match ordering (comparison > historic > period >
            // lookup) holds for Dutch asks too.
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b(vergelijk(en|t)?|vergeleken\s+met|ten\s+opzichte\s+van|t\.o\.v)\b"#,
                    options: .caseInsensitive
                ),
                category: .comparison,
                label: "compare_nl"
            ),
            // Historic — explicit past date phrasing.
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b(am\s+\d{1,2}\.?\s*(januar|februar|m[äa]rz|april|mai|juni|juli|"#
                        + #"august|september|oktober|november|dezember)|on\s+(january|february|"#
                        + #"march|april|may|june|july|august|september|october|november|"#
                        + #"december)\s+\d|im\s+(letzten|vorletzten|vergangenen)\s+"#
                        + #"(monat|jahr|quartal)|last\s+(month|year|quarter))\b"#,
                    options: .caseInsensitive
                ),
                category: .historicLookup,
                label: "historic"
            ),
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b(op\s+\d{1,2}\s*(januari|februari|maart|april|mei|juni|juli|augustus|"#
                        + #"september|oktober|november|december)|(vorige|afgelopen)\s+(maand|kwartaal)|"#
                        + #"(vorig|afgelopen)\s+jaar)\b"#,
                    options: .caseInsensitive
                ),
                category: .historicLookup,
                label: "historic_nl"
            ),
            // Period summary — "wie war meine woche", "how was my week".
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b(wie\s+war(\s+meine?)?|wie\s+sah(\s+meine?)?|zeig(\s+mir)?|"#
                        + #"summary\s+of|how\s+was|how\s+did|show\s+me)\s+\w*\s*"#
                        + #"(woche|monat|tag|week|month|day|period|zeitraum)"#,
                    options: .caseInsensitive
                ),
                category: .periodSummary,
                label: "period"
            ),
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b(hoe\s+was(\s+mijn)?|hoe\s+zag(\s+mijn)?|hoe\s+ging(\s+mijn)?|laat\s+(me|mij)|"#
                        + #"toon(\s+me|\s+mij)?|samenvatting\s+van|overzicht\s+van)\s+\w*\s*(week|maand|dag|periode)"#,
                    options: .caseInsensitive
                ),
                category: .periodSummary,
                label: "period_nl"
            ),
            // Data lookup — "letzter Wert", "current", "highest",
            // direct metric names, "was ist mein". Permissive
            // fallthrough — anything that mentions a metric.
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b(was\s+ist\s+mein|was\s+war\s+mein|mein\s+"#
                        + #"(letzter|höchster|niedrigster)|aktuell|current|latest|"#
                        + #"last\s+(weight|pulse|reading)|highest|lowest|h[öo]chster|niedrigster)\b"#,
                    options: .caseInsensitive
                ),
                category: .dataLookup,
                label: "lookup_phrasing"
            ),
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b(wat\s+is\s+mijn|wat\s+was\s+mijn|mijn\s+(laatste|hoogste|laagste)|huidige?|actuele?|"#
                        + #"laatste\s+(gewicht|hartslag|pols|meting|waarde)|hoogste|laagste)\b"#,
                    options: .caseInsensitive
                ),
                category: .dataLookup,
                label: "lookup_phrasing_nl"
            ),
            // Metric-name fallback. If the user just mentions a metric
            // ("blutdruck?", "weight?"), treat as data-lookup.
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b(blutdruck|puls|gewicht|schlaf|schritte|blutzucker|temperatur|sauerstoff|blood\s+pressure|pulse|weight|sleep|steps|glucose|temperature|oxygen|spo2|heart\s+rate)\b"#,
                    options: .caseInsensitive
                ),
                category: .dataLookup,
                label: "metric_name"
            ),
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b(bloeddruk|hartslag|pols|gewicht|slaap|stappen|bloedsuiker|temperatuur|zuurstof|saturatie)\b"#,
                    options: .caseInsensitive
                ),
                category: .dataLookup,
                label: "metric_name_nl"
            )
        ]
    // swiftlint:enable force_try

    public init() {}

    /// Classify a single user ask. Empty asks short-circuit to
    /// ``RefusalReason/emptyAsk``.
    public func classify(_ ask: String) -> Verdict {
        let trimmed = ask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .refused(reason: .emptyAsk) }
        let range = NSRange(trimmed.startIndex..., in: trimmed)

        // Deny-list first — refuse before allow-list runs.
        for pattern in Self.denyPatterns where pattern.regex.firstMatch(in: trimmed, range: range) != nil {
            HLLog.api
                .info(
                    "MiniCoachAskClassifier denied ask (reason \(pattern.reason.rawValue, privacy: .public), label \(pattern.label, privacy: .public))"
                )
            return .refused(reason: pattern.reason)
        }

        // Allow-list — first match wins, by ordering (comparison >
        // historic > period > data-lookup).
        for pattern in Self.allowPatterns where pattern.regex.firstMatch(in: trimmed, range: range) != nil {
            HLLog.api
                .info(
                    "MiniCoachAskClassifier allowed (category \(pattern.category.rawValue, privacy: .public), label \(pattern.label, privacy: .public))"
                )
            return .allowed(pattern.category)
        }

        HLLog.api.info("MiniCoachAskClassifier refused (out-of-scope, no allow-pattern matched)")
        return .refused(reason: .outOfScope)
    }

    /// Test-introspection: returns the full set of allowed categories
    /// the classifier can produce. Used by tests to assert coverage.
    public static var allowedCategories: Set<MiniCoachPrompt.AllowedCategory> {
        Set(allowPatterns.map(\.category))
    }

    /// Test-introspection: number of deny patterns.
    public static var denyPatternCount: Int {
        denyPatterns.count
    }

    /// Test-introspection: number of allow patterns.
    public static var allowPatternCount: Int {
        allowPatterns.count
    }

    /// The deny rows each interface language owns, by label: its advice,
    /// prediction and injection asks (and Dutch diagnosis asks, see
    /// `diagnosis_nl`). Exhaustive on purpose, like
    /// ``MDRSafetyFilter/rows(for:)``: a new ``AppLanguage`` case does not
    /// compile until it names its rows.
    static func denyLabels(for language: AppLanguage) -> Set<String> {
        switch language {
        case .de: ["advice_de", "prediction_de", "injection_de"]
        case .en: ["advice_en", "prediction_en", "injection_en"]
        case .nl: ["advice_nl", "diagnosis_nl", "prediction_nl", "injection_nl"]
        }
    }

    /// `true` when every deny row the language names exists. Read by
    /// ``OnDeviceLanguageGate``.
    static func covers(_ language: AppLanguage) -> Bool {
        let labels = denyLabels(for: language)
        return !labels.isEmpty && labels.isSubset(of: Set(denyPatterns.map(\.label)))
    }
}
