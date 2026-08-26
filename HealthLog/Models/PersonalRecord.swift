import Foundation
import SwiftUI

/// v0.5.5.6 POLISH-PR — UI-facing view model for the Persönliche-Rekorde
/// surface (`PersonalRecordsScreen`).
///
/// **Why this exists separate from `PersonalRecordDTO`:** the wire DTO is
/// the server contract — flat fields, no view-state, no derived metadata.
/// The new Records screen needs richer per-row affordances:
/// - kind-tinted hero gradient (mapped from `metricType`),
/// - mini sparkline of the 30-day trajectory leading to the record (with a
///   peak marker on the day the record was achieved),
/// - delta-chip ("+12% vs. letztem Monat" / "Neuer Rekord!"),
/// - bucket-classification ("Allzeit" / "Dieses Jahr" / "Dieser Monat" /
///   "Diese Woche") so the segmented picker can filter without re-fetch.
///
/// The view model wraps the DTO (`base`) so server-shipped fields stay the
/// source of truth; everything else is computed at enrichment time
/// (`PersonalRecordsStore.enrich(...)`).
///
/// **Hero selection:** `impressiveness` is a deterministic 0-1 score the
/// hero card uses to pick the "most impressive" record across the user's
/// list. Higher = more impressive. Server may set this directly via
/// `recordImpressiveness` on the wire (future); for derived rows we
/// compute it from `value` × `bucket-recency-weight` so a fresh streak
/// outranks a stale all-time max in the hero slot.
public struct PersonalRecord: Identifiable, Sendable, Equatable {
    public let id: String
    public let base: PersonalRecordDTO
    public let kind: MetricKind?
    /// 30-day trajectory leading to (and including) the record day. Empty
    /// when no series data is available — the card then renders the value
    /// + date only without a sparkline.
    public let sparklineValues: [Double]
    /// 0-based index of the record day inside `sparklineValues`. `nil`
    /// when `sparklineValues` is empty.
    public let peakIndex: Int?
    /// Previous record value (next-best entry of the same metric type)
    /// for the delta chip. `nil` when this is the first record for the
    /// kind — the chip then renders as "Neuer Rekord!".
    public let previousValue: Double?
    /// Pre-classified time bucket for fast filter without re-derivation.
    public let bucket: TimeBucket
    /// Deterministic 0-1 score for hero selection (higher = more
    /// impressive). Used by `PersonalRecordsStore.heroRecord`.
    public let impressiveness: Double

    public init(
        id: String,
        base: PersonalRecordDTO,
        kind: MetricKind?,
        sparklineValues: [Double],
        peakIndex: Int?,
        previousValue: Double?,
        bucket: TimeBucket,
        impressiveness: Double
    ) {
        self.id = id
        self.base = base
        self.kind = kind
        self.sparklineValues = sparklineValues
        self.peakIndex = peakIndex
        self.previousValue = previousValue
        self.bucket = bucket
        self.impressiveness = impressiveness
    }

    /// Delta vs the previous record. `nil` when no previous record exists
    /// — the UI treats `nil` as "Neuer Rekord!".
    public var delta: Delta? {
        guard let previousValue else { return nil }
        let raw = base.value - previousValue
        guard previousValue.isFinite, previousValue != 0 else {
            return Delta(absolute: raw, percent: nil)
        }
        let percent = raw / previousValue
        return Delta(absolute: raw, percent: percent)
    }

    public struct Delta: Sendable, Equatable {
        public let absolute: Double
        /// `nil` when the previous value is zero (percent undefined).
        public let percent: Double?
    }
}

/// Time-bucket the user can filter by on the Records screen.
///
/// **Buckets are anchored to the user's current calendar** — switching
/// time-zones between sessions re-classifies records relative to the
/// fresh "now". This matches the operator's mental model: "Diese Woche"
/// means the calendar-week the user is in right now.
public enum TimeBucket: String, CaseIterable, Identifiable, Sendable {
    // v0.14.1 (#139) — declaration order drives the segmented-picker order
    // (`allCases`). The operator wants the most-recent window FIRST (left) and
    // selected by default: Diese Woche → Dieser Monat → Dieses Jahr → Allzeit.
    // Raw values are unchanged, so persisted selections + the
    // `includes`/`classify` semantics are untouched — only the visual order
    // flipped.
    case week
    case month
    case year
    case allTime

