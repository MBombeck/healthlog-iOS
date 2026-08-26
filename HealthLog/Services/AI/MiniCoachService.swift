import Foundation

#if canImport(FoundationModels)
    import FoundationModels
#endif

/// Outcome of a single Mini-Coach `respond(...)` call.
///
/// The shape is deliberately small — UI rendering is deferred to C4/C5/C6;
/// what we expose here is the plain reply string plus a disposition so
/// the eventual view layer can render *why* a refusal happened without
/// having to inspect strings.
public struct MiniCoachOutcome: Sendable, Equatable {
    public let reply: String
    public let disposition: Disposition

    public enum Disposition: String, Sendable, Equatable {
        case answered
        case refusedByClassifier
        case refusedBySafetyFilter
        case unsupported
        case generationFailed
        case featureFlagDisabled
    }

    public static func answered(_ reply: String) -> Self {
        .init(reply: reply, disposition: .answered)
    }

    public static func refusedByClassifier(_ reply: String) -> Self {
        .init(reply: reply, disposition: .refusedByClassifier)
    }

    public static func refusedBySafetyFilter(_ reply: String) -> Self {
        .init(reply: reply, disposition: .refusedBySafetyFilter)
    }

    public static func unsupported(_ reply: String) -> Self {
        .init(reply: reply, disposition: .unsupported)
    }

    public static func generationFailed(_ reply: String) -> Self {
        .init(reply: reply, disposition: .generationFailed)
    }

    public static func featureFlagDisabled(_ reply: String) -> Self {
        .init(reply: reply, disposition: .featureFlagDisabled)
    }
}

/// Context bundle passed into `respond(...)`. Caller pre-fetches
/// measurements + mood entries from the repositories and hands them in;
/// the service never reaches into stores itself (clean DI seam, easy
/// to test, no MainActor hops inside the actor).
public struct MiniCoachContext: Sendable {
    public let measurements: [Measurement]
    public let moods: [MoodEntry]
    /// Clock injection — defaults to `Date()`. Tests pin this so the
    /// "last 7 days" / "previous 7 days" windows are deterministic.
    public let now: Date

    public init(
        measurements: [Measurement] = [],
        moods: [MoodEntry] = [],
        now: Date = Date()
    ) {
        self.measurements = measurements
        self.moods = moods
        self.now = now
    }
}

