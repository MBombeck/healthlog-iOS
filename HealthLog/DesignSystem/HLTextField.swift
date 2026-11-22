import SwiftUI

/// A labelled text field on a tinted plate, for sign-in and sign-up forms.
///
/// The kind sets the keyboard and the content type: an address, the account
/// password, a new password (iOS offers a strong one), a code or name typed
/// as it is (`plain`: no capital, no correction) or free text (`text`: a
/// capital at the start of a sentence, correction on, for a title or a
/// note). Only sign-in forms use the password kinds; any other secret is a
/// secure field marked `.hlSecretEntry()`.
///
/// The plate is the recessed surface of chips and inset rows, the same in a
/// sheet, on a page and inside a card: the sheet's own surface read bluish
/// under a field, and the card surface vanished inside a card.
struct HLTextField: View {
    enum Kind { case email, password, newPassword, plain, text }

    /// The surface under the field.
    static var plate: Color {
        HLSurface.tertiary
    }

    /// Whether a kind starts sentences with a capital and corrects words.
    nonisolated static func writesProse(_ kind: Kind) -> Bool {
        kind == .text
    }

    let title: String
    @Binding var text: String
    let kind: Kind

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            Text(title)
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)

            Group {
                switch kind {
                case .email:
                    TextField("", text: $text)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                case .password:
                    SecureField("", text: $text)
                        .textContentType(.password)
                case .newPassword:
                    // Registration path — offer iOS's strong-password suggestion.
                    SecureField("", text: $text)
                        .textContentType(.newPassword)
                case .plain:
                    TextField("", text: $text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                case .text:
                    TextField("", text: $text, axis: .vertical)
                        .textInputAutocapitalization(.sentences)
                        .autocorrectionDisabled(false)
                }
            }
            .font(.hlHeadline)
            .foregroundStyle(HLText.primary)
            .hlFieldPlate()
        }
    }
}

public extension View {
    /// The field's plate: the recessed surface under a text or secure field
    /// that stands in a card, not in a form row. A bare field in a card was
    /// only its pale placeholder and did not read as a place to type.
    func hlFieldPlate() -> some View {
        padding(HLSpace.md)
            .background(HLSurface.tertiary)
            .clipShape(RoundedRectangle(cornerRadius: HLRadius.sm, style: .continuous))
    }
}
