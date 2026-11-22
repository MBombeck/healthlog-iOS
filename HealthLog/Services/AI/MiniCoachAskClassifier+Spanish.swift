import Foundation

/// The Spanish refusal rows of the Mini-Coach ask classifier, in a file of
/// their own so the classifier stays within the type body limit. They run
/// after every other deny row, like the Korean rows before them.
extension MiniCoachAskClassifier {
    static let spanishDenyPatterns: [DenyPattern] = // swiftlint:disable force_try
        [
            // Spanish rows (es), accents optional. Advice and dose asks:
            // "¿Qué debo hacer?", "¿Debo aumentar mi dosis?", "¿Puedo dejar la
            // medicación?", "¿Cómo bajo la tensión?".
            DenyPattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b(qu[eé]\s+(debo|deber[ií]a|tengo\s+que|hago|har[ií]as|me\s+recomiendas|me\s+aconsejas)|"#
                        + #"debo|deber[ií]a|tengo\s+que|me\s+recomiendas|me\s+aconsejas|recomi[eé]ndame|acons[eé]jame|"#
                        + #"consejos?|recomendaci[oó]n\w*|"#
                        + #"c[oó]mo\s+(puedo|podr[ií]a|hago\s+para)\s+(mejorar|bajar|subir|reducir|aumentar|estar\s+m[aá]s\s+san[oa])|"#
                        + #"c[oó]mo\s+(bajo|subo|reduzco|mejoro|aumento)|"#
                        + #"(puedo|podr[ií]a)\s+[^.!?]{0,30}(dosis|medicaci[oó]n|medicamentos?|pastillas?|comprimidos?|"#
                        + #"tomar|dejar|saltarme|aumentar|reducir|bajar|subir|suspender))\b"#,
                    options: .caseInsensitive
                ),
                reason: .adviceRequest,
                label: "advice_es"
            ),
            // Spanish diagnosis asks, for the same reason as `diagnosis_nl`:
            // "tensión alta" contains "tensión", so "¿Tengo la tensión alta?"
            // would otherwise pass as a data lookup.
            DenyPattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b((tengo|padezco|sufro\s+de)\s+(\w+\s+)?(hipertensi[oó]n|hipotensi[oó]n|diabetes|apnea|arritmias?|"#
                        + #"fibrilaci[oó]n|(la\s+)?(tensi[oó]n|presi[oó]n)(\s+arterial)?\s+(alta|baja)|(el\s+)?az[uú]car\s+alto|"#
                        + #"una\s+(enfermedad|afecci[oó]n|carencia|deficiencia))|soy\s+(hipertens[oa]|diab[eé]tic[oa])|"#
                        + #"estoy\s+enferm[oa]|diagn[oó]stic(o|os|a|ar|ado|ada)\b|(esto|eso|mi\s+\w+)\s+(indica|apunta\s+a|sugiere)|"#
                        + #"(indica|apunta\s+a|sugiere)\s+(esto|eso))"#,
                    options: .caseInsensitive
                ),
                reason: .outOfScope,
                label: "diagnosis_es"
            ),
            // Spanish prediction asks ("¿Subirá mi tensión?", "¿Va a bajar mi peso?").
            DenyPattern(
                regex: try! NSRegularExpression(
                    pattern: #"\b((va|van|voy)\s+a\s+[^.!?]{0,30}?\b(subir|bajar|aumentar|disminuir|cambiar|mejorar|empeorar)|"#
                        + #"(subir|bajar|aumentar|disminuir|mejorar|empeorar)[aá]n?\b|"#
                        + #"c[oó]mo\s+(estar[aá]|ser[aá]|ir[aá]|evolucionar[aá])|predec\w*|"#
                        + #"predic(e|en|es|ci[oó]n|ciones)|pron[oó]stic(o|os|ar|a)|previsi[oó]n|qu[eé]\s+pasar[aá])\b"#,
                    options: .caseInsensitive
                ),
                reason: .predictionRequest,
                label: "prediction_es"
            ),
            // Spanish injection markers.
            DenyPattern(
                regex: try! NSRegularExpression(
                    pattern: #"(\b(ignora|ignore|olvida|olvide|descarta|descarte)\s+(todas\s+)?(las|tus|sus)\s+((anteriores|previas)\s+)?"#
                        + #"(instrucciones|reglas|indicaciones|normas)|\b(ignora|olvida)\s+todo\s+lo\s+anterior|"#
                        + #"\b(act[uú]a|haz)\s+como\s+si\s+(fueras|eres)|\bfinge\s+(que\s+)?(eres|ser)|\bcomp[oó]rtate\s+como\b)"#,
                    options: .caseInsensitive
                ),
                reason: .promptInjection,
                label: "injection_es"
            )
        ]
    // swiftlint:enable force_try

    // Spanish allow rows. The array in the classifier names each one right
    // after its Korean twin, so the first-match order holds for Spanish asks.
    // swiftlint:disable force_try
    // Spanish twins sit after the Korean ones, in the same order. Only
    // Spanish spellings ("compara", "comparación"), so an English
    // "comparison" keeps the category it had.
    static let spanishCompare = Pattern(
        regex: try! NSRegularExpression(
            pattern: #"\b(compara(r|do|da)?|comp[aá]rame|comparaci[oó]n|frente\s+a|en\s+comparaci[oó]n\s+con|respecto\s+al?)\b"#,
            options: .caseInsensitive
        ),
        category: .comparison,
        label: "compare_es"
    )

    static let spanishHistoric = Pattern(
        regex: try! NSRegularExpression(
            pattern: #"\b(el\s+\d{1,2}\s+de\s+(enero|febrero|marzo|abril|mayo|junio|julio|agosto|septiembre|setiembre|"#
                + #"octubre|noviembre|diciembre)|(el\s+)?(mes|a[nñ]o|trimestre)\s+pasado|el\s+(mes|a[nñ]o|trimestre)\s+anterior)\b"#,
            options: .caseInsensitive
        ),
        category: .historicLookup,
        label: "historic_es"
    )

    static let spanishPeriod = Pattern(
        regex: try! NSRegularExpression(
            pattern: #"\b(c[oó]mo\s+(fue|ha\s+ido|estuvo|ha\s+estado|me\s+fue)(\s+(mi|la|el|esta|este))?|mu[eé]strame|"#
                + #"ens[eé][nñ]ame|resumen\s+de|res[uú]meme)\s+\w*\s*(semana|mes|d[ií]a|periodo|per[ií]odo)"#,
            options: .caseInsensitive
        ),
        category: .periodSummary,
        label: "period_es"
    )

    static let spanishLookupPhrasing = Pattern(
        regex: try! NSRegularExpression(
            pattern: #"\b(cu[aá]l\s+(es|fue|era)\s+mi|cu[aá]nto\s+(es|fue|era)\s+mi|mi\s+([uú]ltim[oa]|m[aá]xim[oa]|m[ií]nim[oa])|"#
                + #"(peso|pulso|valor|tensi[oó]n)\s+actual|[uú]ltim[oa]\s+(peso|pulso|medici[oó]n|valor|lectura)|"#
                + #"m[aá]s\s+(alt[oa]|baj[oa]))\b"#,
            options: .caseInsensitive
        ),
        category: .dataLookup,
        label: "lookup_phrasing_es"
    )

    /// "tensión" only with its accent: the bare "tension" is English.
    static let spanishMetricName = Pattern(
        regex: try! NSRegularExpression(
            pattern: #"\b(tensión|tension\s+arterial|presi[oó]n\s+arterial|pulso|frecuencia\s+card[ií]aca|peso|sue[nñ]o|pasos|"#
                + #"glucosa|az[uú]car|temperatura|ox[ií]geno|saturaci[oó]n)\b"#,
            options: .caseInsensitive
        ),
        category: .dataLookup,
        label: "metric_name_es"
    )
    // swiftlint:enable force_try
}
