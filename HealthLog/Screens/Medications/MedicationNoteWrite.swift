import Foundation

/// **#174 — when the editor sends the medication's note.**
///
/// The web sends `note` only when the person changed it, so a note written
/// elsewhere is never overwritten by an edit of the dose time. Compared
/// after trimming, like the server stores it; an emptied note goes out as
/// `""`, which clears it. Input is capped at the server's 500 characters.
enum MedicationNoteWrite {
    /// The server's `MEDICATION_NOTE_MAX_CHARS`.
    static let maxCharacters = 500

    /// `nil` = leave the server's note as it is.
    static func value(edited: String, baseline: String) -> String? {
        let now = edited.trimmingCharacters(in: .whitespacesAndNewlines)
        let before = baseline.trimmingCharacters(in: .whitespacesAndNewlines)
        return now == before ? nil : now
    }

    /// The text cut to what the server accepts.
    static func capped(_ text: String) -> String {
        text.count > maxCharacters ? String(text.prefix(maxCharacters)) : text
    }
}
