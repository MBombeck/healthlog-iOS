import Foundation

public struct SharingRecoveryEvent: Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
        case accessDenied
        case sessionChanged
    }

    public let reason: Reason
    public let reconciledUser: User?
}

/// Synchronous, lock-backed callback slot so the composition root can install
/// the security-sensitive sharing-recovery bridge before `AppContainer.init`
/// returns. A fire-and-forget actor hop here would leave a launch-time window
/// in which the first selected-record refusal could arrive before the handler.
private final class SharingRecoveryHandlerSlot: @unchecked Sendable {
    typealias Handler = @Sendable (SharingRecoveryEvent) async -> Void

    private let lock = NSLock()
    private var handler: Handler?

    func set(_ handler: @escaping Handler) {
        lock.withLock { self.handler = handler }
    }

    func invoke(_ event: SharingRecoveryEvent) async {
        let handler: Handler? = lock.withLock { self.handler }
        await handler?(event)
    }
}

// The transport actor predates the repository's current split budgets and is
// deliberately kept in one file while auth, retry, pinning, and stream behavior
// remain one state machine. New logic still receives scoped complexity checks.
// swiftlint:disable file_length type_body_length

/// 13-02 — `WebLoginRouteProbing` is inherited rather than restated so the
/// availability gate can ask any client where the login route leads, while the
/// 67 stub conformers inherit the fail-closed default (see
/// `WebLoginRouteProbe.swift`) instead of each implementing a transport they do
/// not own.
public protocol APIClientProtocol: Sendable, WebLoginRouteProbing {
    func send<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> T
    func sendVoid(_ request: APIRequest<EmptyPayload>) async throws
    func download(_ request: APIRequest<Data>) async throws -> (Data, HTTPURLResponse)
    /// **A360 H3 (v0156)** — progressive SSE line stream for the coach turn.
    /// Returns the response body as a sequence of newline-delimited lines that
    /// arrive AS THEY STREAM (not buffered whole), so the caller can parse + render
    /// each `token` frame the instant it lands instead of waiting for the body to
    /// close. Rides the same pinned streaming session as ``download(_:)`` (idle-reset
    /// request timeout + generous resource ceiling), so the inactivity timeout /
    /// cancellation contract is identical — only the body delivery is incremental.
    /// Throws the same mapped ``HLError`` cases as ``download(_:)`` (incl. the 429
    /// rate-limit + the typed assistant-disabled / module-disabled error body)
    /// before the first line; a mid-stream socket failure surfaces as a thrown
    /// error from the returned sequence.
    ///
    /// A default extension implementation buffers via ``download(_:)`` and replays
    /// the lines (so test stubs need not synthesize a live byte stream); the
    /// production ``APIClient`` overrides it with a true `URLSession.bytes(for:)`
    /// stream.
    func streamLines(_ request: APIRequest<Data>) async throws -> AsyncThrowingStream<String, Error>

    /// **Data-Privacy audit H1** — purge any on-disk / in-memory `URLCache` PHI
    /// residue (dashboard / measurements / medications / labs JSON) held by the
    /// client's sessions. Called from the logout / account-deletion cascade so
    /// no cached response body outlives the signed-in user. A default no-op is
    /// provided (below) so test stubs — which own no real `URLSession` — need
    /// not implement it.
    func purgeCachedResponses() async

    /// **Phase 09 / plan 09-02** — send an app-owned file as the whole request
    /// body, in exactly one authenticated attempt.
    ///
    /// This is the only route in the client that never materialises its body.
    /// It is deliberately narrower than ``send(_:)`` rather than a flag on it,
    /// because three of that method's behaviours are wrong for a body this
    /// size and each of them is wrong silently:
    ///
    /// * **No transport retry.** A 5xx or a dropped socket re-sends the whole
    ///   archive. The user re-taps instead; the server's content-hash dedup
    ///   makes an explicit retry resolve to the same job.
    /// * **No authentication recovery.** The 401 → refresh → replay bridge
    ///   would replay the body too. A 401 surfaces.
    /// * **No redirect following.** Foundation replays a body across a
    ///   redirect; see `APIClient+FileUpload.swift`.
    ///
    /// Route, headers, pinning, status handling, envelope decoding and
    /// `URLError` mapping all still come from this client — only the body's
    /// delivery differs.
    ///
    /// The default implementation **throws**. It is not a buffering fallback on
    /// purpose: a stub that quietly read the file into memory would satisfy
    /// every caller while destroying the one property this method exists for,
    /// and it would do so in exactly the test that was supposed to prove the
    /// property held.
    func uploadFile<T: Decodable & Sendable>(_ request: APIFileUploadRequest<T>) async throws -> T
}

public extension APIClientProtocol {
    /// #37 / v1.23.0 — surfaces the decoded server envelope's `data` **and**
    /// `meta` to the caller WITHOUT throwing when `data == nil`. The generic
    /// ``send(_:)`` discards `meta` entirely and treats a `data == null` body
    /// as a fall-through to a raw `T` decode — which is exactly the bug that
    /// hard-blocked MFA-enrolled users (the `MfaRequiredResponse` carries
    /// `data: null` + `meta.mfaRequired`, so `send` never saw the challenge).
    ///
    /// This routes through ``download(_:)`` (which runs the same status-code /
    /// typed-error handling as ``send(_:)`` via the concrete client's
    /// `ensureSuccess`), then decodes the envelope locally so both `data` and
    /// `meta` are returned. A non-nil `error` still throws (a genuine server
    /// rejection). Used by the email/password login branch + the webauthn-2FA
    /// options leg. Implemented as a protocol extension (not a requirement) so
    /// no existing conformer needs to change — it rides the existing
    /// ``download(_:)`` requirement.
    func sendEnvelope<T: Decodable & Sendable>(
        _ request: APIRequest<T>
    ) async throws -> (data: T?, meta: APIEnvelopeMeta?) {
        // Re-project the typed request onto an `APIRequest<Data>` carrying the
        // identical wire fields (incl. `failFast` / `maxRetries` / idempotency
        // key) so `download` issues the byte-for-byte same call.
        let dataRequest = APIRequest<Data>(
            method: request.method,
            path: request.path,
            query: request.query,
            body: request.body,
            extraHeaders: request.extraHeaders,
            idempotencyKey: request.idempotencyKey,
            maxRetries: request.maxRetries,
            failFast: request.failFast,
            streaming: request.streaming,
            allowsAuthenticationRecovery: request.allowsAuthenticationRecovery
        )
        let (data, response) = try await download(dataRequest)
        guard let envelope = try? JSONDecoder.hlDefault.decode(APIEnvelope<T>.self, from: data) else {
            // L2 — preserve the raw-`T` fallback that `send`/`decodePayload` keep:
            // a non-enveloped 200 (a future caller, or an upstream proxy that
            // strips the envelope) still decodes into `(data: T, meta: nil)` rather
            // than failing the whole call. The login/MFA callers always envelope,
            // so this only widens tolerance — it never changes their behaviour.
            if let raw = try? JSONDecoder.hlDefault.decode(T.self, from: data) {
                return (raw, nil)
            }
            throw HLError.decoding("sendEnvelope: could not decode envelope for \(request.path)")
        }
        if let err = envelope.error {
            throw HLError.server(status: response.statusCode, code: envelope.errorCode, message: err)
        }
        return (envelope.data, envelope.meta)
    }

