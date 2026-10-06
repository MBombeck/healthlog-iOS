import SwiftUI

// #97 / #115 · 0.4 — how a partial profile save is told to the person.
//
// The server answers 200 and names the skipped fields in `rejectedFields`;
// `SettingsStore.rejectedProfileFields` holds them. This file turns each one
// into "<field> was not saved: <reason>", localized from the wire `path` and
// `code`. The server's own `message` is validator prose and is never shown.

extension ProfileRejectedField {
    /// The form's own label for the field. A path this build has no label for
    /// is shown verbatim rather than guessed.
    var fieldLabel: String {
        switch path {
        case "displayName": String(localized: "Display name")
        case "heightCm": String(localized: "Height")
        case "dateOfBirth": String(localized: "Date of birth")
        case "gender": String(localized: "Gender")
        case "fullName": String(localized: "Full name")
        case "insurerName": String(localized: "Health insurer")
        case "insuranceNumber": String(localized: "Insurance number")
        case "insurerIkNumber": String(localized: "Insurer ID (IK)")
        case "timeFormat": String(localized: "settings.time_format.title")
        case "dateFormat": String(localized: "settings.date_format.title")
        case "moodReminderEnabled": String(localized: "Mood reminder")
        case "email": String(localized: "profile.rejected.field.email")
        case "locale": String(localized: "profile.rejected.field.locale")
        case "timezone": String(localized: "profile.rejected.field.timezone")
        default: path
        }
    }

    /// Why the field did not land, from the validator `code`.
    var reasonText: String {
        switch code {
        case "too_big": String(localized: "profile.rejected.reason.tooBig")
        case "too_small": String(localized: "profile.rejected.reason.tooSmall")
        case "rate_limited": String(localized: "profile.rejected.reason.rateLimited")
        default: String(localized: "profile.rejected.reason.invalid")
        }
    }

    /// One line per skipped field: "<field> was not saved: <reason>".
    var displayLine: String {
        String(localized: "profile.rejected.line \(fieldLabel) \(reasonText)")
    }
}

/// Inline notice listing the fields a partial save skipped. Renders nothing
/// when the list is empty.
struct ProfileRejectedFieldsNotice: View {
    let fields: [ProfileRejectedField]

    var body: some View {
        if !fields.isEmpty {
            VStack(alignment: .leading, spacing: HLSpace.xs) {
                Label(String(localized: "profile.rejected.title"), systemImage: "exclamationmark.triangle.fill")
                    .font(.hlCaption.weight(.semibold))
                ForEach(fields, id: \.self) { field in
                    Text(field.displayLine)
                        .font(.hlCaption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .foregroundStyle(HLColor.statusBad)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("profile.rejectedFields")
        }
    }
}

/// Form section wrapper for ``ProfileRejectedFieldsNotice``. The typed values
/// stay in the form (the screen does not re-baseline on a partial save), so the
/// person can correct exactly the fields named here.
struct ProfileRejectedFieldsSection: View {
    let fields: [ProfileRejectedField]

    var body: some View {
        if !fields.isEmpty {
            Section {
                ProfileRejectedFieldsNotice(fields: fields)
            }
        }
    }
}
