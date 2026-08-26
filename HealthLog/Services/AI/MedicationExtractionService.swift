import Foundation

#if canImport(FoundationModels)
    import FoundationModels
#endif

/// Result of an on-device medication-draft extraction attempt.
///
/// `nil` draft is the contract callers (`PhotoOfMedSheet`) inspect for
/// fallback routing: any of {device-ineligible, feature-flag-off,
/// safety-refused, framework-unavailable, generation-failed} maps to
/// `nil` so the heuristic-only path (commit 2's
/// `MedicationDraftHeuristic`) takes over.
public struct MedicationExtractionOutcome: Sendable {
    public let draft: MedicationDraft?
    public let fallbackReason: FallbackReason?

    public enum FallbackReason: String, Sendable {
        case deviceIneligible
        case appleIntelligenceDisabled
        case modelNotReady
        case featureFlagDisabled
        case safetyRefused
        case generationFailed
        case frameworkUnavailable
        /// OCR input was empty — neither heuristic nor FoundationModels can
        /// produce a draft from zero text. Caller routes to "type manually".
        case emptyInput
    }

    public static func success(_ draft: MedicationDraft) -> Self {
        .init(draft: draft, fallbackReason: nil)
    }

    public static func fallback(_ reason: FallbackReason) -> Self {
        .init(draft: nil, fallbackReason: reason)
    }
}

