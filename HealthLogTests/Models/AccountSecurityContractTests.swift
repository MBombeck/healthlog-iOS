import Foundation
@testable import HealthLog
import Testing

/// **Parity 2.1 — Settings → Security.**
///
/// Covers the pure parts of the security surface: the two request bodies, the
/// local password gate, the passkey-name normalisation, and — the one with real
/// teeth — the `auth.stepup.*` classification.
///
/// The step-up mapping is the piece most likely to be got wrong later, because
/// `POST /api/auth/password` answers **401 for two completely different things**:
/// a wrong current password, and "your account has 2FA so this needs a fresh
/// cookie step-up". Only the second carries `meta.errorCode`. A future
/// refactor that classifies on the status alone would tell a user who simply
/// mistyped their password to go and use the web app. These tests pin that
/// distinction.
@Suite("Account security — bodies, validation, step-up mapping")
struct AccountSecurityContractTests {
    // MARK: - Change-password body

    /// All three fields ride the wire. The server re-checks the new/confirm
    /// equality itself (`validations/auth.ts:88-102`), so dropping
    /// `confirmPassword` would silently diverge from the contract.
    @Test("Change-password body carries all three fields verbatim")
    func changePasswordBodyEncodesAllThreeFields() throws {
        let body = ChangePasswordBody(
            currentPassword: "old-secret-1234",
            newPassword: "new-secret-5678",
            confirmPassword: "new-secret-5678"
        )

        let data = try JSONEncoder.hlDefault.encode(body)
        let json = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
            "body must encode to a JSON object"
        )

