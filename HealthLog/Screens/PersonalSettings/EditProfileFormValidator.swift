import Foundation

/// Pure value-level validation, extracted from `EditProfileScreen` so the
/// tests can pin the exact copy + range bounds without spinning up the
/// SwiftUI runtime. The view itself reads through these helpers — keeping
/// a single source of truth.
///
/// Moved to its own file in v0.8.3 W-C (file-length hygiene + one-type-per-file).
enum EditProfileFormValidator {
    static func displayNameError(for displayName: String) -> String? {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return String(localized: "Please enter a display name.")
        }
        if trimmed.count > 50 {
            return String(localized: "50 characters max.")
        }
        return nil
    }

    static func heightError(for heightCm: String) -> String? {
        let trimmed = heightCm.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        guard let parsed = Int(trimmed) else {
            return String(localized: "Please enter a whole number.")
        }
        if !(50 ... 300).contains(parsed) {
            return String(localized: "Value between 50 and 300 cm.")
        }
        return nil
    }

    // MARK: - v0.10.0 patient-identity fields

    /// Server `profileSchema.fullName` / `insurerName` caps both free-text
    /// identity fields at 120 chars (trimmed). Empty is valid (clears the
    /// field). Shared by the full-name + insurer footers so the copy + bound
    /// stay in one place.
    static let identityTextMaxLength = 120

    static func fullNameError(for fullName: String) -> String? {
        identityTextError(for: fullName)
    }

    static func insurerNameError(for insurerName: String) -> String? {
        identityTextError(for: insurerName)
    }

    private static func identityTextError(for value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count > identityTextMaxLength {
            return String(localized: "120 characters max.")
        }
        return nil
    }

    /// German KVNR validation mirror. The authoritative mod-10 check runs on
    /// the server (`isValidKvnr`); here we only guard the obvious shape so an
    /// accidental over-long paste doesn't even reach the network. Empty is
    /// valid (clears the number). The canonical KVNR is 10 chars
    /// (1 letter + 9 digits); we allow up to 16 to tolerate spacing/format
    /// the user might type before the server normalises it.
    static func insuranceNumberError(for insuranceNumber: String) -> String? {
        let trimmed = insuranceNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let compact = trimmed.replacingOccurrences(of: " ", with: "")
        if compact.count > 16 {
            return String(localized: "Please check the insurance number.")
        }
        return nil
    }

    /// v0.11.0 — insurer IKNR (Institutionskennzeichen) light format check.
    /// The canonical IKNR is exactly 9 digits. We only guard the obvious
    /// shape client-side (non-numeric or wrong length); the server runs the
    /// authoritative validation and we don't compute the check digit
    /// (matches the server's light-touch, per the v1.8.6 confirmation).
    /// Empty is valid (clears the number).
    static func insurerIkNumberError(for insurerIkNumber: String) -> String? {
        let trimmed = insurerIkNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let compact = trimmed.replacingOccurrences(of: " ", with: "")
        let isNineDigits = compact.count == 9 && compact.allSatisfy(\.isNumber)
        if !isNineDigits {
            return String(localized: "The insurer ID must be 9 digits.")
        }
        return nil
    }
}
