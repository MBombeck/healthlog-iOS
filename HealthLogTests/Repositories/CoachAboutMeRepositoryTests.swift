// swiftlint:disable force_unwrapping
import Foundation
@testable import HealthLog
import Testing

/// **Server-parity v1.16 — coach self-context ("About me") contract**
/// (`GET/PUT /api/coach/about-me`, server v1.15.20 + v1.16.0).
///
/// Pins the wire shapes against the *real* `APIClient` with a stubbed
/// `URLSession` (`MockURLProtocol`) — never a mock server (PROJECT_GUIDE.md):
///   - GET decode (nullable fields, pendingQuestions, server caps),
///   - PUT body (all four fields explicit, empty = clear) + Idempotency-Key,
///   - PUT echo decode (effective state + derived questions).
@Suite("CoachAboutMeRepository", .serialized)
struct CoachAboutMeRepositoryTests {
    private func makeRepo() -> CoachAboutMeRepository {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            cfAccessClientID: nil,
            cfAccessClientToken: nil,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        let api = APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
        return CoachAboutMeRepository(api: api)
    }

    /// `URLProtocol` swaps `httpBody` for `httpBodyStream` — re-materialize.
    nonisolated static func consumeStream(_ stream: InputStream) -> Data? {
        stream.open()
        defer { stream.close() }
        var buf = Data()
        var raw = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&raw, maxLength: 4096)
            guard read > 0 else { break }
            buf.append(raw, count: read)
        }
        return buf.isEmpty ? nil : buf
    }

    @Test("get decodes the stored self-context including caps + questions")
    func getDecodes() async throws {
        let repo = makeRepo()
        nonisolated(unsafe) var capturedPath: String?
        nonisolated(unsafe) var capturedMethod: String?
        MockURLProtocol.handler = { req in
            capturedPath = req.url?.path
            capturedMethod = req.httpMethod
            let payload = """
            {"data":{"aboutMe":"Marathon training","conditions":null,"allergies":"Pollen",\
            "coachFocus":null,"pendingQuestions":["How many hours do you sleep?"],\
            "updatedAt":"2026-06-11T10:00:00.000Z","maxChars":4000,"fieldMaxChars":500},"error":null}
            """
            let http = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (http, Data(payload.utf8))
        }
        let dto = try await repo.get()

        #expect(capturedPath == "/api/coach/about-me")
        #expect(capturedMethod == "GET")
        #expect(dto.aboutMe == "Marathon training")
        #expect(dto.conditions == nil)
        #expect(dto.allergies == "Pollen")
        #expect(dto.pendingQuestions == ["How many hours do you sleep?"])
        #expect(dto.maxChars == 4000)
        #expect(dto.fieldMaxChars == 500)
    }

    @Test("get tolerates the empty (never-saved) state")
    func getEmptyState() async throws {
        let repo = makeRepo()
        MockURLProtocol.handler = { req in
            let payload = """
            {"data":{"aboutMe":null,"conditions":null,"allergies":null,"coachFocus":null,\
            "pendingQuestions":[],"updatedAt":null,"maxChars":4000,"fieldMaxChars":500},"error":null}
            """
            let http = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (http, Data(payload.utf8))
        }
        let dto = try await repo.get()
        #expect(dto.aboutMe == nil)
        #expect(dto.pendingQuestions.isEmpty)
        #expect(dto.updatedAt == nil)
    }

    @Test("update PUTs all four fields + an Idempotency-Key and decodes the echo")
    func updateWireShape() async throws {
        let repo = makeRepo()
        nonisolated(unsafe) var capturedPath: String?
        nonisolated(unsafe) var capturedMethod: String?
        nonisolated(unsafe) var capturedBody: Data?
        nonisolated(unsafe) var capturedIdempotencyKey: String?
        MockURLProtocol.handler = { req in
            capturedPath = req.url?.path
            capturedMethod = req.httpMethod
            capturedBody = req.httpBody ?? req.httpBodyStream.flatMap(Self.consumeStream(_:))
            capturedIdempotencyKey = req.value(forHTTPHeaderField: "Idempotency-Key")
            let payload = """
            {"data":{"aboutMe":"New text","conditions":"Hypertension","allergies":"",\
            "coachFocus":null,"pendingQuestions":["Q1","Q2"],\
            "updatedAt":"2026-06-11T11:00:00.000Z","maxChars":4000,"fieldMaxChars":500},"error":null}
            """
            let http = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (http, Data(payload.utf8))
        }
        let echo = try await repo.update(
            CoachAboutMeWrite(aboutMe: "New text", conditions: "Hypertension", allergies: "", coachFocus: "")
        )

        #expect(capturedPath == "/api/coach/about-me")
        #expect(capturedMethod == "PUT")
        #expect(capturedIdempotencyKey?.isEmpty == false)
        let body = try #require(capturedBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["aboutMe"] as? String == "New text")
        #expect(json["conditions"] as? String == "Hypertension")
        // Empty string = clear (PUT semantics) — must travel, not be dropped.
        #expect((json["allergies"] as? String)?.isEmpty == true)
        #expect((json["coachFocus"] as? String)?.isEmpty == true)
        #expect(json.count == 4)
        #expect(echo.pendingQuestions == ["Q1", "Q2"])
        #expect(echo.conditions == "Hypertension")
    }

    // MARK: - Clarifying-question loop (COACH-3)

    @Test("adopt POSTs question + answer + an Idempotency-Key and decodes the result")
    func adoptWireShape() async throws {
        let repo = makeRepo()
        nonisolated(unsafe) var capturedPath: String?
        nonisolated(unsafe) var capturedMethod: String?
        nonisolated(unsafe) var capturedBody: Data?
        nonisolated(unsafe) var capturedKey: String?
        MockURLProtocol.handler = { req in
            capturedPath = req.url?.path
            capturedMethod = req.httpMethod
            capturedBody = req.httpBody ?? req.httpBodyStream.flatMap(Self.consumeStream(_:))
            capturedKey = req.value(forHTTPHeaderField: "Idempotency-Key")
            let payload = #"{"data":{"adopted":true,"field":"allergies"},"error":null}"#
            let http = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (http, Data(payload.utf8))
        }
        let result = try await repo.adopt(
            CoachAboutMeAdoptWrite(question: "Any allergies?", answer: "Peanuts")
        )

        #expect(capturedPath == "/api/coach/about-me/adopt")
        #expect(capturedMethod == "POST")
        #expect(capturedKey?.isEmpty == false)
        let body = try #require(capturedBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["question"] as? String == "Any allergies?")
        #expect(json["answer"] as? String == "Peanuts")
        #expect(result.adopted)
        #expect(result.field == "allergies")
    }

    @Test("remember (no question) OMITS the question key so the server matches on the answer")
    func adoptRememberOmitsQuestion() async throws {
        let repo = makeRepo()
        nonisolated(unsafe) var capturedBody: Data?
        MockURLProtocol.handler = { req in
            capturedBody = req.httpBody ?? req.httpBodyStream.flatMap(Self.consumeStream(_:))
            let payload = #"{"data":{"adopted":true,"field":"coachFocus"},"error":null}"#
            let http = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (http, Data(payload.utf8))
        }
        _ = try await repo.adopt(CoachAboutMeAdoptWrite(question: nil, answer: "I run every morning"))

        let body = try #require(capturedBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        // The remember-from-chat path must send NO `question` key (not null) —
        // the server's zod treats it as `.optional()` and matches on the text.
        #expect(json["question"] == nil)
        #expect(json.keys.contains("question") == false)
        #expect(json["answer"] as? String == "I run every morning")
    }

    @Test("dismissQuestion DELETEs with the question body and decodes remaining set")
    func dismissWireShape() async throws {
        let repo = makeRepo()
        nonisolated(unsafe) var capturedPath: String?
        nonisolated(unsafe) var capturedMethod: String?
        nonisolated(unsafe) var capturedBody: Data?
        MockURLProtocol.handler = { req in
            capturedPath = req.url?.path
            capturedMethod = req.httpMethod
            capturedBody = req.httpBody ?? req.httpBodyStream.flatMap(Self.consumeStream(_:))
            let payload = #"{"data":{"questions":["Stays pending?"]},"error":null}"#
            let http = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (http, Data(payload.utf8))
        }
        let result = try await repo.dismissQuestion(
            CoachAboutMeDismissWrite(question: "Dismiss me")
        )

        #expect(capturedPath == "/api/coach/about-me/questions")
        #expect(capturedMethod == "DELETE")
        let body = try #require(capturedBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["question"] as? String == "Dismiss me")
        #expect(result.questions == ["Stays pending?"])
    }

    @Test("dismiss-all OMITS the question key (server reads absent as dismiss-all)")
    func dismissAllOmitsQuestion() async throws {
        let repo = makeRepo()
        nonisolated(unsafe) var capturedBody: Data?
        MockURLProtocol.handler = { req in
            capturedBody = req.httpBody ?? req.httpBodyStream.flatMap(Self.consumeStream(_:))
            let payload = #"{"data":{"questions":[]},"error":null}"#
            let http = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (http, Data(payload.utf8))
        }
        let result = try await repo.dismissQuestion(CoachAboutMeDismissWrite(question: nil))

        let body = try #require(capturedBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json.keys.contains("question") == false)
        #expect(result.questions.isEmpty)
    }
}

