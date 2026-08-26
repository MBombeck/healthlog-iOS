import Foundation

// Target-band + display semantics for the custom-metric store. Pure value logic
// — no SwiftUI, no store, no network — so the rules are unit-testable and there
// is exactly ONE definition of "is this value inside the user's target window".

// MARK: - CustomMetricBandStatus

/// Where a reading sits relative to the metric's target window.
///
/// **NEUTRAL render contract**, inherited from `LabRangeStatus`: the target band
/// is the USER'S OWN "good range", not a clinical reference interval and not a
/// medical verdict. `below` / `above` render calm + informative — a value
/// outside the window is *informative*, never an alarm. ``badgeTone`` therefore
/// maps every case to a NON-critical tone.
public enum CustomMetricBandStatus: String, Sendable, Equatable, CaseIterable {
    /// Inside the window (or on a bound — bounds are INCLUSIVE, matching the
    /// labs `LabRangeStatus` doctrine).
    case inBand
    case below
    case above
    /// No usable bound, or the reading carries no number.
    case unknown
}

// MARK: - Band evaluation

public extension CustomMetricDTO {
    /// Classify a reading against this metric's target window.
    ///
    /// Semantics, matching the server's own "both bounds independently optional"
    /// model (`validations/custom-metrics.ts`) and the labs inclusive-bound
    /// doctrine:
    ///   - no bound at all, or `value == nil`      → ``CustomMetricBandStatus/unknown``
    ///   - `value < targetLow`                     → `below`
    ///   - `value > targetHigh`                    → `above`
    ///   - otherwise (incl. exactly on a bound)    → `inBand`
    ///
    /// A ONE-SIDED window is meaningful and supported: with only `targetLow`,
    /// anything at or above it is `inBand`; with only `targetHigh`, anything at
    /// or below it is `inBand`.
    ///
    /// An INVERTED window (`targetLow > targetHigh`) cannot be produced through
    /// this client or the server (both refuse it — schema `.refine` on create,
    /// the partial-update guard at `[id]/route.ts:124-128`), but a legacy row
    /// could carry one. It resolves to `unknown` rather than reporting a value
    /// as simultaneously below and above.
    func bandStatus(for value: Double?) -> CustomMetricBandStatus {
        guard let value, value.isFinite else { return .unknown }
        guard targetLow != nil || targetHigh != nil else { return .unknown }
        if let low = targetLow, let high = targetHigh, low > high { return .unknown }
        if let low = targetLow, value < low { return .below }
        if let high = targetHigh, value > high { return .above }
        return .inBand
    }

    /// Band status of the latest logged value (list-row convenience).
    var latestBandStatus: CustomMetricBandStatus {
        bandStatus(for: latest?.value)
    }
}

public extension CustomMetricEntryDTO {
    /// Classify this entry against `metric`'s CURRENT target window. The window
    /// is a live property of the definition (unlike `unit`, which is snapshotted
    /// per row), so editing the band re-classifies the whole history — which is
    /// what the user means when they move their own goalposts.
    func bandStatus(in metric: CustomMetricDTO) -> CustomMetricBandStatus {
        metric.bandStatus(for: value)
    }
}

// MARK: - Display formatting

/// The ONE way a custom-metric reading renders, so the same value can never
/// appear with different precision on the list row, the stat strip and the
/// detail header. Mirrors `LabValueDisplay`.
public enum CustomMetricFormat {
    /// Typographic placeholder for a genuinely absent reading — not UI copy
    /// (same convention as `LabValueDisplay.absentPlaceholder`).
    public static let absentPlaceholder = "—"

    /// Default precision when the metric declares no `decimals`: 0...2, the
    /// app-wide lab/measurement default.
    public static let defaultFractionRange = 0 ... 2

