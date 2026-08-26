import Foundation

#if canImport(FoundationModels)
    import FoundationModels
#endif

/// Result of an on-device trend-observation attempt for a single metric.
///
/// `nil` payload is the contract per-metric Insights cards inspect for
/// fallback routing — any of {device-ineligible, safety-refused,
/// feature-flag-off, framework-not-importable, insufficient-data} maps to
/// `nil` so the server-comprehensive path takes over (R4 use-case B).
public struct TrendObservationOutcome: Sendable {
    public let observation: TrendObservation?
    public let fallbackReason: FallbackReason?

    public enum FallbackReason: String, Sendable {
        case deviceIneligible
        case appleIntelligenceDisabled
        case modelNotReady
        case featureFlagDisabled
        case safetyRefused
        case generationFailed
        case frameworkUnavailable
        case insufficientData
    }

    public static func success(_ observation: TrendObservation) -> Self {
        .init(observation: observation, fallbackReason: nil)
    }

    public static func fallback(_ reason: FallbackReason) -> Self {
        .init(observation: nil, fallbackReason: reason)
    }
}

/// On-device trend-observations service. Wraps Apple FoundationModels'
/// `LanguageModelSession` behind a single `observe(...)` entry per metric.
/// Mirrors `OnDeviceBriefingService` (I-1 template) verbatim — same
/// availability gate, same feature-flag short-circuit, same MDRSafetyFilter
/// post-process, same locale switch.
///
/// **Availability:** the public type compiles on iOS 18+. The runtime path
/// that actually invokes FoundationModels is gated by
/// `#available(iOS 26.0, *)` per R4 §4.2 step 5.
public actor TrendObservationsService {
    public let featureFlags: any FeatureFlagsServicing
    public let safetyFilter: MDRSafetyFilter

    /// Minimum samples in the window for a meaningful trend call. Below
    /// this we short-circuit with `.insufficientData` and never spend a
    /// FoundationModels inference (R4 §2.7 — context-window discipline).
    public static let minimumSamplesForTrend = 5

    public init(
        featureFlags: any FeatureFlagsServicing = UserDefaultsFeatureFlagsService(),
        safetyFilter: MDRSafetyFilter = MDRSafetyFilter()
    ) {
        self.featureFlags = featureFlags
        self.safetyFilter = safetyFilter
    }

    /// Generates a trend observation for a single metric from its
    /// time-ordered series in the 30-day-or-longer window. Caller decides
    /// the window length; the service does the digest internally.
    ///
    /// Returns `TrendObservationOutcome.success(_:)` on the happy path and
    /// `TrendObservationOutcome.fallback(_:)` for every reason callers
    /// should hand off to the server-comprehensive route.
    public func observe(
        metric: MetricKind,
        series: [Measurement],
        locale: Locale
    ) async -> TrendObservationOutcome {
        // Feature-flag gate.
        //
        // **F-1 (server brief v1.4.31 §c.1 + R5):** the server locked
        // the wire flag for per-metric trend observations as
        // `assistant.trend`. We consult both the briefing-gate
        // (operator may disable the whole AI surface family) AND the
        // trend-specific gate so an operator can leave Briefing ON
        // while silencing per-metric observations — finer-grained
        // kill-switch, same gate-both philosophy as InsightsScreen.
        guard featureFlags.isEnabled(.assistantBriefing),
              featureFlags.isEnabled(.assistantTrend) else
        {
            HLLog.api.info("TrendObservationsService: feature flag off")
            return .fallback(.featureFlagDisabled)
        }

        // Pre-compute the structural facts (sample count, delta, direction)
        // so the model receives a tight digest and we can short-circuit
        // sparse data without an inference call.
        let scalars = Self.scalarSeries(series, kind: metric)
        guard scalars.count >= Self.minimumSamplesForTrend else {
            return .fallback(.insufficientData)
        }
        let delta = Self.delta(scalars)
        let direction = Self.direction(scalars)

        #if canImport(FoundationModels)
            if #available(iOS 26.0, *) {
                return await generateUsingFoundationModels(
                    metric: metric,
                    series: series,
                    scalars: scalars,
                    delta: delta,
                    direction: direction,
                    locale: locale
                )
            } else {
                return .fallback(.deviceIneligible)
            }
        #else
            return .fallback(.frameworkUnavailable)
        #endif
    }

    // MARK: - Pure helpers (testable without FoundationModels)

    /// Extracts a scalar series from `[Measurement]` for the given metric.
    /// Blood-pressure folds to systolic (the canonical primary per
    /// `MeasurementSeries.primary`). Non-matching kinds are filtered out.
    static func scalarSeries(_ series: [Measurement], kind: MetricKind) -> [Double] {
        series
            .filter { $0.kind == kind }
            .sorted(by: { $0.recordedAt < $1.recordedAt })
            .compactMap { measurement -> Double? in
                switch measurement.value {
                case let .scalar(value): value
                case let .bloodPressure(systolic, _): systolic
                }
            }
    }

    /// Window delta = last - first. Returns `nil` for empty input.
    static func delta(_ scalars: [Double]) -> Double? {
        guard let first = scalars.first, let last = scalars.last, scalars.count >= 2 else {
            return nil
        }
        return last - first
    }

    /// Direction heuristic. We deliberately keep this in the service
    /// (not in the model) so the model is constrained to *describe* what
    /// we already computed — never to extrapolate (MDR row 7).
    static func direction(_ scalars: [Double]) -> TrendObservationDirection {
        guard scalars.count >= minimumSamplesForTrend else {
            return .insufficientData
        }
        guard let delta = delta(scalars), let first = scalars.first, first != 0 else {
            return .stable
        }
        let relative = abs(delta) / abs(first)
        // < 2% change: stable. The threshold is intentionally conservative
        // so we don't manufacture trends from noise.
        guard relative >= 0.02 else {
            // Could still be "mixed" (high variance, zero drift). Detect
            // that via mid-window swing.
            return hasHighVariance(scalars) ? .mixed : .stable
        }
        return delta > 0 ? .rising : .falling
    }

    /// Mid-window peak-to-trough swing relative to mean. Used by
    /// `direction(_:)` to label noisy series as `.mixed` rather than
    /// `.stable` when net drift is small.
    private static func hasHighVariance(_ scalars: [Double]) -> Bool {
        guard let min = scalars.min(), let max = scalars.max() else { return false }
        let mean = scalars.reduce(0, +) / Double(scalars.count)
        guard mean != 0 else { return false }
        return (max - min) / abs(mean) > 0.15
    }

    #if canImport(FoundationModels)
        @available(iOS 26.0, *)
        private func generateUsingFoundationModels(
            metric: MetricKind,
            series: [Measurement],
            scalars: [Double],
            delta: Double?,
            direction: TrendObservationDirection,
            locale: Locale
        ) async -> TrendObservationOutcome {
            let model = SystemLanguageModel.default
            switch model.availability {
            case .available:
                break
            case let .unavailable(reason):
                return .fallback(mapAvailabilityReason(reason))
            @unknown default:
                return .fallback(.deviceIneligible)
            }

            let prompt = TrendObservationPrompt.build(
                metric: metric,
                scalars: scalars,
                delta: delta,
                direction: direction,
                seriesCount: series.count,
                locale: locale
            )
            let instructions = TrendObservationPrompt.instructions(locale: locale)

            do {
                let session = LanguageModelSession(instructions: instructions)
                let response = try await session.respond(
                    to: prompt,
                    generating: GenerableTrendObservation.self,
                    options: GenerationOptions(temperature: 0.3)
                )
                var observation = response.content.toTrendObservation(
                    metric: metric,
                    delta: delta,
                    direction: direction
                )
                let scrubResult = await safetyFilter.scrub(observation)
                switch scrubResult {
                case .passed:
                    observation.safetyApplied = true
                    return .success(observation)
                case .refused:
                    HLLog.api.error("TrendObservationsService: safety filter refused output")
                    return .fallback(.safetyRefused)
                }
            } catch {
                HLLog.api.error(
                    "TrendObservationsService: generation failed (\(String(describing: type(of: error)), privacy: .public))"
                )
                return .fallback(.generationFailed)
            }
        }

        @available(iOS 26.0, *)
        private func mapAvailabilityReason(
            _ reason: SystemLanguageModel.Availability.UnavailableReason
        ) -> TrendObservationOutcome.FallbackReason {
            switch reason {
            case .deviceNotEligible:
                .deviceIneligible
            case .appleIntelligenceNotEnabled:
                .appleIntelligenceDisabled
            case .modelNotReady:
                .modelNotReady
            @unknown default:
                .deviceIneligible
            }
        }
    #endif
}