/// On-device medication-draft extraction. Wraps Apple FoundationModels'
/// `LanguageModelSession` to convert the OCR transcript into a structured
/// `MedicationDraft` suggestion. All FM output is passed through
/// `MDRSafetyFilter` before reaching the caller — if the model emits any
/// language that trips the 15-pattern matrix (predictive, prescriptive,
/// diagnostic, causal, drug-level), the outcome is `.fallback(.safetyRefused)`
/// and the caller falls back to the lexical heuristic.
///
/// **Availability:** the public type compiles on iOS 18+ so callers don't
/// need `#available` guards. The runtime path that actually invokes
/// FoundationModels is gated by `#available(iOS 26.0, *)`. On older OS /
/// non-Apple-Intelligence devices the outcome maps to
/// `.fallback(.deviceIneligible)` (or one of the more specific reasons)
/// and the caller invokes `MedicationDraftHeuristic.extract(_:)` directly.
public actor MedicationExtractionService {
    public let featureFlags: any FeatureFlagsServicing
    public let safetyFilter: MDRSafetyFilter

    public init(
        featureFlags: any FeatureFlagsServicing = UserDefaultsFeatureFlagsService(),
        safetyFilter: MDRSafetyFilter = MDRSafetyFilter()
    ) {
        self.featureFlags = featureFlags
        self.safetyFilter = safetyFilter
    }

    /// Extracts a `MedicationDraft` from the given OCR transcript.
    ///
    /// On supported devices (iOS 26+, Apple Intelligence enabled), wraps
    /// the transcript in an `@Generable` prompt and asks the on-device LLM
    /// to fill the four fields. The result is MDR-safety-filtered and
    /// returned as `.success(draft)` — `draft.source == .foundationModels`.
    ///
    /// On any fallback path, returns `.fallback(reason)`. Callers should
    /// run `MedicationDraftHeuristic.extract(_:)` as the second-best.
    ///
    /// Caveat: this method **never** auto-confirms anything. The returned
    /// draft is always handed to the user for verification (R4 §5 MDR
    /// posture extended to extraction).
    public func extract(
        from rawText: String,
        locale: Locale = .current
    ) async -> MedicationExtractionOutcome {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .fallback(.emptyInput)
        }

        guard featureFlags.isEnabled(.assistantBriefing) else {
            HLLog.api.info("MedicationExtractionService: feature flag off, route to heuristic")
            return .fallback(.featureFlagDisabled)
        }

        #if canImport(FoundationModels)
            if #available(iOS 26.0, *) {
                return await extractUsingFoundationModels(rawText: trimmed, locale: locale)
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
            rawText: String,
            locale: Locale
        ) async -> MedicationExtractionOutcome {
            let model = SystemLanguageModel.default
            switch model.availability {
            case .available:
                break
            case let .unavailable(reason):
                return .fallback(mapAvailabilityReason(reason))
            @unknown default:
                return .fallback(.deviceIneligible)
            }

            let prompt = MedicationExtractionPrompt.build(rawText: rawText, locale: locale)
            let instructions = MedicationExtractionPrompt.instructions(locale: locale)

            do {
                let session = LanguageModelSession(instructions: instructions)
                let response = try await session.respond(
                    to: prompt,
                    generating: GenerableMedicationDraft.self,
                    options: GenerationOptions(temperature: 0.2)
                )
                let draft = response.content.toMedicationDraft()

                // MDR safety pass — bail if any field looks like advice / a
                // diagnostic claim / a prescriptive verb. The model is
                // instructed to stay neutral (lexical-extraction only) but
                // the filter is the belt-and-braces guarantee.
                let scrubResult = await safetyFilter.scrub(draft)
                switch scrubResult {
                case .passed:
                    return .success(draft)
                case .refused:
                    HLLog.api.error("MedicationExtractionService: safety filter refused output")
                    return .fallback(.safetyRefused)
                }
            } catch {
                HLLog.api
                    .error("MedicationExtractionService: generation failed (\(String(describing: type(of: error)), privacy: .public))")
                return .fallback(.generationFailed)
            }
        }

        @available(iOS 26.0, *)
        private func mapAvailabilityReason(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> MedicationExtractionOutcome
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
    /// `@Generable` mirror of `MedicationDraft`. Lives behind the
    /// `canImport(FoundationModels)` + `@available(iOS 26.0, *)` gate
    /// because Apple's macro requires both. Converted to the always-available
    /// POD shell via `toMedicationDraft()`.
    @available(iOS 26.0, *)
    @Generable
    struct GenerableMedicationDraft {
        @Guide(
            description: "Produktname des Medikaments, exakt wie auf der Packung. Keine Marketing-Worte, keine Krankheits-Begriffe. Nur der Name."
        )
        var name: String

        @Guide(description: "Dosisstärke wie auf der Packung (z.B. '500 mg', '0,5 mg', '100 IE/ml'). Leer wenn nicht eindeutig erkennbar.")
        var doseStrength: String

        @Guide(description: "Darreichungsform (z.B. 'Tablette', 'Filmtablette', 'Spritze', 'Kapsel'). Leer wenn nicht eindeutig erkennbar.")
        var doseForm: String

        @Guide(
            description: "Optionaler Hersteller-Hinweis aus der Packung (Firmenname mit Suffix wie GmbH, AG, KG). Leer wenn nicht erkennbar."
        )
        var manufacturerHint: String

        func toMedicationDraft() -> MedicationDraft {
            MedicationDraft(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                doseStrength: doseStrength.nilIfEmpty,
                doseForm: doseForm.nilIfEmpty,
                manufacturerHint: manufacturerHint.nilIfEmpty,
                source: .foundationModels
            )
        }
    }
#endif

/// `MedicationDraft` conforms to `BriefingTextProvider` so the existing
/// `MDRSafetyFilter.scrub(_:)` works without a parallel interface. All four
/// fields are surfaced for scanning — the filter's per-pattern regex catches
/// any clinical-claim language that might slip into the dose-form or
/// manufacturer fields (defensive: the FM is instructed to stay lexical-only,
/// but the filter doesn't trust the instruction).
extension MedicationDraft: BriefingTextProvider {
    public var allTextFields: [String] {
        [name, doseStrength ?? "", doseForm ?? "", manufacturerHint ?? ""]
    }
}

/// Locale-aware prompt + instructions builder for the medication-extraction
/// pass. Kept in a dedicated enum so the prompt strings live close to the
/// safety contract they enforce (R4 §7.2 system-prompt template pattern,
/// extended to text-extraction).
enum MedicationExtractionPrompt {
    static func build(rawText: String, locale: Locale) -> String {
        let language = locale.language.languageCode?.identifier ?? "de"
        switch language {
        case "en":
            return """
            OCR transcript from a medication-package photo:
            \"\"\"
            \(rawText)
            \"\"\"

            Extract: product name, dose-strength, dose form, manufacturer hint. \
            Use ONLY substrings that appear verbatim in the transcript. \
            If a field is not clearly present, leave it empty. \
            Do NOT infer the drug's use, indication, or any clinical effect.
            """
        default:
            return """
            OCR-Transkript eines Medikamenten-Packungsfotos:
            \"\"\"
            \(rawText)
            \"\"\"

            Extrahiere: Produktname, Dosisstärke, Darreichungsform, Hersteller-Hinweis. \
            Verwende NUR Textstellen, die im Transkript wortwörtlich vorkommen. \
            Wenn ein Feld nicht eindeutig erkennbar ist, lass es leer. \
            Schließe NICHT auf die Indikation, den Anwendungszweck oder die klinische Wirkung.
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
                    You are a lexical-extraction tool for a German health-journal app. \
                    Your only job is to copy four fields out of an OCR transcript: product name, dose-strength, dose form, manufacturer hint.

                    NON-NEGOTIABLE:
                    - Output only text that appears verbatim in the transcript.
                    - Never invent or paraphrase a drug name.
                    - Never explain what the drug does.
                    - Never diagnose, predict, or prescribe.
                    - Never reference a condition, disease, or symptom.
                    - If a field is not clearly present, leave it empty.

                    STYLE: lexical, not advisory. You are a copy-out function, not a doctor.
                    """
                }
            default:
                return Instructions {
                    """
                    Du bist ein lexikalisches Extraktions-Werkzeug für eine deutsche Gesundheits-Tagebuch-App. \
                    Deine einzige Aufgabe: vier Felder aus einem OCR-Transkript kopieren: Produktname, Dosisstärke, Darreichungsform, Hersteller-Hinweis.

                    UNVERHANDELBAR:
                    - Gib nur Textstellen aus, die im Transkript wortwörtlich vorkommen.
                    - Erfinde oder umformuliere niemals einen Medikamentennamen.
                    - Erkläre niemals, was das Medikament bewirkt.
                    - Diagnostiziere, sage nichts vorher, verordne nichts.
                    - Erwähne keine Krankheit, kein Symptom, keine Indikation.
                    - Wenn ein Feld nicht eindeutig erkennbar ist, lass es leer.

                    STIL: lexikalisch, nicht beratend. Du bist eine Kopier-Funktion, kein Arzt.
                    """
                }
            }
        }
    #endif
}

// `String.nilIfEmpty` is provided by `Util/AppEnvironment.swift` as an
// internal-scope helper. We reuse it here instead of redeclaring so the
// trimming semantics stay consistent project-wide.