    /// Default progressive-stream shim: buffer the body via ``download(_:)`` and
    /// replay it line-by-line. Not actually incremental (the whole body lands
    /// before the first line is yielded), but it gives every conformer — including
    /// the canned-SSE test stubs — a working `streamLines` without a live socket.
    /// The production ``APIClient`` overrides this with a real
    /// `URLSession.bytes(for:)` stream that IS incremental.
    /// Default no-op for the URLCache PHI purge (audit H1). The production
    /// ``APIClient`` overrides this to clear its three sessions' caches plus
    /// `URLCache.shared`; stub conformers hold no real `URLSession`, so there
    /// is nothing to purge.
    func purgeCachedResponses() async {}

    /// See the requirement's documentation for why this throws instead of
    /// reading the file. A conformer that needs the behaviour implements it;
    /// one that does not, fails loudly the first time somebody routes a
    /// file-backed body through it.
    func uploadFile<T: Decodable & Sendable>(_ request: APIFileUploadRequest<T>) async throws -> T {
        throw HLError.unknown(
            "uploadFile(_:) is not implemented by \(Self.self); a file-backed body has no in-memory fallback by design"
        )
    }

    func streamLines(_ request: APIRequest<Data>) async throws -> AsyncThrowingStream<String, Error> {
        let (data, _) = try await download(request)
        // BH-final-diff H5 — preserve blank lines (event terminators). The
        // production `URLSession.AsyncBytes.lines` emits an empty string for a
        // blank line; the SSE reassembler relies on those terminators to delimit
        // events whose payload spans multiple `data:` lines. Dropping empties here
        // would merge every event into one payload at end-of-stream, so keep them.
        let lines = (String(data: data, encoding: .utf8) ?? "")
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map(String.init)
        return AsyncThrowingStream { continuation in
            for line in lines {
                continuation.yield(line)
            }
            continuation.finish()
        }
    }
}

