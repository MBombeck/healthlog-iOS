// swiftlint:disable force_unwrapping
import Foundation
@testable import HealthLog
import Testing

/// **CU-32 — `AnamnesisRepository` gegen echten `APIClient` + `MockURLProtocol`.**
///
/// Kein Mock-Server: der Transportweg ist echt, nur `URLProtocol` ist gestubbt,
/// damit Schema-Drift zwischen Fixture und Decoder auffällt statt durchzurutschen.
/// `.serialized`, weil `MockURLProtocol.handler` prozessglobal ist.
@Suite("AnamnesisRepository", .serialized)
struct AnamnesisRepositoryTests {
    // MARK: - Fixtures

    /// Eine vollständige `GET`-Antwort: Rauchen erfasst (Korrektur), Alkohol
    /// erfasst-aber-unlesbar, Schichtarbeit **nie erfasst** (`null`).
    /// Der Verlauf trägt die abgelöste Erstangabe zum Rauchen.
    static let factsPayload = """
    {"data":{
      "current":{
        "SMOKING_STATUS":{"id":"rev-smoke-2","kind":"SMOKING_STATUS","value":"FORMER",\
    "unreadable":false,"validFrom":"2026-05-02T09:00:00.000Z","validUntil":null,\
    "provenance":"USER_CORRECTION","supersededByRevisionId":null,\
    "createdAt":"2026-05-02T09:00:00.000Z"},
        "ALCOHOL_PATTERN":{"id":"rev-alc-1","kind":"ALCOHOL_PATTERN","value":null,\
    "unreadable":true,"validFrom":"2026-03-01T08:00:00.000Z","validUntil":null,\
    "provenance":"USER_REPORTED","supersededByRevisionId":null,\
    "createdAt":"2026-03-01T08:00:00.000Z"},
        "SHIFT_SCHEDULE":null
      },
      "history":[
        {"id":"rev-smoke-2","kind":"SMOKING_STATUS","value":"FORMER","unreadable":false,\
    "validFrom":"2026-05-02T09:00:00.000Z","validUntil":null,"provenance":"USER_CORRECTION",\
    "supersededByRevisionId":null,"createdAt":"2026-05-02T09:00:00.000Z"},
        {"id":"rev-smoke-1","kind":"SMOKING_STATUS","value":"CURRENT","unreadable":false,\
    "validFrom":"2026-01-10T08:00:00.000Z","validUntil":"2026-05-02T09:00:00.000Z",\
    "provenance":"USER_REPORTED","supersededByRevisionId":"rev-smoke-2",\
    "createdAt":"2026-01-10T08:00:00.000Z"},
        {"id":"rev-alc-1","kind":"ALCOHOL_PATTERN","value":null,"unreadable":true,\
    "validFrom":"2026-03-01T08:00:00.000Z","validUntil":null,"provenance":"USER_REPORTED",\
    "supersededByRevisionId":null,"createdAt":"2026-03-01T08:00:00.000Z"}
      ]},"error":null}
    """

    static let createdRevision = """
    {"data":{"id":"rev-shift-1","kind":"SHIFT_SCHEDULE","value":"ROTATING","unreadable":false,\
    "validFrom":"2026-07-30T12:00:00.000Z","validUntil":null,"provenance":"USER_REPORTED",\
    "supersededByRevisionId":null,"createdAt":"2026-07-30T12:00:00.000Z"},"error":null}
    """

    /// Der PATCH gibt den **Nachfolger** zurück — neue `id`, `USER_CORRECTION`.
    static let successorRevision = """
    {"data":{"id":"rev-smoke-3","kind":"SMOKING_STATUS","value":"NEVER","unreadable":false,\
    "validFrom":"2026-07-30T12:00:00.001Z","validUntil":null,"provenance":"USER_CORRECTION",\
    "supersededByRevisionId":null,"createdAt":"2026-07-30T12:00:00.001Z"},"error":null}
    """

    // MARK: - Helpers

    private func makeRepo() -> AnamnesisRepository {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            cfAccessClientID: nil,
            cfAccessClientToken: nil,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        let api = APIClient(
            environment: env,
            keychain: InMemoryKeychain(),
            sessionConfiguration: .mock()
        )
        return AnamnesisRepository(api: api)
    }