#if canImport(FoundationModels)
    /// `@Generable` mirror of `TrendObservation`. Lives behind the
    /// `canImport(FoundationModels)` + `@available(iOS 26.0, *)` gate
    /// because Apple's macro requires both. Converted to the
    /// always-available POD shell via `toTrendObservation(...)` for
    /// storage + rendering.
    @available(iOS 26.0, *)
    @Generable
    struct GenerableTrendObservation {
        @Guide(
            description: "Ein ruhiger, beobachtender Satz, der den Trend faktisch beschreibt. 1 Satz. Niemals diagnostisch, niemals prädiktiv, niemals prescriptiv."
        )
        var observation: String

        @Guide(description: "Selbsteinschätzung der Datenbasis: 0.0 wenn Daten dünn, 1.0 wenn umfangreich.")
        var confidence: Float

        func toTrendObservation(
            metric: MetricKind,
            delta: Double?,
            direction: TrendObservationDirection
        ) -> TrendObservation {
            TrendObservation(
                observation: observation,
                metric: metric,
                delta: delta,
                direction: direction,
                confidence: confidence,
                safetyApplied: false
            )
        }
    }
#endif

/// Locale-aware prompt + instructions builder for trend observations.
/// Kept in a dedicated enum so the prompt strings live close to the
/// safety contract they enforce (R4 §7.2).
enum TrendObservationPrompt {
    static func build(
        metric: MetricKind,
        scalars: [Double],
        delta: Double?,
        direction: TrendObservationDirection,
        seriesCount: Int,
        locale: Locale
    ) -> String {
        let language = locale.language.languageCode?.identifier ?? "de"
        let unit = metric.unit
        let metricLabel = metric.displayName
        // A360-5 M-5 — pin numeric formatting to the invariant POSIX locale.
        // This prompt can flow to a server-routed / external model where a
        // device-locale comma decimal ("5,5") is ambiguous or mis-tokenised;
        // emit canonical dot-decimal regardless of the device's locale. The
        // prose language still follows the user's locale (`language` switch).
        let posix = Locale(identifier: "en_US_POSIX")
        let firstStr = scalars.first.map { String(format: "%.1f", locale: posix, $0) } ?? "—"
        let lastStr = scalars.last.map { String(format: "%.1f", locale: posix, $0) } ?? "—"
        let deltaStr = delta.map { String(format: "%+.1f", locale: posix, $0) } ?? "—"
        let directionStr = direction.rawValue
        switch language {
        case "en":
            return """
            Metric: \(metricLabel)
            Window: last 30 days (\(seriesCount) samples)
            Start: \(firstStr) \(unit)
            End: \(lastStr) \(unit)
            Delta: \(deltaStr) \(unit)
            Computed direction: \(directionStr)

            Write one calm, observational sentence describing what the data shows. \
            Stay strictly observational. Never diagnose, never predict, never prescribe.
            """
        default:
            return """
            Metrik: \(metricLabel)
            Zeitfenster: letzte 30 Tage (\(seriesCount) Messungen)
            Start: \(firstStr) \(unit)
            Ende: \(lastStr) \(unit)
            Delta: \(deltaStr) \(unit)
            Berechnete Richtung: \(directionStr)

            Schreibe einen ruhigen, beobachtenden Satz, der den Trend faktisch beschreibt. \
            Bleibe streng beobachtend. Niemals diagnostizieren, vorhersagen oder verordnen.
            """
        }
    }

