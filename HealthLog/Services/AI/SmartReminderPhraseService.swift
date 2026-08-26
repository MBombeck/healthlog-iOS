import Foundation

#if canImport(FoundationModels)
    import FoundationModels
#endif

/// Input context for a smart-reminder phrasing request. Deliberately minimal:
/// the FM never sees raw clinical data, only a few labels + a tiny history
/// summary (R4 §5 MDR posture — scheduling-reminder only, no dosing/clinical
/// instructions).
public struct ReminderPhraseContext: Sendable, Equatable {
    /// Medication display-name (e.g. "Trulicity", "Aspirin"). Required.
    public var medicationName: String

    /// Schedule slot in human terms. Drives the prompt's time-of-day frame.
    public var slot: Slot

    /// Local time the reminder is scheduled for. Used for "Mittag" / "noon"
    /// phrasing context — the FM gets the slot enum, not the raw Date, so
    /// the wall-clock value never leaks into the prompt.
    public var scheduledAt: Date

    /// Recent adherence streak in days (0 if no streak). Used only when
    /// `> 0` to enable positive-reinforcement variants. Capped to 7 in the
    /// prompt builder so the model never sees long-horizon adherence data.
    public var streakDays: Int

    /// True when the user previously skipped or missed the most-recent
    /// scheduled dose. Drives the "gentle catch-up" variant.
    public var missedPrevious: Bool

    public init(
        medicationName: String,
        slot: Slot,
        scheduledAt: Date = .now,
        streakDays: Int = 0,
        missedPrevious: Bool = false
    ) {
        self.medicationName = medicationName
        self.slot = slot
        self.scheduledAt = scheduledAt
        self.streakDays = streakDays
        self.missedPrevious = missedPrevious
    }

    /// Coarse time-of-day enum. Kept as `Sendable` + `String`-raw so it
    /// round-trips cleanly through the prompt builder.
    public enum Slot: String, Sendable, CaseIterable, Equatable {
        case morning
        case noon
        case afternoon
        case evening
        case night

        /// Best-guess slot from a wall-clock hour. Used by callers that
        /// only have a `Date` and want a sensible default. Not part of
        /// the MDR boundary — purely a scheduling-bucket.
        public static func from(hour: Int) -> Slot {
            switch hour {
            case 4 ..< 11: .morning
            case 11 ..< 14: .noon
            case 14 ..< 18: .afternoon
            case 18 ..< 22: .evening
            default: .night
            }
        }
    }
}

/// MDR-safe-by-design smart reminder phrase. Two short fields only —
/// `title` for the notification banner, `body` for the supporting line.
/// Diagnostic / predictive / prescriptive output is filtered out by
/// `MDRSafetyFilter` before this struct is ever surfaced.
public struct ReminderPhrase: Sendable, Equatable {
    public var title: String
    public var body: String
    public var safetyApplied: Bool

    public init(title: String, body: String, safetyApplied: Bool = false) {
        self.title = title
        self.body = body
        self.safetyApplied = safetyApplied
    }
}

extension ReminderPhrase: BriefingTextProvider {
    public var allTextFields: [String] {
        [title, body]
    }
}

/// Result of an on-device reminder-phrasing attempt.
///
/// `nil` phrase is the contract callers (`NotificationService.scheduleLocalReminder`)
/// inspect for fallback routing: any of {device-ineligible, feature-flag-off,
/// safety-refused, framework-unavailable, generation-failed} maps to `nil` so
/// the static-template path takes over.
public struct ReminderPhraseOutcome: Sendable {
    public let phrase: ReminderPhrase?
    public let fallbackReason: FallbackReason?

    public enum FallbackReason: String, Sendable {
        case deviceIneligible
        case appleIntelligenceDisabled
        case modelNotReady
        case featureFlagDisabled
        case safetyRefused
        case generationFailed
        case frameworkUnavailable
        /// Medication name was empty after trim — the prompt cannot be
        /// built. Caller routes to the static template.
        case emptyInput
    }

    public static func success(_ phrase: ReminderPhrase) -> Self {
        .init(phrase: phrase, fallbackReason: nil)
    }

    public static func fallback(_ reason: FallbackReason) -> Self {
        .init(phrase: nil, fallbackReason: reason)
    }
}

