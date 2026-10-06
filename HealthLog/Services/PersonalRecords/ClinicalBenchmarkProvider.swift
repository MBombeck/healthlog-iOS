import Foundation

/// v0.5.5.7 RECONCILE-COMPARE — clinical-benchmark provider for the
/// `PersonalRecordsScreen` comparison band (POLISH-PR deferred #5).
///
/// **Why a protocol seam:** the live provider hard-codes population
/// means + std-devs per `MetricKind` so the comparison band paints
/// without a server round-trip. Tests substitute an in-memory stub.
/// A future server-shipped clinical-range endpoint (`/api/insights/
/// benchmarks/:kind`) can swap to a remote impl without touching the
/// view.
///
/// **Scope contract:** these are *rough* population reference points,
/// not medical advice. The disclaimer is enforced at the view layer
/// via `BenchmarkSourceSheet` — every band tap surfaces the source +
/// "kein medizinischer Befund" copy.
///
/// **Direction semantics:** for `min`-direction kinds (resting HR,
/// body fat — lower is better) and `max`-direction kinds (steps,
/// sleep — higher is better), the band rendering stays the same: we
/// always plot mean ± 1σ as a horizontal stripe and place the user's
/// value as a tick on that stripe. The `RangeFavorability` field
/// helps the consumer surface a sentence like "Dein Wert liegt
/// unterhalb des typischen Bereichs" with the correct semantic.
public protocol ClinicalBenchmarkProvider: Sendable {
    /// Returns the population reference for `kind`, or `nil` when we
    /// don't carry benchmark data for that kind. Callers MUST tolerate
    /// `nil` — the comparison band omits itself when the provider has
    /// nothing to render.
    func benchmark(for kind: MetricKind) -> ClinicalBenchmark?
}

/// One population reference snapshot — the mean + 1σ band plus
/// metadata for label + accessibility output.
///
/// **Sources:** see per-case comments in
/// `LiveClinicalBenchmarkProvider.lookup(_:)`. Every figure cites the
/// most recent CDC NHANES or WHO/AHA publication available at
/// authoring time (2026-05). A clinical advisor pass would refine
/// these against per-cohort tables (age-band, gender, BMI-adjusted).
public struct ClinicalBenchmark: Sendable, Equatable {
    /// Population mean for the metric in the unit the
    /// `PersonalRecord.base.unit` ships in (so the band's tick and
    /// the user value line up without unit conversion at the view).
    public let mean: Double
    /// One standard deviation. The band renders `mean - sigma` to
    /// `mean + sigma` so ~68% of the population lands inside the
    /// stripe.
    public let sigma: Double
    /// Optional clinical floor — values below this are clinically
    /// concerning regardless of population distribution (e.g. SpO₂
    /// < 95% per WHO clinical reference). Drives the optional
    /// "Klinische Untergrenze"-line annotation.
    public let clinicalFloor: Double?
    /// Optional clinical ceiling — symmetric counterpart for
    /// hyper-bounds (BP systolic > 140, BMI > 25 etc.). The band
    /// passes this through to the view for the dashed-rule overlay.
    public let clinicalCeiling: Double?
    /// Direction of "good" — whether the user wants to land below or
    /// above the mean. Drives the favorability copy.
    public let favorability: Favorability
    /// One-line population descriptor for the disclaimer sheet
    /// (e.g. "CDC NHANES 2017-2020, Erwachsene 20+ J.").
    public let sourceLabel: String

    public init(
        mean: Double,
        sigma: Double,
        clinicalFloor: Double? = nil,
        clinicalCeiling: Double? = nil,
        favorability: Favorability,
        sourceLabel: String
    ) {
        self.mean = mean
        self.sigma = sigma
        self.clinicalFloor = clinicalFloor
        self.clinicalCeiling = clinicalCeiling
        self.favorability = favorability
        self.sourceLabel = sourceLabel
    }

    /// Encodes which side of the mean the user's wellbeing benefits
    /// from. `.lowerIsBetter` for resting HR, body fat, BMI (above
    /// healthy band). `.higherIsBetter` for steps, sleep duration.
    /// `.centered` when the bullseye is the mean itself (BP systolic
    /// at ~120 mmHg — both too-low and too-high are sub-optimal).
    public enum Favorability: String, Sendable, Equatable {
        case lowerIsBetter
        case higherIsBetter
        case centered
    }

    /// Returns the band's lower edge. Clamped to 0 because every
    /// metric we benchmark is non-negative.
    public var bandLow: Double {
        max(0, mean - sigma)
    }

    /// Returns the band's upper edge.
    public var bandHigh: Double {
        mean + sigma
    }

    /// Classifies `value` against the band. Drives the one-line
    /// summary the comparison band renders.
    public func classify(_ value: Double) -> Region {
        if value < bandLow {
            return .belowBand
        }
        if value > bandHigh {
            return .aboveBand
        }
        return .insideBand
    }

    /// Three-region classification for the band tick.
    public enum Region: String, Sendable, Equatable {
        case belowBand
        case insideBand
        case aboveBand
    }
}

/// Live clinical-benchmark provider — **carries no benchmark (#115 · 1.3).**
///
/// Until 1.0.3 this type hard-coded population means, spreads and clinical
/// floors/ceilings per `MetricKind` (resting HR 70 ± 12, BP 120 ± 12 with a
/// 140 ceiling, body fat 25 ± 6 %, SpO₂ 97 ± 2 %, BMI 24 ± 4, steps
/// 7500 ± 3000, sleep 7 ± 1 h) and classified the person's record against
/// them. None of those figures came from the server, none knew age, sex or the
/// person's own target, and the classification ("below the typical range",
/// with a favourability) is a clinical status the app does not own.
///
/// The server publishes no benchmark for a personal record (`GET
/// /api/personal-records`, v1.39.0), so the live provider answers `nil` for
/// every kind and the comparison band omits itself — the documented `nil`
/// path of ``ClinicalBenchmarkProvider``. A server-shipped benchmark plugs in
/// behind the same protocol (see the B2 report for the issue text).
public struct LiveClinicalBenchmarkProvider: ClinicalBenchmarkProvider {
    public init() {}

    public func benchmark(for _: MetricKind) -> ClinicalBenchmark? {
        nil
    }
}
