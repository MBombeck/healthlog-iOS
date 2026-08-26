import Foundation
@testable import HealthLog
import Testing

/// Anti-regression lock for the client-side email validator that gates
/// the onboarding registration POST. The previous `email.contains("@")`
/// check accepted shapes like `@.com`, `a@@b.com`, and `foo@bar` (no
/// TLD); the registry endpoint would 422 each of those, but only after
/// a network round-trip + a rate-limit hit. The validator is the inline
/// pre-POST guard so the operator sees the failure immediately.
@Suite("RegistrationEmailValidator client-side check")
struct RegistrationEmailValidatorTests {
    @Test("Canonical email passes")
    func validAddressAccepted() {
        #expect(RegistrationEmailValidator.isValid("anna@healthlog.dev"))
    }

    @Test("Missing top-level domain is rejected")
    func missingTLDRejected() {
        #expect(RegistrationEmailValidator.isValid("anna@healthlog") == false)
    }

    @Test("Missing @ is rejected")
    func missingAtRejected() {
        #expect(RegistrationEmailValidator.isValid("anna.healthlog.dev") == false)
    }

    @Test("Double @ is rejected")
    func doubleAtRejected() {
        #expect(RegistrationEmailValidator.isValid("anna@@healthlog.dev") == false)
    }

    @Test("Empty input is rejected")
    func emptyRejected() {
        #expect(RegistrationEmailValidator.isValid("") == false)
        #expect(RegistrationEmailValidator.isValid("   ") == false)
    }

    @Test("Plus-addressing + subdomains accepted")
    func plusAddressingAccepted() {
        #expect(RegistrationEmailValidator.isValid("anna+release@mail.healthlog.dev"))
    }

    @Test("Domain-only-with-dot is rejected (`@.com`)")
    func domainOnlyRejected() {
        #expect(RegistrationEmailValidator.isValid("anna@.com") == false)
    }

    @Test("Case-insensitive (uppercase local + domain)")
    func caseInsensitiveAccepted() {
        #expect(RegistrationEmailValidator.isValid("ANNA@HEALTHLOG.DEV"))
    }
}
