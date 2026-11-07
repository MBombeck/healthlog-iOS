import Foundation

/// **MED (1.5.0) — ending and starting a course, as the server allows it.**
///
/// Server v1.46.0 (#1280) ends a running course at an instant
/// (`POST /api/medications/{id}/courses/end`): the course's last day becomes
/// today and the moment is kept as `endedAt`. A dose slot later today is then
/// not due, not reminded and not expected; a dose taken this morning still
/// counts. The older way, `PUT endsOn = today`, keeps whole-day semantics, so
/// the evening reminder of that day still fired.
///
/// The reads publish who may do what, resolved for the caller:
/// - `canEndCourse` — true while a course runs and the caller may end it (the
///   owner, or a delegate managing the medications).
/// - `canStartCourse` — false for every delegate (starting stays owner-only)
///   and for the rest of a day on which a course was ended.
///
/// The app renders from these and never re-derives them. A server without the
/// fields (`nil`) keeps the 1.4 behaviour: "End" via `PUT endsOn`, no start.
public extension Medication {
    /// Whether this row came from a server that knows the instant end
    /// (`canEndCourse` present, server 1.46.0 or later).
    var serverEndsCourseNow: Bool {
        canEndCourse != nil
    }

    /// Whether "End course" is offered. A server with the field decides; an
    /// older one offers it on every active medication, as 1.4 did.
    var offersEndCourse: Bool {
        guard active else { return false }
        return canEndCourse ?? true
    }

    /// Whether "Start a new course" is offered: only when the server says so.
    /// Absent (an older server) is no, because 1.4 had no start either.
    var offersCourseStart: Bool {
        active && canStartCourse == true
    }

    /// Whether the latest course was ended at an instant. From `endedAt` on
    /// nothing is due or reminded, whatever a stale flag says.
    var hasEndedCourseNow: Bool {
        endedAt != nil
    }

    /// The row as it reads right after a successful end, before the server
    /// row comes back: ended at `result.endedAt` (or `now`), nothing due,
    /// nothing reminded, no second end, no start today.
    func endingCourse(_ result: EndMedicationCourseResult, now: Date) -> Medication {
        var copy = self
        copy.endedAt = result.endedAt ?? now
        copy.endsOn = MedicationWireDTO.parseCourseDate(result.endsOn) ?? endsOn
        copy.courseStatus = .ended
        copy.intakeActionable = false
        copy.remindersActive = false
        copy.canEndCourse = false
        copy.canStartCourse = false
        return copy
    }
}

/// `EndMedicationCourseResponse.data` (server v1.46.0): the medication's
/// window after the end. Every field optional so a partial answer still lands.
public struct EndMedicationCourseResult: Decodable, Sendable, Equatable {
    public let startsOn: String?
    public let endsOn: String?
    public let endedAt: Date?

    public init(startsOn: String? = nil, endsOn: String? = nil, endedAt: Date? = nil) {
        self.startsOn = startsOn
        self.endsOn = endsOn
        self.endedAt = endedAt
    }
}

/// `CreateMedicationCourseRequest` (server v1.40): a course starting on
/// `startsOn` (the person's calendar day, `YYYY-MM-DD`), open-ended.
public struct StartMedicationCourseBody: Encodable, Sendable, Equatable {
    public let startsOn: String

    public init(startsOn: String) {
        self.startsOn = startsOn
    }
}
