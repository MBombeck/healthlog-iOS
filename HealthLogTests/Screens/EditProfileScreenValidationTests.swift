@testable import HealthLog
import Testing

/// **v0.5.5.2 — EditProfileScreen displayName-first-edit gate.**
///
/// Before this fix, opening `EditProfileScreen` on a profile whose server-
/// side `displayName` was empty immediately rendered the red footer
/// "Bitte einen Anzeigenamen eingeben." in the Identität section. The
/// operator read that as "screen broken on open" rather than
/// "field-needs-input" — a classic premature-validation antipattern.
///
/// These tests pin the contract:
/// 1. Validation logic itself is unchanged (empty + > 50 chars still
///    return the same localised copy).
/// 2. The *footer* gate (`displayNameFooterError`) only surfaces the
///    error after the user has typed something — never on initial open.
/// 3. After a single edit, the footer reflects the *current* validation
///    state, so clearing the field back to empty re-shows the error (the
///    gate latches one-way, by design).
@Suite("EditProfileScreen — displayName validation + footer gate")
struct EditProfileScreenValidationTests {
    // MARK: - Pure validation (helper)

    @Test("Empty displayName returns the localised required-field error")
    func emptyDisplayNameIsError() {
        let error = EditProfileFormValidator.displayNameError(for: "")
        #expect(error == String(localized: "Please enter a display name."))
    }

    @Test("Whitespace-only displayName is treated as empty")
    func whitespaceDisplayNameIsError() {
        let error = EditProfileFormValidator.displayNameError(for: "   ")
        #expect(error == String(localized: "Please enter a display name."))
    }

    @Test("Non-empty displayName clears the error")
    func nonEmptyDisplayNameIsValid() {
        #expect(EditProfileFormValidator.displayNameError(for: "Anna") == nil)
    }

    @Test("DisplayName > 50 chars returns the length error")
    func tooLongDisplayNameIsError() {
        let tooLong = String(repeating: "a", count: 51)
        #expect(EditProfileFormValidator.displayNameError(for: tooLong)
            == String(localized: "50 characters max."))
    }

    // MARK: - Footer gate (v0.5.5.2)

    @Test("Footer suppresses the error on initial screen-open (empty + not edited yet)")
    func footerHiddenOnInitialOpenWithEmptyServerValue() {
        // Simulates the operator-reported regression: server returns
        // `displayName == ""`, screen opens, no keystroke yet — the
        // footer must NOT show the red required-field error.
        let surfaced = EditProfileScreen.displayNameFooterError(
            displayName: "",
            hasUserEdited: false
        )
        #expect(surfaced == nil)
    }

    @Test("Footer suppresses the error on initial open even when the value is too long")
    func footerHiddenOnInitialOpenWithTooLongValue() {
        // Edge case: a server-prefilled value that's already past the
        // 50-char ceiling shouldn't shout on open either — same UX
        // reasoning. The user can shorten it, then the error surfaces.
        let tooLong = String(repeating: "a", count: 80)
        let surfaced = EditProfileScreen.displayNameFooterError(
            displayName: tooLong,
            hasUserEdited: false
        )
        #expect(surfaced == nil)
    }

    @Test("Footer surfaces the empty-field error after the user edits + clears")
    func footerVisibleAfterEditClearsField() {
        // The "type one char then clear" sequence from the brief: once
        // `hasUserEdited` flips to true the gate releases, and an empty
        // field now legitimately reads as user-cleared-it.
        let surfaced = EditProfileScreen.displayNameFooterError(
            displayName: "",
            hasUserEdited: true
        )
        #expect(surfaced == String(localized: "Please enter a display name."))
    }

    @Test("Footer surfaces the length error once the user has edited")
    func footerVisibleAfterEditAndOverLength() {
        let tooLong = String(repeating: "a", count: 75)
        let surfaced = EditProfileScreen.displayNameFooterError(
            displayName: tooLong,
            hasUserEdited: true
        )
        #expect(surfaced == String(localized: "50 characters max."))
    }

    @Test("Footer stays hidden when the edited field is valid")
    func footerHiddenWhenValidEvenAfterEdit() {
        let surfaced = EditProfileScreen.displayNameFooterError(
            displayName: "Anna",
            hasUserEdited: true
        )
        #expect(surfaced == nil)
    }
}
