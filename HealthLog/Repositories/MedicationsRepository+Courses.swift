import Foundation

/// **MED (1.5.0) — course actions on the medications repository.**
///
/// - `POST /api/medications/{id}/courses/end` (server v1.46.0, #1280): ends the
///   running course now. No body. 409 `medications.course.notRunning` when no
///   course runs.
/// - `POST /api/medications/{id}/courses` (server v1.40): starts a course on a
///   day. Owner-only; the reads say so through `canStartCourse`.
///
/// Both are interactive writes: one idempotency key each, thrown on failure,
/// **never queued in the outbox**. "End now" replayed an hour later would end
/// the course at a different moment, and a start replayed on another day would
/// start on the wrong one; the person retries instead.
///
/// MED-PLUS (1.5.0, #126 3.4) adds the course list, the correction of a
/// past course and its deletion, all owner-only on the server (a delegate reads
/// 403):
/// - `GET /api/medications/{id}/courses`
/// - `PATCH /api/medications/{id}/courses/{courseId}` (422
///   `medications.course.overlap` / `.invalidRange`)
/// - `DELETE /api/medications/{id}/courses/{courseId}` (404
///   `medications.course.notFound`)
///
/// The same rule holds: interactive, never queued.
public extension MedicationsRepository {
    /// The server code for "no course is running".
    static let courseNotRunningCode = "medications.course.notRunning"

    func endCourse(medicationID: String) async throws -> EndMedicationCourseResult {
        let req: APIRequest<EndMedicationCourseResult> = try .post(
            "/api/medications/\(medicationID)/courses/end",
            body: EmptyPayload(),
            idempotencyKey: IdempotencyKey()
        )
        return try await api.send(req)
    }

    /// Starts a new open-ended course on `startsOn` (`YYYY-MM-DD`). The answer
    /// is the course, not the medication, so the caller re-reads the list.
    func startCourse(medicationID: String, startsOn: String) async throws {
        let req: APIRequest<EmptyResponse> = try .post(
            "/api/medications/\(medicationID)/courses",
            body: StartMedicationCourseBody(startsOn: startsOn),
            idempotencyKey: IdempotencyKey()
        )
        _ = try await api.send(req)
    }

    /// The medication's courses, as the server resolves them.
    func courses(medicationID: String) async throws -> MedicationCourseList {
        let req: APIRequest<MedicationCourseList> = .get("/api/medications/\(medicationID)/courses")
        return try await api.send(req)
    }

    /// Corrects a course's first and last day.
    func updateCourse(medicationID: String, courseID: String, startsOn: String, endsOn: String) async throws {
        let req: APIRequest<EmptyResponse> = try .patch(
            "/api/medications/\(medicationID)/courses/\(courseID)",
            body: UpdateMedicationCourseBody(startsOn: startsOn, endsOn: endsOn),
            idempotencyKey: IdempotencyKey()
        )
        _ = try await api.send(req)
    }

    /// Deletes a course. Its logged doses stay in the history.
    func deleteCourse(medicationID: String, courseID: String) async throws {
        let req: APIRequest<EmptyResponse> = .delete(
            "/api/medications/\(medicationID)/courses/\(courseID)",
            idempotencyKey: IdempotencyKey()
        )
        _ = try await api.send(req)
    }

    /// The server code of a refused course write, if any.
    static func courseErrorCode(_ error: Error) -> String? {
        if case let HLError.server(_, code, _) = error { return code }
        return nil
    }
}
