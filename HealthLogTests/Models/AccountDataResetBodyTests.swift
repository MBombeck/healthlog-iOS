// Parity 2.5 — `DELETE /api/settings/data` request body.
//
// The one trap this guards: the UI asks the user to type a LOCALIZED confirm
// phrase (`LÖSCHEN` in German, matching the `DeleteAccountScreen` idiom), but
// the server compares `confirm` against the literal ASCII `"DELETE"` and 422s
// anything else. If those two ever get conflated, the German build silently
// loses the ability to reset data at all — a locale-only failure that no
// English-language smoke test would catch.

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    @Suite("Account data-reset body (parity 2.5)")
    struct AccountDataResetBodyTests {
        private func encode(_ body: AccountDataResetBody) throws -> String {
            let data = try JSONEncoder.hlDefault.encode(body)
            return String(data: data, encoding: .utf8) ?? ""
        }

        @Test("The default body carries exactly the confirm token the server demands")
        func defaultBodyMatchesServerContract() throws {
            let encoded = try encode(AccountDataResetBody())
            #expect(encoded == #"{"confirm":"DELETE"}"#)
        }

        @Test("The wire token is the ASCII literal the server compares against")
        func serverTokenIsAsciiDelete() {
            #expect(AccountDataResetBody.serverConfirmToken == "DELETE")
        }

        @Test("The wire token is independent of the localized type-confirm phrase")
        func wireTokenIsNotTheLocalizedPhrase() {
            // The localized phrase is a UI gate only. Under a German locale it is
            // "LÖSCHEN"; the body must stay "DELETE" either way, so this asserts
            // the constant is not sourced from the localization table.
            let localized = String(
                localized: "DELETE",
                comment: "Type-confirm phrase the user must enter literally to delete their account"
            )
            #expect(AccountDataResetBody.serverConfirmToken == "DELETE")
            if localized != "DELETE" {
                #expect(AccountDataResetBody.serverConfirmToken != localized)
            }
        }
    }

#endif
