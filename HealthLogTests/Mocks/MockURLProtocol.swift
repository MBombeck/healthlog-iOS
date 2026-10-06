import Foundation
import ObjectiveC
import Testing

/// Stub `URLProtocol` used across the suite so tests exercise the **real**
/// `APIClient` over a fake transport (per PROJECT_GUIDE.md: "echten APIClient mit
/// Stub-URLSession nutzen, sonst entgehen uns Schema-Drift-Bugs").
///
/// ## Issue #82 — there is no process-global handler any more
///
/// Until C2 the handler was one `static var` slot. Swift Testing runs suites in
/// parallel in-process, so any suite could replace any other suite's closure
/// between install and request: a foreign request moved my counter, and — the
/// half no endpoint filter can close — my request was answered by a foreign
/// closure. The slot is gone. Every handler belongs to one
/// ``MockURLProtocolSession`` and a request reaches it only through that
/// session's own configuration or address.
///
/// ## What a suite writes
///
/// ```swift
/// @Suite("Foo", .mockURLSession)          // one session per test case
/// struct FooTests {
///     @Test func bar() async throws {
///         MockURLProtocol.install { req in … }   // this test's handler
///         let api = APIClient(environment: env, keychain: kc,
///                             sessionConfiguration: .mock())  // this test's transport
///     }
/// }
/// ```
///
/// ``MockURLSessionTrait`` (`.mockURLSession`) opens a fresh session around
/// every test case and binds it to the task through
/// ``MockURLProtocolSession/current``. ``URLSessionConfiguration/mock()`` and
/// ``install(_:)`` both resolve that binding **at the call**, so the
/// configuration a client is built from and the handler a test installs always
/// name the same session, and no other test can reach either.
///
/// ## Failing loudly
///
/// * `.mock()` or `install` outside a `.mockURLSession` scope records an issue
///   and hands out a transport that refuses every request.
/// * A request that reaches a live session with no handler installed fails
///   with `URLError(.resourceUnavailable)`, and the trait records an issue at the
///   end of the test naming each such request. A test that means "the network
///   fails" installs a handler that throws.
/// * A request whose session is gone (the test ended, or the session was
///   invalidated) fails with `URLError(.cancelled)` and is answered by nobody.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data?)

    /// Install (or replace) the handler of the session the current test case
    /// is running in. Requires a `.mockURLSession` scope; outside one it
    /// records an issue and installs nothing.
    static func install(
        _ handler: @escaping Handler,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard let session = MockURLProtocolSession.current else {
            Issue.record(
                "MockURLProtocol.install outside a .mockURLSession scope — add the trait to the suite",
                sourceLocation: sourceLocation
            )
            return
        }
        session.install(handler)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    /// Resolution order:
    ///
    /// 1. **Host** — `https://<token>.mock.invalid`, for suites that address a
    ///    session explicitly through ``MockURLProtocolSession/baseURL``.
    /// 2. **Protocol class** — the per-session subclass the configuration
    ///    carries in `protocolClasses`. This is the channel `.mock()` uses, and
    ///    it survives `APIClient.init`, which rewrites the caller's
    ///    `httpAdditionalHeaders` but copies `protocolClasses` to all three of
    ///    its sessions (and to the upload session).
    ///
    /// Anything else fails closed. There is no fallback.
    override func startLoading() {
        if let host = request.url?.host, MockURLProtocolSession.isSessionHost(host) {
            respondOrFailClosed(owner: MockURLProtocolSession.owner(forHost: host))
            return
        }
        // `object_getClass`, not `type(of:)`: the per-session class is made at
        // runtime and is invisible to Swift's own type metadata.
        if let cls = object_getClass(self), ObjectIdentifier(cls) != ObjectIdentifier(MockURLProtocol.self) {
            respondOrFailClosed(owner: MockURLProtocolSession.owner(forProtocolClass: cls))
            return
        }
        client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
    }

    private func respondOrFailClosed(owner: MockURLProtocolSession?) {
        guard let owner else {
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
            return
        }
        guard let handler = owner.snapshotHandler(noting: request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
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
    /// The current test case's mock transport. Requires a `.mockURLSession`
    /// scope; outside one it records an issue and returns a configuration
    /// whose every request fails closed.
    static func mock(sourceLocation: SourceLocation = #_sourceLocation) -> URLSessionConfiguration {
        if let session = MockURLProtocolSession.current {
            return session.configuration
        }
        Issue.record(
            "URLSessionConfiguration.mock() outside a .mockURLSession scope — add the trait to the suite",
            sourceLocation: sourceLocation
        )
        let refused = MockURLProtocolSession()
        refused.invalidate()
        return refused.configuration
    }
}

// MARK: - The session

/// One test's own handler, reachable only through the configuration or the
/// address this object hands out.
///
/// Contract (asserted in `MockURLProtocolIsolationTests`):
///
/// * Two live sessions keep two distinct handlers, in either install order.
/// * Replacing or invalidating one session cannot alter another's handler.
/// * An invalidated session answers nobody, and nobody answers for it.
///
/// Most suites never name this type: `.mockURLSession` makes one per test case.
/// A suite that needs two transports in one test, or wants to address one
/// explicitly, creates its own and uses ``baseURL`` and ``configuration``.
final class MockURLProtocolSession: @unchecked Sendable {
    /// The session of the test case currently running, bound by
    /// ``MockURLSessionTrait``. Inherited by child tasks and `Task {}`; not by
    /// `Task.detached`.
    @TaskLocal static var current: MockURLProtocolSession?

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
    private nonisolated(unsafe) static var classRegistry: [ObjectIdentifier: String] = [:]

    /// Opaque, per-instance, never reused. Lower-cased so it is a legal DNS label.
    let token: String

    /// This session's own host, `<token>.mock.invalid`.
    let host: String

    /// Base URL for a suite that addresses this session explicitly.
    let baseURL: URL

    /// This session's own `MockURLProtocol` subclass, created at runtime and
    /// never reused, so a configuration carrying it can only ever reach this
    /// session — including after `APIClient` has rewritten its headers.
    let protocolClass: AnyClass

    /// Configuration a test hands to its client. A **fresh** object every time,
    /// because `APIClient.init` mutates the configuration it is given.
    var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [protocolClass]
        return configuration
    }

    private let lock = NSLock()
    private var storedHandler: MockURLProtocol.Handler?
    private var unhandled: [String] = []

    init() {
        let token = UUID().uuidString.lowercased()
        let host = token + Self.hostSuffix
        guard let baseURL = URL(string: "https://" + host) else {
            preconditionFailure("MockURLProtocolSession: could not form a base URL for host \(host)")
        }
        let className = "HLMockURLProtocol_" + token.replacingOccurrences(of: "-", with: "")
        guard let protocolClass = objc_allocateClassPair(MockURLProtocol.self, className, 0) else {
            preconditionFailure("MockURLProtocolSession: could not allocate \(className)")
        }
        objc_registerClassPair(protocolClass)

        self.token = token
        self.host = host
        self.baseURL = baseURL
        self.protocolClass = protocolClass

        Self.registryLock.lock()
        defer { Self.registryLock.unlock() }
        Self.registry[token] = WeakBox(self)
        Self.classRegistry[ObjectIdentifier(protocolClass)] = token
    }

    deinit {
        Self.forget(token)
    }

    /// Install (or replace) this session's handler, atomically.
    func install(_ handler: @escaping MockURLProtocol.Handler) {
        lock.lock()
        defer { lock.unlock() }
        storedHandler = handler
    }

    /// Drop this session's handler and unregister it. A request that arrives
    /// afterwards fails closed and reaches nobody.
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

    /// ``snapshotHandler()``, remembering `request` when no handler is
    /// installed so the owning test can be told about it.
    func snapshotHandler(noting request: URLRequest) -> MockURLProtocol.Handler? {
        lock.lock()
        defer { lock.unlock() }
        if storedHandler == nil {
            unhandled.append("\(request.httpMethod ?? "GET") \(request.url?.path ?? "<no url>")")
        }
        return storedHandler
    }

    /// Requests that reached this live session while it had no handler.
    var unhandledRequests: [String] {
        lock.lock()
        defer { lock.unlock() }
        return unhandled
    }

    /// Resolve a token to its live owner, or `nil`.
    static func owner(for token: String) -> MockURLProtocolSession? {
        registryLock.lock()
        defer { registryLock.unlock() }
        return registry[token]?.value
    }

    /// Resolve a per-session protocol class to its live owner, or `nil`.
    static func owner(forProtocolClass cls: AnyClass) -> MockURLProtocolSession? {
        registryLock.lock()
        defer { registryLock.unlock() }
        guard let token = classRegistry[ObjectIdentifier(cls)] else { return nil }
        return registry[token]?.value
    }

    /// True when `host` carries a **non-empty** label in front of
    /// ``hostSuffix``. The bare `mock.invalid` is not a session host.
    static func isSessionHost(_ host: String) -> Bool {
        let host = host.lowercased()
        guard host.hasSuffix(hostSuffix) else { return false }
        return host.count > hostSuffix.count
    }

    /// Resolve a session host to its live owner, or `nil`. Case-folded.
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

    /// Unregisters the token. The class-to-token entry stays (a class pair is
    /// never disposed), so a late request still resolves to "gone" rather than
    /// to "unknown class".
    private static func forget(_ token: String) {
        registryLock.lock()
        defer { registryLock.unlock() }
        registry.removeValue(forKey: token)
    }
}

// MARK: - The trait

/// Opens a fresh ``MockURLProtocolSession`` around every test case of the
/// suite (recursively) or test it is attached to, and invalidates it when the
/// case ends. Records an issue when a request reached the session while no
/// handler was installed.
struct MockURLSessionTrait: TestTrait, SuiteTrait, TestScoping {
    var isRecursive: Bool {
        true
    }

    func scopeProvider(for _: Test, testCase: Test.Case?) -> Self? {
        testCase == nil ? nil : self
    }

    func provideScope(
        for _: Test,
        testCase _: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        let session = MockURLProtocolSession()
        defer {
            let unhandled = session.unhandledRequests
            session.invalidate()
            if !unhandled.isEmpty {
                Issue.record(
                    "request(s) reached the mock transport with no handler installed: \(unhandled.joined(separator: ", "))"
                )
            }
        }
        try await MockURLProtocolSession.$current.withValue(session) {
            try await function()
        }
    }
}

extension Trait where Self == MockURLSessionTrait {
    /// One ``MockURLProtocolSession`` per test case. See ``MockURLProtocol``.
    static var mockURLSession: Self {
        Self()
    }
}

// MARK: - Endpoint-scoped request matching

/// Request matchers for handler-side bookkeeping. With one session per test a
/// foreign request can no longer reach the handler, so these are about
/// precision within a test (the store under test often fires more than one
/// request), not about isolation any more.
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
