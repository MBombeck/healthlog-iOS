import Foundation

// Client-side mirror of the current server mental-health instrument registry
// (`src/lib/mental-health/instruments.ts`, verified 2026-07-21).
//
// **Server is authoritative.** The persisted record's `totalScore` /
// `severityBand` / `item9Flagged` come from the server POST response and are
// rendered as-is online (`MentalHealthStore`). This mirror exists for exactly two
// SAFETY-CRITICAL, offline-tolerant jobs:
//
//   1. `safetyItemIndex` + ``isSafetyFlagged(_:items:)`` — the item-9 flag is
//      `items[8] > 0`, computed LOCALLY the moment the user submits so the crisis
//      card surfaces even when the upload fails / is offline (mirrors the server's
//      `isSafetyFlagged`, `instruments.ts:111`). The flag is NEVER gated on the
//      total / band.
//   2. `itemCount` (how many pickers to render) + a PROVISIONAL offline total /
//      band (``scoreTotal(_:)`` / ``severityBand(id:total:)``) so a check-in
//      completed offline still shows the user a result instead of a dead spinner.
//      The numbers are a deterministic sum — identical to what the server will
//      compute — but they are clearly flagged "provisional, will sync" in the UI
//      and never persisted locally. Online, the server values win.
//
// Re-wording the items invalidates the score, so the human wording lives only in
// `Localizable.xcstrings` (mirrored verbatim from the server `messages/*.json`),
// never here. This file owns the NUMERIC contract only.

/// Client-side registry for the server-authoritative mental-health instruments.
/// Unknown wire values throw so lossy list decoders can omit a future instrument
/// without silently applying another instrument's score range or bands.
public enum MentalHealthInstrument: String, Codable, Sendable, CaseIterable, Identifiable, Equatable {
    case phq9 = "PHQ9"
    case gad7 = "GAD7"
    case who5 = "WHO5"
    case sci = "SCI"

