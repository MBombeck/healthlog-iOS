import Foundation

/// **Dutch (nl) twins of the MDR matrix.**
///
/// The on-device features now answer Dutch users in Dutch, and every German /
/// English row only knows its own language, so a Dutch "Je bloeddruk zal
/// morgen stijgen" walked through all 25 of them. Each row here is the `_nl`
/// twin of a German/English row family: same `matrixRow`, same exemptions,
/// the same unsafe shape written the way a model writes Dutch, informal
/// "je/jij" and formal "u" alike. Lives in its own file only for the
/// `file_length` cap; `MDRSafetyFilter.patterns` concatenates it after the
/// base rows, and like every other row it runs on every text regardless of
/// language, so it can only make the filter stricter.
///
/// Three Dutch-specific traps are handled inline rather than left as false
/// positives on the requested observational shape: "ligt aan de hoge kant"
/// ("is on the high side") is not a cause, "door de week" ("on weekdays") is
/// not a cause, and the possessive "je" in "Dat moet je arts beoordelen" is
/// not the subject of an instruction.
extension MDRSafetyFilter {
    /// The causal verb `causal_nl` looks for on either side of the metric.
    /// Excludes "ligt aan de hoge kant" (a level, not a cause) and "komt door
    /// de week" (a time span).
    private static let dutchCausalVerb =
        #"\b(veroorzaakt|veroorzaken|(komt|komen)\s+(\w+\s+)?door(?!\s+de\s+(week|dag|nacht))|"#
            + #"(ligt|liggen)\s+(\w+\s+)?aan(?!\s+de\s+\w+\s+kant)|te\s+wijten\s+aan|het\s+gevolg\s+van)\b"#

