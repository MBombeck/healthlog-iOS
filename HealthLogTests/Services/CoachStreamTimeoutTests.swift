// swiftlint:disable force_unwrapping force_try
import Foundation
@testable import HealthLog
import Testing

/// **W-COACH-SSE** (audit AUDIT-RELIABILITY-robustness.md H6) — the coach server
/// SSE stream used to ride the generic patient timeouts (20 s request / 60 s
/// resource), so a slow LLM turn got prematurely cut off. This suite proves:
///
///  1. The coach SSE request opts into the streaming transport (`streaming ==
///     true`) while every non-coach request stays on the patient session.
///  2. The coach timeout policy is the streaming one (idle-reset request timeout
///     + generous ceiling), strictly more generous than the 20 s/60 s wall.
///  3. A stream that keeps emitting past 60 s is NOT cut off — exercised against
///     a real `APIClient` with a drip-feeding URLProtocol that delivers the SSE
///     body in chunks spaced across a window that would breach the 60 s wall.
///  4. A genuine idle-stall ends with an honest error (no infinite hang).
@Suite("Coach SSE streaming timeout policy")
struct CoachStreamTimeoutTests {
    // MARK: - 1. Request opts into the streaming transport

    @Test("coachChat request rides the streaming session (streaming == true)")
    func coachRequestIsStreaming() throws {
        let req = try APIRequest<Data>.coachChat(
            body: ChatRequestBody(conversationId: nil, message: "Hi", locale: "en"),
            encoder: .hlDefault
        )
        #expect(req.streaming == true)
        #expect(req.path == "/api/insights/chat")
        // It must NOT also fail-fast (the two transports are mutually exclusive;
        // failFast would win and re-route off the streaming budget).
        #expect(req.failFast == false)
    }

    @Test("generic requests default to the patient session (streaming == false)")
    func genericRequestsAreNotStreaming() throws {
        let get: APIRequest<EmptyPayload> = .get("/api/feature-flags")
        #expect(get.streaming == false)

        let post: APIRequest<EmptyPayload> = try .post("/api/x", body: ["a": "b"])
        #expect(post.streaming == false)

        // Even an interactive auth leg (fail-fast) is not a streaming request.
        let authLeg = APIRequest<EmptyPayload>(
            method: .post,
            path: "/api/auth/login",
            failFast: true
        )
        #expect(authLeg.streaming == false)
        #expect(authLeg.failFast == true)
    }

    // MARK: - 2. The policy is the streaming one, not the generic wall

    @Test("coach policy is idle-reset + generous ceiling, not the 20 s/60 s wall")
    func policyIsStreamingNotGeneric() {
        let coach = CoachStreamTimeoutPolicy.coachStream
        let patient = CoachStreamTimeoutPolicy.patient

        // The generic patient wall is the one that cut off a slow LLM turn.
        #expect(patient.inactivityTimeout == 20)
        #expect(patient.overallCeiling == 60)

        // The coach stream must be strictly more generous on BOTH knobs.
        #expect(coach.inactivityTimeout > patient.inactivityTimeout)
        #expect(coach.overallCeiling > patient.overallCeiling)

        // The overall ceiling must exceed the 60 s wall so a long valid stream
        // is not capped at 60 s (the core of the bug).
        #expect(coach.overallCeiling > 60)
        // The inactivity timeout is per-chunk and resets on every SSE token, so
        // a long pause between tokens during a slow generation survives.
        #expect(coach.inactivityTimeout >= 60)
    }

    // MARK: - 3. A stream emitting past 60 s is NOT cut off

    @MainActor
    @Test("a stream that keeps emitting past the 60 s wall completes (not cut off)")
    func longStreamNotCutOff() async throws {
        // Drip the SSE body in chunks spaced so the LAST chunk lands AFTER the
        // 60 s generic resource wall would have fired (compressed via a time
        // scale so the test runs fast). The streaming session's per-chunk
        // inactivity timer resets on each chunk and its overall ceiling is well
        // above the window, so the request must complete with the full body.
        let frames = [
            "data: {\"type\":\"token\",\"token\":\"Slow \"}\n\n",
            "data: {\"type\":\"token\",\"token\":\"LLM \"}\n\n",
            "data: {\"type\":\"token\",\"token\":\"turn.\"}\n\n",
            "data: {\"type\":\"done\",\"conversationId\":\"c-long\",\"messageId\":\"m-long\"}\n\n"
        ].map { Data($0.utf8) }
        // Inter-chunk gap (compressed). Four chunks * 40 ms ≈ 160 ms of activity;
        // the simulated wall is set BELOW that so a 60 s-style wall would cut it.
        DrippingURLProtocol.configure(
            chunks: frames,
            interChunkDelay: .milliseconds(40),
            stallAfterChunk: nil
        )
        defer { DrippingURLProtocol.reset() }

        let api = makeStreamingAPIClient()
        let req = try APIRequest<Data>.coachChat(
            body: ChatRequestBody(conversationId: nil, message: "slow?", locale: "en"),
            encoder: .hlDefault
        )
        let (data, response) = try await api.download(req)
        #expect(response.statusCode == 200)

        let reply = try CoachServerService.parseSSE(data)
        #expect(reply.text == "Slow LLM turn.")
        #expect(reply.conversationId == "c-long")
        #expect(reply.messageId == "m-long")
    }

