import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **MED (1.5.0, #151 / #1280) — "End treatment" ends the course now.**
///
/// Against a server that publishes `canEndCourse` (1.46.0 or later) the store
/// calls `POST /api/medications/{id}/courses/end` and the local row stops
/// reminding at once, so a course ended in the afternoon gets no reminder that
/// evening. Against a server without the field (1.45) it keeps the 1.4 way,
/// `PUT endsOn = today`. Drives the real `APIClient` through `MockURLProtocol`.
@MainActor
@Suite("MED — end course now (a)", .serialized, .mockURLSession)
struct MedicationCourseEndTests {
    private func makeStore() throws -> MedicationsStore {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            cfAccessClientID: nil,
            cfAccessClientToken: nil,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        let client = APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
        let repo = try MedicationsRepository(api: client, outbox: OutboxQueue(inMemory: true))
        return MedicationsStore(repo: repo)
    }

    /// A daily 20:00 medication as a server row of the given generation.
    nonisolated static func wireRow(canEndCourse: Bool?, canStartCourse: Bool? = nil, endedAt: String? = nil) throws -> Medication {
        var fields = [
            "\"id\":\"med-1\"", "\"name\":\"Lisinopril\"", "\"dose\":\"5 mg\"", "\"active\":true",
            "\"notificationsEnabled\":true", "\"courseStatus\":\"CURRENT\"", "\"intakeActionable\":true",
            "\"schedules\":[{\"windowStart\":\"20:00\",\"timesOfDay\":[\"20:00\"],\"scheduleType\":\"SCHEDULED\"}]"
        ]
        if let canEndCourse {
            fields.append("\"canEndCourse\":\(canEndCourse)")
            fields.append("\"remindersActive\":true")
        }
        if let canStartCourse { fields.append("\"canStartCourse\":\(canStartCourse)") }
        if let endedAt { fields.append("\"endedAt\":\"\(endedAt)\"") }
        let json = "{" + fields.joined(separator: ",") + "}"
        return try JSONDecoder.hlDefault.decode(MedicationWireDTO.self, from: Data(json.utf8)).toDomain()
    }

    private struct Request {
        let method: String
        let path: String
        let body: [String: Any]
    }

    private struct Captured {
        var requests: [Request] = []
    }

    private func install(endStatus: Int = 200) -> () -> Captured {
        nonisolated(unsafe) var captured = Captured()
        MockURLProtocol.install { req in
            let path = req.url?.path ?? ""
            let raw = req.httpBody ?? Self.readStream(req.httpBodyStream) ?? Data()
            let body = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] ?? [:]
            captured.requests.append(Request(method: req.httpMethod ?? "", path: path, body: body))
            let (status, payload): (Int, String) = switch path {
            case "/api/medications/med-1/courses/end" where endStatus == 200:
                (200, #"{"data":{"startsOn":null,"endsOn":"2026-10-25","endedAt":"2026-10-25T14:00:00.000Z"},"error":null}"#)
            case "/api/medications/med-1/courses/end":
                (endStatus, #"{"data":null,"error":"No course is running","meta":{"errorCode":"medications.course.notRunning"}}"#)
            case "/api/medications/med-1":
                (200, #"{"data":{"id":"med-1","name":"Lisinopril","dose":"5 mg","active":true,"endsOn":"2026-10-25"}}"#)
            default:
                (200, #"{"data":[]}"#)
            }
            return (
                HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                Data(payload.utf8)
            )
        }
        return { captured }
    }

    @Test("1.46: End posts courses/end, nothing else, and the evening reminder is gone at once")
    func endNowOnNewServer() async throws {
        let store = try makeStore()
        let row = try Self.wireRow(canEndCourse: true)
        // Before: the planner arms tonight's 20:00 reminder.
        #expect(MedicationReminderDeliveryPolicy.plansLocalReminder(for: row))
        store._testForceSet(medications: [row])
        let captured = install()

        let afternoon = try #require(ISO8601DateFormatter().date(from: "2026-10-25T14:00:00Z"))
        let outcome = await store.endMedication(id: "med-1", on: afternoon)

        #expect(outcome == .success)
        let requests = captured().requests
        #expect(requests.map(\.method) == ["POST"])
        #expect(requests.map(\.path) == ["/api/medications/med-1/courses/end"])
        let ended = try #require(store.medications.first)
        #expect(ended.endedAt == afternoon)
        #expect(ended.courseStatus == .ended)
        #expect(!ended.offersIntakeActions)
        #expect(!ended.offersEndCourse)
        #expect(!MedicationReminderDeliveryPolicy.plansLocalReminder(for: ended))
    }

    @Test("1.45: no canEndCourse on the row, End keeps PUT endsOn = today")
    func endOnOldServerKeepsPut() async throws {
        let store = try makeStore()
        try store._testForceSet(medications: [Self.wireRow(canEndCourse: nil)])
        let captured = install()
        let day = Date(timeIntervalSince1970: 1_781_760_000)

        let outcome = await store.endMedication(id: "med-1", on: day)

        #expect(outcome == .success)
        let requests = captured().requests
        #expect(requests.map(\.method) == ["PUT"])
        #expect(requests.first?.path == "/api/medications/med-1")
        #expect(requests.first?.body["endsOn"] as? String == ProfileDay.key(for: day))
    }

    @Test("409 notRunning (ended elsewhere) re-reads the list instead of failing")
    func notRunningRereads() async throws {
        let store = try makeStore()
        try store._testForceSet(medications: [Self.wireRow(canEndCourse: true)])
        let captured = install(endStatus: 409)

        let outcome = await store.endMedication(id: "med-1")

        #expect(outcome == .success)
        let paths = captured().requests.map(\.path)
        #expect(paths.first == "/api/medications/med-1/courses/end")
        #expect(paths.contains("/api/medications"), "the list is read again")
    }

    @Test("canEndCourse false hides End; absent keeps 1.4's End on an active row")
    func endVisibility() throws {
        #expect(try !Self.wireRow(canEndCourse: false).offersEndCourse)
        #expect(try Self.wireRow(canEndCourse: true).offersEndCourse)
        #expect(try Self.wireRow(canEndCourse: nil).offersEndCourse)
    }

    @Test("A row that carries endedAt never arms a reminder, even with a stale remindersActive")
    func endedAtStopsReminders() throws {
        let row = try Self.wireRow(canEndCourse: false, endedAt: "2026-10-25T14:00:00.000Z")
        #expect(row.hasEndedCourseNow)
        #expect(row.remindersActive == false)
        #expect(!MedicationReminderDeliveryPolicy.plansLocalReminder(for: row))
    }

    nonisolated static func readStream(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: 1024)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

/// **MED (b) — starting a course follows `canStartCourse`.** A delegate reads
/// `false` (starting is owner-only), an older server sends nothing: neither sees
/// "Start a new treatment", and the store sends nothing for them.
@MainActor
@Suite("MED — course start only with canStartCourse (b)", .serialized, .mockURLSession)
struct MedicationCourseStartGateTests {
    @Test("delegate (canStartCourse false) and old server (absent) see no start; the owner does")
    func startVisibility() throws {
        #expect(try !MedicationCourseEndTests.wireRow(canEndCourse: true, canStartCourse: false).offersCourseStart)
        #expect(try !MedicationCourseEndTests.wireRow(canEndCourse: nil).offersCourseStart)
        #expect(try MedicationCourseEndTests.wireRow(canEndCourse: false, canStartCourse: true).offersCourseStart)
    }

    @Test("delegate: startCourse sends no request")
    func delegateSendsNothing() async throws {
        let store = try makeStore()
        try store._testForceSet(medications: [MedicationCourseEndTests.wireRow(canEndCourse: true, canStartCourse: false)])
        nonisolated(unsafe) var paths: [String] = []
        MockURLProtocol.install { req in
            paths.append(req.url?.path ?? "")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("{\"data\":[]}".utf8))
        }
        let outcome = await store.startCourse(id: "med-1")
        #expect(outcome == .failed(.canceled))
        #expect(paths.isEmpty)
    }

    @Test("owner: startCourse posts courses with today's day")
    func ownerPostsStart() async throws {
        let store = try makeStore()
        try store._testForceSet(medications: [MedicationCourseEndTests.wireRow(canEndCourse: false, canStartCourse: true)])
        nonisolated(unsafe) var posts: [(String, [String: Any])] = []
        MockURLProtocol.install { req in
            if req.httpMethod == "POST" {
                let raw = req.httpBody ?? MedicationCourseEndTests.readStream(req.httpBodyStream) ?? Data()
                posts.append((req.url?.path ?? "", (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] ?? [:]))
            }
            let body = req.httpMethod == "POST"
                ? #"{"data":{"id":"c-2","startsOn":"2026-10-26","endsOn":null}}"#
                : #"{"data":[]}"#
            return (
                HTTPURLResponse(url: req.url!, statusCode: req.httpMethod == "POST" ? 201 : 200, httpVersion: nil, headerFields: nil)!,
                Data(body.utf8)
            )
        }
        let day = Date(timeIntervalSince1970: 1_793_000_000)
        let outcome = await store.startCourse(id: "med-1", on: day)
        #expect(outcome == .success)
        #expect(posts.count == 1)
        #expect(posts.first?.0 == "/api/medications/med-1/courses")
        #expect(posts.first?.1["startsOn"] as? String == ProfileDay.key(for: day))
    }

    private func makeStore() throws -> MedicationsStore {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            cfAccessClientID: nil,
            cfAccessClientToken: nil,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        let client = APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
        let repo = try MedicationsRepository(api: client, outbox: OutboxQueue(inMemory: true))
        return MedicationsStore(repo: repo)
    }
}

// swiftlint:enable force_unwrapping
