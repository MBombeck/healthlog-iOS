import Foundation
#if canImport(FoundationModels)
    import FoundationModels
#endif

/// **The language gate for every on-device model feature.**
///
/// An on-device feature (briefing, trend observations, Mini-Coach, the
/// on-device Coach, reminder phrases, mood tags, medication extraction) runs
/// in the interface language only when two things hold:
///
/// 1. The safety net speaks it: ``MDRSafetyFilter`` has rows written for the
///    language and ``MiniCoachAskClassifier`` has its deny rows. Both answer
///    through exhaustive switches over ``AppLanguage``, so a new language does
///    not compile until it names them.
/// 2. Apple's model supports it: `SystemLanguageModel.supportsLocale(_:)`.
///
/// Otherwise the feature is unavailable for that language. It never falls
/// back to English output under a Dutch interface: a closed gate means the
/// service's "not available" path, never a different prompt language.
///
/// **Rule 16 switch.** `supportsLocale(_:)` is FoundationModels API (iOS 26).
/// ``asksModelForLanguage`` is the shipped default. It is `true` because
/// `OnDeviceLanguageGateSimulatorTests` calls the real API on the iOS 27.2
/// simulator and gets the same answer every run: de, en and nl supported.
/// With the switch off the gate keeps 1.4 behaviour (German and English run,
/// every newer language stays off).
enum OnDeviceLanguageGate {
    static let asksModelForLanguage = true

    /// Condition 1: the MDR filter and the ask classifier both have rows for
    /// the language.
    static func safetyCovers(_ language: AppLanguage) -> Bool {
        !MDRSafetyFilter.rows(for: language).isEmpty && MiniCoachAskClassifier.covers(language)
    }

    /// The decision itself, free of FoundationModels so tests can drive
    /// every branch. `modelSupports` is the model's answer, `nil` when it was
    /// not asked (switch off).
    static func allows(_ language: AppLanguage, modelSupports: Bool?) -> Bool {
        guard safetyCovers(language) else { return false }
        guard let modelSupports else { return ranOnDeviceBeforeTheGate(language) }
        return modelSupports
    }

    /// 1.4 behaviour, for the switch-off path: the model ran in German and
    /// English, and nothing else existed.
    static func ranOnDeviceBeforeTheGate(_ language: AppLanguage) -> Bool {
        switch language {
        case .de, .en: true
        case .nl, .ko: false
        }
    }

    /// The locale the model is asked about: the language's home locale, so
    /// the answer does not depend on the device region.
    static func modelLocale(for language: AppLanguage) -> Locale {
        Locale(identifier: language.homeLocaleIdentifier)
    }

    #if canImport(FoundationModels)
        /// The gate for a prompt `locale`, resolved through ``AppLanguage``
        /// exactly like the prompt builders resolve it.
        @available(iOS 26.0, *)
        static func allows(locale: Locale, model: SystemLanguageModel = .default) -> Bool {
            let language = AppLanguage.resolve(locale)
            let answer: Bool? = asksModelForLanguage ? model.supportsLocale(modelLocale(for: language)) : nil
            let allowed = allows(language, modelSupports: answer)
            if !allowed {
                // Language code only, never user or model text.
                // swiftlint:disable:next hllog_public_privacy_interpolation
                HLLog.api.info("OnDeviceLanguageGate: closed for \(language.rawValue, privacy: .public)")
            }
            return allowed
        }
    #endif
}