    /// Format a bare number honouring the metric's `decimals` preference.
    /// `decimals` is server-capped to `0...6`; a rogue out-of-range value is
    /// clamped rather than trusted.
    public static func number(_ value: Double, decimals: Int?) -> String {
        guard let decimals else {
            return value.formatted(.number.precision(.fractionLength(defaultFractionRange)))
        }
        let clamped = min(max(decimals, 0), 6)
        return value.formatted(.number.precision(.fractionLength(clamped)))
    }

    /// Format a reading with its unit, or the em-dash placeholder when absent.
    /// A metric with a blank unit renders the bare number (no trailing space).
    public static func text(value: Double?, unit: String, decimals: Int?) -> String {
        guard let value else { return absentPlaceholder }
        let formatted = number(value, decimals: decimals)
        return unit.isEmpty ? formatted : "\(formatted) \(unit)"
    }
}

public extension CustomMetricEntryDTO {
    /// Rendered reading — number + the row's OWN snapshotted unit, or an em-dash.
    /// `decimals` comes from the parent definition (a display preference, not
    /// historical truth, so it is read live).
    func displayValue(decimals: Int?) -> String {
        CustomMetricFormat.text(value: value, unit: unit, decimals: decimals)
    }
}

public extension CustomMetricDTO {
    /// Rendered latest reading, using the LATEST ENTRY's snapshotted unit (not
    /// this definition's current one) so a unit rename never relabels a value
    /// that was logged under the old unit.
    var latestDisplayValue: String {
        CustomMetricFormat.text(value: latest?.value, unit: latest?.unit ?? unit, decimals: decimals)
    }

    /// Human-readable target window for the definition subtitle, e.g.
    /// "60 – 80 kg", "≥ 60 kg", "≤ 80 kg". `nil` when no bound is set.
    var targetBandDescription: String? {
        let low = targetLow.map { CustomMetricFormat.number($0, decimals: decimals) }
        let high = targetHigh.map { CustomMetricFormat.number($0, decimals: decimals) }
        let suffix = unit.isEmpty ? "" : " \(unit)"
        switch (low, high) {
        case let (low?, high?): return "\(low) – \(high)\(suffix)"
        case let (low?, nil): return "≥ \(low)\(suffix)"
        case let (nil, high?): return "≤ \(high)\(suffix)"
        case (nil, nil): return nil
        }
    }
}

// MARK: - Client-side validation

/// Pre-flight validation for the definition editor, mirroring
/// `createCustomMetricSchema` / `updateCustomMetricSchema` so the user gets an
/// inline message instead of a round-trip 422.
public enum CustomMetricValidation {
    public static let nameMaxLength = 120
    public static let unitMaxLength = 40
    public static let descriptionMaxLength = 2000
    public static let noteMaxLength = 2000
    public static let decimalsRange = 0 ... 6

    /// Why a definition cannot be saved. `nil` == valid.
    public enum Failure: Equatable, Sendable {
        case nameEmpty
        case nameTooLong
        case unitEmpty
        case unitTooLong
        case descriptionTooLong
        case decimalsOutOfRange
        /// The server's `targetLow must not exceed targetHigh` refine — enforced
        /// on create AND, via the partial-update guard, on a single-bound edit.
        case invertedTargetBand
    }

    public static func validate(
        name: String,
        unit: String,
        targetLow: Double?,
        targetHigh: Double?,
        decimals: Int?,
        description: String?
    ) -> Failure? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUnit = unit.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty { return .nameEmpty }
        if trimmedName.count > nameMaxLength { return .nameTooLong }
        if trimmedUnit.isEmpty { return .unitEmpty }
        if trimmedUnit.count > unitMaxLength { return .unitTooLong }
        if let description, description.trimmingCharacters(in: .whitespacesAndNewlines).count > descriptionMaxLength {
            return .descriptionTooLong
        }
        if let decimals, !decimalsRange.contains(decimals) { return .decimalsOutOfRange }
        if let low = targetLow, let high = targetHigh, low > high { return .invertedTargetBand }
        return nil
    }
}
