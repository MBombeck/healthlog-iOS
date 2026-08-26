import SwiftUI

/// Maps the server-side `gender` string into a UI-friendly enum and back.
/// Picker shows localized labels; all three stored values plus "no answer"
/// are offered.
///
/// **Wire contract — verified 2026-07-30 (CU-17 / GH #71) against the server
/// source, not against memory:** `profileSchema.gender` in
/// `src/lib/validations/auth.ts` is a strict `z.enum(["MALE","FEMALE","OTHER"])`
/// (nullable, optional) behind a `preprocess` that folds `""` into `null`.
/// `docs/api/openapi.yaml` publishes the same uppercase enum on the profile
/// PATCH body **and** on every read projection (`GET /api/user/profile`,
/// `GET /api/auth/me`, the dashboard snapshot). So: **uppercase on the wire in
/// both directions**; `null` or `""` clears the field.
///
/// Until CU-17 ``serverValue`` emitted lowercase `"male" | "female" | "other"`
/// — a leftover of the v0.4.1 contract that this docblock still quoted. Since
/// the server tightened the enum that spelling 422s, and because the profile
/// update is **one transaction** (`applyProfileUpdate`), the rejection took
/// every sibling edit of the same auto-save window with it: a user who touched
/// the gender picker also lost their height / date-of-birth / name change.
/// Both write paths were affected — `EditProfileScreen` (`PATCH
/// /api/user/profile`) and the onboarding `BaselineProfileStep`
/// (`PUT /api/auth/profile`, same `applyProfileUpdate`).
///
/// ``init(serverValue:)`` stays case-insensitive on the read side so rows
/// written by an older client (or an older server) still map, and so an
/// unrecognised future value degrades to `.unspecified` instead of throwing.
///
/// Extracted from `EditProfileScreen` in v0.8.3 W-C to keep that file under the
/// `file_length` ceiling and to follow one-type-per-file hygiene.
enum GenderOption: String, CaseIterable, Identifiable {
    case male
    case female
    case other
    case unspecified

    var id: String {
        rawValue
    }

    init(serverValue: String?) {
        switch serverValue?.lowercased() {
        case "male": self = .male
        case "female": self = .female
        case "other": self = .other
        default: self = .unspecified
        }
    }

    /// The literal this option sends on the wire. Uppercase — see the type
    /// docblock. `nil` (encoded as an explicit JSON `null` by `ProfilePatch`)
    /// clears the stored value; we never send `""`, even though the server
    /// now normalises that to `null` too.
    var serverValue: String? {
        switch self {
        case .male: "MALE"
        case .female: "FEMALE"
        case .other: "OTHER"
        case .unspecified: nil
        }
    }

    var label: LocalizedStringKey {
        switch self {
        case .male: "Male"
        case .female: "Female"
        case .other: "Other"
        case .unspecified: "Prefer not to say"
        }
    }
}