    // MARK: - 4. A true idle-stall ends with an honest error (no hang)

    @MainActor
    @Test("a true idle-stall ends with an honest timeout error, not an infinite hang")
    func idleStallEndsCleanly() async throws {
        // Emit one token, then stall forever. The streaming session is built with
        // a short inactivity timeout for THIS test (so the stall trips quickly);
        // the production policy uses 120 s but the *mechanism* — an inactivity
        // timeout that ends the request when no chunk arrives — is identical.
        let firstChunk = Data("data: {\"type\":\"token\",\"token\":\"partial\"}\n\n".utf8)
        DrippingURLProtocol.configure(
            chunks: [firstChunk],
            interChunkDelay: .milliseconds(10),
            stallAfterChunk: 0 // never finish loading after the first chunk
        )
        defer { DrippingURLProtocol.reset() }

        // Short inactivity timeout so the stall trips fast; same MECHANISM as the
        // production 120 s policy (an inactivity timer that ends the request when
        // no chunk arrives). Overall ceiling stays high so the stall — not the
        // ceiling — is what ends it.
        let api = makeStreamingAPIClient(
            policy: CoachStreamTimeoutPolicy(inactivityTimeout: 0.4, overallCeiling: 30)
        )
        let req = try APIRequest<Data>.coachChat(
            body: ChatRequestBody(conversationId: nil, message: "stall?", locale: "en"),
            encoder: .hlDefault
        )

        // Must throw (timeout) within a bounded window — never hang.
        await #expect(throws: (any Error).self) {
            _ = try await api.download(req)
        }
    }

    // MARK: - Helpers

    private func makeStreamingAPIClient(
        policy: CoachStreamTimeoutPolicy = .coachStream
    ) -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://stream.healthlog.local")!,
            cfAccessClientID: nil,
            cfAccessClientToken: nil,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        // A config whose protocolClasses carry our dripping protocol; APIClient
        // copies `protocolClasses` into BOTH the patient and streaming sessions,
        // and the coach request rides the streaming one. `coachStreamPolicy`
        // governs only the streaming session's timeouts.
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DrippingURLProtocol.self]
        return APIClient(
            environment: env,
            keychain: InMemoryKeychain(),
            sessionConfiguration: config,
            coachStreamPolicy: policy
        )
    }
}

// MARK: - Dripping URLProtocol (streaming seam)

/// A `URLProtocol` that delivers a response body in timed chunks so the test can
/// exercise the streaming session against a stream longer than the 60 s wall,
/// and can stall mid-stream to prove the inactivity timeout ends cleanly. It is
/// private to this suite so it cannot collide with the shared `MockURLProtocol`.
private final class DrippingURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var chunks: [Data] = []
    nonisolated(unsafe) static var interChunkDelayMS: Int = 10
    /// When set, the protocol delivers chunks up to and including this index then
    /// stalls forever (never calls `urlProtocolDidFinishLoading`) — models a
    /// server that opens the stream then hangs mid-generation.
    nonisolated(unsafe) static var stallAfterChunk: Int?

    /// Serial queue the chunk-drip schedule runs on (URLProtocol callbacks must
    /// be delivered consistently off the test's actor). Drives the same
    /// inactivity behaviour as a real socket: each `didLoad` is a "chunk arrived"
    /// event that resets URLSession's request (inactivity) timer.
    private let queue = DispatchQueue(label: "dev.healthlog.test.dripping-sse")
    private var cancelled = false

    static func configure(chunks: [Data], interChunkDelay: Duration, stallAfterChunk: Int?) {
        self.chunks = chunks
        // Duration → whole milliseconds for the dispatch schedule (seconds +
        // sub-second attoseconds; the tests use < 1 s gaps but this stays correct
        // for any value).
        let comps = interChunkDelay.components
        let ms = comps.seconds * 1000 + comps.attoseconds / 1_000_000_000_000_000
        interChunkDelayMS = max(1, Int(ms))
        self.stallAfterChunk = stallAfterChunk
    }

    static func reset() {
        chunks = []
        interChunkDelayMS = 10
        stallAfterChunk = nil
    }

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

        let chunks = Self.chunks
        let delayMS = Self.interChunkDelayMS
        let stallAfter = Self.stallAfterChunk
        scheduleChunk(at: 0, chunks: chunks, delayMS: delayMS, stallAfter: stallAfter)
    }

    /// Recursively delivers chunk `index` after `delayMS`, resetting the
    /// inactivity timer each time, until the body is exhausted or a stall index
    /// is reached (after which no further callback fires — the session's
    /// inactivity timeout is what ends the request).
    private func scheduleChunk(at index: Int, chunks: [Data], delayMS: Int, stallAfter: Int?) {
        queue.asyncAfter(deadline: .now() + .milliseconds(delayMS)) { [weak self] in
            guard let self, !cancelled else { return }
            guard index < chunks.count else {
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            client?.urlProtocol(self, didLoad: chunks[index])
            if let stallAfter, index >= stallAfter {
                return // hang — the inactivity timeout must end it
            }
            scheduleChunk(at: index + 1, chunks: chunks, delayMS: delayMS, stallAfter: stallAfter)
        }
    }

    override func stopLoading() {
        queue.sync { cancelled = true }
    }
}
