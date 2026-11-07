import Foundation

/// **The MDR matrix's exemptions.** The `Exemption` type, the three phrase
/// regexes the row-8 / row-9 exemptions are built from, and the
/// anti-laundering guard they share. Moved here unchanged from
/// `MDRSafetyFilter.swift` so the actor body stays under the `file_length`
/// and `type_body_length` caps once every language carries rows; the rows in
/// `MDRSafetyFilter.swift` and `MDRSafetyFilter+Dutch.swift` attach them.
extension MDRSafetyFilter {
    /// **R19b (1.0.3, App Review 1.4.1)** — the two ways a match can be the
    /// thing the app *wants* rather than the thing the matrix forbids.
    ///
    /// Both are deliberately different in scope, because the two false
    /// positives are different in kind. A citation's verb is forbidden only
    /// because of who its subject is, so the exemption has to attach to that
    /// verb — `overlapping`. A possibility handed to a clinician is forbidden
    /// only because of what stands next to it, so that exemption reads the
    /// sentence — `sentenceCarries`.
    struct Exemption {
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
    static let concreteIntervention =
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"\b(Dosis|Dosierung|Tablette|Spritze|Therapie|Medikament\w*|"#
                + #"dose|dosage|tablet|medication|therapy|treatment|"#
                + #"dosering|tabletten|injectie\w*|spuit\w*|medicijn\w*|medicatie|behandeling\w*|pillen)\b"#,
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
    ///
    /// **Dutch (nl).** Dutch cites in three shapes, so it needs three arms: the
    /// body as subject ("De ESH-richtlijnen bevelen … aan"), the body's
    /// "aanbeveling", and the passive "volgens/door de WHO … aanbevolen". Each
    /// arm runs from the body to the flagged verb, so the overlap rule still
    /// scopes the exemption to that one verb.
    static let citedBodyRecommends =
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"\b(Leitlinien?|ESH|ESC|AHA|ACC|ADA|WHO|EMA|guidelines?)\s+"#
                + #"(empfiehlt|empfehlen|recommends?|recommend)\b|"#
                + #"\b(\w*richtlijnen?|ESH|ESC|AHA|ACC|ADA|WHO|EMA|NHG|RIVM|Gezondheidsraad)\s+"#
                + #"(beveelt|bevelen|adviseert|adviseren|raadt|raden)\b|"#
                + #"\baanbeveling\w*\s+van\s+(de\s+)?[\w-]*(richtlijnen?|ESH|ESC|AHA|ACC|ADA|WHO|EMA|NHG|RIVM|Gezondheidsraad)\b|"#
                + #"\b(volgens|door)\s+(de\s+)?[\w-]*(richtlijnen?|ESH|ESC|AHA|ACC|ADA|WHO|EMA|NHG|RIVM|Gezondheidsraad)\b"#
                + #"[^.!?]{0,60}?\b(aanbevolen|aanbeveling\w*|aangeraden|geadviseerd)\b"#,
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
    ///
    /// The Dutch arms follow the German breadth ("mit deinem Arzt" is any
    /// sentence that routes to the doctor): "met/aan/bij je arts", "vraag je
    /// huisarts", "raadpleeg uw arts", "(laten) medisch beoordelen".
    static let clinicianHandOff =
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"(ask\s+your\s+doctor|talk\s+to\s+your\s+(doctor|clinician)|"#
                + #"discuss(ing)?\s+(this\s+)?with\s+your\s+(doctor|clinician)|"#
                + #"mit\s+(deiner|Ihrer)\s+Ärztin|mit\s+(deinem|Ihrem)\s+Arzt|"#
                + #"ärztlich\s+(abklären|besprechen)|"#
                + #"\b(met|aan|door|bij)\s+(je|jouw|uw|een|de)\s+(huis)?(arts|dokter|behandelaar)\b|"#
                + #"\bvraag\s+(het\s+)?(ook\s+)?(je|jouw|uw)\s+(huis)?(arts|dokter)\b|"#
                + #"\braadpleeg\s+(je|jouw|uw|een)\s+(huis)?(arts|dokter)\b|"#
                + #"\bmedisch\s+(laten\s+)?(beoordelen|onderzoeken|nakijken))"#,
            options: .caseInsensitive
        )

    /// The two row-8 exemptions, named once. Every recommendation row carries
    /// the same pair, so spelling the struct out at each call site only invited
    /// them to drift apart — which is precisely the bug fix round 1 found (the
    /// old `prescriptive` row had one of the two and behaved differently from
    /// its English twin as a result).
    static var citationExemption: Exemption {
        Exemption(scope: .overlappingMatch, phrase: citedBodyRecommends, blockedBy: concreteIntervention)
    }

    static var handOffExemption: Exemption {
        Exemption(scope: .sentence, phrase: clinicianHandOff, blockedBy: concreteIntervention)
    }

    /// The row-9 hand-off, WITHOUT the concrete-intervention guard: "this could
    /// point to hypertension, ask your doctor" names no intervention, and
    /// blocking on those words there would refuse ordinary talking points.
    static var handOffExemptionUnguarded: Exemption {
        Exemption(scope: .sentence, phrase: clinicianHandOff)
    }
}
