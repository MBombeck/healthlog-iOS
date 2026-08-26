import Foundation

/// Wire-form mirror of `GET /api/insights/pulse/intraday?date=YYYY-MM-DD`
/// (server route `src/app/api/insights/pulse/intraday/route.ts`, payload type
/// `IntradayPulseResult` in `src/lib/analytics/intraday-pulse-io.ts`).
///
/// **What it is.** ONE local day's heart-rate shape: 10-minute (or, for older
/// days, hourly) mean buckets anchored on their minute-of-local-midnight, plus
/// the user's personal resting reference line and — when every confidence gate
/// held — a single cautious "elevated at rest" window.
///
/// **Timezone doctrine (load-bearing).** The server has ALREADY localised the
/// series: `startMinute` is wall-clock minutes since local midnight in
/// ``timezone``, and ``dateKey`` names the day those minutes belong to. The
/// client renders `startMinute` as raw wall time and NEVER converts it through
/// a `Date`/`TimeZone` — a per-client re-derivation would silently shift every
/// bucket for a traveling operator. The payload is the truth for the label.
///
/// **Gaps are real (honesty rule).** A minute slot absent from ``series`` means
/// there was no trustworthy reading, not zero and not "somewhere between the
/// neighbours". The chart splits the line into contiguous runs and never
/// interpolates across a gap (web parity: `connectNulls={false}`,
/// `intraday-pulse-chart.tsx:118-138, 328-344`).
///
/// **``tension`` is DESCRIPTIVE, never a diagnosis.** It marks a stretch that
/// sat measurably above the personal resting reference while at rest — a
/// cautious observation with a deliberately high bar (`ELEVATION_MARGIN_BPM`
/// = 12 bpm, ≥ 30 sustained minutes, movement- and baseline-gated). It is not
/// stress, not a finding, and is framed exactly as the web frames it.
///
/// **Tolerant-first decoding.** ``baselineSource``, ``resolution`` and
/// `tension.partOfDay` decode as RAW strings with typed accessor enums that
/// carry an unknown fallback (precedent: `MetricStatusDTO`,
/// `MetricInsightsRepository`). The server ships faster than the app; a new
/// literal must never cost the whole block.
public struct IntradayPulseDTO: Codable, Sendable, Equatable {
    /// The local day the series describes (`yyyy-MM-dd`), server-resolved.
    public let dateKey: String
    /// The IANA zone `startMinute` is wall-clock in (server-resolved profile
    /// timezone). Display truth — never re-derived from the device.
    public let timezone: String
    /// Bucket width in minutes: `10` (`tenMin`) or `60` (`hourly`).
    public let bucketMinutes: Int
    /// The present buckets, ascending by `startMinute`. Missing slots are REAL
    /// gaps (see the type doc).
    public let series: [Bucket]
    /// The personal resting reference (bpm), or `nil` when the server has no
    /// mature baseline. A reference LINE, never a data point.
    public let baseline: Double?
    /// How the baseline was derived: `resting` | `proxy` | `none`.
    public let baselineSource: String
    /// The single cautious elevated-at-rest window, or `nil` (the common case).
    /// Always `nil` on an `hourly` day.
    public let tension: TensionWindow?
    /// The grain the series was actually computed at: `tenMin` | `hourly`.
    public let resolution: String

    public init(
        dateKey: String,
        timezone: String,
        bucketMinutes: Int,
        series: [Bucket],
        baseline: Double?,
        baselineSource: String,
        tension: TensionWindow?,
        resolution: String
    ) {
        self.dateKey = dateKey
        self.timezone = timezone
        self.bucketMinutes = bucketMinutes
        self.series = series
        self.baseline = baseline
        self.baselineSource = baselineSource
        self.tension = tension
        self.resolution = resolution
    }

    /// One mean bucket, anchored on its start minute-of-local-day.
    public struct Bucket: Codable, Sendable, Equatable, Identifiable {
        /// Minutes since LOCAL midnight (0, 10, 20, … or 0, 60, 120, …).
        public let startMinute: Int
        /// Mean bpm across the raw samples that fell in the bucket.
        public let mean: Double
        /// Raw sample count behind the mean (feeds the coverage disclosure).
        public let count: Int
        /// Low / high bpm of the bucket, when the source carried a spread
        /// (server v1.30.7). Absent for sources that report a mean only.
        public let min: Double?
        public let max: Double?

        /// `startMinute` is unique within a day's series — a stable list id.
        public var id: Int {
            startMinute
        }

        public init(startMinute: Int, mean: Double, count: Int, min: Double? = nil, max: Double? = nil) {
            self.startMinute = startMinute
            self.mean = mean
            self.count = count
            self.min = min
            self.max = max
        }
    }

    /// A detected elevated-at-rest window. DESCRIPTIVE ONLY — see the type doc.
    public struct TensionWindow: Codable, Sendable, Equatable {
        /// Window bounds, minutes since local midnight.
        public let startMinute: Int
        public let endMinute: Int
        /// Coarse part of day the window's midpoint fell in — drives the copy.
        /// `morning` | `afternoon` | `evening` | `night`.
        public let partOfDay: String
        /// Mean bpm across the window.
        public let meanHr: Double
        /// The resting baseline the window was judged against.
        public let baseline: Double
        /// `true` when intraday HRV independently confirmed the stretch.
        public let hrvConfirmed: Bool

        public init(
            startMinute: Int,
            endMinute: Int,
            partOfDay: String,
            meanHr: Double,
            baseline: Double,
            hrvConfirmed: Bool
        ) {
            self.startMinute = startMinute
            self.endMinute = endMinute
            self.partOfDay = partOfDay
            self.meanHr = meanHr
            self.baseline = baseline
            self.hrvConfirmed = hrvConfirmed
        }

        /// Typed accessor over the raw ``partOfDay`` literal.
        public var part: PartOfDay {
            PartOfDay(rawValue: partOfDay) ?? .unknown
        }
    }

    /// Typed ``baselineSource`` accessor with an unknown fallback.
    public enum BaselineSource: String, Sendable {
        case resting
        case proxy
        case none
        case unknown
    }

    /// Typed ``resolution`` accessor with an unknown fallback.
    public enum Resolution: String, Sendable {
        case tenMin
        case hourly
        case unknown
    }

    /// Typed `tension.partOfDay` accessor with an unknown fallback.
    public enum PartOfDay: String, Sendable {
        case morning
        case afternoon
        case evening
        case night
        case unknown
    }

    /// The typed baseline provenance. A `none`/`unknown` source draws NO line.
    public var source: BaselineSource {
        BaselineSource(rawValue: baselineSource) ?? .unknown
    }

    /// The typed grain. `hourly` is labelled honestly in the caption.
    public var grain: Resolution {
        Resolution(rawValue: resolution) ?? .unknown
    }

    /// The baseline value to DRAW, or `nil`. A baseline is only drawable when
    /// the server both sent a number AND claims a real provenance for it — a
    /// `baselineSource: "none"` day must never grow a reference line.
    public var drawableBaseline: Double? {
        guard let baseline, source != .none, source != .unknown else { return nil }
        return baseline
    }

    /// `true` when this day carries anything worth painting. An empty series
    /// with no baseline is "nothing to show", and the block stays hidden.
    public var hasContent: Bool {
        !series.isEmpty
    }
}
