import Foundation

/// Direction of an observed trend across a metric series. Strictly
/// descriptive — never predictive. The model is instructed (R4 §5.1 row 7)
/// to NEVER say "will rise" / "will fall" — only describe what is in the
/// data window.
/// Discrete trend direction reported by `TrendObservation`. Disambiguated
/// from the server-side `TrendDirection` in `ComprehensiveDigest` (which
/// has a different `CaseIterable`/conformance contract) by name: this enum
/// is the on-device-AI observation contract; the server one is the
/// API-decoded server trend.
public enum TrendObservationDirection: String, Sendable, Equatable, Codable, CaseIterable {
    case rising
    case falling
    case stable
    case mixed
    case insufficientData
}

/// MDR-safe-by-design observation shape consumed by per-metric Insights
/// cards. Strictly observational — diagnostic / predictive / prescriptive
/// output is filtered out by `MDRSafetyFilter` before this struct is ever
/// surfaced to the renderer.
///
/// **Why not `@Generable` here?** Same reason as `OnDeviceBriefing` —
/// Apple's `@Generable` macro requires `FoundationModels` (iOS 26+). The
/// plain transport type lives here; the `@Generable` mirror used at the
/// model call site is in `TrendObservationsService` under
/// `#if canImport(FoundationModels)` + `@available(iOS 26.0, *)`.
public struct TrendObservation: Sendable, Equatable {
    /// One short, calm sentence describing what the data shows. Never
    /// diagnostic, never predictive, never prescriptive.
    public var observation: String

    /// Which metric this observation describes.
    public var metric: MetricKind

    /// Numeric delta versus the start of the window (unit per-metric).
    /// `nil` when the window is too sparse for a meaningful delta.
    public var delta: Double?

    /// Discrete trend direction. `.insufficientData` when fewer than
    /// `minimumSamplesForTrend` samples in the window.
    public var direction: TrendObservationDirection

    /// Self-rated confidence by the model (0.0 = data thin, 1.0 = ample).
    public var confidence: Float

    /// `true` after `MDRSafetyFilter.scrub` has passed; never set by the
    /// model directly. Tests rely on this to verify the filter ran.
    public var safetyApplied: Bool

    public init(
        observation: String,
        metric: MetricKind,
        delta: Double? = nil,
        direction: TrendObservationDirection = .stable,
        confidence: Float = 0,
        safetyApplied: Bool = false
    ) {
        self.observation = observation
        self.metric = metric
        self.delta = delta
        self.direction = direction
        self.confidence = confidence
        self.safetyApplied = safetyApplied
    }
}

extension TrendObservation: BriefingTextProvider {
    public var allTextFields: [String] {
        [observation]
    }
}
