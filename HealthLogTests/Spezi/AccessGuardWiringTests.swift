#if canImport(UIKit) && canImport(Spezi) && canImport(SpeziHealthKit) && canImport(SpeziLocalStorage) && canImport(SpeziAccessGuard)
    @testable import HealthLog
    import Spezi
    @_spi(Internal) import SpeziAccessGuard
    import Testing
    import UIKit

    /// Structural coverage for the GH issue #8 Path 2 SpeziAccessGuard
    /// wiring. Behavioral auth-prompt testing is not possible on the
    /// simulator (no enrolled biometrics, `LAContext.evaluatePolicy` cannot
    /// succeed in a unit-test host), so these tests pin the *wiring*: the
    /// delegate configuration must build with the `AccessGuards` module
    /// registered, and the shared identifier must stay stable — its raw
    /// value is persisted by SpeziAccessGuard across launches.
    @MainActor
    @Suite("SpeziAccessGuard — Path 2 wiring (GH #8)")
    struct AccessGuardWiringTests {
        @Test("delegate configuration builds with the AccessGuards module registered")
        func configurationBuildsWithAccessGuards() {
            let delegate = HealthLogSpeziDelegate()
            // Reading `configuration` runs the Spezi configuration builder,
            // which instantiates `AccessGuards { BiometricAccessGuard(...) }`.
            // A registration-shape regression (e.g. an upstream init change)
            // would crash or fail to compile here.
            _ = delegate.configuration
        }

        @Test("sensitive-screens guard identifier is stable across releases")
        func sensitiveScreensIdentifierIsStable() {
            // The raw value is the persistence key for unlock state — a
            // silent rename would orphan persisted guard state. Frozen.
            #expect(AccessGuardIdentifier.sensitiveScreens.value == "dev.healthlog.app.accessguard.sensitive-screens")
        }

        @Test("guard config for sensitive screens instantiates with fallback + timeout")
        func biometricGuardConfigInstantiates() {
            let guardConfig = BiometricAccessGuard(
                .sensitiveScreens,
                timeout: .minutes(5),
                fallback: .regular(format: .numeric(6))
            )
            #expect(guardConfig.timeout == .minutes(5))
            #expect(guardConfig.id == .sensitiveScreens)
            #expect(guardConfig.fallback != nil)
        }
    }
#endif