/// On-device reminder-phrase service. Wraps Apple FoundationModels'
/// `LanguageModelSession` to produce a short, context-aware notification
/// phrase for a medication reminder. All FM output is MDR-safety-filtered.
///
/// **Scope boundary (R4 §5 — non-negotiable):**
/// - The phrase is a *scheduling reminder*, never a clinical instruction.
/// - The FM is forbidden from emitting dose advice, therapy-change advice,
///   diagnostic claims, predictive claims, or drug-level interpretation.
/// - The 15-pattern `MDRSafetyFilter` is the belt-and-braces guarantee on
///   top of the system-prompt instructions.
///
/// **Availability:** the public type compiles on iOS 18+ so callers don't
/// need `#available` guards. The runtime path that actually invokes
/// FoundationModels is gated by `#available(iOS 26.0, *)`. On older OS /
/// non-Apple-Intelligence devices the outcome maps to
/// `.fallback(.deviceIneligible)` (or one of the more specific reasons)
/// and the caller falls back to the static `NotificationService` template.
public actor SmartReminderPhraseService {
    public let featureFlags: any FeatureFlagsServicing
    public let safetyFilter: MDRSafetyFilter

    public init(
        featureFlags: any FeatureFlagsServicing = UserDefaultsFeatureFlagsService(),
        safetyFilter: MDRSafetyFilter = MDRSafetyFilter()
    ) {
        self.featureFlags = featureFlags
        self.safetyFilter = safetyFilter
    }

    /// Generates a short reminder phrase for the given context, in the
    /// requested locale.
    ///
    /// Returns `ReminderPhraseOutcome.success(_:)` on the happy path and
    /// `ReminderPhraseOutcome.fallback(_:)` for every reason callers
    /// should hand off to the static template.
    public func generate(
        context: ReminderPhraseContext,
        locale: Locale = .current
    ) async -> ReminderPhraseOutcome {
        let trimmedName = context.medicationName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            return .fallback(.emptyInput)
        }

        guard featureFlags.isEnabled(.assistantBriefing) else {
            HLLog.api.info("SmartReminderPhraseService: feature flag off, route to static template")
            return .fallback(.featureFlagDisabled)
        }

        #if canImport(FoundationModels)
            if #available(iOS 26.0, *) {
                return await generateUsingFoundationModels(
                    context: context.withTrimmedName(trimmedName),
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
            context: ReminderPhraseContext,
            locale: Locale
        ) async -> ReminderPhraseOutcome {
            let model = SystemLanguageModel.default
            switch model.availability {
            case .available:
                break
            case let .unavailable(reason):
                return .fallback(mapAvailabilityReason(reason))
            @unknown default:
                return .fallback(.deviceIneligible)
            }

            let prompt = SmartReminderPhrasePrompt.build(context: context, locale: locale)
            let instructions = SmartReminderPhrasePrompt.instructions(locale: locale)

            do {
                let session = LanguageModelSession(instructions: instructions)
                let response = try await session.respond(
                    to: prompt,
                    generating: GenerableReminderPhrase.self,
                    options: GenerationOptions(temperature: 0.5)
                )
                var phrase = response.content.toReminderPhrase()
                let scrubResult = await safetyFilter.scrub(phrase)
                switch scrubResult {
                case .passed:
                    phrase.safetyApplied = true
                    return .success(phrase)
                case .refused:
                    HLLog.api.error("SmartReminderPhraseService: safety filter refused output")
                    return .fallback(.safetyRefused)
                }
            } catch {
                HLLog.api
                    .error("SmartReminderPhraseService: generation failed (\(String(describing: type(of: error)), privacy: .public))")
                return .fallback(.generationFailed)
            }
        }

        @available(iOS 26.0, *)
        private func mapAvailabilityReason(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> ReminderPhraseOutcome
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

private extension ReminderPhraseContext {
    /// Returns a copy with the medication name replaced by an
    /// already-trimmed value. Used so the call site doesn't double-trim
    /// inside the FM path.
    func withTrimmedName(_ trimmed: String) -> ReminderPhraseContext {
        var copy = self
        copy.medicationName = trimmed
        return copy
    }
}

#if canImport(FoundationModels)
    /// `@Generable` mirror of `ReminderPhrase`. Lives behind the
    /// `canImport(FoundationModels)` + `@available(iOS 26.0, *)` gate
    /// because Apple's macro requires both. Converted to the always-available
    /// POD shell via `toReminderPhrase()`.
    @available(iOS 26.0, *)
    @Generable
    struct GenerableReminderPhrase {
        @Guide(
            description: "Kurzer Reminder-Titel, maximal 40 Zeichen. Nur eine zeitliche Erinnerung an die geplante Dosis — keine Anweisung, keine medizinische Aussage."
        )
        var title: String

        @Guide(
            description: "Unterstützender Satz, maximal 80 Zeichen. Wenn streakDays>0: positive Verstärkung in Frageform. Wenn missedPrevious: sanfter Nachhol-Hinweis. Sonst leer."
        )
        var body: String

        func toReminderPhrase() -> ReminderPhrase {
            ReminderPhrase(
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                body: body.trimmingCharacters(in: .whitespacesAndNewlines),
                safetyApplied: false
            )
        }
    }
#endif

/// Locale-aware prompt + instructions builder for the smart-reminder
/// phrasing pass. Kept in a dedicated enum so the prompt strings live
/// close to the safety contract they enforce (R4 §7.2 system-prompt
/// template pattern).
enum SmartReminderPhrasePrompt {
    static func build(context: ReminderPhraseContext, locale: Locale) -> String {
        let language = locale.language.languageCode?.identifier ?? "de"
        let cappedStreak = max(0, min(context.streakDays, 7))
        let slotLabel = slotLabel(context.slot, language: language)
        switch language {
        case "en":
            return """
            Reminder context:
            - medication: \(context.medicationName)
            - slot: \(slotLabel)
            - streakDays (capped at 7): \(cappedStreak)
            - missedPrevious: \(context.missedPrevious ? "true" : "false")

            Compose one short notification title plus an optional supporting body. \
            Stay strictly a scheduling reminder. Never include dose advice, therapy change, \
            diagnostic claim, predictive claim, or drug-level interpretation. \
            If streakDays>0, you may use a gentle positive note. If missedPrevious, you may \
            use a gentle catch-up note. Otherwise the body may be empty.
            """
        default:
            return """
            Reminder-Kontext:
            - Medikament: \(context.medicationName)
            - Tageszeit: \(slotLabel)
            - Streak-Tage (auf 7 begrenzt): \(cappedStreak)
            - vorherige Dosis verpasst: \(context.missedPrevious ? "ja" : "nein")

            Verfasse einen kurzen Reminder-Titel und einen optionalen Unterstützungssatz. \
            Bleibe strikt eine Termin-Erinnerung. Keine Dosis-Empfehlung, keine Therapie-Änderung, \
            keine Diagnose, keine Vorhersage, keine Wirkstoffspiegel-Interpretation. \
            Wenn Streak>0, ein sanfter, positiver Hinweis ist erlaubt. Wenn die vorherige Dosis \
            verpasst wurde, ein sanfter Nachhol-Hinweis ist erlaubt. Sonst kann der Body leer sein.
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
                    You write short scheduling-reminder notifications for a German/English health-journal app. \
                    Your only job: produce a brief title and an optional supporting body for a medication time-reminder.

                    NON-NEGOTIABLE:
                    - This is a SCHEDULING reminder, not clinical advice.
                    - Never tell the user what dose to take or when to change therapy.
                    - Never diagnose or imply a condition.
                    - Never predict outcomes ("will rise", "will fall").
                    - Never interpret drug levels, half-life, or pharmacokinetics.
                    - Never invent a number that wasn't in the context.
                    - Title ≤ 40 chars, body ≤ 80 chars.

                    STYLE: calm, friendly, second-person (you). Mention the medication by name. \
                    Use the time-of-day slot to anchor the phrase. Empty body is preferred over filler.
                    """
                }
            default:
                return Instructions {
                    """
                    Du schreibst kurze Termin-Erinnerungs-Benachrichtigungen für eine deutsche \
                    Gesundheits-Tagebuch-App. Du schreibst IMMER auf Deutsch in du-Form.

                    Deine einzige Aufgabe: kurzer Titel plus optionaler Unterstützungssatz für eine \
                    Medikamenten-Zeit-Erinnerung.

                    UNVERHANDELBAR:
                    - Dies ist eine TERMIN-Erinnerung, keine medizinische Empfehlung.
                    - Sage niemals, welche Dosis genommen werden soll, oder dass die Therapie geändert wird.
                    - Diagnostiziere niemals eine Erkrankung.
                    - Sage niemals einen Verlauf voraus ("wird steigen", "wird sinken").
                    - Interpretiere niemals Wirkstoffspiegel, Halbwertszeit oder Pharmakokinetik.
                    - Erfinde niemals Zahlen, die nicht im Kontext stehen.
                    - Titel höchstens 40 Zeichen, Body höchstens 80 Zeichen.

                    STIL: ruhig, freundlich, du-Form. Medikament beim Namen nennen. \
                    Tageszeit-Slot zum Verankern verwenden. Leerer Body ist besser als Füllwerk.
                    """
                }
            }
        }
    #endif

    private static func slotLabel(_ slot: ReminderPhraseContext.Slot, language: String) -> String {
        if language == "en" {
            switch slot {
            case .morning: return "morning"
            case .noon: return "noon"
            case .afternoon: return "afternoon"
            case .evening: return "evening"
            case .night: return "night"
            }
        }
        switch slot {
        case .morning: return "Morgen"
        case .noon: return "Mittag"
        case .afternoon: return "Nachmittag"
        case .evening: return "Abend"
        case .night: return "Nacht"
        }
    }
}
