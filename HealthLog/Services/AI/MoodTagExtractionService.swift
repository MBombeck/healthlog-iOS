import Foundation

#if canImport(FoundationModels)
    import FoundationModels
#endif

/// Result of an on-device mood-tag extraction attempt.
///
/// `nil` `suggestions` is the contract callers (`MoodStore.suggestTags`,
/// `EditMoodSheet`) inspect for fallback routing: any of {device-ineligible,
/// feature-flag-off, safety-refused, framework-unavailable, generation-failed,
/// empty-input} maps to `nil` so the caller can present a calm, neutral
/// empty-state to the user. We deliberately do not synthesise local tags as
/// a heuristic — mood-tag extraction is semantic, not lexical, and a regex
/// fallback would shadow-implement diagnostic copy (R4 §5 MDR posture).
public struct MoodTagSuggestionOutcome: Sendable {
    public let suggestions: [MoodTagSuggestion]?
    public let fallbackReason: FallbackReason?

    public enum FallbackReason: String, Sendable {
        case deviceIneligible
        case appleIntelligenceDisabled
        case modelNotReady
        case featureFlagDisabled
        case safetyRefused
        case generationFailed
        case frameworkUnavailable
        /// Note input was empty / whitespace-only — there is nothing to
        /// extract from. Caller suppresses the suggestion-row entirely.
        case emptyInput
    }

    public static func success(_ suggestions: [MoodTagSuggestion]) -> Self {
        .init(suggestions: suggestions, fallbackReason: nil)
    }

    public static func fallback(_ reason: FallbackReason) -> Self {
        .init(suggestions: nil, fallbackReason: reason)
    }
}

/// A single tag suggestion extracted from a free-text mood note.
///
/// **MDR posture (per R4 §5):** suggestions are SUGGESTIONS, not facts.
/// The struct deliberately carries no severity, no diagnostic mapping, no
/// causal claim — just a human-legible label the user can tap-to-accept.
/// The text label is consumed verbatim by the user-visible suggestion row;
/// nothing else mutates it before render, so the safety filter scrubbing
/// guarantee holds from extraction site to user surface.
public struct MoodTagSuggestion: Sendable, Equatable, Hashable, Identifiable {
    public let label: String
    public var id: String {
        label
    }

    public init(label: String) {
        self.label = label
    }
}

