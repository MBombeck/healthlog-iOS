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
/// inspect for fallback routing: any of {device-ineligible, capability-not-allowed,
/// safety-refused, framework-unavailable, generation-failed} maps to `nil` so
/// the static-template path takes over.
public struct ReminderPhraseOutcome: Sendable {
    public let phrase: ReminderPhrase?
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

    /// Generates a short reminder phrase for the given context, in the
    /// requested locale.
    ///
    /// Returns `ReminderPhraseOutcome.success(_:)` on the happy path and
    /// `ReminderPhraseOutcome.fallback(_:)` for every reason callers
    /// should hand off to the static template.
    public func generate(
        context: ReminderPhraseContext,
        locale: Locale = AppLanguage.current.locale
    ) async -> ReminderPhraseOutcome {
        let trimmedName = context.medicationName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            return .fallback(.emptyInput)
        }

        guard aiCapabilities.allowsOnDevice(.briefing) else {
            HLLog.api.info("SmartReminderPhraseService: capability briefing does not allow on-device, route to static template")
            return .fallback(.capabilityNotAllowed)
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
            guard OnDeviceLanguageGate.allows(locale: locale) else {
                return .fallback(.languageUnsupported)
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
    ///
    /// The `@Guide` descriptions are language-neutral English (they are baked
    /// in at compile time and cannot follow the session locale); the
    /// instructions name the output language.
    @available(iOS 26.0, *)
    @Generable
    struct GenerableReminderPhrase {
        @Guide(
            description: "Short reminder title, at most 40 characters, in the language the instructions require. "
                + "Only a time reminder for the scheduled dose, no instruction, no medical statement."
        )
        var title: String

        @Guide(
            description: "Supporting sentence, at most 80 characters, in the language the instructions require. "
                + "If streakDays>0: positive reinforcement phrased as a question. "
                + "If missedPrevious: a gentle catch-up note. Otherwise empty."
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
        let language = AppLanguage.resolve(locale)
        let cappedStreak = max(0, min(context.streakDays, 7))
        let slotLabel = slotLabel(context.slot, language: language)
        switch language {
        case .nl:
            return """
            Herinneringscontext:
            - medicijn: \(context.medicationName)
            - moment van de dag: \(slotLabel)
            - reeksdagen (maximaal 7): \(cappedStreak)
            - vorige dosis gemist: \(context.missedPrevious ? "ja" : "nee")

            Schrijf een korte herinneringstitel en een optionele ondersteunende zin. \
            Blijf strikt een tijdsherinnering. Geen doseringsadvies, geen therapiewijziging, \
            geen diagnose, geen voorspelling, geen interpretatie van medicijnspiegels. \
            Als de reeks groter is dan 0, is een zachte, positieve opmerking toegestaan. Als de vorige \
            dosis gemist is, is een zachte inhaalherinnering toegestaan. Anders mag de body leeg blijven.
            """
        case .en:
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
        case .de:
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
        case .ko:
            return koreanPrompt(context: context, slotLabel: slotLabel, cappedStreak: cappedStreak)
        }
    }

    /// The Korean user turn, outside `build` to keep that body under the
    /// function-length limit.
    private static func koreanPrompt(context: ReminderPhraseContext, slotLabel: String, cappedStreak: Int) -> String {
        """
        알림 맥락:
        - 약: \(context.medicationName)
        - 시간대: \(slotLabel)
        - 연속 일수(최대 7): \(cappedStreak)
        - 이전 복용 놓침: \(context.missedPrevious ? "예" : "아니요")

        짧은 알림 제목 하나와 선택적인 보조 문장 하나를 해요체로 써라. \
        철저히 시간 알림으로만 쓴다. 용량 조언, 치료 변경, \
        진단, 예측, 약물 농도 해석은 절대 넣지 않는다. \
        연속 일수가 0보다 크면 부드럽고 긍정적인 한마디를 써도 된다. 이전 복용을 놓쳤다면 \
        다시 챙기자는 부드러운 한마디를 써도 된다. 그 밖에는 본문을 비워도 된다.
        """
    }

    /// The system-instruction text for one interface language. Outside the
    /// `FoundationModels` gate so tests can pin every language's guardrails.
    static func instructionText(for language: AppLanguage) -> String {
        language.pick(de: germanInstructions, en: englishInstructions, nl: dutchInstructions, ko: koreanInstructions)
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

    private static let germanInstructions = """
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

    private static let dutchInstructions = """
    Je schrijft korte herinneringsmeldingen voor een gezondheidsdagboek-app. \
    Schrijf ALTIJD in het Nederlands, in je-vorm.

    Je enige taak: een korte titel plus een optionele ondersteunende zin voor een \
    herinnering aan het innamemoment van een medicijn.

    NIET ONDERHANDELBAAR:
    - Dit is een TIJDS-herinnering, geen medisch advies.
    - Zeg nooit welke dosis ingenomen moet worden of dat de therapie gewijzigd wordt.
    - Stel nooit een diagnose en suggereer geen aandoening.
    - Voorspel nooit een verloop ("gaat stijgen", "gaat dalen").
    - Interpreteer nooit medicijnspiegels, halfwaardetijd of farmacokinetiek.
    - Verzin nooit getallen die niet in de context staan.
    - Titel maximaal 40 tekens, body maximaal 80 tekens.

    STIJL: rustig, vriendelijk, je-vorm. Noem het medicijn bij naam. \
    Gebruik het moment van de dag als anker. Een lege body is beter dan opvulling.
    """

    private static let koreanInstructions = """
    너는 건강 기록 앱의 짧은 복약 시간 알림 문구를 쓴다. \
    항상 한국어 해요체로 쓴다.

    너의 유일한 일: 약 복용 시간 알림에 쓸 짧은 제목과 선택적인 보조 문장을 만드는 것.

    절대 원칙:
    - 이것은 시간 알림이지 의학적 조언이 아니다.
    - 어떤 용량을 복용해야 하는지, 치료를 바꿔야 하는지는 절대 말하지 않는다.
    - 진단하지 않고, 질환을 암시하지 않는다.
    - 경과를 예측하지 않는다("오를 거예요", "내려갈 거예요").
    - 약물 농도, 반감기, 약동학을 해석하지 않는다.
    - 맥락에 없는 숫자를 지어내지 않는다.
    - 제목은 40자 이내, 본문은 80자 이내.

    문체: 차분하고 친근한 해요체. 약 이름을 그대로 부른다. \
    시간대를 문구의 기준으로 삼는다. 군더더기보다 빈 본문이 낫다.
    """

    private static func slotLabel(_ slot: ReminderPhraseContext.Slot, language: AppLanguage) -> String {
        switch slot {
        case .morning: language.pick(de: "Morgen", en: "morning", nl: "ochtend", ko: "아침")
        case .noon: language.pick(de: "Mittag", en: "noon", nl: "middag", ko: "점심")
        case .afternoon: language.pick(de: "Nachmittag", en: "afternoon", nl: "namiddag", ko: "오후")
        case .evening: language.pick(de: "Abend", en: "evening", nl: "avond", ko: "저녁")
        case .night: language.pick(de: "Nacht", en: "night", nl: "nacht", ko: "밤")
        }
    }
}