    #if canImport(FoundationModels)
        @available(iOS 26.0, *)
        static func instructions(locale: Locale) -> Instructions {
            let language = locale.language.languageCode?.identifier ?? "de"
            switch language {
            case "en":
                return Instructions {
                    """
                    You are a calm, factual trend-observation voice for a German/English health-journal app.

                    NON-NEGOTIABLE:
                    - Never make medical diagnoses.
                    - Never recommend doses or therapy changes.
                    - Never interpret drug levels.
                    - Never claim causal links between metrics.
                    - Never predict ("will rise", "will fall").
                    - Defer to a doctor if values look unusual.

                    STYLE: observational, not advisory. One sentence. Use concrete numbers from the data.
                    """
                }
            default:
                return Instructions {
                    """
                    Du bist eine ruhige, sachliche Trend-Beobachtungs-Stimme für eine deutsche \
                    Gesundheits-Tagebuch-App. Schreibe IMMER auf Deutsch in du-Form.

                    UNVERHANDELBAR:
                    - Du gibst niemals medizinische Diagnosen.
                    - Du empfiehlst niemals Dosierungen oder Therapieänderungen.
                    - Du interpretierst niemals Wirkstoffspiegel.
                    - Du behauptest niemals kausale Zusammenhänge zwischen Werten.
                    - Du sagst nichts vorher ("wird steigen", "wird sinken").
                    - Bei Auffälligkeiten verweise auf den Arzt.

                    STIL: beobachtend, nicht ratend. Ein Satz. Konkrete Zahlen aus den Daten verwenden.
                    """
                }
            }
        }
    #endif
}