/// **COACH-3 — store-level loop semantics** against the real `APIClient` +
/// stubbed `URLSession`: adopt round-trips into the about-me fields (via the
/// post-adopt re-GET), dismiss removes the question, remember appends context.
@MainActor
@Suite("CoachAboutMeStore — clarifying-question loop", .serialized)
struct CoachAboutMeStoreLoopTests {
    private func makeStore() -> CoachAboutMeStore {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            cfAccessClientID: nil,
            cfAccessClientToken: nil,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        let api = APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
        return CoachAboutMeStore(repository: CoachAboutMeRepository(api: api))
    }

    @Test("adopt round-trips the answer into the about-me field + clears the question")
    func adoptRoundTrips() async {
        let store = makeStore()
        // Seed: one pending question, no allergies yet.
        MockURLProtocol.handler = { req in
            let payload = """
            {"data":{"aboutMe":null,"conditions":null,"allergies":null,"coachFocus":null,\
            "pendingQuestions":["Any allergies?"],"updatedAt":null,"maxChars":4000,"fieldMaxChars":500},"error":null}
            """
            let http = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (http, Data(payload.utf8))
        }
        await store.load()
        #expect(store.pendingQuestions == ["Any allergies?"])

        // Adopt → POST /adopt then a re-GET that now returns the appended field.
        nonisolated(unsafe) var sawAdoptPost = false
        MockURLProtocol.handler = { req in
            if req.url?.path == "/api/coach/about-me/adopt" {
                sawAdoptPost = true
                let payload = #"{"data":{"adopted":true,"field":"allergies"},"error":null}"#
                let http = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (http, Data(payload.utf8))
            }
            // The post-adopt re-GET — allergies now populated, question gone.
            let payload = """
            {"data":{"aboutMe":null,"conditions":null,"allergies":"Peanuts","coachFocus":null,\
            "pendingQuestions":[],"updatedAt":"2026-06-14T10:00:00.000Z","maxChars":4000,"fieldMaxChars":500},"error":null}
            """
            let http = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (http, Data(payload.utf8))
        }
        await store.adoptQuestion("Any allergies?", answer: "Peanuts")

        #expect(sawAdoptPost)
        #expect(store.allergies == "Peanuts") // round-tripped into the field
        #expect(store.pendingQuestions.isEmpty) // question cleared
        #expect(store.questionOutcome == .adopted(field: "allergies"))
    }

