import CryptoKit
import Foundation

/// **D5 #2 — one `GET /api/auth/me` for everyone who reads it at once.**
///
/// Nine repositories read their own slice of the same route: the module gate,
/// the push relay, the disclaimer, the forced second factor, the setup tour,
/// the server prefs, the coach reasoning and more. Each decoded its projection
/// from a round trip of its own, so a cold start sent the route eight to twelve
/// times, several of them back to back.
///
/// The client now keeps one snapshot of the raw answer. Every plain read of
/// the route joins the request already on the wire (single flight) or reads a
/// 2xx answer younger than ``defaultTTL``; each caller still decodes its own
/// projection from the same bytes, so no repository changes shape.
///
/// What keeps it honest:
///   - **Keyed by the request it answers.** The key hashes the URL and every
///     header the request carries: bearer, selected account, proxy access
///     headers. A token rotation, an account switch, a server switch or a
///     sign-out is a different key and never reads the other one's answer.
///   - **Any write ends it.** A non-GET request through the client drops the
///     snapshot before and after it runs and retires a read still on the wire,
///     so a read after a disclaimer ack, a tour stamp or a prefs patch always
///     sees the server's new state.
///   - **Only plain reads share.** A read with a query, extra headers, the
///     fail-fast or streaming session, or without auth recovery goes to the
///     server on its own, as before.
///   - **Only 2xx is kept.** A failure is shared by the callers that were
///     already waiting on it (they would all have failed the same way) and is
///     not reused afterwards.
struct AuthMeSnapshot {
    static let path = "/api/auth/me"
    static let defaultTTL: Duration = .seconds(10)

    var ttl: Duration = defaultTTL
    var now: @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }

    private(set) var generation: UInt64 = 0
    private var stored: Entry?
    private var inFlight: Flight?

    private struct Entry {
        let key: SHA256Digest
        let storedAt: ContinuousClock.Instant
        let data: Data
        let response: HTTPURLResponse
    }

    private struct Flight {
        let key: SHA256Digest
        let generation: UInt64
        let task: Task<(Data, HTTPURLResponse), Error>
    }

    var isEnabled: Bool {
        ttl > .zero
    }

    func cached(for key: SHA256Digest) -> (Data, HTTPURLResponse)? {
        guard let stored, stored.key == key, now() - stored.storedAt < ttl else { return nil }
        return (stored.data, stored.response)
    }

    func flight(for key: SHA256Digest) -> Task<(Data, HTTPURLResponse), Error>? {
        guard let inFlight, inFlight.key == key, inFlight.generation == generation else { return nil }
        return inFlight.task
    }

    mutating func begin(key: SHA256Digest, task: Task<(Data, HTTPURLResponse), Error>) {
        inFlight = Flight(key: key, generation: generation, task: task)
    }

    /// Lands the answer of the flight that started under `generation`. A
    /// flight a write retired on the way is not stored.
    mutating func finish(key: SHA256Digest, startedIn flightGeneration: UInt64, result: (Data, HTTPURLResponse)?) {
        if let inFlight, inFlight.key == key, inFlight.generation == flightGeneration {
            self.inFlight = nil
        }
        guard flightGeneration == generation, let result,
              (200 ... 299).contains(result.1.statusCode) else { return }
        stored = Entry(key: key, storedAt: now(), data: result.0, response: result.1)
    }

    mutating func invalidate() {
        generation &+= 1
        stored = nil
        inFlight = nil
    }
}

extension APIClient {
    /// The transport every buffered request goes through: `execute`, with
    /// the `/api/auth/me` snapshot in front of plain reads of that route and
    /// the snapshot dropped around every write.
    func executeSharingAuthMe(_ request: APIRequest<some Any>) async throws -> (Data, HTTPURLResponse) {
        guard request.method == .get else {
            authMeSnapshot.invalidate()
            defer { authMeSnapshot.invalidate() }
            return try await execute(request)
        }
        guard authMeSnapshot.isEnabled, Self.sharesAuthMeSnapshot(request) else {
            return try await execute(request)
        }
        let key = try authMeSnapshotKey(for: request)
        if let hit = authMeSnapshot.cached(for: key) { return hit }
        if let flight = authMeSnapshot.flight(for: key) { return try await flight.value }

        let generation = authMeSnapshot.generation
        // Unstructured on purpose: the flight belongs to every caller that
        // joins it, so the first caller's cancellation must not fail theirs.
        let task = Task { try await self.execute(request) }
        authMeSnapshot.begin(key: key, task: task)
        do {
            let result = try await task.value
            authMeSnapshot.finish(key: key, startedIn: generation, result: result)
            return result
        } catch {
            authMeSnapshot.finish(key: key, startedIn: generation, result: nil)
            throw error
        }
    }

    /// Drops the snapshot. For the write paths that do not run through
    /// ``executeSharingAuthMe(_:)`` (file upload, the coach stream) and for
    /// the logout purge.
    func invalidateAuthMeSnapshot() {
        authMeSnapshot.invalidate()
    }

    /// Test seam: the snapshot's lifetime and clock. A `ttl` of zero turns
    /// the snapshot off, which is how the start-up count test measures the
    /// client without it.
    func configureAuthMeSnapshot(
        ttl: Duration,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        authMeSnapshot.invalidate()
        authMeSnapshot.ttl = ttl
        authMeSnapshot.now = now
    }

    nonisolated static func sharesAuthMeSnapshot(_ request: APIRequest<some Any>) -> Bool {
        request.method == .get
            && request.path == AuthMeSnapshot.path
            && request.query.isEmpty
            && request.body == nil
            && request.extraHeaders.isEmpty
            && !request.failFast
            && !request.streaming
            && request.allowsAuthenticationRecovery
    }

    /// The hash of the URL and every header the request would go out with.
    /// Only the digest is kept, never the bearer itself.
    private func authMeSnapshotKey(for request: APIRequest<some Any>) throws -> SHA256Digest {
        let built = try buildURLRequest(request)
        var material = built.url?.absoluteString ?? ""
        for (name, value) in (built.allHTTPHeaderFields ?? [:]).sorted(by: { $0.key.lowercased() < $1.key.lowercased() }) {
            material += "\n\(name.lowercased()):\(value)"
        }
        return SHA256.hash(data: Data(material.utf8))
    }
}