public actor APIClient: APIClientProtocol {
    public private(set) var environment: AppEnvironment
    public let keychain: KeychainStoring
    public let pinner: CertificatePinner
    /// `internal` (not `private`) so `APIClient+HealthProbe.swift` can run
    /// the captive-portal probe through the same pinned session.
    let session: URLSession
    /// #96 — dedicated FAIL-FAST session for interactive auth legs (passkey
    /// login-options/verify, email login, register, refresh). The default
    /// `session` waits for connectivity + a 60 s resource timeout — right for
    /// the outbox, wrong for the login door (a no-network attempt parks on a
    /// dead spinner). This flips `waitsForConnectivity = false` (→ immediate
    /// `HLError.offline`) + a short request timeout, rides the SAME pin
    /// contract, and inherits the caller's `protocolClasses` (so `MockURLProtocol`
    /// still intercepts). Selected per-request via `APIRequest.failFast`; every
    /// non-auth request keeps the patient `session` untouched.
    let authSession: URLSession
    /// W-COACH-SSE — dedicated STREAMING session for the server-Coach SSE turn
    /// (`POST /api/insights/chat`). Applies ``CoachStreamTimeoutPolicy`` (idle-reset
    /// request timeout + generous resource ceiling) instead of the patient
    /// session's 20 s/60 s wall, which prematurely cut off a slow LLM turn. Same
    /// pin contract + headers + protocol classes as the patient session.
    let streamingSession: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private let onUnauthorized: (@Sendable () async -> Void)?
    /// F-1 — notification closure invoked when a route responds
    /// with `403 + errorCode: "assistant.disabled.<surface>"`.
    /// AppContainer wires this to mirror the disabled flag into
    /// `FeatureFlagsStore` so the next render tick surfaces the
    /// placeholder without waiting for the next foreground refresh
    /// of `/api/feature-flags`. The closure runs fire-and-forget
    /// (the surfaced `HLError.assistantDisabled(_:)` is the
    /// authoritative signal; the store mirror is a convenience).
    private var onAssistantDisabled: (@Sendable (FeatureFlag) async -> Void)?
    /// #30 / v1.18.0 — fire-and-forget mirror invoked when a route 403's with
    /// `meta.errorCode: "module.disabled"` + `meta.module: "<key>"`. AppContainer
    /// wires this to flip the matching key OFF in ``ModuleGate`` so the surface
    /// disappears on the same tick the route rejects, without waiting on the
    /// next `/api/auth/me` refresh. The closure runs fire-and-forget (the
    /// surfaced `HLError.moduleDisabled(_:)` is the authoritative signal; the
    /// gate mirror is a convenience). The argument is the `meta.module` key.
    private var onModuleDisabled: (@Sendable (String) async -> Void)?
    /// Optional refresh-attempt closure (siehe `05-auth-flows.md §3.1`). Wenn
    /// gesetzt, versucht APIClient bei jedem 401 genau **einen** Refresh und
    /// gated `onUnauthorized` am dreiwertigen ``RefreshOutcome``:
    /// `.refreshed` → Original-Request mit frischem Bearer wiederholen,
    /// `.authFailure` → `onUnauthorized` (Logout-Cascade),
    /// `.transient` → **kein** Logout (Session überlebt, der Request schlägt
    /// dieses eine Mal fehl). Letzteres ist die 401-Cascade-Schutzschicht:
    /// ein transienter Refresh-Fehler darf nicht in einen Logout-Storm kippen.
    private var refreshHandler: (@Sendable () async -> RefreshOutcome)?
    private var selectedAccount: AccountAccessEntry?
    private nonisolated let sharingRecoveryHandler = SharingRecoveryHandlerSlot()

    public init(
        environment: AppEnvironment,
        keychain: KeychainStoring,
        pinner: CertificatePinner = CertificatePinner(),
        sessionConfiguration: URLSessionConfiguration = .default,
        // W-COACH-SSE — the timeout policy for the coach SSE streaming session.
        // Production uses the generous default (`.coachStream`); a test can inject
        // a short policy to exercise the inactivity-stall path without a real
        // 120 s wait. Non-streaming paths are unaffected by this value.
        coachStreamPolicy: CoachStreamTimeoutPolicy = .coachStream,
        onUnauthorized: (@Sendable () async -> Void)? = nil,
        refreshHandler: (@Sendable () async -> RefreshOutcome)? = nil
    ) {
        self.environment = environment
        self.keychain = keychain
        self.pinner = pinner
        self.onUnauthorized = onUnauthorized
        self.refreshHandler = refreshHandler

        let config = sessionConfiguration
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = true
        config.httpAdditionalHeaders = [
            "User-Agent": "HealthLog-iOS/\(environment.appVersion) (\(environment.bundleID))",
            "X-Client-Type": "native" // Signal: Login soll Bearer-Token zurückgeben.
        ]

        let delegate = PinningDelegate(pinner: pinner)
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)

        // #96 — fail-fast auth session: same pinning/headers/protocol-classes,
        // but never waits for connectivity + short timeout. Built from a fresh
        // sibling config (inheriting `protocolClasses` so `MockURLProtocol`
        // still intercepts) so these knobs can't leak into the outbox config.
        let authConfig = URLSessionConfiguration.default
        authConfig.protocolClasses = config.protocolClasses
        authConfig.httpAdditionalHeaders = config.httpAdditionalHeaders
        authConfig.waitsForConnectivity = false
        authConfig.timeoutIntervalForRequest = 15
        authConfig.timeoutIntervalForResource = 20
        let authDelegate = PinningDelegate(pinner: pinner)
        authSession = URLSession(configuration: authConfig, delegate: authDelegate, delegateQueue: nil)

        // W-COACH-SSE — streaming session for the server-Coach SSE turn. Same
        // pin/headers/protocol-classes as the patient session, but timeouts come
        // from `coachStreamPolicy`: request = inactivity timeout (resets on every
        // received chunk, so an actively streaming reply never trips it), resource
        // = generous overall ceiling (a long-but-valid stream isn't cut at 60 s).
        // `waitsForConnectivity = false` so a no-network coach turn fails fast.
        let streamingConfig = URLSessionConfiguration.default
        streamingConfig.protocolClasses = config.protocolClasses
        streamingConfig.httpAdditionalHeaders = config.httpAdditionalHeaders
        streamingConfig.timeoutIntervalForRequest = coachStreamPolicy.inactivityTimeout
        streamingConfig.timeoutIntervalForResource = coachStreamPolicy.overallCeiling
        streamingConfig.waitsForConnectivity = false
        let streamingDelegate = PinningDelegate(pinner: pinner)
        streamingSession = URLSession(configuration: streamingConfig, delegate: streamingDelegate, delegateQueue: nil)

        // Single source of truth: `JSONDecoder.hlDefault` — siehe
        // `Util/JSONDecoder+HLDefault.swift`. Akzeptiert ISO8601 (fractional +
        // plain) plus YYYY-MM-DD Day-Keys. camelCase belassen.
        decoder = .hlDefault

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
    }

    // MARK: - Public API

    public func send<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> T {
        let started = ContinuousClock.now
        do {
            let (data, response) = try await execute(request)
            try ensureSuccess(response: response, data: data)
            return try decodePayload(T.self, data: data, status: response.statusCode)
        } catch {
            EndpointFailureDiagnostics.record(error, method: request.method, path: request.path, since: started)
            throw error
        }
    }

    /// `internal`, not `private`, so `APIClient+FileUpload.swift` decodes the
    /// one-shot upload's response through this exact envelope logic instead of
    /// growing a second one (Swift's `private` is file-scoped).
    func decodePayload<T: Decodable & Sendable>(_ type: T.Type, data: Data, status: Int) throws -> T {
        // Server-Envelope ist Pflicht (`{ data, error: string | null }`). Erst envelope decoden,
        // dann data extrahieren. Fallback nur für Endpoints die historisch ohne Envelope antworten.
        if let envelope = try? decoder.decode(APIEnvelope<T>.self, from: data) {
            if let err = envelope.error {
                // Preserve the typed error-code discriminator (was dropped as `nil`
                // here, so generic `send()` callers couldn't distinguish e.g.
                // `documents.inbound.providerUnsupported` from a plain 422). The code
                // lives in `meta.errorCode` (module-gate + document AI shapes); the
                // top-level `errorCode` carries the older assistant-disabled shape.
                throw HLError.server(
                    status: status,
                    code: envelope.meta?.errorCode ?? envelope.errorCode,
                    message: err
                )
            }
            if let payload = envelope.data {
                return payload
            }
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw HLError.decoding(String(describing: error))
        }
    }

    public func sendVoid(_ request: APIRequest<EmptyPayload>) async throws {
        let started = ContinuousClock.now
        do {
            let (data, response) = try await execute(request)
            try ensureSuccess(response: response, data: data)
        } catch {
            EndpointFailureDiagnostics.record(error, method: request.method, path: request.path, since: started)
            throw error
        }
    }

    public func download(_ request: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
        let started = ContinuousClock.now
        do {
            let (data, response) = try await execute(request)
            try ensureSuccess(response: response, data: data)
            return (data, response)
        } catch {
            EndpointFailureDiagnostics.record(error, method: request.method, path: request.path, since: started)
            throw error
        }
    }

    /// **Data-Privacy audit H1** — belt-and-braces PHI residue sweep on logout /
    /// account deletion. The three authenticated sessions run on
    /// `URLSessionConfiguration.default`, whose on-disk `URLCache` can persist
    /// cacheable GET response bodies (dashboard summary, measurements,
    /// medications, labs, cycle …) in `Library/Caches/<bundle>/Cache.db` —
    /// surviving both logout AND account deletion, at a weaker file-protection
    /// class than the app's own export discipline. The SWR layer owns the real
    /// caching; this URL cache is pure liability. Purge every session's cache
    /// (patient + fail-fast auth + coach streaming) plus the process-wide
    /// `URLCache.shared` so no PHI JSON outlives the signed-in user. Idempotent
    /// and cheap (logout is rare); called from `performFullLocalLogout`.
    public func purgeCachedResponses() {
        for cache in [
            session.configuration.urlCache,
            authSession.configuration.urlCache,
            streamingSession.configuration.urlCache
        ] {
            cache?.removeAllCachedResponses()
        }
        URLCache.shared.removeAllCachedResponses()
    }

    /// **A360 H3 (v0156)** — progressive SSE line stream (see protocol doc).
    /// Single-shot (no retry loop): the coach request already carries
    /// `maxRetries: 0`, and a streamed reply must not be silently re-issued mid
    /// way. Resolves the transport exactly like ``execute(_:)`` (streaming session
    /// for the coach turn) and maps the status line up front so a 429 / 5xx / 401 /
    /// 403 throws the same typed ``HLError`` the buffered path would, BEFORE the
    /// caller starts consuming tokens. The returned line stream drives each chunk
    /// as it lands; `URLSession.bytes(for:)` resets the session's inactivity timer
    /// per chunk — identical idle-reset behaviour to ``download(_:)``.
    public func streamLines(_ request: APIRequest<Data>) async throws -> AsyncThrowingStream<String, Error> {
        let urlRequest = try buildURLRequest(request)
        let transport: URLSession = if request.failFast {
            authSession
        } else if request.streaming {
            streamingSession
        } else {
            session
        }

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await transport.bytes(for: urlRequest)
        } catch let urlError as URLError {
            throw mapURLError(urlError)
        }
        guard let http = response as? HTTPURLResponse else {
            throw HLError.network(.other("non-HTTP response"))
        }
        if http.statusCode == 401 {
            // Mirror the buffered path's 401 surfacing. The coach turn never
            // refreshes mid-stream (one-shot); the store surfaces a sign-in error.
            throw HLError.unauthorized
        }
        if http.statusCode == 429 {
            let retryAfter = parseRateLimitReset(headers: http) ?? Self.parseRetryAfterHeader(http)
            throw HLError.rateLimited(retryAfter: retryAfter)
        }
        // For a non-2xx that carries an error body (e.g. a 403 assistant-disabled
        // envelope), drain the bytes so `ensureSuccess` can decode the typed error
        // — the error body is small, so buffering it is acceptable.
        if !(200 ... 299).contains(http.statusCode) {
            var collected = Data()
            for try await byte in bytes {
                collected.append(byte)
            }
            try ensureSuccess(response: http, data: collected)
            throw HLError.server(status: http.statusCode, code: nil, message: "")
        }
        // Adapt the live `AsyncBytes.lines` sequence onto the protocol's
        // `AsyncThrowingStream<String, Error>` so the body is delivered line by
        // line as it streams. Cancelling the consuming task cancels this task,
        // which tears the socket down (cooperative `URLSession` cancellation) —
        // the store's `cancelInFlightTurn()` path, unchanged.
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Internals

    /// Optional Setter — wird vom AppContainer nach Bootstrap genutzt um den
    /// `RefreshCoordinator` einzukoppeln (Composition-Root sieht den Coordinator
    /// erst NACH dem APIClient-Init). Idempotent.
    public func setRefreshHandler(_ handler: @escaping @Sendable () async -> RefreshOutcome) {
        refreshHandler = handler
    }

    /// F-1 — composition-root setter for the assistant-disabled
    /// mirror closure. Idempotent. AppContainer wires this so the
    /// store learns about operator-disabled surfaces in the same
    /// tick the route 403's, without a follow-up
    /// `/api/feature-flags` round-trip.
    public func setAssistantDisabledHandler(_ handler: @escaping @Sendable (FeatureFlag) async -> Void) {
        onAssistantDisabled = handler
    }

    /// #30 — composition-root setter for the module-disabled mirror closure.
    /// Idempotent. AppContainer wires this so ``ModuleGate`` learns about a
    /// disabled module in the same tick the route 403's, without a follow-up
    /// `/api/auth/me` round-trip.
    public func setModuleDisabledHandler(_ handler: @escaping @Sendable (String) async -> Void) {
        onModuleDisabled = handler
    }

    /// Installs the narrow Bearer selector used by explicitly admitted record
    /// routes. There is deliberately no UI here; callers may adopt only an
    /// already-decoded, server-resolved entry from `/api/auth/me`.
    public func selectAccount(_ account: AccountAccessEntry?) {
        guard let account else {
            selectedAccount = nil
            return
        }
        guard !account.accountId.isEmpty,
              account.level != .unknown,
              account.recordKind != .unknown,
              account.sections != .unavailable else
        {
            selectedAccount = nil
            return
        }
        selectedAccount = account
    }

    public func selectedAccountID() -> String? {
        selectedAccount?.accountId
    }

    public nonisolated func setSharingRecoveryHandler(
        _ handler: @escaping @Sendable (SharingRecoveryEvent) async -> Void
    ) {
        sharingRecoveryHandler.set(handler)
    }

    /// Live-swap the runtime `AppEnvironment`. Called by `AppContainer.reloadEnvironment`
    /// during onboarding after the user picks a custom server URL — the next request
    /// is built against the new `baseURL` without restarting the app or rebuilding
    /// the URLSession (the session config is bundle-ID + version + UA only; none
    /// of those change when the user just retargets a different host).
    ///
    /// **Safe to call only before the first authenticated request fires** —
    /// switching mid-session would invalidate Cert-Pin SPKI hashes (those are
    /// bundle-pinned to the managed host). v0.4.1 onboarding only calls
    /// this BEFORE login, so Cert-Pinning is not affected for the managed cloud;
    /// self-hosted instances run against a Self-Signed-Cert workflow that we
    /// document separately.
    ///
    /// **Runtime guard (M-2, v0.6.2):** if an auth token is already in the
    /// Keychain when this is called, the swap is rejected (Debug:
    /// `assertionFailure` to surface the bug loudly during development;
    /// Release: log + return early so the live session continues against
    /// the previous environment instead of silently breaking the SPKI-pin
    /// contract). The current onboarding call-site fires BEFORE login so
    /// the guard never triggers in production; a future "switch server"
    /// affordance in Settings would be caught here before it can corrupt
    /// the trust chain.
    ///
    /// **Ausnahme: die Ersteinrichtung (R1).** Siehe die Begründung am Wächter.
    public func setEnvironment(_ newEnvironment: AppEnvironment) {
        // R1 — Ersteinrichtung ist kein Hostwechsel. Ohne bisherige Adresse
        // gibt es keinen vorherigen Host, dessen Pins verletzt werden könnten,
        // und keinen Transport, auf dem der Token je benutzt wurde. Diesen Fall
        // zu verweigern hat den Betreiber ausgesperrt: das Onboarding schrieb
        // die Adresse in den Schlüsselbund, der APIClient behielt `nil`, und
        // jeder Anmeldeversuch warf danach `serverNotConfigured` — beliebig oft.
        let isInitialConfiguration = environment.baseURL == nil
        if !isInitialConfiguration, keychain.getString(forKey: KeychainKey.authToken) != nil {
            HLLog.security.error(
                "setEnvironment refused: auth-token present — environment swap would break Cert-Pin SPKI contract."
            )
            // `_HLAPIClientTestHook.suppressAssertion` lets the unit test exercise
            // the Release branch without aborting the Debug test runner. Production
            // code paths never flip this flag.
            if !_HLAPIClientTestHook.suppressAssertion {
                assertionFailure(
                    "APIClient.setEnvironment called after authentication — would invalidate Cert-Pin SPKI hashes."
                )
            }
            return
        }
        environment = newEnvironment
    }

    // Ordered transport state machine: session choice, one-shot auth recovery,
    // rate limits, server retries, URL errors, and typed retry delays.
    // swiftlint:disable:next cyclomatic_complexity
    private func execute(_ request: APIRequest<some Any>) async throws -> (Data, HTTPURLResponse) {
        var urlRequest = try buildURLRequest(request)
        var attempt = 0
        let maxRetries = request.maxRetries
        var attemptedRefresh = false
        var attemptedSharingReconcile = false
        // #96 — interactive auth legs ride the fail-fast session (no
        // wait-for-connectivity, short timeout). W-COACH-SSE — the coach SSE
        // turn rides the streaming session (idle-reset request timeout + generous
        // resource ceiling). Everything else keeps the patient outbox session.
        // `failFast` is checked first so an auth leg can never be misrouted onto
        // the streaming budget (the two are mutually exclusive in practice).
        let transport: URLSession = if request.failFast {
            authSession
        } else if request.streaming {
            streamingSession
        } else {
            session
        }

        while true {
            attempt += 1
            do {
                let (data, response) = try await transport.data(for: urlRequest)
                guard let http = response as? HTTPURLResponse else {
                    throw HLError.network(.other("non-HTTP response"))
                }

                if http.statusCode == 401 {
                    // #37/H1 — the TOTP/recovery MFA verify leg must DISTINGUISH a
                    // wrong code (retry) from a dead ticket (eject); the server
                    // returns 401 for BOTH, with only the body message differing.
                    // For this one path surface the 401 body (a typed `.server(401,
                    // …)` via `ensureSuccess` downstream) instead of collapsing to a
                    // bare `.unauthorized`, so `AuthStore.handleMfaVerifyFailure` can
                    // tell them apart. Scoped to exactly this path — every other 401
                    // (incl. login wrong-password + webauthn verify) keeps the
                    // established collapse-to-`.unauthorized` behaviour, and the
                    // refresh→logout bridge is intentionally bypassed here (the ticket,
                    // not a Bearer, is the credential — there is nothing to refresh).
                    if Self.preserves401Body(path: request.path) {
                        return (data, http)
                    }
                    if await shouldRetryAfterUnauthorized(
                        request: request,
                        attemptedRefresh: &attemptedRefresh
                    ) {
                        urlRequest = try buildURLRequest(request)
                        attempt = 0
                        continue
                    }
                    throw HLError.unauthorized
                }

                // 14-06 — gated on the only two status codes that can consume the
                // result. This is behaviour-preserving BY CONSTRUCTION, not by
                // argument: both arms below already require `403` and `409`
                // respectively, so for every other status the decode was computed
                // and discarded. It ran on EVERY response — including image
                // bodies from the avatar download, on the actor every request
                // shares.
                //
                // Measured, so the claim is sized honestly rather than inflated:
                // the discarded decode costs ~3 µs on a small JSON body and
                // ~104 µs on a large list body, and only ~0.6 µs on 220 KB of
                // JPEG or PNG (a JSON parser rejects image bytes on the first
                // byte — it does not walk the buffer). So this removes real but
                // small serial work from a shared actor. It is worth doing
                // because it is provably safe, not because it is a cure.
                if http.statusCode == 403 || http.statusCode == 409,
                   let sharingCode = sharingErrorCode(in: data)
                {
                    if http.statusCode == 403,
                       sharingCode == "sharing.access.denied",
                       selectedAccount != nil
                    {
                        await recoverSharingContext(reason: .accessDenied, clearSelection: true)
                        return (data, http)
                    }
                    if http.statusCode == 409,
                       sharingCode == "sharing.session.changed",
                       selectedAccount != nil,
                       !attemptedSharingReconcile
                    {
                        attemptedSharingReconcile = true
                        let selectedID = selectedAccount?.accountId
                        await recoverSharingContext(reason: .sessionChanged, clearSelection: false)
                        guard selectedAccount?.accountId == selectedID else {
                            return (data, http)
                        }
                        urlRequest = try buildURLRequest(request)
                        attempt = 0
                        continue
                    }
                }

                if http.statusCode == 429 {
                    // Server schickt `X-RateLimit-Reset` als ISO-8601-Timestamp
                    // (siehe `17-error-handling.md §4.2`). Früher hat iOS
                    // `Retry-After` (Sekunden) gelesen — gibt es nicht, also
                    // war `retryAfter` immer nil und der retry-Loop hat den
                    // gerate-limiteten Endpoint mit Exponential-Backoff
                    // gehammert (W2a-A2 Audit §6 + §7). Wir lesen jetzt
                    // primär `X-RateLimit-Reset` und werfen mit der
                    // berechneten Delta — der retry-Loop unten respektiert
                    // genau diesen Wert (kein Backoff-Doppel).
                    let retryAfter = parseRateLimitReset(headers: http) ?? Self.parseRetryAfterHeader(http)
                    throw HLError.rateLimited(retryAfter: retryAfter)
                }

                if (500 ... 599).contains(http.statusCode), attempt <= maxRetries {
                    try await Task.sleep(nanoseconds: backoffDelay(attempt: attempt))
                    continue
                }

                return (data, http)
            } catch let urlError as URLError {
                let mapped = mapURLError(urlError)
                if mapped.isRetriable, attempt <= maxRetries {
                    try await Task.sleep(nanoseconds: backoffDelay(attempt: attempt))
                    continue
                }
                throw mapped
            } catch let err as HLError {
                if err.isRetriable, attempt <= maxRetries {
                    try await Task.sleep(nanoseconds: rateLimitOrBackoffDelay(error: err, attempt: attempt))
                    continue
                }
                throw err
            }
        }
    }

    private func sharingErrorCode(in data: Data) -> String? {
        let envelope = try? decoder.decode(APIEnvelope<EmptyPayload>.self, from: data)
        return envelope?.meta?.errorCode ?? envelope?.errorCode
    }

    private func recoverSharingContext(
        reason: SharingRecoveryEvent.Reason,
        clearSelection: Bool
    ) async {
        if clearSelection {
            selectedAccount = nil
        }
        await purgeCachedResponses()
        let request: APIRequest<User> = .get("/api/auth/me")
        let user = try? await send(request)
        await sharingRecoveryHandler.invoke(SharingRecoveryEvent(reason: reason, reconciledUser: user))
    }

    private func shouldRetryAfterUnauthorized(
        request: APIRequest<some Any>,
        attemptedRefresh: inout Bool
    ) async -> Bool {
        guard request.allowsAuthenticationRecovery else { return false }
        return await handleUnauthorizedAndShouldRetry(
            request: request,
            attemptedRefresh: &attemptedRefresh
        )
    }

    /// Coordinated 401-handling — the single path through which an `Unauthorized`
    /// response is resolved (extracted from `execute` to keep that loop's
    /// cyclomatic complexity bounded).
    ///
    /// One-shot Refresh-Try (siehe `17-error-handling.md §9` Algorithmus).
    /// Auth-Endpoints selbst (login/refresh/logout) überspringen den Refresh-Pfad
    /// — sie haben kein Refresh-Token-Konzept und der Server hat ihre 401s schon
    /// mit `Invalid credentials` etc. erklärt.
    ///
    /// **401-Cascade-Gating (v0.10.0):** der Refresh liefert ein dreiwertiges
    /// ``RefreshOutcome``. Nur ``RefreshOutcome/authFailure`` (revoked/reuse/
    /// invalid → toter Token) triggert `onUnauthorized` (Logout-Cascade).
    /// ``RefreshOutcome/transient`` (Netzwerk/5xx/Rate-Limit beim Refresh selbst)
    /// lässt die Session unangetastet — sonst kippt ein vorübergehender Hiccup in
    /// einen Spurious-Logout-Storm. Single-Flight im `RefreshCoordinator` dedupt
    /// parallele 401s auf EINEN Refresh-Versuch.
    ///
    /// - Returns: `true` iff the original request should be retried (a fresh
    ///   bearer was obtained). `false` means the caller throws `.unauthorized`;
    ///   `onUnauthorized` has already fired on the genuine-auth-failure path.
    /// - Parameter attemptedRefresh: in/out flag so a single request never
    ///   refreshes more than once (a second 401 gives up).
    private func handleUnauthorizedAndShouldRetry(
        request: APIRequest<some Any>,
        attemptedRefresh: inout Bool
    ) async -> Bool {
        HLLog.api.warning("401 Unauthorized for \(request.path, privacy: .private)")
        if !attemptedRefresh,
           !Self.isAuthExempt(path: request.path),
           let refreshHandler
        {
            attemptedRefresh = true
            switch await refreshHandler() {
            case .refreshed:
                // Frischen Bearer-Token einbauen und wiederholen.
                return true
            case .transient:
                // Refresh konnte transient nicht abschließen — NICHT ausloggen.
                // Der Request schlägt dieses eine Mal fehl; der nächste Versuch
                // refresht erneut.
                return false
            case .authFailure:
                // Toter Refresh-Token → echter Logout (onUnauthorized unten).
                break
            }
        }
        if let onUnauthorized {
            await onUnauthorized()
        }
        return false
    }

    /// Rate-limit-aware Delay-Picker. Bei `.rateLimited(retryAfter:)` wird
    /// genau der vom Server diktierte Wert (+ kleiner Jitter) verwendet —
    /// kein zusätzliches Exponential-Backoff. Sonst Standard-Backoff.
    private func rateLimitOrBackoffDelay(error: HLError, attempt: Int) -> UInt64 {
        if case let .rateLimited(retryAfter) = error, let retryAfter, retryAfter > 0 {
            let jitter = Double.random(in: 0 ... 0.5)
            let seconds = retryAfter + jitter
            return UInt64(min(seconds, 60.0) * 1_000_000_000)
        }
        return backoffDelay(attempt: attempt)
    }

    /// Parses the server's `X-RateLimit-Reset` header (ISO-8601 timestamp) and
    /// returns the seconds-from-now-until-reset interval, plus zero floor.
    private nonisolated func parseRateLimitReset(headers: HTTPURLResponse) -> TimeInterval? {
        guard let raw = headers.value(forHTTPHeaderField: "X-RateLimit-Reset") else { return nil }
        let date = ISO8601DateFormatter.fractional.date(from: raw)
            ?? ISO8601DateFormatter.plain.date(from: raw)
        guard let reset = date else { return nil }
        return max(0, reset.timeIntervalSinceNow)
    }

    /// Fallback: parse `Retry-After` (HTTP/1.1 seconds form) for upstream
    /// proxies that strip our header. Server itself never sends this.
    private nonisolated static func parseRetryAfterHeader(_ headers: HTTPURLResponse) -> TimeInterval? {
        guard let raw = headers.value(forHTTPHeaderField: "Retry-After") else { return nil }
        return TimeInterval(raw)
    }

    /// Auth-Endpoints sind selbst die Quelle des Refresh-Token-Flows — sie
    /// dürfen den 401→refresh-Bridge NICHT triggern, sonst gehen wir in einen
    /// Endlos-Refresh-Loop wenn der Server schon "Invalid credentials" sagt.
    private nonisolated static func isAuthExempt(path: String) -> Bool {
        path.hasPrefix("/api/auth/login")
            || path.hasPrefix("/api/auth/refresh")
            || path.hasPrefix("/api/auth/logout")
            || path.hasPrefix("/api/auth/passkey/")
            || path.hasPrefix("/api/auth/register")
            // #37 — the second-factor verify legs are pre-auth (the ticket, not
            // a Bearer, is the credential). A wrong/expired code returns 401/422
            // that must surface verbatim, NOT trigger the refresh→logout bridge.
            || path.hasPrefix("/api/auth/mfa")
            // #49 — the native OIDC token exchange is pre-auth (the one-time
            // handoff code + PKCE verifier are the credential, there is no Bearer
            // yet). Its single generic 401 (invalid/expired/used/PKCE-mismatch) is
            // a login failure that must surface, NOT trigger the refresh→logout
            // bridge.
            || path.hasPrefix("/api/auth/oidc")
    }

    /// The 401-body-preserving paths: a 401 here surfaces its typed
    /// `.server(401, code, message)` (via `ensureSuccess`) instead of collapsing
    /// to a bare `.unauthorized`, and the refresh→logout bridge is bypassed (there
    /// is nothing a token-refresh can fix on these legs).
    ///
    /// - `/api/auth/mfa/verify` (#37/H1) — the server returns 401 for BOTH a wrong
    ///   TOTP/recovery code ("Invalid code" → retry) and a dead ticket ("Invalid or
    ///   expired challenge" → eject); only the body distinguishes them. WebAuthn
    ///   verify (`/api/auth/mfa/webauthn/verify`) is deliberately NOT matched — a
    ///   rejected assertion keeps the bare-401 behaviour.
    /// - `/api/settings/account` (#37/#38 — v1.25 step-up) — an MFA-enrolled account
    ///   delete is gated behind a fresh-MFA step-up that is COOKIE-ONLY, so a native
    ///   Bearer session can never satisfy it and gets `401 auth.stepup.required`.
    ///   That is NOT a dead session (a refresh would succeed then 401 again, reading
    ///   as a bogus "please re-login"), so the body must survive for the delete flow
    ///   to detect it and route the user to the web deletion page. This path is
    ///   ONLY ever the account-delete DELETE, so preserving all its 401s is safe.
    /// `internal` — the one-shot file-upload path in `APIClient+FileUpload.swift`
    /// consults the same allowlist, so the two 401 policies cannot drift.
    nonisolated static func preserves401Body(path: String) -> Bool {
        path.hasPrefix("/api/auth/mfa/verify")
            || path == "/api/settings/account"
            // Parity item 2.5 — `DELETE /api/settings/data` sits behind the same
            // `requireFreshMfaIfEnrolled` gate as the account delete above and
            // answers `401 auth.stepup.required` for an MFA-enrolled account.
            // Without this entry the 401 would be consumed by the refresh-then-
            // logout cascade and `ResetDataScreen` could never distinguish
            // "step up on the web" from "your session died", showing a
            // misleading re-login prompt for a perfectly valid session.
            || path == "/api/settings/data"
            // #57 — native 2FA: `step-up`'s generic-401 factor re-proof and the
            // `…/me/mfa/*` `401 auth.stepup.required` must surface verbatim, not
            // collapse to `.unauthorized` + the refresh→logout bridge (the token
            // is valid; the store branches on the body to re-prompt the ceremony).
            || path.hasPrefix("/api/auth/step-up")
            || path.hasPrefix("/api/auth/me/mfa")
    }

    // Existing URL construction covers encoded paths, query items, auth, device
    // headers, idempotency, and body types as one ordered security boundary.
    // `internal` — see `decodePayload`. The file-upload route builds its request
    // here so that boundary stays one place rather than two.
    // swiftlint:disable:next cyclomatic_complexity
    func buildURLRequest(_ request: APIRequest<some Any>) throws -> URLRequest {
        // `request.path` is an absolute, already-valid path whose opaque segments
        // are percent-encoded by the caller where needed. Append it via
        // `percentEncodedPath` so that encoding is PRESERVED — `URL.appendingPathComponent`
        // is a FILE-path API that re-encodes any `%`, turning a caller's `%2F` into
        // `%252F` (double-encoding opaque keys so the server can't match the resource).
        // Kein Server eingerichtet → typisierter Einrichtungsfehler, bevor
        // überhaupt ein Transport anläuft. Die App bringt keinen Default-Host
        // mit; ein erfundener Platzhalter würde daraus nur einen
        // Netzwerkfehler an der falschen Stelle machen.
        guard let configuredBaseURL = environment.baseURL else {
            throw HLError.serverNotConfigured
        }
        guard var components = URLComponents(url: configuredBaseURL, resolvingAgainstBaseURL: false) else {
            throw HLError.unknown("Could not build URL for \(request.path)")
        }
        // `request.path` always begins with "/"; drop any trailing slash a
        // self-hosted `baseURL` may carry so the join never doubles it.
        var basePath = components.percentEncodedPath
        if basePath.hasSuffix("/") { basePath.removeLast() }
        components.percentEncodedPath = basePath + request.path
        if !request.query.isEmpty {
            components.queryItems = request.query.map(URLQueryItem.init(name:value:))
        }
        guard let finalURL = components.url else {
            throw HLError.unknown("Could not build URL for \(request.path)")
        }

        var req = URLRequest(url: finalURL)
        req.httpMethod = request.method.rawValue
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        if let body = request.body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        if let token = keychain.getString(forKey: KeychainKey.authToken) {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        // `X-Device-Id` ist Pflicht auf Auth-Flows (siehe `05-auth-flows.md §9`)
        // und ein Audit-Breadcrumb auf allen anderen Requests. Wir senden ihn
        // global — billiger als pro Endpoint zu unterscheiden, und der Server
        // ignoriert das Feld auf Read-Routen einfach.
        if let device = try? keychain.deviceID() {
            req.setValue(device, forHTTPHeaderField: "X-Device-Id")
        }

        if let id = environment.cfAccessClientID {
            req.setValue(id, forHTTPHeaderField: "cf-access-client-id")
        }
        if let token = environment.cfAccessClientToken {
            req.setValue(token, forHTTPHeaderField: "cf-access-client-token")
        }

        // An EMPTY key means "this route does not evaluate one"
        // (``IdempotencyKey/notSent``) — omit the header entirely rather than
        // send a blank one, which would assert an idempotency contract that
        // does not exist on that route.
        if request.method.requiresIdempotency, !request.idempotencyKey.headerValue.isEmpty {
            req.setValue(request.idempotencyKey.headerValue, forHTTPHeaderField: "Idempotency-Key")
        }

        for (key, value) in request.extraHeaders {
            req.setValue(value, forHTTPHeaderField: key)
        }

        try applySelectedAccount(to: &req, request: request)

        if request.method == .get { req.cachePolicy = .reloadRevalidatingCacheData }

        #if DEBUG
            // HLLogger redacts intern: URL → scheme://host, Bearer/Token/UUID → Marker.
            // DEBUG-only request trace; the sanitizer reduces the URL to scheme://host
            // before it reaches OSLog, so no path/query can surface in sysdiagnose.
            // swiftlint:disable:next hllog_public_privacy_interpolation
            HLLog.api.debug("→ \(req.httpMethod ?? "?", privacy: .public) \(finalURL.absoluteString, privacy: .public)")
        #endif

        return req
    }

    private func applySelectedAccount(
        to urlRequest: inout URLRequest,
        request: APIRequest<some Any>
    ) throws {
        let header = "X-HealthLog-Account"
        guard !request.extraHeaders.keys.contains(where: { $0.caseInsensitiveCompare(header) == .orderedSame }) else {
            throw HLError.server(
                status: 403,
                code: "sharing.client.selector_not_centralized",
                message: "Account selector must be applied by APIClient"
            )
        }
        guard let selectedAccount else { return }
        switch Self.recordRoute(for: request.path) {
        case .actor:
            return
        case let .section(section):
            guard selectedAccount.allows(section: section, write: request.method != .get) else {
                throw Self.localSharingDenial()
            }
        case .wholeRecord:
            guard selectedAccount.allowsWholeRecord(write: request.method != .get) else {
                throw Self.localSharingDenial()
            }
        case .unclassified:
            throw Self.localSharingDenial()
        }
        urlRequest.setValue(selectedAccount.accountId, forHTTPHeaderField: header)
    }

    private enum RecordRoute {
        case actor
        case section(AccountAccessSection)
        case wholeRecord
        case unclassified
    }

    private nonisolated static func recordRoute(for path: String) -> RecordRoute {
        let actorPrefixes = [
            "/api/auth", "/api/account", "/api/meta", "/api/health", "/api/version",
            "/api/devices", "/api/notifications", "/api/integrations", "/api/import",
            "/api/workouts", "/api/insights/ecg"
        ]
        if actorPrefixes.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return .actor
        }
        let sections: [(String, AccountAccessSection)] = [
            ("/api/measurements", .measurements), ("/api/custom-metrics", .measurements),
            ("/api/medications", .medications),
            ("/api/biomarkers", .labs), ("/api/labs", .labs),
            ("/api/allergies", .profile), ("/api/family-history", .profile),
            ("/api/anamnesis", .profile), ("/api/encounters", .profile),
            ("/api/vaccinations", .profile),
            ("/api/illness", .illness),
            ("/api/mood", .mind), ("/api/mental-health", .mind),
            ("/api/cycle", .cycle),
            ("/api/documents", .documents)
        ]
        if let section = sections.first(where: { path == $0.0 || path.hasPrefix($0.0 + "/") })?.1 {
            return .section(section)
        }
        let wholeRecordPrefixes = ["/api/dashboard", "/api/insights", "/api/export/health-record"]
        if wholeRecordPrefixes.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return .wholeRecord
        }
        return .unclassified
    }

    private nonisolated static func localSharingDenial() -> HLError {
        .server(
            status: 403,
            code: "sharing.client.access.denied",
            message: "Selected record does not admit this request"
        )
    }

    /// `internal` — see `decodePayload`.
    func ensureSuccess(response: HTTPURLResponse, data: Data) throws {
        guard !(200 ... 299).contains(response.statusCode) else { return }
        let envelope = try? decoder.decode(APIEnvelope<EmptyPayload>.self, from: data)
        // F-1 — surface the assistant-disabled envelope as a typed
        // error so the caller can mirror the operator state into
        // `FeatureFlagsStore` and the matching surface placeholder
        // can render. Server brief v1.4.31 §5 + cross-coordination
        // audit §c.1: `errorCode: "assistant.disabled.<surface>"`
        // paired with status `403`. We only honour the typed error
        // when BOTH (a) the status is 403 (not 401/422/...) AND
        // (b) the errorCode parses to a known `FeatureFlag`. Any
        // other shape falls through to the generic server-error
        // path so future surfaces don't silently drop into the
        // typed branch.
        // #30 — module-gate rejection: `403` + `meta.errorCode ==
        // "module.disabled"` + `meta.module: "<key>"`. We honour the typed
        // error only when BOTH (a) status is 403 AND (b) the meta carries the
        // module.disabled code with a non-empty module key. Any other shape
        // falls through to the generic server-error path. Mirrors the
        // assistant-disabled hop: fire-and-forget into ModuleGate so the
        // surface disappears on the next render tick, while the typed
        // `HLError.moduleDisabled(_:)` stays the authoritative signal.
        // v1.18.1 — the born-gated illness module 403s with `errorCode:
        // "illness.disabled"` (not the generic `module.disabled`), but carries the
        // same `meta.module: "illness"`. Treat it on the SAME typed path so the
        // gate auto-mirrors OFF and the surface disappears immediately, exactly
        // like every other module. `IllnessRepository.isIllnessDisabled` already
        // recognises both the typed `.moduleDisabled("illness")` and the raw form.
        if response.statusCode == 403,
           let meta = envelope?.meta,
           meta.errorCode == "module.disabled" || meta.errorCode == "illness.disabled",
           let module = meta.module, !module.isEmpty
        {
            if let handler = onModuleDisabled {
                Task { await handler(module) }
            }
            throw HLError.moduleDisabled(module)
        }
        if response.statusCode == 403, let envelope, let flag = parseAssistantDisabled(envelope.errorCode) {
            // Fire-and-forget mirror into FeatureFlagsStore so the
            // next render tick can surface the placeholder without
            // waiting on the foreground-refresh of `/api/feature-flags`.
            // Errors here are intentionally ignored — the typed
            // `HLError.assistantDisabled(_:)` is the authoritative
            // signal; the mirror is a convenience.
            if let handler = onAssistantDisabled {
                Task { await handler(flag) }
            }
            throw HLError.assistantDisabled(flag)
        }
        // v1.35.0 (GH #83) — a refusal that states WHICH rule it missed throws
        // its own typed error; every other envelope falls through (see
        // `APIRefusal`).
        try APIRefusal.throwIfReasoned(envelope?.meta)
        let msg = envelope?.error ?? "HTTP \(response.statusCode)"
        // The typed discriminator lives in `meta.errorCode` for the module-gate +
        // document-AI shapes (e.g. `documents.inbound.providerUnsupported` on a 422);
        // the top-level `errorCode` carries the older assistant-disabled shape. Prefer
        // the nested one so callers can distinguish typed errors from a plain status.
        throw HLError.server(
            status: response.statusCode,
            code: envelope?.meta?.errorCode ?? envelope?.errorCode,
            message: msg
        )
    }

    /// Parses `"assistant.disabled.<surface>"` into the corresponding
    /// ``FeatureFlag``. Returns `nil` for any other shape. Defined
    /// `nonisolated` so the actor's `ensureSuccess` can call it
    /// without an `await` hop (pure-function).
    private nonisolated func parseAssistantDisabled(_ errorCode: String?) -> FeatureFlag? {
        guard let errorCode, errorCode.hasPrefix("assistant.disabled.") else { return nil }
        let surface = String(errorCode.dropFirst("assistant.disabled.".count))
        return FeatureFlag.from(serverSurface: surface)
    }

    private func backoffDelay(attempt: Int) -> UInt64 {
        let base = 0.25 // 250ms
        let cap = 5.0
        let exponential = min(cap, base * Foundation.pow(2.0, Double(attempt - 1)))
        let jitter = Double.random(in: -0.2 ... 0.2) * exponential
        let seconds = max(0.05, exponential + jitter)
        return UInt64(seconds * 1_000_000_000)
    }

    /// `internal` — see `decodePayload`.
    func mapURLError(_ err: URLError) -> HLError {
        switch err.code {
        case .timedOut: .network(.timeout)
        case .notConnectedToInternet, .networkConnectionLost: .offline
        case .cannotFindHost, .dnsLookupFailed: .network(.dnsFailure)
        case .secureConnectionFailed, .serverCertificateUntrusted, .clientCertificateRejected, .clientCertificateRequired:
            .network(.sslPinning)
        case .cancelled: .canceled
        default: .network(.other(err.localizedDescription))
        }
    }
}

// Note: the ISO8601 date-decoding helpers that used to live at the bottom of
// this file now sit next to their siblings in `Util/JSONDecoder+HLDefault.swift`
// (pure move, no behaviour change) — they were Foundation-only helpers with no
// relation to the transport core, and this file is at its `file_length` ceiling.