    /// `URLProtocol` tauscht `httpBody` gegen `httpBodyStream` — zurückholen.
    nonisolated static func consumeStream(_ stream: InputStream) -> Data? {
        stream.open()
        defer { stream.close() }
        var buffer = Data()
        var raw = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&raw, maxLength: 4096)
            guard read > 0 else { break }
            buffer.append(raw, count: read)
        }
        return buffer.isEmpty ? nil : buffer
    }

    private static func respond(_ request: URLRequest, _ status: Int, _ json: String)
        -> (HTTPURLResponse, Data?)
    {
        let http = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
        )!
        return (http, Data(json.utf8))
    }

    // MARK: - GET

    @Test("GET decodes current + history and keeps 'never recorded' distinct from NONE")
    func getDecodesThreeStates() async throws {
        let repo = makeRepo()
        nonisolated(unsafe) var capturedPath: String?
        nonisolated(unsafe) var capturedMethod: String?
        MockURLProtocol.handler = { request in
            capturedPath = request.url?.path
            capturedMethod = request.httpMethod
            return Self.respond(request, 200, Self.factsPayload)
        }

        let payload = try await repo.facts()

        #expect(capturedPath == "/api/anamnesis/facts")
        #expect(capturedMethod == "GET")

        // Erfasst und lesbar.
        guard case let .recorded(revision, value) = payload.state(for: .smokingStatus) else {
            Issue.record("SMOKING_STATUS should be recorded")
            return
        }
        #expect(revision.id == "rev-smoke-2")
        #expect(value == .former)
        #expect(revision.provenance == .userCorrection)
        #expect(revision.isCurrent)

        // Erfasst, aber unlesbar — angezeigt, nicht versteckt.
        guard case let .unreadable(unreadableRevision) = payload.state(for: .alcoholPattern) else {
            Issue.record("ALCOHOL_PATTERN should be unreadable")
            return
        }
        #expect(unreadableRevision.value == nil)
        #expect(unreadableRevision.unreadable)

        // Nie erfasst — der Server sendet `null`, und das ist NICHT `NONE`.
        #expect(payload.state(for: .shiftSchedule) == .neverRecorded)
        #expect(payload.state(for: .shiftSchedule).value == nil)
        #expect(payload.state(for: .shiftSchedule).revision == nil)
    }

    @Test("history is per-kind, newest validity first, and carries the superseded predecessor")
    func historyRenders() async throws {
        let repo = makeRepo()
        MockURLProtocol.handler = { Self.respond($0, 200, Self.factsPayload) }

        let payload = try await repo.facts()
        let smoking = payload.history(for: .smokingStatus)

        #expect(smoking.count == 2)
        #expect(smoking.first?.id == "rev-smoke-2")
        #expect(smoking.first?.validUntil == nil)
        #expect(smoking.last?.id == "rev-smoke-1")
        #expect(smoking.last?.supersededByRevisionId == "rev-smoke-2")
        #expect(smoking.last?.isCurrent == false)
        #expect(payload.history(for: .shiftSchedule).isEmpty)
        #expect(payload.recordedKinds == [.smokingStatus, .alcoholPattern])
    }

    @Test("a history row with an unknown kind is skipped, not fatal")
    func historyDecodesLossily() async throws {
        let repo = makeRepo()
        let payload = """
        {"data":{"current":{"SMOKING_STATUS":null,"ALCOHOL_PATTERN":null,"SHIFT_SCHEDULE":null},
          "history":[
            {"id":"rev-x","kind":"CAFFEINE_INTAKE","value":"DAILY","unreadable":false,\
        "validFrom":"2026-01-01T00:00:00.000Z","validUntil":null,"provenance":"USER_REPORTED",\
        "supersededByRevisionId":null,"createdAt":"2026-01-01T00:00:00.000Z"},
            {"id":"rev-smoke-1","kind":"SMOKING_STATUS","value":"NEVER","unreadable":false,\
        "validFrom":"2026-01-01T00:00:00.000Z","validUntil":null,"provenance":"USER_REPORTED",\
        "supersededByRevisionId":null,"createdAt":"2026-01-01T00:00:00.000Z"}
          ]},"error":null}
        """
        MockURLProtocol.handler = { Self.respond($0, 200, payload) }

        let decoded = try await repo.facts()
        #expect(decoded.history.count == 1)
        #expect(decoded.history.first?.kind == .smokingStatus)
    }

    @Test("an unknown value literal decodes to .unknown instead of failing")
    func unknownValueIsTolerated() async throws {
        let repo = makeRepo()
        let payload = """
        {"data":{"current":{"SMOKING_STATUS":{"id":"r1","kind":"SMOKING_STATUS",\
        "value":"VAPING_ONLY","unreadable":false,"validFrom":"2026-01-01T00:00:00.000Z",\
        "validUntil":null,"provenance":"USER_REPORTED","supersededByRevisionId":null,\
        "createdAt":"2026-01-01T00:00:00.000Z"},"ALCOHOL_PATTERN":null,"SHIFT_SCHEDULE":null},
          "history":[]},"error":null}
        """
        MockURLProtocol.handler = { Self.respond($0, 200, payload) }

        let decoded = try await repo.facts()
        #expect(decoded.state(for: .smokingStatus).value == .unknown("VAPING_ONLY"))
        #expect(decoded.state(for: .smokingStatus).value?.isUnknown == true)
    }

    // MARK: - POST

    @Test("create POSTs the discriminated union body plus an Idempotency-Key")
    func createWireShape() async throws {
        let repo = makeRepo()
        nonisolated(unsafe) var capturedBody: Data?
        nonisolated(unsafe) var capturedMethod: String?
        nonisolated(unsafe) var capturedKey: String?
        MockURLProtocol.handler = { request in
            capturedBody = request.httpBody ?? request.httpBodyStream.flatMap(Self.consumeStream(_:))
            capturedMethod = request.httpMethod
            capturedKey = request.value(forHTTPHeaderField: "Idempotency-Key")
            return Self.respond(request, 201, Self.createdRevision)
        }

        let created = try await repo.create(kind: .shiftSchedule, value: .rotating)

        #expect(capturedMethod == "POST")
        #expect(capturedKey?.isEmpty == false)
        let body = try #require(capturedBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["kind"] as? String == "SHIFT_SCHEDULE")
        #expect(json["value"] as? String == "ROTATING")
        #expect(json.count == 2)
        #expect(created.id == "rev-shift-1")
        #expect(created.provenance == .userReported)
    }

    @Test("a value from a foreign kind is rejected locally — no request goes out")
    func crossKindValueIsRejectedBeforeTheWire() async throws {
        let repo = makeRepo()
        nonisolated(unsafe) var didHitNetwork = false
        MockURLProtocol.handler = { request in
            didHitNetwork = true
            return Self.respond(request, 201, Self.createdRevision)
        }

        await #expect(throws: AnamnesisFactFailure.invalidValue) {
            try await repo.create(kind: .smokingStatus, value: .rotating)
        }
        #expect(!didHitNetwork)
    }

    // MARK: - PATCH

    @Test("correct PATCHes only { value } to the revision path and returns the successor")
    func correctWireShape() async throws {
        let repo = makeRepo()
        nonisolated(unsafe) var capturedPath: String?
        nonisolated(unsafe) var capturedMethod: String?
        nonisolated(unsafe) var capturedBody: Data?
        MockURLProtocol.handler = { request in
            capturedPath = request.url?.path
            capturedMethod = request.httpMethod
            capturedBody = request.httpBody ?? request.httpBodyStream.flatMap(Self.consumeStream(_:))
            return Self.respond(request, 200, Self.successorRevision)
        }

        let successor = try await repo.correct(
            revisionId: "rev-smoke-2", kind: .smokingStatus, to: .never
        )

        #expect(capturedMethod == "PATCH")
        // Die Revisions-ID im Pfad IST das Nebenläufigkeits-Token.
        #expect(capturedPath == "/api/anamnesis/facts/rev-smoke-2")
        let body = try #require(capturedBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["value"] as? String == "NEVER")
        // Kein `kind`, kein `baseUpdatedAt` — der Body trägt genau einen Schlüssel.
        #expect(json.count == 1)
        #expect(json["baseUpdatedAt"] == nil)
        // Der Nachfolger hat eine NEUE id — ein naiver Cache bricht genau hier.
        #expect(successor.id == "rev-smoke-3")
        #expect(successor.provenance == .userCorrection)
    }

    // MARK: - DELETE

    @Test("remove decodes the smaller removed-shape (no value field)")
    func removeWireShape() async throws {
        let repo = makeRepo()
        nonisolated(unsafe) var capturedMethod: String?
        nonisolated(unsafe) var capturedPath: String?
        MockURLProtocol.handler = { request in
            capturedMethod = request.httpMethod
            capturedPath = request.url?.path
            let json = """
            {"data":{"id":"rev-smoke-2","kind":"SMOKING_STATUS",\
            "removedAt":"2026-07-30T12:00:00.000Z"},"error":null}
            """
            return Self.respond(request, 200, json)
        }

        let removed = try await repo.remove(revisionId: "rev-smoke-2")

        #expect(capturedMethod == "DELETE")
        #expect(capturedPath == "/api/anamnesis/facts/rev-smoke-2")
        #expect(removed.id == "rev-smoke-2")
        #expect(removed.kind == .smokingStatus)
    }

    // MARK: - Die vier Fehlerbilder

    @Test("409 anamnesis.fact.conflict becomes .conflict, not a generic error")
    func conflictIsNamed() async throws {
        let repo = makeRepo()
        MockURLProtocol.handler = { request in
            let json = """
            {"data":null,"error":"Profile fact changed since it was loaded",\
            "meta":{"errorCode":"anamnesis.fact.conflict"}}
            """
            return Self.respond(request, 409, json)
        }

        await #expect(throws: AnamnesisFactFailure.conflict) {
            try await repo.correct(revisionId: "rev-1", kind: .smokingStatus, to: .never)
        }
    }

    @Test("409 anamnesis.fact.currentExists becomes .currentExists")
    func currentExistsIsNamed() async throws {
        let repo = makeRepo()
        MockURLProtocol.handler = { request in
            let json = """
            {"data":null,"error":"A current value already exists for this fact",\
            "meta":{"errorCode":"anamnesis.fact.currentExists"}}
            """
            return Self.respond(request, 409, json)
        }

        await #expect(throws: AnamnesisFactFailure.currentExists) {
            try await repo.create(kind: .smokingStatus, value: .never)
        }
    }

    @Test("422 anamnesis.fact.invalidValue becomes .invalidValue")
    func invalidValueIsNamed() async throws {
        let repo = makeRepo()
        MockURLProtocol.handler = { request in
            let json = """
            {"data":null,"error":"Value is not valid for this fact kind",\
            "meta":{"errorCode":"anamnesis.fact.invalidValue"}}
            """
            return Self.respond(request, 422, json)
        }

        await #expect(throws: AnamnesisFactFailure.invalidValue) {
            try await repo.correct(revisionId: "rev-1", kind: .smokingStatus, to: .never)
        }
    }

    @Test("404 on a superseded revision id becomes .staleRevision, not a bare not-found")
    func staleRevisionIsNamed() async throws {
        let repo = makeRepo()
        MockURLProtocol.handler = { request in
            Self.respond(request, 404, #"{"data":null,"error":"Current profile fact not found"}"#)
        }

        await #expect(throws: AnamnesisFactFailure.staleRevision) {
            try await repo.correct(revisionId: "rev-dead", kind: .smokingStatus, to: .never)
        }
    }

    /// **Die Falle aus der Wire-Recherche.** Der Idempotenz-Wrapper auf POST
    /// sendet `error` als **Objekt** statt als String. Vor der toleranten
    /// `APIEnvelope`-Dekodierung versenkte das den ganzen Envelope und der
    /// Aufrufer bekam ein nacktes `HTTP 409` — genau im Outbox-Replay-Pfad,
    /// in dem zwei Requests denselben Idempotency-Key tragen.
    @Test("409 with an OBJECT-shaped error (idempotency wrapper) becomes .requestInFlight")
    func idempotencyInFlightIsCaught() async throws {
        let repo = makeRepo()
        MockURLProtocol.handler = { request in
            let json = """
            {"data":null,"error":{"message":"A request with this Idempotency-Key is already in progress"}}
            """
            let http = HTTPURLResponse(
                url: request.url!,
                statusCode: 409,
                httpVersion: nil,
                headerFields: ["X-Idempotent-Replay": "false"]
            )!
            return (http, Data(json.utf8))
        }

        await #expect(throws: AnamnesisFactFailure.requestInFlight) {
            try await repo.create(kind: .shiftSchedule, value: .rotating)
        }
    }

    @Test("a successful idempotent replay (201 + X-Idempotent-Replay) decodes normally")
    func idempotentReplayDecodes() async throws {
        let repo = makeRepo()
        MockURLProtocol.handler = { request in
            let http = HTTPURLResponse(
                url: request.url!,
                statusCode: 201,
                httpVersion: nil,
                headerFields: ["X-Idempotent-Replay": "true"]
            )!
            return (http, Data(Self.createdRevision.utf8))
        }

        let created = try await repo.create(kind: .shiftSchedule, value: .rotating)
        #expect(created.id == "rev-shift-1")
    }

    @Test("a 500 stays generic — only the four named failures get their own copy")
    func serverErrorFallsThrough() async throws {
        let repo = makeRepo()
        MockURLProtocol.handler = { request in
            Self.respond(request, 500, #"{"data":null,"error":"Interner Serverfehler"}"#)
        }

        do {
            _ = try await repo.facts()
            Issue.record("expected a failure")
        } catch let failure as AnamnesisFactFailure {
            guard case .other = failure else {
                Issue.record("a 500 must not be mapped onto a named anamnesis failure")
                return
            }
            #expect(!failure.requiresReload)
        }
    }
}

// swiftlint:enable force_unwrapping
