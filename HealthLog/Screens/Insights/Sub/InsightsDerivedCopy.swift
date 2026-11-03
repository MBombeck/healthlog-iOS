import Foundation

/// The copy for the server-derived wellness scores and re-frames
/// (`GET /api/insights/derived`): titles, re-frame sentences, honesty caveats,
/// "what is it" explainers and the provenance line. Read by the score ring
/// cards, the re-frame ring cards, `WellnessScoreDetailSheet` and the Insights
/// customization screen.
///
/// 1.4 B4 — these resolvers used to live on `InsightsDerivedBlock`, the
/// "More from your data" text lane. Every derived score became a ring tile, so
/// that lane rendered nothing and was deleted; the copy it shared with the live
/// surfaces stayed and moved here.
enum InsightsDerivedCopy {
    /// Localized display title per derived metric id (web parity copy).
    nonisolated static func title(for metric: String) -> String {
        switch metric {
        // v0.14.1 §4 — clearer, "wertig" wellness names. "Readiness"/"Strain"
        // were unclear (operator feedback); renamed to plain "daily condition /
        // daily load". EN+DE in Localizable.xcstrings. 1.4: German says
        // "Belastung" like the web, because WHOOP's 0 to 21 day strain is
        // "Tagesbelastung" and both can sit one tap apart.
        case "READINESS": String(localized: "Daily condition")
        case "SLEEP_SCORE": String(localized: "Sleep score")
        case "RECOVERY_SCORE": String(localized: "Recovery")
        case "STRESS_SCORE": String(localized: "Stress")
        case "STRAIN_SCORE": String(localized: "Daily load")
        case "FITNESS_AGE": String(localized: "Cardio fitness")
        case "VASCULAR_AGE_DELTA": String(localized: "Vascular age")
        case "HRV_BALANCE": String(localized: "HRV balance")
        default: metric
        }
    }

    /// FITNESS_AGE re-frame sentence (web `vitals.fitness*` copy).
    nonisolated static func fitnessHeadline(_ years: Double?) -> String {
        guard let years, years != 0, let mag = Int(safeServer: abs(years)) else {
            return String(localized: "Cardio fitness typical for your age")
        }
        return years < 0
            ? String(localized: "Cardio fitness of someone ~\(mag) yr younger")
            : String(localized: "Cardio fitness ~\(mag) yr above your age")
    }

    /// VASCULAR_AGE_DELTA re-frame sentence (web `vitals.vascular*` copy).
    nonisolated static func vascularHeadline(_ years: Double?) -> String {
        guard let years, years != 0, let mag = Int(safeServer: abs(years)) else {
            return String(localized: "In line with your age")
        }
        return years < 0
            ? String(localized: "\(mag) yr below your age")
            : String(localized: "\(mag) yr above your age")
    }

    /// HRV_BALANCE band sentence (web `vitals.hrvBand.*` copy).
    nonisolated static func hrvHeadline(_ band: String?) -> String? {
        switch band {
        case "balanced": String(localized: "Balanced for you")
        case "unbalanced": String(localized: "Above your usual range")
        case "low": String(localized: "Below your usual range")
        default: nil
        }
    }

    /// **W-B187 #29 — provenance-aware honesty caveat.**
    ///
    /// RECOVERY_SCORE flips between a WHOOP-native recovery and the computed HRV
    /// proxy server-side (v1.17 W2b). The static `caveat(for:)` copy hardcodes the
    /// computed-proxy framing, which is WRONG once the server resolves a
    /// WHOOP-native value. This overload reads the server-resolved source from the
    /// envelope and returns the honest caveat for that source; every other metric
    /// delegates unchanged to the string-keyed resolver.
    nonisolated static func caveat(for dto: DerivedMetricDTO) -> String? {
        guard dto.metric == "RECOVERY_SCORE" else { return caveat(for: dto.metric) }
        if WellnessScorePresentation.isWhoopNativeRecovery(dto) {
            return String(localized: "From your WHOOP recovery — descriptive, not a clinical recovery measure.")
        }
        return caveat(for: dto.metric)
    }

    /// The honesty caveat per metric (web `*.caveat` copy). `nil` for metrics
    /// the web does not caveat. RECOVERY_SCORE here is the COMPUTED-proxy framing;
    /// the provenance-aware ``caveat(for:)-(DerivedMetricDTO)`` overload swaps in
    /// the WHOOP-native wording when the server resolved a WHOOP recovery.
    nonisolated static func caveat(for metric: String) -> String? {
        switch metric {
        case "READINESS": String(localized: "A wellness proxy, not a recovery or clinical score.")
        case "RECOVERY_SCORE": String(localized: "A descriptive wellness proxy, not a training-grade or clinical recovery measure.")
        // 1.4 B2 — STRESS_SCORE carries no caveat any more: "descriptive, not
        // clinical" is confirmed once at launch, and its "what is it" already
        // says the number comes from heart-rate variability.
        case "STRAIN_SCORE": String(localized: "A descriptive activity-load proxy, not a clinical or training-grade load measure.")
        // GH-Standard R4 — die vier Geschwister oben grenzen jeweils gegen
        // eine KONKURRIERENDE Kategorie ab (WHOOP-Recovery, trainingsreife
        // Last, EDA-Sensorik) und korrigieren damit eine sonst unkorrigierbare
        // Erwartung. Hier gab es keine solche Kategorie — "beschreibend, keine
        // klinische Gefaessbewertung" war die allgemeine Formel, die seit
        // v0.19.0 einmalig beim Start bestaetigt wird
        // (`disclaimer.ack.intro.body`) und nicht auf jeder Flaeche wiederholt
        // gehoert. Was bleibt, ist die Herkunft — und die ist hier die
        // eigentliche Auskunft: die Zahl kommt vom Geraet, nicht von uns.
        case "VASCULAR_AGE_DELTA": String(
                localized: "Your device's own estimate — HealthLog only re-frames it, it does not compute it."
            )
        default: nil
        }
    }