    public var id: String {
        rawValue
    }

    /// Human label for the segmented picker. Localized strings live in
    /// `Localizable.xcstrings` under the same key. Plain `String` here so
    /// the picker can render via `Text(LocalizedStringKey(...))` without
    /// a second translation step.
    public var label: String {
        switch self {
        case .allTime: "Allzeit"
        case .year: "Dieses Jahr"
        case .month: "Dieser Monat"
        case .week: "Diese Woche"
        }
    }

    /// Classify a record `achievedAt` date against `now`. Returns the
    /// narrowest bucket the date qualifies for (week ⊂ month ⊂ year ⊂
    /// allTime). The classifier is total — every date returns at least
    /// `.allTime`.
    public static func classify(
        achievedAt: Date,
        now: Date,
        calendar: Calendar = .current
    ) -> TimeBucket {
        if calendar.isDate(achievedAt, equalTo: now, toGranularity: .weekOfYear) {
            return .week
        }
        if calendar.isDate(achievedAt, equalTo: now, toGranularity: .month) {
            return .month
        }
        if calendar.isDate(achievedAt, equalTo: now, toGranularity: .year) {
            return .year
        }
        return .allTime
    }

    /// Filter predicate — `true` when `record.bucket` should appear in
    /// the currently-selected bucket. The contract is **inclusive
    /// downward**: a `.week` record is also visible in `.month`,
    /// `.year`, and `.allTime`.
    public func includes(_ recordBucket: TimeBucket) -> Bool {
        switch self {
        case .allTime: true
        case .year: recordBucket == .year || recordBucket == .month || recordBucket == .week
        case .month: recordBucket == .month || recordBucket == .week
        case .week: recordBucket == .week
        }
    }
}

/// Resolves the canonical iOS `MetricKind` for a server `metricType`
/// enum value. Returns `nil` for unknown types so the screen can render
/// the row generically without a kind-specific tint / sparkline / icon.
///
/// **Pattern:** mirrors `MetricTypeLocalisation.dictionary` but emits a
/// `MetricKind` instead of a German label. Single source of truth for
/// metric-type → kind resolution; no per-call-site switch ladders.
public enum MetricTypeKindResolver {
    public static func kind(forMetricType raw: String) -> MetricKind? {
        let key = raw.uppercased()
        return dictionary[key]
    }

    private static let dictionary: [String: MetricKind] = [
        "WEIGHT": .weight,
        "BMI": .bmi,
        "BODY_FAT": .bodyFat,
        "BLOOD_PRESSURE": .bloodPressure,
        "BLOOD_PRESSURE_SYS": .bloodPressure,
        "BLOOD_PRESSURE_DIA": .bloodPressure,
        "BP_SYSTOLIC": .bloodPressure,
        "BP_DIASTOLIC": .bloodPressure,
        "PULSE": .pulse,
        "RESTING_HR": .restingHeartRate,
        "RESTING_HEART_RATE": .restingHeartRate,
        "HRV": .hrv,
        "HEART_RATE_VARIABILITY": .hrv,
        "VO2_MAX": .vo2Max,
        "OXYGEN_SATURATION": .spo2,
        "BODY_TEMPERATURE": .bodyTemperature,
        "ACTIVITY_STEPS": .steps,
        "SLEEP_DURATION": .sleep,
        "SLEEP_ASLEEP": .sleep,
        "SLEEP_IN_BED": .sleep,
        "BLOOD_GLUCOSE": .glucose,
        "BLOOD_GLUCOSE_FASTING": .glucose,
        "BLOOD_GLUCOSE_POSTPRANDIAL": .glucose,
        "BLOOD_GLUCOSE_RANDOM": .glucose,
        "BLOOD_GLUCOSE_BEDTIME": .glucose
    ]
}

/// Kind-specific tint used by the `RecordCard` glyph.
///
/// **v0.6.1 mono refresh:** the per-kind Dracula-palette hue mapping is
/// collapsed to a single `HLText.primary` so the record cards live in
/// the same monochrome key as the rest of the app. Differentiation
/// comes from the SF Symbol + headline copy per kind, not from a
/// per-metric hue.
public enum PersonalRecordKindTint {
    public static func color(for _: MetricKind?) -> Color {
        HLText.primary
    }
}