/// Mini-Coach on-device service. Wraps Apple FoundationModels'
/// `LanguageModelSession` behind a single `respond(to:context:locale:)`
/// entry that:
///   1. Gate-checks the feature flag.
///   2. Routes the user ask through ``MiniCoachAskClassifier``.
///   3. Binds pre-fetched data via ``MiniCoachDataBinder``.
///   4. Calls the model with a strict, locale-aware system prompt.
///   5. Scrubs the output via ``MDRSafetyFilter``.
///   6. Records the turn in ``MiniCoachHistory``.
///
/// The whole pipeline is **triple-gated**:
///   - `#if canImport(FoundationModels)` (compile)
///   - `@available(iOS 26.0, *)` (OS)
///   - `SystemLanguageModel.default.availability` (runtime / Apple
///     Intelligence enabled)
///
/// On iOS < 26 / non-Apple-Intelligence devices the service returns a
/// stub `.unsupported(_:)` outcome with the localized "Mini-Coach
/// requires iOS 26+" copy.
public actor MiniCoachService {
    public let featureFlags: any FeatureFlagsServicing
    public let classifier: MiniCoachAskClassifier
    public let safetyFilter: MDRSafetyFilter
    public let history: MiniCoachHistory

    public init(
        featureFlags: any FeatureFlagsServicing = UserDefaultsFeatureFlagsService(),
        classifier: MiniCoachAskClassifier = MiniCoachAskClassifier(),
        safetyFilter: MDRSafetyFilter = MDRSafetyFilter(),
        history: MiniCoachHistory = MiniCoachHistory()
    ) {
        self.featureFlags = featureFlags
        self.classifier = classifier
        self.safetyFilter = safetyFilter
        self.history = history
    }

    /// Main entry. Returns the reply outcome; the caller is responsible
    /// for rendering. The history is updated as a side-effect.
    public func respond(
        to ask: String,
        context: MiniCoachContext,
        locale: Locale
    ) async -> MiniCoachOutcome {
        guard featureFlags.isEnabled(.assistantCoach) else {
            HLLog.api.info("MiniCoachService: feature flag off")
            return .featureFlagDisabled(MiniCoachPrompt.refusalCopy(locale: locale))
        }

        // Pre-flight classifier.
        let verdict = await classifier.classify(ask)
        switch verdict {
        case let .refused(reason):
            // Refusal-reason enum raw value — operator-grade, never user text.
            // swiftlint:disable:next hllog_public_privacy_interpolation
            HLLog.api.info("MiniCoachService: classifier refused (\(reason.rawValue, privacy: .public))")
            let refusal = MiniCoachPrompt.refusalCopy(locale: locale)
            // Refused turns leave a sentinel in history (no original
            // output preserved per the operator brief).
            await history.record(userAsk: ask, assistantReply: nil)
            return .refusedByClassifier(refusal)
        case let .allowed(category):
            return await runAllowedTurn(
                ask: ask,
                category: category,
                context: context,
                locale: locale
            )
        }
    }

    /// Test introspection: how many turns the history actor has logged.
    public func historyCompletedTurns() async -> Int {
        await history.completedTurns()
    }

    // MARK: - Allowed-turn pipeline

    private func runAllowedTurn(
        ask: String,
        category: MiniCoachPrompt.AllowedCategory,
        context: MiniCoachContext,
        locale: Locale
    ) async -> MiniCoachOutcome {
        let binder = MiniCoachDataBinder(locale: locale)
        let boundContext = binder.bind(
            category: category,
            measurements: context.measurements,
            moods: context.moods,
            now: context.now
        )
        let snapshot = await history.snapshot()

        #if canImport(FoundationModels)
            if #available(iOS 26.0, *) {
                return await generateUsingFoundationModels(
                    ask: ask,
                    category: category,
                    boundContext: boundContext,
                    history: snapshot,
                    locale: locale
                )
            } else {
                return .unsupported(MiniCoachPrompt.unsupportedFallback(locale: locale))
            }
        #else
            // Mark unused parameters used in the non-FM build to keep
            // strict-concurrency compilers happy.
            _ = (boundContext, snapshot)
            return .unsupported(MiniCoachPrompt.unsupportedFallback(locale: locale))
        #endif
    }

    #if canImport(FoundationModels)
        @available(iOS 26.0, *)
        private func generateUsingFoundationModels(
            ask: String,
            category: MiniCoachPrompt.AllowedCategory,
            boundContext: String,
            history snapshot: [HistoryLine],
            locale: Locale
        ) async -> MiniCoachOutcome {
            let model = SystemLanguageModel.default
            switch model.availability {
            case .available:
                break
            case .unavailable:
                return .unsupported(MiniCoachPrompt.unsupportedFallback(locale: locale))
            @unknown default:
                return .unsupported(MiniCoachPrompt.unsupportedFallback(locale: locale))
            }

            let userTurn = MiniCoachPrompt.userTurn(
                ask: ask,
                category: category,
                boundContext: boundContext,
                history: snapshot,
                locale: locale
            )
            let instructions = MiniCoachPrompt.instructions(locale: locale)

            do {
                let session = LanguageModelSession(instructions: instructions)
                let response = try await session.respond(
                    to: userTurn,
                    options: GenerationOptions(temperature: 0.3)
                )
                let raw = response.content
                if await safetyFilter.containsForbiddenPattern(in: raw) {
                    HLLog.api.error("MiniCoachService: safety filter refused output")
                    let refusal = MiniCoachPrompt.refusalCopy(locale: locale)
                    await history.record(userAsk: ask, assistantReply: nil)
                    return .refusedBySafetyFilter(refusal)
                }
                // UI-Standard R15 (U1) — die Antwort geht unverändert heraus.
                // Bis hierher wurde ihr alle fünf Züge ein Pauschalsatz
                // angehängt („Erinnerung: Ich kann nur Daten erklären …"), der
                // wie Modellausgabe aussah, aber App-Text war. Die Zählung in
                // ``MiniCoachHistory`` bleibt (sie trägt auch den 8-Zug-Cap);
                // nur ihr Rückgabewert wird nicht mehr ausgewertet.
                await history.record(userAsk: ask, assistantReply: raw)
                return .answered(raw)
            } catch {
                HLLog.api.error("MiniCoachService: generation failed (\(String(describing: type(of: error)), privacy: .public))")
                // Generation failures don't leave a `.refused` sentinel —
                // they're transient. The user is free to retry, so we
                // simply skip the history write.
                return .generationFailed(MiniCoachPrompt.refusalCopy(locale: locale))
            }
        }
    #endif
}
