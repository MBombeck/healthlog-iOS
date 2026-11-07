import Foundation

/// **MED-PLUS (1.5.0, #126 3.4) — a medication's courses, as the server
/// resolves them.**
///
/// Since server v1.40 a medication is taken in courses ("Behandlungen"): each
/// with a first day, an optional last day and, when it was ended with "End
/// treatment" (#1280), the instant it ended (`endedAt`). The list rows carry a
/// summary (`courseCount`, `previousCourseEndedOn`); the courses themselves are
/// read on demand from `GET /api/medications/{id}/courses` (owner-only).
///
/// The app renders what the server sends and never re-derives a status: the
/// newest course first, a past course offered for correction (first and last
/// day) and deletion, a new one only where the server says `canStartCourse`.
/// A server without the summary (`courseCount == nil`) shows no section.
public extension Medication {
    /// Whether the server knows courses (v1.40 or later) and the medication can
    /// have any: a one-time dose has its single course and nothing to list.
    var offersCourseHistory: Bool {
        courseCount != nil && !oneShot
    }
}

/// One course (`MedicationCourse`, server v1.40). Calendar days stay the
/// wire's `YYYY-MM-DD` strings; only the display parses them.
public struct MedicationCourse: Decodable, Sendable, Identifiable, Hashable {
    public enum Status: String, Sendable, Hashable {
        case upcoming = "UPCOMING"
        case current = "CURRENT"
        case ended = "ENDED"
    }

    public let id: String
    public let startsOn: String
    public let endsOn: String?
    public let endedAt: Date?
    /// `nil` for a value this build does not know.
    public let status: Status?

    public init(id: String, startsOn: String, endsOn: String?, endedAt: Date? = nil, status: Status?) {
        self.id = id
        self.startsOn = startsOn
        self.endsOn = endsOn
        self.endedAt = endedAt
        self.status = status
    }

    private enum CodingKeys: String, CodingKey {
        case id, startsOn, endsOn, endedAt, status
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        startsOn = try c.decode(String.self, forKey: .startsOn)
        endsOn = try? c.decodeIfPresent(String.self, forKey: .endsOn)
        endedAt = try? c.decodeIfPresent(Date.self, forKey: .endedAt)
        status = (try? c.decodeIfPresent(String.self, forKey: .status)).flatMap(Status.init(rawValue:))
    }

    /// A course that is over can be corrected and deleted. A running or
    /// planned one is ended (or changed) through the medication itself.
    public var isCorrectable: Bool {
        status == .ended
    }

    /// First day as a UTC-midnight date (the course-window convention).
    public var startDay: Date? {
        MedicationWireDTO.parseCourseDate(startsOn)
    }

    public var endDay: Date? {
        MedicationWireDTO.parseCourseDate(endsOn)
    }
}

/// `MedicationCoursesResponse.data`. A course that fails to decode is left
/// out rather than failing the list.
public struct MedicationCourseList: Decodable, Sendable, Equatable {
    public let courses: [MedicationCourse]
    public let canStartCourse: Bool

    public init(courses: [MedicationCourse], canStartCourse: Bool) {
        self.courses = courses
        self.canStartCourse = canStartCourse
    }

    private enum CodingKeys: String, CodingKey {
        case courses, canStartCourse
    }

    private struct Lossy: Decodable {
        let course: MedicationCourse?

        init(from decoder: Decoder) throws {
            course = try? MedicationCourse(from: decoder)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        courses = ((try? c.decodeIfPresent([Lossy].self, forKey: .courses)) ?? []).compactMap(\.course)
        canStartCourse = (try? c.decodeIfPresent(Bool.self, forKey: .canStartCourse)) ?? false
    }

    /// Newest first: by first day, descending (the server sends ascending).
    public var newestFirst: [MedicationCourse] {
        courses.sorted { $0.startsOn > $1.startsOn }
    }
}

/// `UpdateMedicationCourseRequest` (server v1.40): a past course's first and
/// last day. Both are always named; the server re-projects the medication's
/// window in the same transaction.
public struct UpdateMedicationCourseBody: Encodable, Sendable, Equatable {
    public let startsOn: String
    public let endsOn: String

    public init(startsOn: String, endsOn: String) {
        self.startsOn = startsOn
        self.endsOn = endsOn
    }
}
