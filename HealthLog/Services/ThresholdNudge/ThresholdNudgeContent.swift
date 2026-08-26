import Foundation

/// **W-THRESHOLD-NUDGE — the factual, non-diagnostic copy for an out-of-range
/// nudge.**
///
/// Built ONLY from the server-resolved reading + its server / user-defined
/// bounds. The copy is *retrospective + factual*: it states the just-logged
/// reading and the range it falls outside of, then carries the standard
/// non-diagnostic disclaimer. It NEVER diagnoses, advises treatment, or
/// reassures — and the absence of a nudge must never read as an all-clear.
///
/// This struct holds resolved `String`s (already localized) so it is trivially
/// `Sendable` + can be asserted on in tests without a notification center.
struct ThresholdNudgeContent: Equatable {
    /// The localized banner title — calm + neutral ("A reading is outside your
    /// range"). Never alarming, never a verdict.
    let title: String
    /// The localized banner body — the factual reading-vs-range sentence plus
    /// the non-diagnostic disclaimer.
    let body: String
    /// The deep-link target so a tap routes to the labs surface (the reading in
    /// context), never a dead-end.
    let deepLink: URL?

    /// A small value+bound bundle, resolved from a lab row. `nil` when the row
    /// is out-of-range per the server but carries no usable bound — in which
    /// case the evaluator withholds the nudge (we never fabricate a range).
    struct Bounded: Equatable {
        let value: Double
        let unit: String
        let low: Double?
        let high: Double?
        /// The breach direction taken straight from the server verdict.
        let isBelow: Bool
    }

    /// Resolve the value + the bound the reading breached, from the server's
    /// verdict. Returns `nil` when the verdict is in-range/unknown, or when the
    /// breached side has no numeric bound (so there is nothing factual to state).
    static func boundedValue(for lab: LabResultDTO) -> Bounded? {
        // Item 1.5 — no number, nothing factual to state about a numeric bound.
        // A qualitative or absent row can never produce a bounded breach.
        guard let value = lab.value else { return nil }
        switch lab.rangeStatus {
        case .inRange, .unknown:
            return nil
        case .below:
            guard lab.referenceLow != nil else { return nil }
            return Bounded(
                value: value,
                unit: lab.unit,
                low: lab.referenceLow,
                high: lab.referenceHigh,
                isBelow: true
            )
        case .above:
            guard lab.referenceHigh != nil else { return nil }
            return Bounded(
                value: value,
                unit: lab.unit,
                low: lab.referenceLow,
                high: lab.referenceHigh,
                isBelow: false
            )
        }
    }

    init(lab: LabResultDTO) {
        title = String(localized: "threshold.nudge.title")

        let analyte = lab.analyte
        let bounded = Self.boundedValue(for: lab)
        // Item 1.5 — fall back to the row's rendered reading (which covers the
        // qualitative + absent cases) instead of a force-unwrapped number.
        let valueText: String = if let bounded {
            Self.formatValue(bounded.value, unit: bounded.unit)
        } else if let value = lab.value {
            Self.formatValue(value, unit: lab.unit)
        } else {
            lab.displayValue
        }
        let rangeText = Self.formatRange(low: bounded?.low, high: bounded?.high)
        let disclaimer = String(localized: "threshold.nudge.disclaimer")

        // The factual sentence: "<analyte> reading of <value> is <below/above>
        // the range you set (<range>)." Each interpolation is a pre-localized
        // String, so the format key stays stable (`%@ … %@ … %@`).
        let factual = if bounded?.isBelow == true {
            String(localized: "threshold.nudge.body.below \(analyte) \(valueText) \(rangeText)")
        } else {
            String(localized: "threshold.nudge.body.above \(analyte) \(valueText) \(rangeText)")
        }
        // Body = factual reading-vs-range + the non-diagnostic disclaimer. The
        // disclaimer is appended (not interpolated) so it reads as a distinct,
        // standing sentence on every nudge.
        //
        // UI-Standard R16 (U1) — dies ist die EINE Fläche, auf der der
        // Pauschalhinweis den Ack-Schalter überlebt: eine Push verlässt die App
        // und erreicht den Nutzer auf dem Sperrbildschirm, wo er seine einmalige
        // Bestätigung nicht dabei hat. Gekürzt wurde er trotzdem — von einem
        // ganzen Satz auf eine Halbzeile.
        body = factual + "\n" + disclaimer

        deepLink = URL(string: "healthlog://labs")
    }

    /// Test/coordinator seam — build content from explicit, already-localized
    /// strings (used by the notification builder + the copy-assertion tests).
    init(title: String, body: String, deepLink: URL?) {
        self.title = title
        self.body = body
        self.deepLink = deepLink
    }

    // MARK: - Formatting (factual, locale-aware)

    /// Format the reading as "<value> <unit>" with a sober precision — integers
    /// stay integer, fractional values get one decimal. Locale-aware via
    /// `formatted`.
    static func formatValue(_ value: Double, unit: String) -> String {
        let numberText: String = if value == value.rounded() {
            Int(value).formatted()
        } else {
            value.formatted(.number.precision(.fractionLength(0 ... 1)))
        }
        let trimmedUnit = unit.trimmingCharacters(in: .whitespaces)
        return trimmedUnit.isEmpty ? numberText : "\(numberText) \(trimmedUnit)"
    }

    /// Format the range "<low>–<high>" / "≥ <low>" / "≤ <high>" depending on
    /// which bounds exist. Pure presentation of the user/server-defined bounds —
    /// no invented values.
    static func formatRange(low: Double?, high: Double?) -> String {
        func fmt(_ v: Double) -> String {
            v == v.rounded() ? Int(v).formatted() : v.formatted(.number.precision(.fractionLength(0 ... 1)))
        }
        switch (low, high) {
        case let (low?, high?):
            return "\(fmt(low))–\(fmt(high))"
        case let (low?, nil):
            return String(localized: "threshold.nudge.range.atLeast \(fmt(low))")
        case let (nil, high?):
            return String(localized: "threshold.nudge.range.atMost \(fmt(high))")
        case (nil, nil):
            return ""
        }
    }
}