    static let dutchPatterns: [Pattern] = // swiftlint:disable force_try
        [
            // Row 7 — Predictive language ("zal stijgen", "gaat dalen", "wordt verwacht te stijgen", "voorspelde piek")
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b(zal|zullen|zult|gaat|gaan|wordt\s+verwacht|worden\s+verwacht|naar\s+verwachting)\b"#
                        + #"[^.!?]{0,40}\b(stijgen|dalen|toenemen|afnemen|oplopen|zakken|pieken)\b|"#
                        + #"\bvoorspeld\w*\s+(piek|dal|waarde|niveau|stijging|daling)"#,
                    options: .caseInsensitive
                ),
                matrixRow: 7,
                label: "predictive_nl"
            ),
            // Row 8 — Dose / treatment advice, plus the bare third-person
            // recommendation verbs (`bare_recommend_en`'s twin lives here, the
            // way the German bare `empfehl…` lives in `prescriptive`).
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b(aanbevel\w*|aanbevolen|aanraden|aangeraden|beveel|beveelt|bevelen|"#
                        + #"advis(eer|eert|eren)|geadviseerd|raadt|raden\s+aan|"#
                        + #"(je|jij|u)\s+moet\s+[^.!?]{0,30}?\b(in)?nemen|"#
                        + #"(je|jij|u)\s+zou(dt)?\s+(je|jouw|uw|de)\s+(dosis|dosering|tablet\w*|injectie|spuit|medicatie)|"#
                        + #"(verhoog|verlaag)\s+(je|jouw|uw|de)\s+dos\w*|"#
                        + #"dos(is|ering)\s+(verhogen|verlagen|ophogen|opbouwen|afbouwen))\b"#,
                    options: .caseInsensitive
                ),
                matrixRow: 8,
                label: "prescriptive_nl",
                // Same pair as `prescriptive`: "De ESH-richtlijnen bevelen …
                // aan" is a citation, a hand-off sentence is the requested
                // shape, and neither excuses a dose, medication or therapy.
                exemptions: [citationExemption, handOffExemption]
            ),
            // Row 9 — Diagnostic claim. The second arm is the Dutch verb-first
            // order ("Dit wijst op hypertensie"). Both arms take only the
            // finite "wijst/duidt": the infinitive in "zou/kan … wijzen" is the
            // modal possibility, which falls to `reflective_suggestive_nl`,
            // the row that knows the clinician hand-off.
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b(hypertensie|hypotensie|diabetes|aritmie|boezemfibrilleren|hyperthyreo[iï]die|"#
                        + #"hypothyreo[iï]die|hoge\s+bloeddruk|hartritmestoornis(sen)?)\b"#
                        + #".{0,40}(wijst|duidt|diagnose|(je|jij)\s+hebt|u\s+heeft|(je|jij|u)\s+lijdt)|"#
                        + #"\b(wijst|duidt)\s+(\w+\s+)?op\s+(een\s+)?(hypertensie|hypotensie|diabetes|aritmie|"#
                        + #"boezemfibrilleren|hyperthyreo[iï]die|hypothyreo[iï]die|hoge\s+bloeddruk|hartritmestoornis)"#,
                    options: .caseInsensitive
                ),
                matrixRow: 9,
                label: "diagnostic_nl"
            ),
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b(diagnose|diagnosticeer\w*|gediagnosticeerd|(je|jij|u)\s+lijdt\s+aan|lijd\s+je\s+aan|"#
                        + #"(je|jij)\s+hebt\s+een\s+(ziekte|aandoening)|u\s+heeft\s+een\s+(ziekte|aandoening))\b"#,
                    options: .caseInsensitive
                ),
                matrixRow: 9,
                label: "diagnostic_direct_nl"
            ),
            // Row 11 — Causal medical claim. Dutch puts the effect first as
            // often as the cause ("Je hoge bloeddruk komt door stress"), so the
            // metric may stand on either side of the causal verb.
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: MDRSafetyFilter.dutchCausalVerb
                        + #".{0,30}(bloeddruk|stress|hartslag|pols|slaap|gewicht|bloedsuiker|medicatie|medicijn)|"#
                        + #"\b(bloeddruk|stress|hartslag|pols|slaap|gewicht|bloedsuiker)\w*[^.!?]{0,40}?"#
                        + MDRSafetyFilter.dutchCausalVerb,
                    options: .caseInsensitive
                ),
                matrixRow: 11,
                label: "causal_nl"
            ),
            // Row 14 — Drug-level interpretation (GROUND RULE 10/15 universal)
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b((medicijn|geneesmiddel|bloed|piek|dal|plasma)spiegel\w*|werkzame[\s-]?stofspiegel\w*|"#
                        + #"spiegel\s+van\s+(je|jouw|uw|het)\s+(medicijn|geneesmiddel|middel|medicatie)|"#
                        + #"(nu|momenteel)\s+op\s+(zijn|haar|het)\s+(piek|hoogtepunt))\b"#,
                    options: .caseInsensitive
                ),
                matrixRow: 14,
                label: "drug_level_nl"
            ),
            // Row 9 (extended) — "je bent ziek" diagnostic shorthand
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b((je|jij|u)\s+bent\s+ziek|ben\s+je\s+ziek|bent\s+u\s+ziek|ziektebeeld\w*)\b"#,
                    options: .caseInsensitive
                ),
                matrixRow: 9,
                label: "sick_claim_nl"
            ),
            // Row 8 (extended) — therapy change suggestion
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b((je|jouw|uw|de)\s+(therapie|medicatie|behandeling|medicijnen|dosis|dosering)\s+"#
                        + #"(aanpassen|wijzigen|veranderen|omzetten|verhogen|verlagen|afbouwen|stoppen|stopzetten)|"#
                        + #"pas\s+(je|jouw|uw|de)\s+(therapie|medicatie|behandeling|medicijnen|dosis|dosering)\s+aan|"#
                        + #"verander\s+(je|jouw|uw|de)\s+(therapie|medicatie|behandeling|medicijnen)|"#
                        + #"stop\s+met\s+(je|jouw|uw|de)\s+(therapie|medicatie|behandeling|medicijnen))\b"#,
                    options: .caseInsensitive
                ),
                matrixRow: 8,
                label: "therapy_change_nl"
            ),
            // Row 7 (extended) — future-tense risk claim
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b(risico|kans)\s+op\s+(een\s+)?\w*(beroerte|hartaanval|herseninfarct|hartinfarct|infarct|"#
                        + #"hart-\s*en\s+vaatziekte)"#,
                    options: .caseInsensitive
                ),
                matrixRow: 7,
                label: "future_risk_nl"
            ),
            // Row 9 (extended) — symptom-to-diagnosis bridge
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b(je|jouw|uw|deze|die|de)\s+(waarden|metingen|meetwaarden|resultaten|cijfers|gegevens)\b"#
                        + #".{0,30}(wijzen|duiden|wijst|duidt)\s+(\w+\s+)?(op|naar)\s+\w+"#,
                    options: .caseInsensitive
                ),
                matrixRow: 9,
                label: "values_indicate_nl"
            ),
            // Row 11 (extended) — explicit causality verb between metrics
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b((leidt|leiden|leidde|leidden)\s+tot|(zorgt|zorgen)\s+voor)\b"#
                        + #".{0,40}(hoger|lager|stijging|daling|toename|afname)"#,
                    options: .caseInsensitive
                ),
                matrixRow: 11,
                label: "leads_to_nl"
            ),
            // Row 8 (extended) — "je moet nu (in)nemen" prescriptive
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b((je|jij|u)\s+(moet|zou\s+moeten)\s+nu|moet\s+(je|jij|u)\s+nu)\b"#,
                    options: .caseInsensitive
                ),
                matrixRow: 8,
                label: "must_take_now_nl"
            ),
            // Row 14 (extended) — interpret half-life / PK
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b(halfwaardetijd|halveringstijd|farmacokineti\w*|plasmaspiegel\w*)\b"#
                        + #".{0,30}(wijst|wijzen|duidt|duiden|betekent|interpret)"#,
                    options: .caseInsensitive
                ),
                matrixRow: 14,
                label: "pharmacokinetic_nl"
            ),
            // Row 9 (extended) — direct condition assertion. No article: "je
            // hebt hoge bloeddruk" names the condition, "je hebt een hoge
            // bloeddruk gemeten" a reading.
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b((je|jij)\s+hebt|u\s+heeft|heb\s+je|heeft\s+u)\s+(last\s+van\s+)?"#
                        + #"(hoge\s+bloeddruk|diabetes|suikerziekte|hypertensie|hartritmestoornis\w*|boezemfibrilleren)\b"#,
                    options: .caseInsensitive
                ),
                matrixRow: 9,
                label: "direct_condition_nl"
            ),
            // Row 8 (Mini-Coach C2 twin) — implicit advice / "het zou goed
            // zijn als je…" softener phrasing.
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b(het\s+zou\s+(goed|beter|verstandig|raadzaam|zinvol|slim)\s+zijn\s+(als|om|wanneer)|"#
                        + #"het\s+is\s+(beter|verstandig|raadzaam|aan\s+te\s+raden)\s+(om|als|dat|wanneer)|"#
                        + #"(je|jij|u)\s+zou(dt)?\s+(eens|misschien|beter|wellicht|eventueel)|"#
                        + #"zou(dt)?\s+(je|jij|u)\s+(eens|misschien|beter|wellicht|eventueel)|"#
                        + #"(je|jij|u)\s+(zou(dt)?\s+kunnen|kunt|kan)\s+(proberen|overwegen)\s+[^.!?]{0,20}?\b(minder|meer)|"#
                        + #"(je|jij|u)\s+zou(dt)?\s+[^.!?]{0,30}?\b(minder|meer|vaker)\b[^.!?]{0,30}?\bkunnen|"#
                        + #"(je|jij|u)\s+(kunt|kan)\s+beter|kun\s+je\s+beter)\b"#,
                    options: .caseInsensitive
                ),
                matrixRow: 8,
                label: "implicit_advice_nl"
            ),
            // Row 9 (Mini-Coach C2 twin) — reflective-suggestive: the condition
            // floated as a possibility. "zou/kon" is the Dutch "könnte"; the
            // present "kan/kunnen" only counts next to a pointing verb, since
            // on its own it is the everyday "can".
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b(zou|zouden|kon|konden)\b[^.!?]{0,60}\b"#
                        + #"(hypertensie|hypotensie|diabetes|aritmie|(slaap)?apneu|aandoening|tekort|ziekte|"#
                        + #"hoge\s+bloeddruk|boezemfibrilleren|hartritmestoornis)|"#
                        + #"\b(kan|kunnen)\s+[^.!?]{0,20}?\b(wijzen|duiden|passen|een\s+teken|een\s+aanwijzing)\b"#
                        + #"[^.!?]{0,40}?\b(hypertensie|hypotensie|diabetes|aritmie|(slaap)?apneu|aandoening|tekort|"#
                        + #"ziekte|hoge\s+bloeddruk|boezemfibrilleren|hartritmestoornis)"#,
                    options: .caseInsensitive
                ),
                matrixRow: 9,
                label: "reflective_suggestive_nl",
                // R19b — see `reflective_suggestive_de`.
                exemptions: [handOffExemptionUnguarded]
            ),
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b(mogelijk|misschien|wellicht|eventueel)\s+(heb\s+je|hebt\s+u|heeft\s+u|lijd\s+je|"#
                        + #"lijdt\s+u|is\s+er\s+sprake\s+van|gaat\s+het\s+om)\b"#,
                    options: .caseInsensitive
                ),
                matrixRow: 9,
                label: "reflective_possibly_nl"
            ),
            // Row 8 (R21 twin) — the bare imperative: "je moet", "u zou …
            // moeten", "ik raad je aan", "ik adviseer". Dutch splits the modal
            // from its infinitive ("Je zou minder zout moeten eten"), hence
            // the window. Carries the hand-off exemption like its twins.
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b((je|jij|u)\s+moet|moet\s+(je|jij|u)\b(?!\s+(huis)?(arts|dokter))|"#
                        + #"(je|jij|u)\s+zou(dt)?\s+[^.!?]{0,40}?\bmoeten|"#
                        + #"zou(dt)?\s+(je|jij|u)\b(?!\s+(huis)?(arts|dokter))[^.!?]{0,40}?\bmoeten|"#
                        + #"(je|jij|u)\s+dient|dient\s+u\b|ik\s+raad\b|raad\s+ik\b|ik\s+adviseer|adviseer\s+ik|ik\s+stel\s+voor|"#
                        + #"ik\s+zou\s+[^.!?]{0,40}?\b(aanraden|adviseren|aanbevelen|voorstellen))\b"#,
                    options: .caseInsensitive
                ),
                matrixRow: 8,
                label: "bare_prescriptive_nl",
                exemptions: [handOffExemption]
            ),
            // R4 §5 (Mini-Coach C2 twin) — prompt-injection marker.
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"(negeer\s+(alle|de|je|jouw|uw|vorige|eerdere)\s+((vorige|eerdere)\s+)?"#
                        + #"(instructies|regels|opdrachten|prompt)|"#
                        + #"vergeet\s+(je|jouw|uw|alle|de)\s+((vorige|eerdere)\s+)?(regels|instructies|opdrachten))"#,
                    options: .caseInsensitive
                ),
                matrixRow: 0,
                label: "prompt_injection_marker_nl"
            )
        ]
    // swiftlint:enable force_try
}
