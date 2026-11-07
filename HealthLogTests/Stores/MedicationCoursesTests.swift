import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **MED-PLUS (1.5.0, #126 3.4) — the course list under "Erweitert".**
///
/// Drives the real `APIClient` through `MockURLProtocol` with answers shaped
/// after `openapi.yaml` v1.47.0 (`MedicationCoursesResponse`, the PATCH and
/// DELETE of `/api/medications/{id}/courses/{courseId}`).
@MainActor
@Suite("MED-PLUS — treatment courses", .serialized, .mockURLSession)
struct MedicationCoursesTests {
    private func makeRepo() throws -> MedicationsRepository {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            cfAccessClientID: nil,
            cfAccessClientToken: nil,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        let client = APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
        return try MedicationsRepository(api: client, outbox: OutboxQueue(inMemory: true))
    }

    /// Two courses, ascending as the server sends them: one ended at an
    /// instant in October, one running since November.
    static let twoCourses = #"""
    {"data":{"courses":[
      {"id":"c-1","startsOn":"2026-09-01","endsOn":"2026-10-25","endedAt":"2026-10-25T14:00:00.000Z","status":"ENDED","takenDoses":40,"note":null},
      {"id":"c-2","startsOn":"2026-11-01","endsOn":null,"endedAt":null,"status":"CURRENT","takenDoses":4,"note":null}
    ],"courseCount":2,"previousCourseEndedOn":"2026-10-25","canStartCourse":CAN_START},"error":null}
    """#

    private struct Request {
        let method: String
        let path: String
        let body: [String: Any]
    }

    private final class Captured: @unchecked Sendable {
        var requests: [Request] = []
    }

    /// `write` answers PATCH/DELETE/POST on the courses.
    private func install(
        canStart: Bool = false,
        listStatus: Int = 200,
        write: (status: Int, payload: String) = (200, #"{"data":{"id":"c-1","deleted":true},"error":null}"#)
    ) -> Captured {
        let captured = Captured()
        let list = Self.twoCourses.replacingOccurrences(of: "CAN_START", with: canStart ? "true" : "false")
        MockURLProtocol.install { req in
            let path = req.url?.path ?? ""
            let raw = req.httpBody ?? Self.readStream(req.httpBodyStream) ?? Data()
            let body = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] ?? [:]
            let method = req.httpMethod ?? ""
            captured.requests.append(Request(method: method, path: path, body: body))
            let (status, payload): (Int, String) = if path == "/api/medications/med-1/courses", method == "GET" {
                listStatus == 200
                    ? (200, list)
                    : (listStatus, #"{"data":null,"error":"Forbidden"}"#)
            } else if path.hasPrefix("/api/medications/med-1/courses") {
                write
            } else {
                (200, #"{"data":[]}"#)
            }
            return (
                HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                Data(payload.utf8)
            )
        }
        return captured
    }

    private nonisolated static func readStream(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    private func loadedList(_ model: MedicationCoursesModel) throws -> MedicationCourseList {
        guard case let .loaded(list) = model.state else {
            Issue.record("expected a loaded list, got \(model.state)")
            throw CancellationError()
        }
        return list
    }

    @Test("Two courses read newest first; only the ended one is correctable")
    func twoCoursesNewestFirst() async throws {
        let captured = install()
        let model = MedicationCoursesModel()
        try await model.load(medicationID: "med-1", repo: makeRepo())

        let list = try loadedList(model)
        #expect(list.newestFirst.map(\.id) == ["c-2", "c-1"])
        #expect(list.newestFirst.map(\.isCorrectable) == [false, true])
        let ended = try #require(list.courses.first)
        #expect(ended.endedAt == ISO8601DateFormatter().date(from: "2026-10-25T14:00:00Z"))
        #expect(captured.requests.map(\.method) == ["GET"])
        #expect(captured.requests.map(\.path) == ["/api/medications/med-1/courses"])
    }

    @Test("Correcting a past course PATCHes both days, re-reads the medications and the list")
    func correctPastCourse() async throws {
        let captured = install(write: (200, #"{"data":{"id":"c-1","startsOn":"2026-09-02","endsOn":"2026-10-20"},"error":null}"#))
        let model = MedicationCoursesModel()
        var medicationsReloaded = 0
        try await model.load(medicationID: "med-1", repo: makeRepo(), afterWrite: { medicationsReloaded += 1 })
        let course = try #require(try loadedList(model).courses.first)

        try await model.update(course, startsOn: "2026-09-02", endsOn: "2026-10-20")

        let patch = try #require(captured.requests.first { $0.method == "PATCH" })
        #expect(patch.path == "/api/medications/med-1/courses/c-1")
        #expect(patch.body["startsOn"] as? String == "2026-09-02")
        #expect(patch.body["endsOn"] as? String == "2026-10-20")
        #expect(medicationsReloaded == 1, "the medication window (and its reminders) is re-read")
        #expect(captured.requests.map(\.method) == ["GET", "PATCH", "GET"])
    }

    @Test("The edit page saves nothing untouched, and its days are the UTC calendar days")
    func editPageBody() throws {
        let course = MedicationCourse(id: "c-1", startsOn: "2026-09-01", endsOn: "2026-10-25", status: .ended)
        let start = try #require(course.startDay)
        let end = try #require(course.endDay)
        #expect(MedicationCourseEditPage.body(startsOn: start, endsOn: end) == MedicationCourseEditPage.body(of: course))
        #expect(MedicationCourseEditPage.isRangeValid(startsOn: start, endsOn: end))
        #expect(!MedicationCourseEditPage.isRangeValid(startsOn: end, endsOn: start))
    }

    @Test("A refused correction says why (overlap, invalid range), not the server's English")
    func refusedCorrection() async throws {
        _ = install(write: (422, #"{"data":null,"error":"Overlap","meta":{"errorCode":"medications.course.overlap"}}"#))
        let model = MedicationCoursesModel()
        try await model.load(medicationID: "med-1", repo: makeRepo())
        let course = try #require(try loadedList(model).courses.first)

        await #expect(throws: HLError.self) {
            try await model.update(course, startsOn: "2026-10-30", endsOn: "2026-11-05")
        }
        let overlap = HLError.server(status: 422, code: "medications.course.overlap", message: "x")
        #expect(MedicationCoursesModel.message(for: overlap) == String(localized: "med.courses.error.overlap"))
        let range = HLError.server(status: 422, code: "medications.course.invalidRange", message: "x")
        #expect(MedicationCoursesModel.message(for: range) == String(localized: "med.schedule.course.invalidRange"))
        #expect(MedicationCoursesModel.message(for: CancellationError()) == nil)
    }

    @Test("Deleting a course sends DELETE; one already gone (404) counts as deleted")
    func deleteCourse() async throws {
        let captured = install()
        let model = MedicationCoursesModel()
        var reloaded = 0
        try await model.load(medicationID: "med-1", repo: makeRepo(), afterWrite: { reloaded += 1 })
        let course = try #require(try loadedList(model).courses.first)

        try await model.delete(course)
        let delete = try #require(captured.requests.first { $0.method == "DELETE" })
        #expect(delete.path == "/api/medications/med-1/courses/c-1")
        #expect(reloaded == 1)

        _ = install(write: (404, #"{"data":null,"error":"Not found","meta":{"errorCode":"medications.course.notFound"}}"#))
        try await model.delete(course)
        #expect(reloaded == 2, "a 404 is the state the person wanted")
    }

    @Test("Start is offered only with canStartCourse and posts today's account day")
    func startOnlyWithCanStart() async throws {
        let active = try MedicationAutoMarkTakenTests.row()
        _ = install(canStart: false)
        let model = MedicationCoursesModel()
        try await model.load(medicationID: "med-1", repo: makeRepo())
        #expect(try !MedicationCoursesModel.offersStart(list: loadedList(model), medication: active))

        let captured = install(canStart: true, write: (201, #"{"data":{"id":"c-3","startsOn":"2026-11-05","endsOn":null},"error":null}"#))
        await model.reload()
        #expect(try MedicationCoursesModel.offersStart(list: loadedList(model), medication: active))
        let now = try #require(ISO8601DateFormatter().date(from: "2026-11-05T09:00:00Z"))
        await model.start(now: now)
        let post = try #require(captured.requests.first { $0.method == "POST" })
        #expect(post.path == "/api/medications/med-1/courses")
        #expect(post.body["startsOn"] as? String == ProfileDay.key(for: now))
        #expect(model.writeError == nil)
    }

    @Test("A delegate (403, the read is owner-only) gets the disabled card; a 500 can be retried")
    func refusalAndFailure() async throws {
        _ = install(listStatus: 403)
        let model = MedicationCoursesModel()
        try await model.load(medicationID: "med-1", repo: makeRepo(), offReason: { "reason" })
        #expect(model.state == .disabled("reason"))

        _ = install(listStatus: 500)
        await model.reload()
        #expect(model.state == .failed)

        _ = install()
        await model.reload()
        #expect(try loadedList(model).courses.count == 2)
    }

    @Test("No section without the server's course summary (older server), none on a one-time dose")
    func sectionGate() throws {
        #expect(try !MedicationAutoMarkTakenTests.row().offersCourseHistory)
        #expect(try MedicationAutoMarkTakenTests.row(extra: [#""courseCount":2"#]).offersCourseHistory)
        #expect(try !MedicationAutoMarkTakenTests.row(extra: [#""courseCount":1"#, #""oneShot":true"#]).offersCourseHistory)
    }

    @Test("Row text: range or 'since', the ended moment, statuses; no raw keys")
    func rowText() throws {
        let open = MedicationCourse(id: "c-2", startsOn: "2026-11-01", endsOn: nil, status: .current)
        let ended = MedicationCourse(
            id: "c-1", startsOn: "2026-09-01", endsOn: "2026-10-25",
            endedAt: Date(timeIntervalSince1970: 1_792_929_600), status: .ended
        )
        for text in [
            MedicationCourseFormat.range(open), MedicationCourseFormat.range(ended),
            MedicationCourseFormat.status(open) ?? "", MedicationCourseFormat.status(ended) ?? "",
            MedicationCourseFormat.accessibilityLabel(ended)
        ] {
            #expect(!text.isEmpty)
            #expect(!text.contains("med.courses"), "raw key in \(text)")
        }
        for key in ["med.courses.title", "med.courses.range %@ %@", "med.courses.endedAt %@ %@", "med.courses.delete.question"] {
            let entry = try CatalogProbe.entry(key)
            #expect(entry["de"]?.isEmpty == false && entry["en"]?.isEmpty == false, "\(key) de/en")
        }
    }

    @Test("A course list that is partly malformed keeps the readable courses")
    func lossyDecode() throws {
        let json = #"{"courses":[{"id":"c-1","startsOn":"2026-09-01","status":"ENDED"},{"startsOn":"2026-10-01"},{"id":"c-3","startsOn":"2026-11-01","status":"WHATEVER"}],"canStartCourse":true}"#
        let list = try JSONDecoder.hlDefault.decode(MedicationCourseList.self, from: Data(json.utf8))
        #expect(list.courses.map(\.id) == ["c-1", "c-3"])
        #expect(list.courses.last?.status == nil)
        #expect(list.canStartCourse)
    }
}

// swiftlint:enable force_unwrapping
