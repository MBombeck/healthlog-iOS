import Foundation

#if canImport(FoundationModels)
    import FoundationModels
#endif

/// Result of an on-device briefing attempt.
///
/// `nil` payload is the contract callers inspect
/// for fallback routing: any of {device-ineligible, safety-refused,
/// capability-not-allowed, framework-not-importable} maps to `nil` so the
/// server-AI path takes over.
public struct OnDeviceBriefingOutcome: Sendable {
    public let briefing: OnDeviceBriefing?
    public let fallbackReason: FallbackReason?

    public enum FallbackReason: String, Sendable {
        case deviceIneligible
        case appleIntelligenceDisabled
        case modelNotReady
        case capabilityNotAllowed
        case safetyRefused
        case generationFailed
        case frameworkUnavailable
        /// ``OnDeviceLanguageGate`` is closed for the interface language:
        /// the model or the MDR filter does not speak it. Never answered in
        /// another language instead.
        case languageUnsupported
    }

    public static func success(_ briefing: OnDeviceBriefing) -> Self {
        .init(briefing: briefing, fallbackReason: nil)
    }

    public static func fallback(_ reason: FallbackReason) -> Self {
        .init(briefing: nil, fallbackReason: reason)
    }
}

/// On-device briefing service. Wraps Apple FoundationModels' `LanguageModelSession`
/// behind a single `generate(...)` entry. All calls are MDR-safety-filtered.
///
/// **Availability:** the public type compiles on iOS 18+ so callers don't
/// need `#available` guards. The runtime path that actually invokes
/// FoundationModels is gated by `#available(iOS 26.0, *)` per R4 §4.2 step 5.
/// On older OS / non-Apple-Intelligence devices, `generate(...)` returns a
/// `fallback(.deviceIneligible)` outcome — the caller renders the legacy
/// server-AI surface (R4 §8).
public actor OnDeviceBriefingService {
    /// #115 · 0.2 — the server-resolved AI capabilities (`/api/auth/me` `ai`).
    /// This service runs only while `.briefing` allows on-device work
    /// (`onDeviceAllowed`). The default is the legacy (pre-v1.39) reading; it
    /// never consults anything a previous build persisted.
    public let aiCapabilities: any AICapabilityReading
    public let safetyFilter: MDRSafetyFilter

    public init(
        aiCapabilities: any AICapabilityReading = LegacyAICapabilities(),
        safetyFilter: MDRSafetyFilter = MDRSafetyFilter()
    ) {
        self.aiCapabilities = aiCapabilities
        self.safetyFilter = safetyFilter
    }

    /// Generates a daily briefing from the given measurements + optional
    /// `HealthScore`, in the requested locale.
    ///
    /// Returns `OnDeviceBriefingOutcome.success(_:)` on the happy path and
    /// `OnDeviceBriefingOutcome.fallback(_:)` for every reason callers
    /// should hand off to the server-AI route.
    public func generate(
        measurements: [Measurement],
        healthScore: HealthScore?,
        locale: Locale
    ) async -> OnDeviceBriefingOutcome {
        guard aiCapabilities.allowsOnDevice(.briefing) else {
            HLLog.api.info("OnDeviceBriefingService: capability briefing does not allow on-device")
            return .fallback(.capabilityNotAllowed)
        }

        #if canImport(FoundationModels)
            if #available(iOS 26.0, *) {
                return await generateUsingFoundationModels(
                    measurements: measurements,
                    healthScore: healthScore,
                    locale: locale
                )
            } else {
                return .fallback(.deviceIneligible)
            }
        #else
            return .fallback(.frameworkUnavailable)
        #endif
    }

    #if canImport(FoundationModels)
        @available(iOS 26.0, *)
        private func generateUsingFoundationModels(
            measurements: [Measurement],
            healthScore: HealthScore?,
            locale: Locale
        ) async -> OnDeviceBriefingOutcome {
            let model = SystemLanguageModel.default
            switch model.availability {
            case .available:
                break
            case let .unavailable(reason):
                return .fallback(mapAvailabilityReason(reason))
            @unknown default:
                return .fallback(.deviceIneligible)
            }
            guard OnDeviceLanguageGate.allows(locale: locale) else {
                return .fallback(.languageUnsupported)
            }

            let prompt = OnDeviceBriefingPrompt.build(
                measurements: measurements,
                healthScore: healthScore,
                locale: locale
            )
            let instructions = OnDeviceBriefingPrompt.instructions(locale: locale)

            do {
                let session = LanguageModelSession(instructions: instructions)
                let response = try await session.respond(
                    to: prompt,
                    generating: GenerableBriefing.self,
                    options: GenerationOptions(temperature: 0.4)
                )
                var briefing = response.content.toOnDeviceBriefing()
                // v0.5.4.1 — guard against the model echoing the on-device
                // identifier scaffolding back into the user-facing string
                // pool. Observed on real devices (operator walkthrough,
                // 2026-05-17): chips rendered "on_device_0 · 7d" /
                // "on_device_1 · 7d" instead of the intended headlines.
                // Drop chips that look like raw identifier tokens; if the
                // summary itself contains the marker, surface as a
                // generation-failure so the caller falls through to the
                // Statistik-Mode floor instead of painting garbage.
                briefing = sanitised(briefing)
                if containsRawIdentifierLeak(briefing) {
                    HLLog.api.error("OnDeviceBriefingService: identifier-leak detected, falling through")
                    return .fallback(.generationFailed)
                }
                let scrubResult = await safetyFilter.scrub(briefing)
                switch scrubResult {
                case .passed:
                    briefing.safetyApplied = true
                    return .success(briefing)
                case .refused:
                    HLLog.api.error("OnDeviceBriefingService: safety filter refused output")
                    return .fallback(.safetyRefused)
                }
            } catch {
                HLLog.api.error("OnDeviceBriefingService: generation failed (\(String(describing: type(of: error)), privacy: .public))")
                return .fallback(.generationFailed)
            }
        }

        /// v0.5.4.1 — drops chip strings that match `on_device_\d+` or are
        /// otherwise empty/whitespace-only. The model is allowed to fail
        /// silently per-chip; the surrounding paragraph stays intact.
        private nonisolated func sanitised(_ briefing: OnDeviceBriefing) -> OnDeviceBriefing {
            var copy = briefing
            copy.keyFindings = briefing.keyFindings.filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return false }
                if Self.identifierLeakRange(in: trimmed) != nil { return false }
                return true
            }
            copy.actionableNudges = briefing.actionableNudges.filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return false }
                if Self.identifierLeakRange(in: trimmed) != nil { return false }
                return true
            }
            return copy
        }

        /// v0.5.4.1 — true when the *paragraph* itself contains a raw
        /// identifier marker. We treat that as a generation-failure
        /// because the user-facing copy is unsalvageable.
        private nonisolated func containsRawIdentifierLeak(_ briefing: OnDeviceBriefing) -> Bool {
            Self.identifierLeakRange(in: briefing.summary) != nil
        }

        /// Matches `on_device_<digits>` anywhere in the string via the
        /// stdlib `range(of:options:)` regex pump — no need to wrangle
        /// `NSRange` ⇄ `Range<String.Index>` conversions for a simple
        /// substring lookup.
        private nonisolated static func identifierLeakRange(in text: String) -> Range<String.Index>? {
            text.range(of: #"on_device_\d+"#, options: .regularExpression)
        }

        @available(iOS 26.0, *)
        private func mapAvailabilityReason(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> OnDeviceBriefingOutcome
            .FallbackReason
        {
            switch reason {
            case .deviceNotEligible:
                return .deviceIneligible
            case .appleIntelligenceNotEnabled:
                return .appleIntelligenceDisabled
            case .modelNotReady:
                return .modelNotReady
            @unknown default:
                return .deviceIneligible
            }
        }
    #endif
}

#if canImport(FoundationModels)
    /// `@Generable` mirror of `OnDeviceBriefing`. Lives behind the
    /// `canImport(FoundationModels)` + `@available(iOS 26.0, *)` gate because
    /// Apple's macro requires both. Converted to the always-available POD
    /// shell via `toOnDeviceBriefing()` for storage + rendering.
    ///
    /// The `@Guide` descriptions are language-neutral English: a description
    /// is baked into the generation schema at compile time and cannot branch
    /// on the session locale. They used to be German, which pulled a Dutch
    /// session's output back into German; the instructions now name the
    /// output language and the guides defer to them.
    @available(iOS 26.0, *)
    @Generable
    struct GenerableBriefing {
        @Guide(
            description: "A calm, observational daily-briefing summary, 1-3 sentences, in the language the instructions require. "
                + "Never diagnostic, never predictive, never prescriptive."
        )
        var summary: String

        @Guide(
            description: "2-4 brief observations from the last 7 days, each factual and anchored in time, "
                + "in the language the instructions require."
        )
        var keyFindings: [String]

        @Guide(
            description: "0-3 gentle nudges phrased as questions, in the language the instructions require. "
                + "Never a statement of what the user should do."
        )
        var actionableNudges: [String]

        @Guide(description: "Self-assessment of the data basis: 0.0 when data is thin, 1.0 when it is ample.")
        var confidence: Float

        func toOnDeviceBriefing() -> OnDeviceBriefing {
            OnDeviceBriefing(
                summary: summary,
                keyFindings: keyFindings,
                actionableNudges: actionableNudges,
                confidence: confidence,
                safetyApplied: false
            )
        }
    }
#endif

/// Locale-aware prompt + instructions builder. Kept in a dedicated enum so
/// the prompt strings live close to the safety contract they enforce
/// (R4 §7.2 system-prompt template).
enum OnDeviceBriefingPrompt {
    static func build(
        measurements: [Measurement],
        healthScore: HealthScore?,
        locale: Locale
    ) -> String {
        let language = AppLanguage.resolve(locale)
        let digest = digestMeasurements(measurements, language: language)
        let scoreLine = if let healthScore {
            "HealthScore: \(healthScore.score)/100" + (healthScore.delta.map { ", Δ \($0)" } ?? "")
        } else {
            "HealthScore: " + language.pick(de: "keine Daten", en: "no data", nl: "geen gegevens")
        }
        switch language {
        case .en:
            return """
            Last 7 days of data:
            \(digest)
            \(scoreLine)

            Compose a calm, observational daily briefing. Stay strictly observational. \
            Never diagnose, predict, or prescribe. If data is thin, say so.
            """
        case .nl:
            return """
            Gegevens van de laatste 7 dagen:
            \(digest)
            \(scoreLine)

            Schrijf een rustige, beschrijvende dagbriefing. Blijf strikt beschrijvend. \
            Nooit diagnosticeren, voorspellen of voorschrijven. Als er weinig gegevens zijn, zeg dat eerlijk.
            """
        case .de:
            return """
            Daten der letzten 7 Tage:
            \(digest)
            \(scoreLine)

            Erstelle ein ruhiges, beobachtendes Tagesbriefing. Bleibe streng beobachtend. \
            Niemals diagnostizieren, vorhersagen oder verordnen. Bei dünner Datenlage sage es ehrlich.
            """
        }
    }

    /// The system-instruction text for one interface language. Outside the
    /// `FoundationModels` gate so tests can pin every language's guardrails.
    static func instructionText(for language: AppLanguage) -> String {
        language.pick(de: germanInstructions, en: englishInstructions, nl: dutchInstructions)
    }

    #if canImport(FoundationModels)
        @available(iOS 26.0, *)
        static func instructions(locale: Locale) -> Instructions {
            let text = instructionText(for: AppLanguage.resolve(locale))
            return Instructions {
                text
            }
        }
    #endif

    private static let englishInstructions = """
    You are a calm, factual daily-briefing voice for a German/English health-journal app.

    NON-NEGOTIABLE:
    - Never make medical diagnoses.
    - Never recommend doses or therapy changes.
    - Never interpret drug levels.
    - Never claim causal links between metrics.
    - Never predict ("will rise", "will fall").
    - Defer to a doctor if values look unusual.

    STYLE: observational, not advisory. Use concrete numbers only if they appear in the data.
    """

    private static let germanInstructions = """
    Du bist eine ruhige, sachliche Tagesbriefing-Stimme für eine deutsche \
    Gesundheits-Tagebuch-App. Schreibe IMMER auf Deutsch in du-Form.

    UNVERHANDELBAR:
    - Du gibst niemals medizinische Diagnosen.
    - Du empfiehlst niemals Dosierungen oder Therapieänderungen.
    - Du interpretierst niemals Wirkstoffspiegel.
    - Du behauptest niemals kausale Zusammenhänge zwischen Werten.
    - Du sagst nichts vorher ("wird steigen", "wird sinken").
    - Bei Auffälligkeiten verweise auf den Arzt.

    STIL: beobachtend, nicht ratend. Konkrete Zahlen nur, wenn sie in den Daten stehen.
    """

    private static let dutchInstructions = """
    Je bent een rustige, zakelijke stem voor de dagbriefing in een \
    gezondheidsdagboek-app. Schrijf ALTIJD in het Nederlands, in je-vorm.

    NIET ONDERHANDELBAAR:
    - Je stelt nooit een medische diagnose.
    - Je raadt nooit doseringen of therapiewijzigingen aan.
    - Je interpreteert nooit medicijnspiegels.
    - Je beweert nooit oorzakelijke verbanden tussen waarden.
    - Je voorspelt niets ("gaat stijgen", "gaat dalen").
    - Bij opvallende waarden verwijs je naar de arts, met de woorden "bespreek dit met je arts".

    STIJL: beschrijvend, niet adviserend. Noem concrete getallen alleen als ze in de gegevens staan.
    """

    /// Compact digest of the last 7 days of measurements (R4 §2.7 — the
    /// 4096-token context window means we never dump raw data).
    ///
    /// v0.5.3 D1 — previously the digest collapsed to a single
    /// "(N) measurements logged" line with no per-kind detail. The
    /// on-device model has nothing concrete to anchor its summary to and
    /// frequently produced output like "Du hast Messungen erfasst" or
    /// "weitere Daten wären hilfreich" — which the operator reads as
    /// "keine Daten" because the surface stays generic. The expanded
    /// digest groups by kind, lists count + latest numeric value, and
    /// keeps the prompt well under the 4096-token budget (we cap at
    /// 12 kinds × ~30 chars/line ≈ 360 chars/locale, plus the legacy
    /// count line). Free-form notes are still excluded (PII).
    private static func digestMeasurements(_ measurements: [Measurement], language: AppLanguage) -> String {
        if measurements.isEmpty {
            return language.pick(
                de: "(keine Messungen im Zeitfenster)",
                en: "(no measurements in window)",
                nl: "(geen metingen in het tijdvenster)"
            )
        }
        let count = measurements.count
        let header = language.pick(
            de: "\(count) Messungen erfasst",
            en: "\(count) measurements logged",
            nl: "\(count) metingen vastgelegd"
        )
        let breakdown = perKindBreakdown(measurements, language: language)
        return breakdown.isEmpty ? header : "\(header)\n\(breakdown)"
    }

    private static func perKindBreakdown(_ measurements: [Measurement], language: AppLanguage) -> String {
        let suffix = language.pick(de: "letzte", en: "latest", nl: "laatste")
        var buckets: [MetricKind: [Measurement]] = [:]
        for m in measurements {
            buckets[m.kind, default: []].append(m)
        }
        let lines: [String] = buckets
            .sorted { $0.value.count > $1.value.count }
            .prefix(12)
            .map { kind, rows in
                let latest = rows.max(by: { $0.recordedAt < $1.recordedAt })
                let label = promptLabel(kind: kind, language: language)
                let valueLabel = latestValueText(latest: latest, kind: kind) ?? "—"
                return "- \(label): \(rows.count)× (\(suffix) \(valueLabel))"
            }
        return lines.joined(separator: "\n")
    }

    /// v0.5.3 D1 — table-driven EN label lookup. Inline `switch` exceeds
    /// the swiftlint cyclomatic-complexity ceiling (12) once 18 cases
    /// land; dictionary form keeps the function trivial and easy to
    /// extend as new `MetricKind` cases arrive.
    private static let englishLabels: [MetricKind: String] = [
        .weight: "Weight",
        .bloodPressure: "Blood pressure",
        .pulse: "Pulse",
        .glucose: "Blood glucose",
        .bodyFat: "Body fat",
        .bodyTemperature: "Body temperature",
        .spo2: "SpO₂",
        .bodyWater: "Body water",
        .boneMass: "Bone mass",
        .sleep: "Sleep",
        .steps: "Steps",
        .restingHeartRate: "Resting HR",
        .hrv: "HRV",
        .vo2Max: "VO₂ max",
        .walkingSpeed: "Walking speed",
        .walkingAsymmetry: "Walking asymmetry",
        .walkingStepLength: "Step length",
        .bmi: "BMI"
    ]

    /// English prompts use the fixed table above; every other language
    /// reads the catalogue name, which is in the interface language.
    private static func promptLabel(kind: MetricKind, language: AppLanguage) -> String {
        switch language {
        case .en: englishLabels[kind] ?? kind.displayName
        case .de, .nl: kind.displayName
        }
    }

    private static func latestValueText(latest: Measurement?, kind: MetricKind) -> String? {
        guard let latest else { return nil }
        switch latest.value {
        case let .scalar(v):
            let formatted = switch kind {
            case .pulse, .restingHeartRate, .spo2, .glucose, .steps:
                String(format: "%.0f", v)
            default:
                String(format: "%.1f", v)
            }
            return kind.unit.isEmpty ? formatted : "\(formatted) \(kind.unit)"
        case let .bloodPressure(systolic, diastolic):
            return String(format: "%.0f/%.0f %@", systolic, diastolic, kind.unit)
        }
    }
}
