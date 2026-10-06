import Foundation

/// **Server v1.39.4 — where today sits in a medication's course.**
///
/// `courseStatus` on `GET /api/medications` and `GET /api/medications/{id}`:
/// `UPCOMING` before `startsOn`, `ENDED` after `endsOn`, `CURRENT` otherwise —
/// calendar days on the account's clock, both ends inclusive, so a course that
/// ends today is `CURRENT` all day. The server resolves it; the app reads it
/// and never re-derives it from `startsOn` / `endsOn` (that comparison is the
/// west-of-UTC trap the server fixed in 1.39.3).
///
/// Optional on the medication because a server older than 1.39.4 does not send
/// it; absent means "no status", never a guess. An unknown word lands on
/// ``unknown`` and changes nothing either.
public enum MedicationCourseStatus: String, Codable, Sendable, Hashable, TolerantServerEnum {
    case upcoming = "UPCOMING"
    case current = "CURRENT"
    case ended = "ENDED"
    case unknown

    public static let unknownFallback: MedicationCourseStatus = .unknown
    public static let wireVocabulary: StaticString = "medication.courseStatus"
}
