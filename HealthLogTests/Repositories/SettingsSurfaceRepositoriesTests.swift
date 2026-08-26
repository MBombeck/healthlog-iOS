import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// Locks the wire contracts for the Settings-surface repos lifted out of
/// their Views in v0.8.0 W6 (`PasskeyRepository`,
/// `WithingsRepository`). Real `APIClient` + stubbed `URLProtocol` — never a
/// mock server (PROJECT_GUIDE.md outbox/replay testing rule). The whole point of the
/// re-home is that the endpoint paths are now contract-testable rather than
/// hand-rolled inside the View, so the historic path-drift 404s
/// (`/api/integrations/...`) can be pinned.
private func makeAPI() -> APIClient {
    let env = AppEnvironment(
        baseURL: URL(string: "https://test.healthlog.local")!,
        bundleID: "dev.healthlog.app",
        appVersion: "0.8.0",
        buildNumber: "1"
    )
    let kc = InMemoryKeychain()
    return APIClient(environment: env, keychain: kc, sessionConfiguration: .mock())
}

@Suite("PasskeyRepository — wire contract", .serialized)
struct PasskeyRepositoryTests {
    @Test("list — GET /api/auth/passkeys decodes the credential array")
    func listDecodes() async throws {
        let repo = PasskeyRepository(api: makeAPI())
        nonisolated(unsafe) var lastPath: String?
        MockURLProtocol.handler = { req in
            lastPath = req.url?.path
            let body = Data(#"""
            {"data":[{"id":"pk-1","name":"iPhone","credentialDeviceType":"multiDevice","credentialBackedUp":true,"createdAt":"2026-05-01T12:00:00.000Z"}],"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let entries = try await repo.list()
        #expect(lastPath == "/api/auth/passkeys")
        #expect(entries.count == 1)
        #expect(entries.first?.id == "pk-1")
        #expect(entries.first?.name == "iPhone")
    }

    @Test("delete — DELETE /api/auth/passkeys/{id} hits the per-credential path")
    func deleteHitsPath() async throws {
        let repo = PasskeyRepository(api: makeAPI())
        nonisolated(unsafe) var lastMethod: String?
        nonisolated(unsafe) var lastPath: String?
        MockURLProtocol.handler = { req in
            lastMethod = req.httpMethod
            lastPath = req.url?.path
            return (HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
        }
        try await repo.delete(id: "pk-42")
        #expect(lastMethod == "DELETE")
        #expect(lastPath == "/api/auth/passkeys/pk-42")
    }

    @Test("delete — DELETE carries no Idempotency-Key header (path-idempotent)")
    func deleteOmitsIdempotencyKey() async throws {
        // `HTTPMethod.requiresIdempotency` excludes DELETE — idempotency comes
        // from the resource path, not a header. Pin the contract so a future
        // change to the framework's header policy is caught here.
        let repo = PasskeyRepository(api: makeAPI())
        nonisolated(unsafe) var key: String?
        MockURLProtocol.handler = { req in
            key = req.value(forHTTPHeaderField: "Idempotency-Key")
            return (HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
        }
        try await repo.delete(id: "pk-1")
        #expect(key == nil)
    }
}

@Suite("WithingsRepository — wire contract", .serialized)
struct WithingsRepositoryTests {
    @Test("status — GET /api/withings/status decodes the connection snapshot")
    func statusDecodes() async throws {
        let repo = WithingsRepository(api: makeAPI())
        nonisolated(unsafe) var lastPath: String?
        MockURLProtocol.handler = { req in
            lastPath = req.url?.path
            let body = Data(#"""
            {"data":{"connected":true,"configured":true,"lastSyncedAt":"2026-05-02T10:00:00.000Z"},"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let status = try await repo.status()
        // Regression pin: the dead `/api/integrations/...` path shipped a
        // permanent "Not connected" 404 (W2a-A2 §8).
        #expect(lastPath == "/api/withings/status")
        #expect(status.connected == true)
    }

    @Test("sync — POST /api/withings/sync with the measure-bucket body + idempotency key")
    func syncPostsMeasureBody() async throws {
        let repo = WithingsRepository(api: makeAPI())
        nonisolated(unsafe) var method: String?
        nonisolated(unsafe) var path: String?
        nonisolated(unsafe) var key: String?
        nonisolated(unsafe) var bodyContainsMeasure = false
        MockURLProtocol.handler = { req in
            method = req.httpMethod
            path = req.url?.path
            key = req.value(forHTTPHeaderField: "Idempotency-Key")
            // URLProtocol strips httpBody into httpBodyStream; the shared
            // `bodyStreamData()` test helper drains whichever is set.
            if let data = req.httpBody ?? drainBodyStream(req),
               let str = String(data: data, encoding: .utf8)
            {
                bodyContainsMeasure = str.contains("measure")
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        try await repo.sync()
        #expect(method == "POST")
        #expect(path == "/api/withings/sync")
        #expect(key?.isEmpty == false)
        #expect(bodyContainsMeasure, "sync body must request the measure bucket")
    }

    @Test("disconnect — DELETE /api/withings/disconnect, no idempotency header")
    func disconnectDeletes() async throws {
        let repo = WithingsRepository(api: makeAPI())
        nonisolated(unsafe) var method: String?
        nonisolated(unsafe) var path: String?
        nonisolated(unsafe) var key: String?
        MockURLProtocol.handler = { req in
            method = req.httpMethod
            path = req.url?.path
            key = req.value(forHTTPHeaderField: "Idempotency-Key")
            return (HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
        }
        try await repo.disconnect()
        #expect(method == "DELETE")
        #expect(path == "/api/withings/disconnect")
        // DELETE is path-idempotent; the framework omits the header.
        #expect(key == nil)
    }

    @Test("sync(kind:idempotencyKey:) — replay overload passes the explicit key")
    func syncReplayOverloadPropagatesKey() async throws {
        let repo = WithingsRepository(api: makeAPI())
        nonisolated(unsafe) var key: String?
        MockURLProtocol.handler = { req in
            key = req.value(forHTTPHeaderField: "Idempotency-Key")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        try await repo.sync(kind: "measure", idempotencyKey: IdempotencyKey(raw: "fixed-ws-key-0001"))
        #expect(key == "fixed-ws-key-0001")
    }
}

/// Drains a `URLRequest` body stream (URLProtocol moves `httpBody` into
/// `httpBodyStream`). File-private to avoid colliding with the equivalent
/// helper in `MedicationsRepositoryReminderIntakeTests`.
private func drainBodyStream(_ request: URLRequest) -> Data? {
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var out = Data()
    let bufSize = 1024
    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
    defer { buf.deallocate() }
    while stream.hasBytesAvailable {
        let read = stream.read(buf, maxLength: bufSize)
        if read <= 0 { break }
        out.append(buf, count: read)
    }
    return out.isEmpty ? nil : out
}

// swiftlint:enable force_unwrapping
