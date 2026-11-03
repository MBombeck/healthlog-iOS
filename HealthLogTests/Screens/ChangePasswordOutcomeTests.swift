import Foundation
@testable import HealthLog
import Testing

/// **B5 (1.4) — a wrong current password is said in the person's language.**
@Suite("B5 — change password outcome")
struct ChangePasswordOutcomeTests {
    @Test("a 401 that is not a step-up is the wrong current password")
    func wrongCurrentPassword() {
        let refused = HLError.server(status: 401, code: "http.unauthenticated", message: "Current password is incorrect")
        #expect(AccountSecurityStore.classify(refused) == .wrongCurrentPassword)
        let older = HLError.server(status: 401, code: nil, message: "Current password is incorrect")
        #expect(AccountSecurityStore.classify(older) == .wrongCurrentPassword)
    }

    @Test("step-up and every other refusal keep their outcome")
    func otherOutcomes() {
        let stepUp = HLError.server(status: 401, code: "auth.stepup.required", message: "Step-up authentication required")
        #expect(AccountSecurityStore.classify(stepUp) == .stepUpRequired)
        let weak = HLError.server(status: 422, code: "http.invalid", message: "Password too weak (score < 3)")
        #expect(AccountSecurityStore.classify(weak) == .failure("Password too weak (score < 3)"))
    }

    @Test("the sentence exists in German and English")
    func catalogSentence() throws {
        let catalog = try ParityCatalog.load()
        let entry = try #require(catalog.strings["settings.security.password.wrongCurrent"])
        #expect(ParityCatalog.value(entry, language: "de") == "Das aktuelle Passwort stimmt nicht.")
        #expect(ParityCatalog.value(entry, language: "en") == "The current password is not correct.")
    }
}
