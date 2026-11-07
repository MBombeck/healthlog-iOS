import Foundation
#if canImport(FoundationModels)
    import FoundationModels
#endif
@testable import HealthLog
import Testing

/// **Rule 16 evidence for ``OnDeviceLanguageGate/asksModelForLanguage``.**
///
/// Calls the real `SystemLanguageModel.supportsLocale(_:)` (FoundationModels,
/// iOS 26) with the exact locale the gate passes, for every interface
/// language, three times in a row. The switch ships on because this suite is
/// green on the iOS 27.2 simulator: no crash, and the same answer (supported)
/// for de, en and nl on every call. If Apple ever drops one of them, this
/// suite turns red before the gate quietly closes a feature for that language.
@Suite("Language gate: the real model answers for every interface language")
struct OnDeviceLanguageGateSimulatorTests {
    @Test("supportsLocale answers yes for every interface language, every time")
    func modelSupportsEveryInterfaceLanguage() {
        #if canImport(FoundationModels)
            guard #available(iOS 26.0, *) else {
                Issue.record("FoundationModels needs iOS 26; the rule 16 evidence runs on the iOS 27.2 simulator")
                return
            }
            let model = SystemLanguageModel.default
            for language in AppLanguage.allCases {
                let locale = OnDeviceLanguageGate.modelLocale(for: language)
                let answers = (0 ..< 3).map { _ in model.supportsLocale(locale) }
                #expect(answers == [true, true, true], "\(locale.identifier): \(answers)")
                #expect(OnDeviceLanguageGate.allows(locale: language.locale, model: model))
            }
        #else
            Issue.record("FoundationModels is not importable in this build")
        #endif
    }

    @Test("the gate is switched on, as the evidence above allows")
    func switchIsOn() {
        #expect(OnDeviceLanguageGate.asksModelForLanguage)
    }
}