    @Test("dismiss removes the question from the pending set")
    func dismissRemovesQuestion() async {
        let store = makeStore()
        MockURLProtocol.handler = { req in
            let payload = """
            {"data":{"aboutMe":null,"conditions":null,"allergies":null,"coachFocus":null,\
            "pendingQuestions":["Drop me","Keep me"],"updatedAt":null,"maxChars":4000,"fieldMaxChars":500},"error":null}
            """
            let http = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (http, Data(payload.utf8))
        }
        await store.load()
        #expect(store.pendingQuestions == ["Drop me", "Keep me"])

        MockURLProtocol.handler = { req in
            let payload = #"{"data":{"questions":["Keep me"]},"error":null}"#
            let http = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (http, Data(payload.utf8))
        }
        await store.dismissQuestion("Drop me")

        #expect(store.pendingQuestions == ["Keep me"])
        #expect(store.questionOutcome == .dismissed)
    }

    @Test("remember adds context (POST adopt with no question) + returns the result")
    func rememberAddsContext() async {
        let store = makeStore()
        nonisolated(unsafe) var sawNoQuestion = false
        MockURLProtocol.handler = { req in
            if req.url?.path == "/api/coach/about-me/adopt" {
                let body = req.httpBody ?? CoachAboutMeRepositoryTests.consumeStream(req.httpBodyStream!)
                if let body, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                    sawNoQuestion = json.keys.contains("question") == false
                }
                let payload = #"{"data":{"adopted":true,"field":"conditions"},"error":null}"#
                let http = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (http, Data(payload.utf8))
            }
            let http = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (http, Data(#"{"data":{},"error":null}"#.utf8))
        }
        // Store not loaded → remember skips the refresh re-GET (didLoad == false).
        let result = await store.remember("I was diagnosed with asthma")

        #expect(sawNoQuestion)
        #expect(result?.adopted == true)
        #expect(result?.field == "conditions")
    }
}
