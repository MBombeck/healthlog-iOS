import Foundation

/// Stub `URLProtocol` used across the suite so tests exercise the **real**
/// `APIClient` over a fake transport (per PROJECT_GUIDE.md: "echten APIClient mit
/// Stub-URLSession nutzen, sonst entgehen uns Schema-Drift-Bugs"). Install a
/// per-test closure via ``handler`` and route it into an `APIClient` through
/// ``URLSessionConfiguration/mock()``.
///
/// ## audit-v0162 H2 — data-race hardening
///
/// The `handler` is a process-global shared by ~149 test files. Swift Testing
/// runs suites **in parallel in-process by default**, so an unsynchronized
/// `static var` is a genuine data race: one suite can read the pointer while
/// another writes it (torn access / TSan trap / false-green network answers).
///
/// The lowest-risk fix that removes the *data race* without rewriting 149 call
/// sites is to serialize every get/set of the backing storage behind a lock —
/// so the closure reference is always read and written atomically. The public
/// API (`MockURLProtocol.handler = { … }` / `Self.handler`) is unchanged, so no
/// call site moves.
///
/// **Residual (documented, not silently accepted):** the lock makes handler
/// access memory-safe but does NOT give each suite its *own* handler — two
/// suites racing can still logically overwrite one another's closure (last
/// writer wins), just never corrupt memory doing so. Suites whose assertions
/// depend on the handler answering only *their* requests must additionally
/// carry `.serialized` (serializes within the suite) and, where cross-suite
/// isolation matters, be grouped under a shared `.serialized` parent suite.
///
/// ## 09-10 — the residual is now fixable, one file at a time
///
/// ``MockURLProtocolSession`` below owns a handler per instance and is
/// reachable only through the configuration it hands out, so the endgame is
/// no longer "out of scope" — it is available, and the migration is the work.
/// The slot above stays as the **compatibility path** for the files that have
/// not migrated yet; every one of them is inventoried by path, line and
/// mutable site in `09-MOCKURLPROTOCOL-AUDIT.md`, with an owner. A tagged
/// request never reads this slot.
///
/// ## CU-07 — counters must not depend on the schedule
///
/// `.serialized` orders the tests *inside* a suite; it does not stop a suite
/// running **in parallel** from pushing a request through the handler that is
/// currently installed. Any handler-side bookkeeping — a call counter, a
/// captured path/header/body, a phase machine driving the response — therefore
/// has to be gated on the endpoint under test. Use ``URLRequest/targets(_:)``
/// and friends at the bottom of this file; the unguarded form
/// (`calls += 1` on every request) is a scheduling-dependent assertion and was
/// the cause of the `MeasurementsRepositorySWRTests` merge-gate failure.
///
/// The remaining hole is the mirror image, and only the endgame migration
/// closes it: if a parallel suite *replaces* the handler between our install
/// and our request, our own request is answered by a foreign closure and our
/// counter stays at zero.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data?)

    /// Backing storage — only ever touched through the locked ``handler``
    /// accessor below. `nonisolated(unsafe)` is sound precisely *because* the
    /// lock, not the compiler, enforces exclusive access.
    private nonisolated(unsafe) static var _handler: Handler?
    private static let handlerLock = NSLock()

    /// Process-global request handler. Get/set are serialized by
    /// ``handlerLock`` so concurrent suites can never tear the closure
    /// reference (audit-v0162 H2).
    static var handler: Handler? {
        get {
            handlerLock.lock()
            defer { handlerLock.unlock() }
            return _handler
        }
        set {
            handlerLock.lock()
            defer { handlerLock.unlock() }
            _handler = newValue
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    /// Resolution order, stated once (Plan 09-13):
    ///
    /// 1. **Host** — `https://<token>.mock.invalid`.
    /// 2. **Header** — `X-HealthLog-Mock-Session`.
    /// 3. The process-global slot, for the inventoried legacy files.
    ///
    /// Host before header, deliberately. The host is the *per-request* address
    /// the test author wrote at the call site and the only one that survives an
    /// intermediary; the header is *ambient* configuration, and `APIClient.init`
    /// assigns `config.httpAdditionalHeaders` wholesale on the caller's own
    /// configuration object, which destroys the token before its `URLSession`
    /// exists. Where both are present they always name the same session, because
    /// both come from the same object — unless a test deliberately crosses them,
    /// and then the URL wins, which is the visible half of the pair.
    ///
    /// Both session channels fail **closed**: an unresolvable host is refused
    /// exactly like an unresolvable token, and neither reads the global slot. A
    /// fallback there would silently restore last-writer-wins for precisely the
    /// requests that arrive after an invalidation, which is the hardest case to
    /// notice and the easiest to mistake for flakiness.
    override func startLoading() {
        if let host = request.url?.host, MockURLProtocolSession.isSessionHost(host) {
            guard let owner = MockURLProtocolSession.owner(forHost: host) else {
                // No live owner for this opaque host: fail closed.
                client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
                return
            }
            respondOrFailClosed(owner: owner)
            return
        }

        if let token = request.value(forHTTPHeaderField: MockURLProtocolSession.tokenHeader) {
            guard let owner = MockURLProtocolSession.owner(for: token) else {
                // Missing or expired token: fail closed.
                client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
                return
            }
            respondOrFailClosed(owner: owner)
            return
        }

        // Compatibility path for the inventoried legacy files. Snapshot the
        // handler through the locked accessor exactly once so a concurrent
        // reassignment mid-request can't swap it under us.
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        respond(using: handler)
    }

    /// Snapshot the owner's handler once and answer with it, or fail closed.
    /// Shared by both session channels so they cannot drift apart.
    private func respondOrFailClosed(owner: MockURLProtocolSession) {
        guard let handler = owner.snapshotHandler() else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        respond(using: handler)
    }

    private func respond(using handler: Handler) {
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let data {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

extension URLSessionConfiguration {
    static func mock() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [MockURLProtocol.self]
        return c
    }
}

// MARK: - Plan 09-10 — session-owned transport

/// One test's own handler, reachable only through the configuration this
/// object hands out.
///
/// The contract, stated before it is implemented:
///
/// * Two live sessions keep two distinct handlers. Installing on B never
///   changes what A's requests are answered with, in either order.
/// * Replacing or invalidating one session cannot alter another's handler.
/// * An invalidated session cannot answer a later session's request.
///
/// ## How a request finds its owner
///
/// There are two channels, and a request needs only one of them.
///
/// **The host (Plan 09-13, and the one a migrated suite uses).** Every session
/// owns an opaque address, `https://<token>.mock.invalid`, exposed as
/// ``baseURL``. A migrated test sets its `AppEnvironment.baseURL` to that value,
/// and `startLoading` resolves the owner from `request.url?.host`.
///
/// **The header (Plan 09-10).** The configuration this object hands out carries
/// the same opaque token in a bespoke header, and nothing else — no handler, no
/// closure, no state another session could reach. A bare
/// `URLSession(configuration: session.configuration)` is routed by it with no
/// URL convention at all.
///
/// Both resolve through the same locked registry, which holds sessions
/// **weakly**, and snapshot that instance's handler exactly once.
///
/// ## Why the host channel exists at all
///
/// The header alone was not enough, and this is measured rather than assumed:
/// `APIClient.init` assigns `config.httpAdditionalHeaders = [...]` **wholesale**
/// on the caller's own configuration object, before `URLSession(configuration:)`
/// exists. The token is gone by the time the first request is built, so every
/// request from a real client arrived untagged and was answered by the global
/// slot. 253 test files build a real `APIClient` over a mock configuration, so
/// without a channel that survives that constructor no suite could migrate.
/// The host survives it because it is not configuration at all — it is the
/// address the request is sent to. Nothing in `HealthLog/` changed to make this
/// work, which was the point.
///
/// Four properties fall out of that shape and are each asserted:
///
/// * A token — or a host — resolves to at most one live owner, so B's install
///   cannot be read by A's request in either order, through either channel.
/// * A token or host that resolves to nothing fails **closed** —
///   `URLError(.cancelled)` — instead of falling back to the process-global
///   slot. A fallback would restore last-writer-wins for exactly the requests
///   that arrive after an invalidation, which is the hardest case to notice
///   and the easiest to mistake for flakiness.
/// * The registry is weak, so a dropped session cannot keep answering and
///   cannot keep its handler's captures alive.
/// * Handing this session's configuration to a client that rewrites it does not
///   disarm the session for anybody else — see ``configuration``.
///
/// The process-global `MockURLProtocol.handler` stays, untouched, as the
/// compatibility path for the inventoried legacy files. It is never consulted
/// for a tagged request, and never for a request addressed to a session host —
/// including one whose owner is gone.
///
/// ## What a migrating suite does
///
/// ```swift
/// let session = MockURLProtocolSession()
/// defer { session.invalidate() }
/// session.install { req in … }
///
/// let environment = AppEnvironment(
///     baseURL: session.baseURL,          // ← the load-bearing line
///     bundleID: "dev.healthlog.app", appVersion: "0.0.0", buildNumber: "1"
/// )
/// let api = APIClient(
///     environment: environment,
///     keychain: InMemoryKeychain(),
///     sessionConfiguration: session.configuration
/// )
/// ```
///
/// The base URL is not optional decoration. A suite that swaps `.mock()` for
/// `session.configuration` but keeps a hard-coded host such as
/// `https://test.healthlog.local` is **not** migrated: `APIClient` strips the
/// token, the host is not a session host, and every request falls through to
/// the global slot — which is the exact behaviour the migration exists to
/// remove, now wearing a session's clothes. Take the base URL from the session
/// and the transport is yours; `req.targets("/api/…")` still works unchanged
/// because only the host moved.
final class MockURLProtocolSession: @unchecked Sendable {
    /// Header that carries the session token. Bespoke on purpose: no
    /// production request sets it, so it can only ever be the session's own.
    static let tokenHeader = "X-HealthLog-Mock-Session"

    /// Suffix of the per-session host. `.invalid` is reserved by RFC 2606 and
    /// can never resolve, so nothing here can leave the process even if a
    /// request escaped the protocol stub.
    static let hostSuffix = ".mock.invalid"

    private final class WeakBox {
        weak var value: MockURLProtocolSession?
        init(_ value: MockURLProtocolSession) {
            self.value = value
        }
    }

    private static let registryLock = NSLock()
    private nonisolated(unsafe) static var registry: [String: WeakBox] = [:]

    /// Opaque, per-instance, never reused. Lower-cased so it is a legal DNS
    /// label and so a host comparison needs no case folding beyond the one
    /// ``MockURLProtocolSession/owner(forHost:)`` already does.
    let token: String

    /// This session's own host, `<token>.mock.invalid`. Opaque and exact: no
    /// other session can claim it, and no production code names it.
    let host: String

    /// Base URL a migrated test hands to `AppEnvironment.baseURL`. See the
    /// routing note above — this is the channel that survives a client which
    /// rewrites the caller's headers.
    let baseURL: URL

    /// Configuration a test hands to its `APIClient`. A **fresh** object every
    /// time, not one stored instance.
    ///
    /// `APIClient.init` mutates the configuration object it is given — it sets
    /// timeouts and then assigns `httpAdditionalHeaders` wholesale. Handing out
    /// one shared instance would mean that constructing a client permanently
    /// disarms this session's header channel for every later consumer, including
    /// a plain `URLSession(configuration:)` made from the same session. Handing
    /// out a copy makes the session immune to whatever its clients do to it.
    ///
    /// The consequence to know: `session.configuration.timeoutIntervalForRequest = 5`
    /// writes to a temporary and is lost. Bind it first, then use the binding.
    var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        var headers = configuration.httpAdditionalHeaders ?? [:]
        headers[Self.tokenHeader] = token
        configuration.httpAdditionalHeaders = headers
        return configuration
    }

    private let lock = NSLock()
    private var storedHandler: MockURLProtocol.Handler?

    init() {
        let token = UUID().uuidString.lowercased()
        let host = token + Self.hostSuffix
        guard let baseURL = URL(string: "https://" + host) else {
            preconditionFailure("MockURLProtocolSession: could not form a base URL for host \(host)")
        }
        self.token = token
        self.host = host
        self.baseURL = baseURL

        Self.registryLock.lock()
        defer { Self.registryLock.unlock() }
        Self.registry[token] = WeakBox(self)
    }

    deinit {
        Self.forget(token)
    }

    /// Install (or replace) this session's handler. Synchronized per session,
    /// so a replacement is atomic and cannot be seen half-applied.
    func install(_ handler: @escaping MockURLProtocol.Handler) {
        lock.lock()
        defer { lock.unlock() }
        storedHandler = handler
    }

    /// Drop this session's handler and unregister the token. A request that
    /// arrives afterwards fails closed; it does not reach another session and
    /// it does not reach the legacy global slot.
    func invalidate() {
        lock.lock()
        storedHandler = nil
        lock.unlock()
        Self.forget(token)
    }

    /// Read the handler once, under this session's own lock.
    func snapshotHandler() -> MockURLProtocol.Handler? {
        lock.lock()
        defer { lock.unlock() }
        return storedHandler
    }

    /// Resolve a token to its live owner, or `nil`.
    static func owner(for token: String) -> MockURLProtocolSession? {
        registryLock.lock()
        defer { registryLock.unlock() }
        return registry[token]?.value
    }

    /// True when `host` is inside the session namespace — that is, when it
    /// carries a **non-empty** label in front of ``hostSuffix``.
    ///
    /// The bare `mock.invalid` is deliberately *not* a session host. Several of
    /// this suite's own legacy-path cases address it, and `"mock.invalid"` does
    /// not end in `".mock.invalid"`, so the label requirement is what keeps the
    /// compatibility path reachable. Everything below the namespace is opaque
    /// and per-session, so no test can accidentally claim another's address.
    static func isSessionHost(_ host: String) -> Bool {
        let host = host.lowercased()
        guard host.hasSuffix(hostSuffix) else { return false }
        return host.count > hostSuffix.count
    }

    /// Resolve a session host to its live owner, or `nil`. Case-folded, because
    /// a host is case-insensitive and a caller may have typed it either way.
    static func owner(forHost host: String) -> MockURLProtocolSession? {
        let host = host.lowercased()
        guard isSessionHost(host) else { return nil }
        return owner(for: String(host.dropLast(hostSuffix.count)))
    }

    /// Number of live registered sessions. Used by the contract tests to
    /// prove the registry does not leak.
    static var liveSessionCount: Int {
        registryLock.lock()
        defer { registryLock.unlock() }
        registry = registry.filter { $0.value.value != nil }
        return registry.count
    }

    private static func forget(_ token: String) {
        registryLock.lock()
        defer { registryLock.unlock() }
        registry.removeValue(forKey: token)
    }
}

// MARK: - CU-07 — endpoint-scoped request matching

/// Request matchers for handler-side bookkeeping (CU-07).
///
/// Because ``MockURLProtocol/handler`` is process-global, a counter that
/// increments on *every* request also counts the requests of any suite running
/// in parallel — `#expect(calls == 1)` then fails for a reason that has nothing
/// to do with the code under test (and, worse, `#expect(calls == 0)` can pass or
/// fail by coincidence). Gate the bookkeeping on the endpoint under test:
///
/// ```swift
/// MockURLProtocol.handler = { req in
///     if req.targets("/api/personal-records") { calls += 1 }
///     …
/// }
/// ```
///
/// This is stricter than the unguarded counter, not weaker: the assertion moves
/// from "some request arrived" to "exactly my endpoint was called once", and it
/// holds no matter how Swift Testing schedules the suites.
extension URLRequest {
    /// True when the request's **path** equals `path` exactly. The query string
    /// is ignored, so `/api/measurements?limit=50` matches `/api/measurements`
    /// while `/api/measurements/series` does not.
    func targets(_ path: String) -> Bool {
        url?.path == path
    }

    /// ``targets(_:)`` plus an HTTP-method pin — for suites that count only the
    /// writes (or only the reads) on one endpoint.
    func targets(_ path: String, method: String) -> Bool {
        targets(path) && httpMethod == method
    }

    /// True when the request targets `prefix` itself or any sub-resource below
    /// it (`/api/medications`, `/api/medications/abc`, …) — for endpoints whose
    /// path carries an id or a trailing segment.
    func targets(prefixedBy prefix: String) -> Bool {
        guard let path = url?.path else { return false }
        return path == prefix || path.hasPrefix(prefix + "/")
    }
}
