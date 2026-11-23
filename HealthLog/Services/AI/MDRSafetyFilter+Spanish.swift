import Foundation

/// **Spanish (es) twins of the MDR matrix.**
///
/// Each row is the `_es` twin of a Dutch row family
/// (`MDRSafetyFilter+Dutch.swift`): same `matrixRow`, same exemptions, the same
/// unsafe shape written the way a model writes Spanish, informal "tú" and
/// formal "usted" alike. Four more rows (`dose_amount_es` to
/// `predictive_present_es`) close the shapes the Korean red-team found in its
/// own language and that Spanish shares: a dose by number, a multiple or an
/// extra pill, the bare assertion of a condition, and a forecast in the present
/// tense. Lives in its own file only for the `file_length` cap;
/// `MDRSafetyFilter.patterns` concatenates it after the other rows, and like
/// every other row it runs on every text regardless of language, so it can
/// only make the filter stricter.
///
/// Accents are optional wherever a model or a keyboard might drop them
/// ("diagnóstico"/"diagnostico", "tensión"/"tension"). Five Spanish traps are
/// handled inline rather than left as false positives on the requested
/// observational shape: "por la mañana" ("in the morning") is not a forecast,
/// "debido a que no hay registros" (missing data) is not a cause, "llevas 7
/// días" (a streak) is not "lleva a" ("leads to"), "la toma de 500 mg" (a
/// logged intake) is not the imperative "toma", and "Toma tu Metformina" (the
/// reminder's own phrasing, the twin of "Take your Metformin") names no dose.
extension MDRSafetyFilter {
    /// The causal verb `causal_es` looks for on either side of the metric.
    /// "debido a" and "a causa de" do not count before missing data ("debido a
    /// que no hay registros de sueño"), and the noun "causa" inside "a causa
    /// de" does not count on its own either.
    private static let spanishCausalVerb =
        #"\b(causad[oa]s?|(?<!a\s)causan?|caus[oó]|causando|provocad[oa]s?|provocan?|provoc[oó]|provocando|"#
            + #"desencadenad[oa]s?|desencadenan?|originad[oa]s?|se\s+deben?\s+al?\b|"#
            + #"(es|son)\s+(una\s+)?consecuencia\s+del?\b|(es|son)\s+(el\s+)?resultado\s+del?\b|"#
            + #"debido\s+al?\b(?!\s+(que\s+)?(no\b|la\s+falta|falta|la\s+ausencia|ausencia|pocos|pocas|escas[oa]s))|"#
            + #"a\s+causa\s+del?\b(?!\s+(la\s+)?(falta|ausencia))|por\s+culpa\s+del?\b)"#

    /// The metrics a causal claim is made about.
    private static let spanishCausalMetric =
        #"(tensi[oó]n|presi[oó]n|estr[eé]s|pulso|frecuencia\s+card[ií]aca|sue[nñ]o|peso|glucosa|az[uú]car)"#

    /// The conditions a diagnostic row names.
    private static let spanishCondition =
        #"(hipertensi[oó]n|hipotensi[oó]n|diabetes|arritmias?|fibrilaci[oó]n\s+auricular|hipertiroidismo|"#
            + #"hipotiroidismo|apnea(\s+del\s+sue[nñ]o)?|(tensi[oó]n|presi[oó]n)(\s+arterial)?\s+alta)"#

