// The Face ID / passcode system prompt must show catalog text, so an English
// build never presents a fixed German reason or fallback title.

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    @Suite("App-lock prompt copy")
    struct AppLockPromptCopyTests {
        @Test("the prompt reason and fallback title resolve from the String Catalog")
        func promptTextsComeFromTheCatalog() {
            #expect(BiometricGate.localizedReason == String(localized: "applock.prompt.reason"))
            #expect(BiometricGate.localizedFallbackTitle == String(localized: "applock.prompt.fallback"))
            #expect(BiometricGate.localizedReason != "applock.prompt.reason")
            #expect(BiometricGate.localizedFallbackTitle != "applock.prompt.fallback")
            #expect(BiometricGate.localizedReason != BiometricGate.localizedFallbackTitle)
        }
    }

#endif