    /// **W-B187 #29 — provenance-aware "Was ist Erholung?" explainer.**
    ///
    /// The static `whatIs(for:)` recovery copy describes the COMPUTED proxy
    /// ("read mainly from your heart-rate variability"). When the server resolves
    /// a WHOOP-native recovery, that description is wrong; this overload reads the
    /// server-resolved source and returns the matching explainer. Every other
    /// metric delegates unchanged to the string-keyed resolver.
    nonisolated static func whatIs(for dto: DerivedMetricDTO) -> String? {
        guard dto.metric == "RECOVERY_SCORE" else { return whatIs(for: dto.metric) }
        if WellnessScorePresentation.isWhoopNativeRecovery(dto) {
            return String(
                localized: "How well your body has bounced back, taken straight from your WHOOP recovery."
            )
        }
        return whatIs(for: dto.metric)
    }

    /// v0.14.1 §6 — "Was ist [Metrik]?" explainer body: WHAT the metric IS
    /// (plain-language definition), NOT how it's computed. Replaces the boring
    /// "Server-computed from your own data" line on the score-detail sheet. EN+DE
    /// in Localizable.xcstrings. `nil` → the sheet omits the explainer body and
    /// falls back to the existing caveat. RECOVERY_SCORE here is the
    /// COMPUTED-proxy framing; the provenance-aware
    /// ``whatIs(for:)-(DerivedMetricDTO)`` overload swaps in the WHOOP-native
    /// wording when the server resolved a WHOOP recovery.
    nonisolated static func whatIs(for metric: String) -> String? {
        switch metric {
        case "READINESS": String(localized: "How ready your body looks for the day, blended from your resting heart rate, HRV and sleep.")
        case "SLEEP_SCORE": String(localized: "A single 0–100 read on last night's sleep — its length, depth and how settled it was.")
        case "RECOVERY_SCORE": String(
                localized: "How well your body has bounced back, read mainly from your heart-rate variability versus your own baseline."
            )
        case "STRESS_SCORE": String(
                localized: "An HRV-derived read of physiological load — how taxed your nervous system looks compared with your calm baseline."
            )
        case "STRAIN_SCORE": String(
                localized: "How much physical load you put on your body today, from your activity and elevated heart rate."
            )
        case "FITNESS_AGE": String(localized: "What your cardio fitness (VO₂max) suggests your body's age is, compared with your real age.")
        case "VASCULAR_AGE_DELTA": String(
                localized: "What your blood-pressure pattern suggests your arteries' age is, compared with your real age."
            )
        case "HRV_BALANCE": String(localized: "Whether your heart-rate variability is sitting in, above or below your own usual range.")
        default: nil
        }
    }

    /// "Was ist [Metrik]?" heading for the explainer — pairs the localized metric
    /// title into a question. EN+DE.
    nonisolated static func whatIsTitle(for metric: String) -> String {
        String(localized: "What is \(title(for: metric))?")
    }

    /// The provenance transparency line: "From your last N days · <source> data".
    /// 1.4 B2 — "Aus Tageswerten der letzten 30 Tage" (it read "Aus deinen
    /// letzten 30 Tagen, täglich-Daten").
    /// 1.4 B4 — a source token this build does not name ("none", or one a
    /// newer server adds) reads as the window alone, never as the raw token
    /// ("Aus none der letzten 30 Tage").
    nonisolated static func provenanceLine(for provenance: DerivedMetricDTO.Provenance) -> String {
        guard let source = sourceLabel(provenance.source) else {
            return String(localized: "insights.provenance.window \(provenance.windowDays)")
        }
        return String(localized: "insights.provenance \(source) \(provenance.windowDays)")
    }

    /// The values the window is built from, as the object of the provenance
    /// line. `nil` for a token without words.
    nonisolated static func sourceLabel(_ source: String) -> String? {
        switch source {
        case "DAY": String(localized: "insights.provenance.source.day")
        case "WEEK": String(localized: "insights.provenance.source.week")
        case "MONTH": String(localized: "insights.provenance.source.month")
        case "YEAR": String(localized: "insights.provenance.source.year")
        case "live": String(localized: "insights.provenance.source.live")
        default: nil
        }
    }
}