/// On-device mood-tag extraction. Wraps Apple FoundationModels'
/// `LanguageModelSession` to convert a free-text mood note into a small set
/// of structured tag suggestions. All model output is passed through
/// `MDRSafetyFilter` before reaching the caller — if any field trips the
/// 15-pattern matrix (predictive, prescriptive, diagnostic, causal,
/// drug-level), the outcome is `.fallback(.safetyRefused)`.
///
/// **MDR posture:** the service returns SUGGESTIONS only. The caller MUST
/// surface them in a user-confirmation UI (tap-to-accept). The service
/// itself never persists, never auto-applies, never speaks in clinical
/// terms — it stays at a lexical extraction layer (R4 §5 extended).
///
/// **Availability:** the public type compiles on iOS 18+ so callers don't
/// need `#available` guards. The runtime path that actually invokes
/// FoundationModels is gated by `#available(iOS 26.0, *)`. On older OS /
/// non-Apple-Intelligence devices the outcome maps to
/// `.fallback(.deviceIneligible)`. The caller hides the "Tags vorschlagen"
/// affordance entirely on unsupported devices.
///
/// **Feature flag:** gated behind `.assistantTrend` (per the D-2 dispatch
/// brief — re-uses the same operator-flag that governs trend observations
/// since both surfaces are derivations over per-day data).
public actor MoodTagExtractionService {
    public let featureFlags: any FeatureFlagsServicing
    public let safetyFilter: MDRSafetyFilter

    /// Hard cap on suggestion count. The user surface lists chips in a
    /// horizontal scroll row, so we keep the visible set short to avoid
    /// pagination + decision fatigue. Five is plenty — the v0.5.0 redesign
    /// uses six default + N custom tags and the user rarely picks more
    /// than 3.
    public static let maxSuggestions = 5

    /// Hard cap on per-tag label length (chars). Anything longer is almost
    /// certainly hallucinated free-text, not a tag label.
    public static let maxLabelLength = 32

    public init(
        featureFlags: any FeatureFlagsServicing = UserDefaultsFeatureFlagsService(),
        safetyFilter: MDRSafetyFilter = MDRSafetyFilter()
    ) {
        self.featureFlags = featureFlags
        self.safetyFilter = safetyFilter
    }

    /// Extracts up to `Self.maxSuggestions` tag suggestions from the given
    /// note. Empty / whitespace input short-circuits to `.fallback(.emptyInput)`
    /// — the caller hides the "Tags vorschlagen" affordance.
    ///
    /// On the happy path, returns `.success(suggestions)` where each label
    /// is short, lower-case, MDR-scrubbed. The caller renders them as
    /// tap-to-accept chips; only after the user taps does a label become a
    /// real `MoodEntry.tags` entry.
    public func suggestTags(
        forNote rawNote: String,
        existingTags: [String] = [],
        locale: Locale = .current
    ) async -> MoodTagSuggestionOutcome {
        let trimmed = rawNote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .fallback(.emptyInput)
        }

        guard featureFlags.isEnabled(.assistantTrend) else {
            HLLog.api.info("MoodTagExtractionService: feature flag off")
            return .fallback(.featureFlagDisabled)
        }

        #if canImport(FoundationModels)
            if #available(iOS 26.0, *) {
                return await extractUsingFoundationModels(
                    rawNote: trimmed,
                    existingTags: existingTags,
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
        private func extractUsingFoundationModels(
            rawNote: String,
            existingTags: [String],
            locale: Locale
        ) async -> MoodTagSuggestionOutcome {
            let model = SystemLanguageModel.default
            switch model.availability {
            case .available:
                break
            case let .unavailable(reason):
                return .fallback(mapAvailabilityReason(reason))
            @unknown default:
                return .fallback(.deviceIneligible)
            }

            let prompt = MoodTagExtractionPrompt.build(rawNote: rawNote, existingTags: existingTags, locale: locale)
            let instructions = MoodTagExtractionPrompt.instructions(locale: locale)

            do {
                let session = LanguageModelSession(instructions: instructions)
                let response = try await session.respond(
                    to: prompt,
                    generating: GenerableMoodTagsExtraction.self,
                    options: GenerationOptions(temperature: 0.3)
                )
                let extraction = response.content.toExtraction()

                // MDR safety pass — bail if any label looks like advice / a
                // diagnostic claim / a prescriptive verb. The model is
                // instructed to stay neutral (short lexical labels only)
                // but the filter is the belt-and-braces guarantee.
                let scrubResult = await safetyFilter.scrub(extraction)
                switch scrubResult {
                case .passed:
                    let cleaned = Self.sanitise(extraction.suggestions, existingTags: existingTags)
                    return .success(cleaned)
                case .refused:
                    HLLog.api.error("MoodTagExtractionService: safety filter refused output")
                    return .fallback(.safetyRefused)
                }
            } catch {
                HLLog.api.error(
                    "MoodTagExtractionService: generation failed (\(String(describing: type(of: error)), privacy: .public))"
                )
                return .fallback(.generationFailed)
            }
        }

        @available(iOS 26.0, *)
        private func mapAvailabilityReason(_ reason: SystemLanguageModel.Availability.UnavailableReason)
            -> MoodTagSuggestionOutcome.FallbackReason
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

    /// Post-process model output: trim, de-duplicate (case-insensitive),
    /// drop empties, drop labels already on the entry, cap length + count.
    /// Lives at type-scope so callers + tests can reuse it without an
    /// instance hop.
    static func sanitise(_ rawLabels: [String], existingTags: [String]) -> [MoodTagSuggestion] {
        let existingLower = Set(existingTags.map { $0.lowercased() })
        var seen: Set<String> = []
        var out: [MoodTagSuggestion] = []
        for raw in rawLabels {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let capped = trimmed.count > maxLabelLength ? String(trimmed.prefix(maxLabelLength)) : trimmed
            let key = capped.lowercased()
            guard !existingLower.contains(key) else { continue }
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            out.append(MoodTagSuggestion(label: capped))
            if out.count == maxSuggestions { break }
        }
        return out
    }
}

/// Transport-shell for the FM extraction result, kept iOS-18-compatible so
/// it can also serve as the input to `MDRSafetyFilter.scrub(_:)` without a
/// canImport gate. Mirrors the `OnDeviceBriefing` / `TrendObservation`
/// pattern — POD here, `@Generable` mirror lives in the service.
public struct MoodTagsExtraction: Sendable, Equatable, BriefingTextProvider {
    public var suggestions: [String]

    public init(suggestions: [String]) {
        self.suggestions = suggestions
    }

    public var allTextFields: [String] {
        suggestions
    }
}

#if canImport(FoundationModels)
    /// `@Generable` mirror of `MoodTagsExtraction`. Lives behind the
    /// `canImport(FoundationModels)` + `@available(iOS 26.0, *)` gate
    /// because Apple's macro requires both. Converted to the always-available
    /// POD shell via `toExtraction()`.
    @available(iOS 26.0, *)
    @Generable
    struct GenerableMoodTagsExtraction {
        @Guide(
            description: "Bis zu 5 kurze Tag-Labels (1-2 Wörter, kein Satz), die das Thema der Notiz beschreiben. " +
                "Keine Diagnosen, keine Wertungen, keine Empfehlungen. " +
                "Beispiele: 'Schlaf', 'Stress', 'Arbeit', 'Sport'."
        )
        var suggestions: [String]

        func toExtraction() -> MoodTagsExtraction {
            MoodTagsExtraction(suggestions: suggestions)
        }
    }
#endif

/// Locale-aware prompt + instructions builder. The MDR safety contract is
/// baked into the system prompt — the model is told repeatedly to stay
/// lexical, never diagnostic, never predictive. The `MDRSafetyFilter` post-
/// pass is the belt-and-braces guarantee if the model drifts anyway.
enum MoodTagExtractionPrompt {
    static func build(rawNote: String, existingTags: [String], locale: Locale) -> String {
        let language = locale.language.languageCode?.identifier ?? "de"
        let existingClause: String
        if existingTags.isEmpty {
            existingClause = ""
        } else {
            let joined = existingTags.joined(separator: ", ")
            existingClause = language == "en"
                ? "\n\nTags already on the entry (do NOT repeat): \(joined)"
                : "\n\nBereits gesetzte Tags (NICHT wiederholen): \(joined)"
        }
        switch language {
        case "en":
            return """
            Free-text mood note from a German/English health-journal user:
            \"\"\"
            \(rawNote)
            \"\"\"\(existingClause)

            Extract up to 5 short tag labels (1-2 words each, no sentences) that capture the topics the user wrote about. \
            Use neutral, descriptive labels only. \
            Do NOT diagnose anything. Do NOT recommend anything. Do NOT predict anything. \
            If nothing extracts cleanly, return an empty list.
            """
        default:
            return """
            Freitext-Notiz eines deutschen Stimmungs-Tagebuch-Nutzers:
            \"\"\"
            \(rawNote)
            \"\"\"\(existingClause)

            Extrahiere bis zu 5 kurze Tag-Labels (je 1-2 Wörter, keine Sätze), die die in der Notiz \
            angesprochenen Themen beschreiben. \
            Verwende nur neutrale, beschreibende Labels. \
            Diagnostiziere NICHTS. Empfehle NICHTS. Sage NICHTS vorher. \
            Wenn nichts sauber extrahierbar ist, gib eine leere Liste zurück.
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
                    You are a lexical-extraction tool for a German/English mood-journal app. \
                    Your only job is to extract short tag labels from a free-text mood note.

                    NON-NEGOTIABLE:
                    - Output only short labels (1-2 words each, never sentences).
                    - Never diagnose, predict, or prescribe.
                    - Never reference a condition, disease, or symptom by clinical name.
                    - Never recommend an action.
                    - Never imply causality between metrics.
                    - If nothing extracts cleanly, return an empty list — do NOT invent labels.

                    STYLE: lexical, not advisory. You are a topic-extractor, not a doctor.
                    """
                }
            default:
                return Instructions {
                    """
                    Du bist ein lexikalisches Extraktions-Werkzeug für eine deutsche Stimmungs-Tagebuch-App. \
                    Deine einzige Aufgabe: kurze Tag-Labels aus einer Freitext-Stimmungsnotiz extrahieren.

                    UNVERHANDELBAR:
                    - Gib nur kurze Labels aus (je 1-2 Wörter, niemals Sätze).
                    - Diagnostiziere, sage nichts vorher, verordne nichts.
                    - Erwähne keine Krankheit, kein Symptom und keine Indikation mit klinischem Namen.
                    - Empfehle keine Handlung.
                    - Behaupte keine kausalen Zusammenhänge zwischen Werten.
                    - Wenn nichts sauber extrahierbar ist, gib eine leere Liste zurück — erfinde KEINE Labels.

                    STIL: lexikalisch, nicht beratend. Du bist ein Themen-Extraktor, kein Arzt.
                    """
                }
            }
        }
    #endif
}