    public var id: String {
        rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let known = MentalHealthInstrument(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown mental-health instrument \"\(raw)\""
            )
        }
        self = known
    }

    public var keySegment: String {
        switch self {
        case .phq9: "phq9"
        case .gad7: "gad7"
        case .who5: "who5"
        case .sci: "sci"
        }
    }

    public var itemCount: Int {
        switch self {
        case .phq9: 9
        case .gad7: 7
        case .who5: 5
        case .sci: 8
        }
    }

    public var maxScore: Int {
        switch self {
        case .phq9: 27
        case .gad7: 21
        case .who5: 100
        case .sci: 32
        }
    }

    public var itemMax: Int {
        switch self {
        case .phq9, .gad7: 3
        case .sci: 4
        case .who5: 5
        }
    }

    public var optionOrder: [Int] {
        switch self {
        case .phq9, .gad7: [0, 1, 2, 3]
        case .who5: [5, 4, 3, 2, 1, 0]
        case .sci: [4, 3, 2, 1, 0]
        }
    }

    /// Namespace below `mentalHealth` for this instrument's response labels.
    public var optionNamespace: String {
        switch self {
        case .phq9, .gad7: "options"
        case .who5: "who5Options"
        case .sci: "sciOptions"
        }
    }

    /// Optional per-item response groups. SCI uses four different anchor scales.
    public var optionGroups: [String]? {
        switch self {
        case .sci:
            [
                "duration", "duration", "nights", "quality",
                "impact", "impact", "impact", "problemDuration"
            ]
        case .phq9, .gad7, .who5:
            nil
        }
    }

    /// Per-item stem key segments below `mentalHealth.stems`.
    public var stemKeys: [String] {
        switch self {
        case .phq9, .gad7:
            []
        case .who5:
            Array(repeating: "who5.period", count: 5)
        case .sci:
            [
                "sci.night", "sci.night", "sci.night", "sci.night",
                "sci.impact", "sci.impact", "sci.impact", "sci.finally"
            ]
        }
    }

    /// Full localized response-key prefix for one item.
    public func optionKeyPrefix(forItem index: Int) -> String {
        let base = "mentalHealth.\(optionNamespace)"
        guard let optionGroups, optionGroups.indices.contains(index) else {
            return base
        }
        return "\(base).\(optionGroups[index])"
    }

    /// Full localized stem key for one item, or nil when the item is standalone.
    public func stemKey(forItem index: Int) -> String? {
        guard stemKeys.indices.contains(index) else { return nil }
        return "mentalHealth.stems.\(stemKeys[index])"
    }

    public var scoreMultiplier: Int {
        switch self {
        case .who5: 4
        case .phq9, .gad7, .sci: 1
        }
    }

    public var higherIsBetter: Bool {
        switch self {
        case .phq9, .gad7: false
        case .who5, .sci: true
        }
    }

    /// Only PHQ-9 carries the optional, unscored functional follow-up.
    public var showsFunctionalFollowUp: Bool {
        self == .phq9
    }

    public var actionThreshold: Int {
        switch self {
        case .phq9, .gad7: 10
        case .who5: 50
        case .sci: 16
        }
    }

    public var safetyItemIndex: Int? {
        self == .phq9 ? 8 : nil
    }

    public var bands: [Band] {
        switch self {
        case .phq9:
            [
                Band(key: "minimal", min: 0, max: 4),
                Band(key: "mild", min: 5, max: 9),
                Band(key: "moderate", min: 10, max: 14),
                Band(key: "modSevere", min: 15, max: 19),
                Band(key: "severe", min: 20, max: 27)
            ]
        case .gad7:
            [
                Band(key: "minimal", min: 0, max: 4),
                Band(key: "mild", min: 5, max: 9),
                Band(key: "moderate", min: 10, max: 14),
                Band(key: "severe", min: 15, max: 21)
            ]
        case .who5:
            [
                Band(key: "low", min: 0, max: 50),
                Band(key: "good", min: 51, max: 100)
            ]
        case .sci:
            [
                Band(key: "belowThreshold", min: 0, max: 16),
                Band(key: "aboveThreshold", min: 17, max: 32)
            ]
        }
    }

    /// Item wording is validated in all bundled server locales except SCI,
    /// whose redistributed validated wording is English only.
    public var validatedItemLocales: Set<String> {
        switch self {
        case .sci:
            ["en"]
        case .phq9, .gad7, .who5:
            ["de", "en", "es", "fr", "it", "pl"]
        }
    }

    public func hasValidatedItems(locale: String) -> Bool {
        let base = locale
            .lowercased()
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first
            .map(String.init) ?? locale.lowercased()
        return validatedItemLocales.contains(base)
    }

    public var attribution: String {
        switch self {
        case .phq9, .gad7: MentalHealthAttribution.text
        case .who5: MentalHealthAttribution.who5
        case .sci: MentalHealthAttribution.sci
        }
    }

    public struct Band: Sendable, Equatable {
        public let key: String
        public let min: Int
        public let max: Int
    }

    public static func scoreTotal(_ items: [Int]) -> Int {
        items.reduce(0, +)
    }

    public func scoreTotal(items: [Int]) -> Int {
        items.reduce(0, +) * scoreMultiplier
    }

    public func severityBand(forTotal total: Int) -> String {
        let resolved = bands.first { total >= $0.min && total <= $0.max }
        return resolved?.key ?? bands[bands.count - 1].key
    }

    /// Direction-aware follow-up test against an EXPLICIT threshold — used with
    /// the server's `actionThreshold` from the POST response so the online result
    /// never depends on this file's mirrored constant. Only the DIRECTION comes
    /// from here (a structural property of the instrument the wire does not
    /// carry): SCI and WHO-5 flag the LOW side, PHQ-9 and GAD-7 the high side.
    /// Getting SCI's direction wrong would invert an insomnia screen, so it is
    /// pinned by ``MentalHealthInstrument/higherIsBetter`` and tested, never
    /// re-derived at the call site.
    public func needsFollowUp(forTotal total: Int, threshold: Int) -> Bool {
        higherIsBetter ? total <= threshold : total >= threshold
    }

    /// Convenience over the mirrored constant. Reserved for the PROVISIONAL
    /// offline result — online, pass the server's threshold explicitly.
    public func needsFollowUp(forTotal total: Int) -> Bool {
        needsFollowUp(forTotal: total, threshold: actionThreshold)
    }

    public func isSafetyFlagged(items: [Int]) -> Bool {
        guard let index = safetyItemIndex, items.indices.contains(index) else {
            return false
        }
        return items[index] > 0
    }
}

/// Required source attributions, rendered verbatim rather than localized.
public enum MentalHealthAttribution {
    public static let text =
        "Developed by Drs. Robert L. Spitzer, Janet B.W. Williams, Kurt Kroenke and " +
        "colleagues, with an educational grant from Pfizer Inc. No permission " +
        "required to reproduce, translate, display or distribute."

    public static let who5 =
        "World Health Organization. The World Health Organization-Five Well-Being " +
        "Index (WHO-5). Geneva: World Health Organization; 2024. Licence: " +
        "CC BY-NC-SA 3.0 IGO. WHO does not endorse this application."

    public static let sci =
        "Espie CA, Kyle SD, Hames P, et al. The Sleep Condition Indicator: a " +
        "clinical screening tool to evaluate insomnia disorder. BMJ Open " +
        "2014;4:e004183. © Sleepio Limited; free for non-commercial use (CC BY-NC)."
}