        #expect(json.count == 3, "no extra fields may leak onto a credential endpoint")
        #expect(json["currentPassword"] as? String == "old-secret-1234")
        #expect(json["newPassword"] as? String == "new-secret-5678")
        #expect(json["confirmPassword"] as? String == "new-secret-5678")
    }

    // MARK: - Local password gate

    @Test("Matching, fully-populated passwords pass the local gate")
    func validationPassesForWellFormedInput() {
        #expect(ChangePasswordValidation.validate(
            current: "old-secret-1234",
            new: "new-secret-5678",
            confirm: "new-secret-5678"
        ) == nil)
    }

    @Test("Mismatched confirmation is caught locally")
    func validationCatchesMismatch() {
        #expect(ChangePasswordValidation.validate(
            current: "old-secret-1234",
            new: "new-secret-5678",
            confirm: "new-secret-9999"
        ) == .mismatch)
    }

    /// Each empty field is `.incomplete`, and the check runs *before* the
    /// mismatch check — an all-empty form is "fill this in", not "these don't
    /// match" (they do match: both empty).
    @Test("Empty fields are caught locally, before the mismatch check")
    func validationCatchesEmptyFields() {
        #expect(ChangePasswordValidation.validate(
            current: "", new: "new-secret-5678", confirm: "new-secret-5678"
        ) == .incomplete, "empty current password")

        #expect(ChangePasswordValidation.validate(
            current: "old-secret-1234", new: "", confirm: "new-secret-5678"
        ) == .incomplete, "empty new password")

        #expect(ChangePasswordValidation.validate(
            current: "old-secret-1234", new: "new-secret-5678", confirm: ""
        ) == .incomplete, "empty confirmation")

        // All-empty: the two blanks are equal, so a mismatch-first ordering
        // would wrongly report "passwords do not match".
        #expect(ChangePasswordValidation.validate(
            current: "", new: "", confirm: ""
        ) == .incomplete, "all fields empty must report incomplete, not mismatch")
    }

    /// The local gate deliberately stops at mismatch + emptiness. A short
    /// password must reach the server so the *server's* policy (12-char floor,
    /// zxcvbn score, HIBP breach list) is the single source of truth.
    @Test("A short-but-matching password is NOT blocked locally — server policy decides")
    func validationDefersLengthPolicyToServer() {
        #expect(ChangePasswordValidation.validate(
            current: "old-secret-1234",
            new: "short",
            confirm: "short"
        ) == nil)
    }

    // MARK: - Passkey rename body + name rules

    @Test("Rename body uses the server's `name` field")
    func renameBodyUsesNameField() throws {
        let data = try JSONEncoder.hlDefault.encode(PasskeyRenameBody(name: "iPhone 16"))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json.count == 1)
        #expect(json["name"] as? String == "iPhone 16")
    }

    @Test("Names are trimmed and clamped to the server's 64-character ceiling")
    func nameNormalisationMatchesServerSchema() {
        #expect(WebAuthnKeyName.normalized("  iPhone 16  ") == "iPhone 16")

        let overlong = String(repeating: "a", count: 100)
        #expect(WebAuthnKeyName.normalized(overlong).count == WebAuthnKeyName.maxLength)
    }

    @Test("Whitespace-only names are rejected before they reach the network", arguments: [
        "", " ", "\t", "\n", "   \n  ",
    ])
    func whitespaceOnlyNamesAreInvalid(raw: String) {
        #expect(!WebAuthnKeyName.isValid(raw))
    }

    @Test("A name that is only padding around real text is valid")
    func paddedNameIsValid() {
        #expect(WebAuthnKeyName.isValid("  Yubikey  "))
    }

    // MARK: - Step-up classification

    /// Prefix match, not equality — mirrors the web helper
    /// (`totp-card.tsx:47-65`, `code.startsWith("auth.stepup")`) so a future
    /// sibling code needs no client change.
    @Test("A 401 carrying an auth.stepup.* code classifies as step-up", arguments: [
        "auth.stepup.required",
        "auth.stepup.mfa_not_enrolled",
        "auth.stepup.some_future_variant",
    ])
    func stepUpCodesAreRecognised(code: String) {
        let err = HLError.server(status: 401, code: code, message: "Recent second-factor verification required")
        #expect(SecurityStepUp.isRequired(err))
        #expect(AccountSecurityStore.classify(err) == .stepUpRequired)
    }

    /// The headline regression guard. `POST /api/auth/password` returns a bare
    /// 401 for a wrong current password; misreading it as step-up would send a
    /// user who made a typo off to the web app.
    @Test("A 401 with NO error code is an ordinary auth failure, not step-up")
    func codelessUnauthorizedIsNotStepUp() {
        let err = HLError.server(status: 401, code: nil, message: "Current password is incorrect")

        #expect(!SecurityStepUp.isRequired(err))
        #expect(AccountSecurityStore.classify(err) == .failure("Current password is incorrect"))
    }

    /// Status is part of the rule: the same code on a non-401 is not step-up.
    @Test("An auth.stepup code on a non-401 status does not classify as step-up")
    func stepUpRequiresStatus401() {
        let err = HLError.server(status: 403, code: "auth.stepup.required", message: "nope")
        #expect(!SecurityStepUp.isRequired(err))
    }

    @Test("Unrelated error codes are not step-up", arguments: [
        "module.disabled",
        "assistant.disabled.coach",
        "auth.refresh.revoked",
        "auth.stepu",
    ])
    func unrelatedCodesAreNotStepUp(code: String) {
        let err = HLError.server(status: 401, code: code, message: "nope")
        #expect(!SecurityStepUp.isRequired(err))
    }

    @Test("Non-server errors are never step-up")
    func nonServerErrorsAreNotStepUp() {
        #expect(!SecurityStepUp.isRequired(.offline))
        #expect(!SecurityStepUp.isRequired(.unauthorized))
        #expect(!SecurityStepUp.isRequired(.decoding("boom")))
    }

    /// Server prose is surfaced verbatim — it is written for the end user and
    /// is more specific than any client substitute.
    @Test("Server messages are surfaced verbatim", arguments: [
        "New password must differ from current password",
        "Too many attempts. Please wait 15 minutes.",
        "Password too weak (score < 3)",
    ])
    func serverMessagesPassThrough(message: String) {
        let err = HLError.server(status: 422, code: nil, message: message)
        #expect(AccountSecurityStore.classify(err) == .failure(message))
    }

    /// An empty envelope message must not render as an empty error row — the
    /// exact defect the web passkey-rename path still has
    /// (`passkey-list-section.tsx:111`, bare `setMsg(err.message)`).
    @Test("An empty server message falls back to the error's own description")
    func emptyServerMessageFallsBack() {
        let err = HLError.server(status: 500, code: nil, message: "")
        #expect(AccountSecurityStore.classify(err) != .failure(""))
    }
}