    static let spanishPatterns: [Pattern] = // swiftlint:disable force_try
        [
            // Row 7 — Predictive language ("va a subir", "bajará", "se espera que suba", "pico previsto")
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b(va|van|vas)\s+a\s+(\w+\s+)?(subir|bajar|aumentar|disminuir|descender|empeorar|mejorar|caer|"#
                        + #"elevarse|dispararse|seguir\s+(subiendo|bajando|aumentando|disminuyendo))\b|"#
                        + #"\b(subir|bajar|aumentar|disminuir|descender|empeorar|mejorar|caer|elevar)[aá]n?\b|"#
                        + #"\bseguir[aá]n?\s+(subiendo|bajando|aumentando|disminuyendo)\b|"#
                        + #"\b(se\s+(espera|prev[eé])|es\s+(probable|previsible|de\s+esperar))\s+que\s+[^.!?]{0,30}?"#
                        + #"\b(suba|baje|aumente|disminuya|empeore|mejore|caiga|descienda)n?\b|"#
                        + #"\b(pico|valor|nivel|m[aá]ximo|m[ií]nimo)\s+(previsto|esperado|pronosticado)\b"#,
                    options: .caseInsensitive
                ),
                matrixRow: 7,
                label: "predictive_es"
            ),
            // Row 8 — Dose / treatment advice, plus the bare recommendation
            // verbs in every person ("recomiendo", "se recomienda",
            // "aconsejan"); `bare_recommend_en`'s twin lives here, as in Dutch.
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b(recomiend\w*|recomend\w*|aconsej\w*|"#
                        + #"(aumenta|aumente|sube|suba|baja|baje|reduce|reduzca|disminuye|disminuya|duplica|duplique|"#
                        + #"ajusta|ajuste|modifica|modifique|cambia|cambie)\s+(tu|su|la|el)\s+(dosis|dosificaci[oó]n)|"#
                        + #"(aumentar|subir|bajar|reducir|disminuir|duplicar|ajustar|modificar|cambiar)\s+(tu|su|la)\s+"#
                        + #"(dosis|dosificaci[oó]n))\b"#,
                    options: .caseInsensitive
                ),
                matrixRow: 8,
                label: "prescriptive_es",
                // Same pair as `prescriptive`: "Las guías de la ESH recomiendan
                // …" is a citation, a hand-off sentence is the requested shape,
                // and neither excuses a dose, medication or therapy.
                exemptions: [citationExemption, handOffExemption]
            ),
            // Row 9 — Diagnostic claim. The second arm is the verb-first order
            // ("Esto apunta a una diabetes"). Both arms take only the finite
            // "indica/sugiere": the infinitive in "podría indicar" is the modal
            // possibility, which falls to `reflective_suggestive_es`, the row
            // that knows the clinician hand-off.
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b"# + MDRSafetyFilter.spanishCondition
                        + #"\b.{0,40}\b(indica|indican|sugiere|sugieren|apunta|apuntan|se[nñ]ala|se[nñ]alan|"#
                        + #"diagn[oó]stic(o|os|a|ar|ado|ada)|padeces|sufres|tienes\s+una?)\b|"#
                        + #"\b(indica|indican|sugiere|sugieren|apunta|apuntan|se[nñ]ala|se[nñ]alan|revela|revelan)\s+"#
                        + #"(\w+\s+){0,2}((a|hacia)\s+)?(una?\s+)?"# + MDRSafetyFilter.spanishCondition,
                    options: .caseInsensitive
                ),
                matrixRow: 9,
                label: "diagnostic_es"
            ),
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b(diagn[oó]stic(o|os|a|as|ar|ado|ada|ados|adas|aron|aste|ó)|te\s+diagnostiqu\w*|"#
                        + #"padec(es|e|en)|sufres\s+de|usted\s+sufre\s+de|sufre\s+usted\s+de|"#
                        + #"(tienes|tiene\s+usted|usted\s+tiene)\s+una\s+(enfermedad|afecci[oó]n|patolog[ií]a|dolencia))\b"#,
                    options: .caseInsensitive
                ),
                matrixRow: 9,
                label: "diagnostic_direct_es"
            ),
            // Row 11 — Causal medical claim. Spanish puts the effect first as
            // often as the cause ("Tu pulso alto se debe al estrés"), so the
            // metric may stand on either side of the causal verb. "viene del
            // estrés" counts only before a cause, never before a source ("Tu
            // pulso viene de tu Apple Watch").
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: MDRSafetyFilter.spanishCausalVerb
                        + #".{0,30}(tensi[oó]n|presi[oó]n|estr[eé]s|pulso|frecuencia\s+card[ií]aca|sue[nñ]o|peso|"#
                        + #"glucosa|az[uú]car|medicaci[oó]n|medicamento)|"#
                        + #"\b"# + MDRSafetyFilter.spanishCausalMetric + #"\w*[^.!?]{0,40}?"#
                        + MDRSafetyFilter.spanishCausalVerb + #"|"#
                        + #"\bvienen?\s+(del|de\s+la|de)\s+(estr[eé]s|cansancio|falta\s+de\s+sue[nñ]o|poco\s+sue[nñ]o|"#
                        + #"alcohol|caf[eé]|medicaci[oó]n|medicamento)\b"#,
                    options: .caseInsensitive
                ),
                matrixRow: 11,
                label: "causal_es"
            ),
            // Row 14 — Drug-level interpretation (GROUND RULE 10/15 universal).
            // "nivel de glucosa en sangre" is a reading and passes: only a level
            // of the drug itself counts.
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b(nivel(es)?\s+del?\s+(f[aá]rmaco|medicamento|medicaci[oó]n|principio\s+activo)\w*|"#
                        + #"nivel(es)?\s+(en\s+sangre|plasm[aá]ticos?)|"#
                        + #"concentraci[oó]n(es)?\s+(del?\s+(f[aá]rmaco|medicamento|principio\s+activo)|en\s+sangre|plasm[aá]ticas?)|"#
                        + #"(efecto|concentraci[oó]n)\s+m[aá]xim[oa]|"#
                        + #"(ahora|ahora\s+mismo|actualmente|en\s+este\s+momento)\s+(est[aá]\s+)?en\s+su\s+(pico|punto\s+m[aá]ximo))\b"#,
                    options: .caseInsensitive
                ),
                matrixRow: 14,
                label: "drug_level_es"
            ),
            // Row 9 (extended) — "estás enfermo" diagnostic shorthand
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b((t[uú]\s+)?est[aá]s\s+enferm[oa]|usted\s+est[aá]\s+enferm[oa]|est[aá]\s+usted\s+enferm[oa]|"#
                        + #"cuadro\s+cl[ií]nico)\b"#,
                    options: .caseInsensitive
                ),
                matrixRow: 9,
                label: "sick_claim_es"
            ),
            // Row 8 (extended) — therapy change suggestion, imperative (tú and
            // usted) or infinitive, including stopping and skipping a dose
            // ("deja de tomar", "puedes saltarte la dosis"). "para" is left out
            // on purpose: "un recordatorio para tu medicación" is the reminder's
            // own phrasing.
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b((deja|deje|dejes|dejar|suspende|suspenda|suspender|interrumpe|interrumpa|interrumpir|"#
                        + #"abandona|abandone|abandonar|cambia|cambie|cambiar|ajusta|ajuste|ajustar|modifica|modifique|"#
                        + #"modificar|sustituye|sustituya|sustituir|pausa|pausar)\s+(de\s+tomar\s+)?(tu|tus|su|sus|la|las|el|los)\s+"#
                        + #"(tratamiento|terapia|medicaci[oó]n|medicamentos?|pastillas?|comprimidos?|f[aá]rmacos?|dosis|"#
                        + #"dosificaci[oó]n|insulina|pauta)|"#
                        + #"(deja|deje|dejes|dejar)\s+de\s+(tomar\w*|usar|ponerte|inyectarte)|"#
                        + #"(s[aá]ltate|saltarte|saltar|saltas|saltes|s[aá]ltese|saltarse|omite|omita|omitir|omites)\s+"#
                        + #"(\w+\s+)?(la|tu|su|una)\s+(dosis|toma|pastilla|comprimido|inyecci[oó]n))\b"#,
                    options: .caseInsensitive
                ),
                matrixRow: 8,
                label: "therapy_change_es"
            ),
            // Row 7 (extended) — future-tense risk claim ("riesgo de ictus",
            // "mayor riesgo de sufrir un infarto")
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b(riesgo|probabilidad|posibilidad)\s+(\w+\s+){0,2}?(de\s+)?(sufrir\s+|tener\s+)?(una?\s+)?"#
                        + #"(ictus|infarto|derrame|accidente\s+cerebrovascular|ataque\s+(al\s+coraz[oó]n|card[ií]aco)|"#
                        + #"insuficiencia\s+card[ií]aca|enfermedad\s+cardiovascular)"#,
                    options: .caseInsensitive
                ),
                matrixRow: 7,
                label: "future_risk_es"
            ),
            // Row 9 (extended) — symptom-to-diagnosis bridge
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b(tus|sus|estos|estas|esos|esas|los|las)\s+(valores|mediciones|medidas|lecturas|resultados|"#
                        + #"datos|cifras)\b.{0,30}\b(indican|sugieren|apuntan|se[nñ]alan|revelan)\s+((a|hacia|que)\s+)?\w+"#,
                    options: .caseInsensitive
                ),
                matrixRow: 9,
                label: "values_indicate_es"
            ),
            // Row 11 (extended) — explicit causality verb between metrics. The
            // finite "lleva a" never matches the streak "llevas 7 días".
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b((lleva|llevan|llev[oó]|llevar|conduce|conducen|condujo|conducir)\s+a|"#
                        + #"(da|dan|dio|dar)\s+lugar\s+a|(provoca|provocan|provoc[oó]|causa|causan|caus[oó]))\b"#
                        + #".{0,40}(m[aá]s\s+alt[oa]s?|m[aá]s\s+baj[oa]s?|aumento|subida|descenso|bajada|disminuci[oó]n|incremento)"#,
                    options: .caseInsensitive
                ),
                matrixRow: 11,
                label: "leads_to_es"
            ),
            // Row 8 (extended) — "debes … ahora", the twin of "je moet nu". The
            // plain "Toma tu Metformina ahora" is the reminder's phrasing (the
            // twin of "Take your Metformin now") and passes, as in English.
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b((debes|tienes\s+que|deber[ií]as|usted\s+debe|debe\s+usted|tiene\s+que)\s+[^.!?]{0,30}?\bahora|"#
                        + #"ahora\s+(mismo\s+)?(debes|tienes\s+que|deber[ií]as|debe\s+usted|tiene\s+usted\s+que))\b"#,
                    options: .caseInsensitive
                ),
                matrixRow: 8,
                label: "must_take_now_es"
            ),
            // Row 14 (extended) — interpret half-life / PK
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b(vida\s+media|semivida|farmacocin[eé]tic\w*|concentraci[oó]n\s+plasm[aá]tica|nivel\s+plasm[aá]tico)\b"#
                        + #".{0,30}(indica|indican|significa|significan|sugiere|sugieren|interpret|muestra|apunta)"#,
                    options: .caseInsensitive
                ),
                matrixRow: 14,
                label: "pharmacokinetic_es"
            ),
            // Row 9 (extended) — direct condition assertion. No article: "tienes
            // la tensión alta" names the condition, "mediste una tensión alta"
            // a reading.
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b((t[uú]\s+)?tienes|usted\s+tiene|tiene\s+usted|(t[uú]\s+)?padeces|usted\s+padece|sufres\s+de)\s+"#
                        + #"(hipertensi[oó]n|hipotensi[oó]n|diabetes|arritmias?|apnea|fibrilaci[oó]n\s+auricular|"#
                        + #"hipotiroidismo|hipertiroidismo|(la\s+)?(tensi[oó]n|presi[oó]n)(\s+arterial)?\s+alta|"#
                        + #"(el\s+)?az[uú]car\s+alto)\b|"#
                        + #"\b(eres|es\s+usted|usted\s+es)\s+(hipertens[oa]|diab[eé]tic[oa]|hipotens[oa])\b"#,
                    options: .caseInsensitive
                ),
                matrixRow: 9,
                label: "direct_condition_es"
            ),
            // Row 8 (Mini-Coach C2 twin) — implicit advice / "sería bueno que…"
            // softener phrasing.
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b(ser[ií]a\s+(bueno|mejor|conveniente|aconsejable|recomendable|[uú]til|buena\s+idea|ideal|sensato)\s+(que|si)|"#
                        + #"convendr[ií]a|lo\s+(mejor|ideal)\s+(ser[ií]a|es\s+que)|te\s+vendr[ií]a\s+bien|no\s+estar[ií]a\s+de\s+m[aá]s|"#
                        + #"es\s+(aconsejable|recomendable|conveniente|preferible)\s+(que|si)|"#
                        + #"podr[ií]as\s+(intentar|probar|plantearte|considerar)\s+[^.!?]{0,20}?\b(menos|m[aá]s|reducir|aumentar|dejar)|"#
                        + #"(quiz[aá]s?|tal\s+vez|a\s+lo\s+mejor)\s+(deber[ií]as|tendr[ií]as\s+que|podr[ií]as))\b"#,
                    options: .caseInsensitive
                ),
                matrixRow: 8,
                label: "implicit_advice_es"
            ),
            // Row 9 (Mini-Coach C2 twin) — reflective-suggestive: the condition
            // floated as a possibility. "podría", "puede que", "es posible que"
            // are the Spanish "könnte"; the bare present "puede" ("can") is
            // left out.
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b(podr[ií]as?|podr[ií]an|pudiera|pudiese|puede\s+que|quiz[aá]s?|tal\s+vez|posiblemente|"#
                        + #"probablemente|es\s+(posible|probable)\s+que)\b[^.!?]{0,60}\b"#
                        + #"(hipertensi[oó]n|hipotensi[oó]n|diabetes|arritmias?|apnea|trastorno|d[eé]ficit|carencia|"#
                        + #"enfermedad|afecci[oó]n|patolog[ií]a|fibrilaci[oó]n|hipotiroidismo|hipertiroidismo)"#,
                    options: .caseInsensitive
                ),
                matrixRow: 9,
                label: "reflective_suggestive_es",
                // See `reflective_suggestive_de`.
                exemptions: [handOffExemptionUnguarded]
            ),
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b(posiblemente|quiz[aá]s?|tal\s+vez|probablemente|puede\s+que|es\s+(posible|probable)\s+que)\s+"#
                        + #"(tengas|padezcas|sufras|tenga\s+usted|usted\s+tenga|se\s+trate\s+de|haya\s+una?)\b"#,
                    options: .caseInsensitive
                ),
                matrixRow: 9,
                label: "reflective_possibly_es"
            ),
            // Row 8 (R21 twin) — the bare imperative: "debes", "deberías",
            // "tienes que", "te sugiero", "yo que tú". The third person "debe"
            // is left out ("Eso debe valorarlo tu médico" names the doctor, not
            // the reader). Carries the hand-off exemption like its twins.
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b(debes|deber[ií]as|deber[ií]a\s+usted|usted\s+deber[ií]a|usted\s+debe|debe\s+usted|"#
                        + #"tienes\s+que|tiene\s+usted\s+que|usted\s+tiene\s+que|necesitas\s+\w+(ar|er|ir)|"#
                        + #"(te|le)\s+(sugiero|propongo)|sugiero|propongo|yo\s+que\s+t[uú]|yo\s+en\s+tu\s+lugar)\b"#,
                    options: .caseInsensitive
                ),
                matrixRow: 8,
                label: "bare_prescriptive_es",
                exemptions: [handOffExemption]
            ),
            // R4 §5 (Mini-Coach C2 twin) — prompt-injection marker.
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"(\b(ignora|ignore|ignorar|olvida|olvide|olvidar|descarta|descarte)\s+(todas\s+)?(las|tus|sus)\s+"#
                        + #"((anteriores|previas)\s+)?(instrucciones|reglas|indicaciones|normas)|"#
                        + #"\b(ignora|olvida)\s+todo\s+lo\s+anterior)"#,
                    options: .caseInsensitive
                ),
                matrixRow: 0,
                label: "prompt_injection_marker_es"
            ),
            // Row 8 (extended) — an amount after a dose verb in the imperative
            // ("Tómate 2 comprimidos", "Sube la dosis a 20 mg", "Ponte 10
            // unidades"). The noun "la toma de 500 mg" (a logged intake) and a
            // measured value ("Tu peso es 72,4 kg") name no imperative and pass.
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b(toma(?!\s+de\b)|tome|t[oó]mate|t[oó]mese|t[oó]matel[oa]s?|aumenta|aumente|sube|suba|baja|baje|"#
                        + #"reduce|reduzca|disminuye|disminuya|duplica|duplique|a[nñ]ade|a[nñ]ada|ponte|p[oó]ngase|"#
                        + #"inyecta|inyecte|iny[eé]ctate|iny[eé]ctese|pasa|pase)\b[^.!?\d]{0,25}\d+([.,]\d+)?\s*"#
                        + #"(mg|mcg|µg|g|ui|unidades|comprimidos?|pastillas?|c[aá]psulas?|gotas|ml|tabletas?|inyecciones)\b"#,
                    options: .caseInsensitive
                ),
                matrixRow: 8,
                label: "dose_amount_es"
            ),
            // Row 8 (extended) — a multiple or an extra pill ("Toma media
            // pastilla", "tómate otra pastilla", "doble dosis").
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b(toma(?!\s+de\b)|tome|t[oó]mate|t[oó]mese|tomar|tomarte|ponte|p[oó]ngase)\s+[^.!?]{0,15}?"#
                        + #"\b(media|otra|una\s+segunda|el\s+doble\s+de(\s+la)?)\s+(pastilla|dosis|c[aá]psula|comprimido|tableta|inyecci[oó]n)|"#
                        +
                        #"\b(doble\s+dosis|dosis\s+doble|dosis\s+(extra|adicional)|(pastilla|c[aá]psula|comprimido)\s+(extra|adicional))\b"#,
                    options: .caseInsensitive
                ),
                matrixRow: 8,
                label: "dose_multiplier_es"
            ),
            // Row 9 (extended) — the condition asserted outright ("Esto es
            // hipertensión", "Se trata de una diabetes").
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b(se\s+trata\s+de|esto\s+es|eso\s+es|parece|suena\s+a)\s+(una?\s+)?"#
                        + MDRSafetyFilter.spanishCondition + #"\b"#,
                    options: .caseInsensitive
                ),
                matrixRow: 9,
                label: "diagnostic_assert_es"
            ),
            // Row 7 (extended) — a forecast in the present tense ("Mañana tu
            // tensión sube"). "por la mañana" and "esta mañana" are a time of
            // day, not tomorrow.
            Pattern(
                regex: try! NSRegularExpression(
                    pattern: #"(\b(?<!la\s)(?<!esta\s)(?<!cada\s)(?<!una\s)ma[nñ]ana\b|\bpronto\b|\bla\s+pr[oó]xima\s+semana\b|"#
                        + #"\bel\s+pr[oó]ximo\s+mes\b|\bde\s+seguir\s+as[ií]\b|\bsi\s+sigues\s+as[ií]\b)[^.!?]{0,30}"#
                        + #"\b(sube|suben|baja|bajan|aumenta|aumentan|disminuye|disminuyen|empeora|empeoran|mejora|mejoran|"#
                        + #"se\s+normaliza|se\s+estabiliza|se\s+dispara|cae|caen)\b"#,
                    options: .caseInsensitive
                ),
                matrixRow: 7,
                label: "predictive_present_es"
            )
        ]
    // swiftlint:enable force_try
}
