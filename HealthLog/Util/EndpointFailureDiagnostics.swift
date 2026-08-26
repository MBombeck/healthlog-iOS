import Foundation

// MARK: - EndpointRouteTemplate

/// Pure route-templating for the endpoint-failure diagnostics line (#67 / CU-02).
///
/// **Why this exists.** A failed request currently surfaces as a generic banner,
/// so nobody — least of all the server team — learns *which* endpoint fell over.
/// Naming the route in the log fixes that, but a raw path leaks identifiers
/// (`/api/medications/018f…-…/dose-history` carries a medication UUID, i.e. PHI
/// linkage). So the route is emitted **templated**: every opaque segment
/// collapses to `:id`, leaving the shape (`/api/medications/:id/dose-history`)
/// which is exactly what an operator needs and nothing more.
///
/// This is a deliberately **pure** function — no network, no `APIClient`, no
/// actor — so it can be exercised segment by segment in unit tests.
///
/// ## Recognition rules (in order, per path segment)
///
/// 1. Percent-encoded (`%`) → `:id`. Opaque server keys are percent-encoded by
///    their repositories (see `MoodTagCatalogRepository.pathComponent`); a
///    segment carrying an escape is by definition caller data, not a literal.
/// 2. All-numeric → `:id` (numeric row ids, epoch stamps).
/// 3. Canonical UUID (8-4-4-4-12) → `:id`.
/// 4. `<prefix>_<body>` with a 1…8-letter prefix and a ≥6-char alphanumeric body
///    → `:id`. Covers the server's opaque token shapes (`hls_…` share links,
///    `hlh_…`, `hle_…` step-up elevation) and the cuid2 entity ids
///    (`med_…`, `meas_…`, `mood_…`, `pr_…`).
/// 5. ≥ 8 digit characters → `:id` (hex tokens, `YYYY-MM-DD` day keys,
///    millisecond timestamps). The longest legitimate route literal in this API
///    carries a single digit (`glp1`), so the floor is safe.
/// 6. ≥ 24 characters → `:id` (bare cuid2 / nanoid without a prefix). The
///    longest route literal in this API is 22 characters
///    (`measurement-categories`, `documents-auto-ai-read`), so 24 clears it.
/// 7. Mixed uppercase **and** digits → `:id` (base62 / nanoid shapes). Route
///    literals in this API are lowercase kebab-case throughout.
///
/// Anything else is treated as a route literal and kept verbatim. The emitted
/// line still passes through ``LogSanitizer`` (every `HLLog` call does), so the
/// classic identifier shapes have a second net under them.
///
/// **Residual, stated honestly:** a short, lowercase, digit-free *caller-chosen*
/// key (e.g. a custom mood-tag key that the user typed and that survives
/// percent-encoding unchanged) is indistinguishable from a route literal by
/// shape alone and would be kept. It is not an identifier and carries no
/// account linkage, but it is user-authored text — noted here rather than
/// silently assumed away.
public enum EndpointRouteTemplate {
    /// Templates an API path. Query and fragment are dropped entirely (they can
    /// carry ids, dates and free text that the log has no business seeing).
    public static func template(_ path: String) -> String {
        let base = path.prefix { $0 != "?" && $0 != "#" }
        guard !base.isEmpty else { return "/" }
        return base
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { isOpaqueIdentifier(String($0)) ? ":id" : String($0) }
            .joined(separator: "/")
    }

    /// `true` when the segment looks like caller data rather than a route literal.
    static func isOpaqueIdentifier(_ segment: String) -> Bool {
        guard !segment.isEmpty else { return false }
        if segment.contains("%") { return true }
        if segment.allSatisfy(\.isNumber) { return true }
        if isCanonicalUUID(segment) { return true }
        if isPrefixedToken(segment) { return true }
        if segment.filter(\.isNumber).count >= 8 { return true }
        if segment.count >= 24 { return true }
        if segment.contains(where: \.isUppercase), segment.contains(where: \.isNumber) { return true }
        return false
    }

    private static func isCanonicalUUID(_ segment: String) -> Bool {
        segment.count == 36 && UUID(uuidString: segment) != nil
    }

    /// `hls_…` / `hlh_…` / `hle_…` / `med_…` / `meas_…` — a short letter prefix,
    /// an underscore, then a contiguous alphanumeric body.
    private static func isPrefixedToken(_ segment: String) -> Bool {
        guard let separator = segment.firstIndex(of: "_") else { return false }
        let prefix = segment[segment.startIndex ..< separator]
        let body = segment[segment.index(after: separator)...]
        guard (1 ... 8).contains(prefix.count), prefix.allSatisfy(\.isLetter) else { return false }
        return body.count >= 6 && body.allSatisfy { $0.isLetter || $0.isNumber }
    }
}

// MARK: - EndpointFailureClass

/// The five buckets an endpoint failure falls into (#67). Deliberately coarse:
/// the point is to tell "the server was slow / said no / spoke nonsense / was
/// unreachable" apart at a glance, not to reproduce the full `HLError` surface.
public enum EndpointFailureClass: String, Sendable {
    /// Connection-level failure that is not a timeout (DNS, TLS/pin, socket).
    case transport
    /// The request exceeded the session's request timeout.
    case timeout
    /// The server answered with a non-2xx status.
    case status
    /// The server answered 2xx but the body could not be decoded.
    case decoding
    /// No usable network path at all.
    case offline
}

// MARK: - StoreEffectDiagnostics

/// **13-03 (A1 / H-A1c) — the refusals that used to be silent.**
///
/// A store effect that cannot run because its authenticated-session lease is
/// unavailable or has been retired is *correct* to do nothing: publishing
/// another account's data would be the actual defect. What was wrong is that it
/// did nothing **observably**. `EndpointFailureDiagnostics.classify` deliberately
/// swallows the cancellation classes, so a refused effect produced no endpoint
/// line either, and "the dashboard sometimes shows nothing" had no signature an
/// operator could look for in a sysdiagnose. Phase 07 found the same defect
/// class once already (`HealthSyncContracts.swift:486-496`).
///
/// Everything emitted here is a closed-set word: which store, which refusal.
/// No owner id, no generation, no route, no identifier of any kind — a refusal
/// is about the *shape* of the session boundary, and the shape is all an
/// operator needs.
public enum StoreEffectDiagnostics {
    /// The stores that publish user-visible state through a session lease, or
    /// that raise a loading flag an SWR stream is responsible for lowering.
    ///
    /// **14-06** — 13-03 left this at two cases, which is why every store other
    /// than the dashboard and labs stayed uncountable. The operator's
    /// "die Medikamente werden gar nicht angezeigt" had no signature to look
    /// for at all: `medications` was not a word this vocabulary could say.
    public enum Store: String, Sendable {
        case dashboard
        case labs
        case medications
        case settings
        case measurements
        case aiProvider = "ai_provider"
        case charts
        case dailyBriefing = "daily_briefing"
        case dashboardLayout = "dashboard_layout"
        case healthScore = "health_score"
        case insights
        case notifications
    }

    /// Why an effect declined to run or to publish.
    public enum Refusal: String, Sendable {
        /// No lease could be captured at all — no admitted owner yet, or the
        /// owner id was empty. The effect never started.
        case leaseUnavailable = "lease_unavailable"
        /// A lease was captured, then superseded while the effect was in
        /// flight. The result belongs to an account that is no longer here.
        case leaseRetired = "lease_retired"
        /// **14-06** — the load ended without ever reaching a terminal emission:
        /// the SWR stream was cancelled (a bounded foreground pass expiring is
        /// the common case) before `.cached`, `.fresh` or `.failed` arrived.
        ///
        /// Distinct from the two lease refusals on purpose. Those say "this
        /// result belongs to somebody else"; this one says "there was no result
        /// at all, and the surface was left waiting for one". Without it, a
        /// store that published nothing because it was cut off is
        /// indistinguishable from an account that genuinely has nothing — which
        /// is exactly the ambiguity that made a blank medications list take
        /// three builds to name.
        case loadInterrupted = "load_interrupted"
        /// **22-01** — the load reached a TERMINAL error and published nothing.
        ///
        /// Distinct from ``loadInterrupted`` on purpose, and the distinction is
        /// the whole diagnostic value: "there was no result yet" and "there will
        /// be no result" send an operator to different places. A read that was
        /// cut off may well succeed on the next trigger; a read that ended in a
        /// terminal error will keep ending there until the wire or the account
        /// changes.
        case loadFailed = "load_failed"
    }

    /// Test-only observation hook, same contract as
    /// ``EndpointFailureDiagnostics/sink``: the line always goes to the log
    /// regardless, so installing a sink adds an observer rather than diverting.
    public typealias Sink = @Sendable (String) -> Void

    private nonisolated(unsafe) static var _sink: Sink?
    private static let sinkLock = NSLock()

    static var sink: Sink? {
        get {
            sinkLock.lock()
            defer { sinkLock.unlock() }
            return _sink
        }
        set {
            sinkLock.lock()
            defer { sinkLock.unlock() }
            _sink = newValue
        }
    }

    /// Pure formatter — the exact wire shape of the line.
    static func formatLine(store: Store, refusal: Refusal) -> String {
        "store-effect-refused store=\(store.rawValue) reason=\(refusal.rawValue)"
    }

    /// **22-01 — the additive form of ``sink``, for suites that need an exact
    /// count rather than a containment check.**
    ///
    /// ``sink`` is ONE process-global slot, and Swift Testing runs suites in
    /// parallel in-process: a suite that installs it and clears it in a `defer`
    /// switches OFF every other suite's observation for the rest of that suite's
    /// window. That is the mirror image of the `MockURLProtocol.handler` hole
    /// 09-10 inventoried, and it fails silently — the robbed suite reads an
    /// empty log and goes red for a reason that has nothing to do with the store
    /// it is testing.
    ///
    /// Observers are additive and independently removable, so no suite can take
    /// another's observation away. `sink` is left exactly as it was; both are
    /// fanned out to.
    private nonisolated(unsafe) static var _observers: [UUID: Sink] = [:]

    static func addRefusalObserver(_ observer: @escaping Sink) -> UUID {
        let token = UUID()
        sinkLock.lock()
        defer { sinkLock.unlock() }
        _observers[token] = observer
        return token
    }

    static func removeRefusalObserver(_ token: UUID) {
        sinkLock.lock()
        defer { sinkLock.unlock() }
        _observers.removeValue(forKey: token)
    }

    private static var observers: [Sink] {
        sinkLock.lock()
        defer { sinkLock.unlock() }
        return Array(_observers.values)
    }

    static func recordRefusal(_ refusal: Refusal, store: Store) {
        let line = formatLine(store: store, refusal: refusal)
        // Two closed-set words and nothing else — operator-grade by
        // construction, exactly like the endpoint-failure line above.
        // swiftlint:disable:next hllog_public_privacy_interpolation
        HLLog.api.debug("\(line, privacy: .public)")
        sink?(line)
        for observer in observers {
            observer(line)
        }
    }

    // MARK: - The foreground pass census (14-05 / J3)

    /// **14-05 (D-09-06-A / J3) — one line per foreground pass.**
    ///
    /// The pass ledger already recorded every member that finished and every
    /// member that never started; nothing read it, so "did the dashboard
    /// refresh run?" had no signature in a sysdiagnose and the operator's "es
    /// kommen eher weniger Daten an" had nothing to be checked against.
    ///
    /// The parameters are raw strings rather than the pass types on purpose:
    /// this file is part of the `HealthLogCore` SPM target and
    /// `ForegroundPassReport` is app-target-only. Every value a caller passes
    /// comes from a `rawValue` of a closed enum — `ForegroundPassOutcome` and
    /// `ForegroundMember` — so the line carries member names and counts and
    /// nothing else: no identifier, no route, no payload, no timing.
    static func formatForegroundPassLine(
        outcome: String,
        finished: [String],
        skipped: [String]
    ) -> String {
        "foreground-pass outcome=\(outcome) ran=\(finished.count) skipped=\(skipped.count)"
            + " finished=\(finished.joined(separator: ",")) skipped=\(skipped.joined(separator: ","))"
    }

    static func recordForegroundPass(outcome: String, finished: [String], skipped: [String]) {
        let line = formatForegroundPassLine(outcome: outcome, finished: finished, skipped: skipped)
        // Closed-set words and two counts — operator-grade by construction.
        // swiftlint:disable:next hllog_public_privacy_interpolation
        HLLog.api.debug("\(line, privacy: .public)")
        sink?(line)
    }
}

// MARK: - EndpointFailureDiagnostics

/// Emits exactly one PII-free line per failed `APIClient` request (#67 / CU-02):
///
/// ```
/// endpoint-failure method=GET route=/api/medications/:id/dose-history status=503 class=status elapsedMs=812
/// ```
///
/// Everything in that line is operator-grade: the method, the *templated* route,
/// the HTTP status (`0` when there never was a response), the failure class and
/// the wall time until the failure. No token, no header, no idempotency key, no
/// URL, no email — and the line still runs through ``LogSanitizer`` on its way
/// into `os.log`, because every `HLLog` call does.
public enum EndpointFailureDiagnostics {
    /// Test-only observation hook. Production leaves this `nil`; the line always
    /// goes to `HLLog.api` regardless, so installing a sink adds an observer
    /// rather than diverting the log.
    public typealias Sink = @Sendable (String) -> Void

    /// Backing storage — only ever touched through the locked ``sink`` accessor.
    /// `nonisolated(unsafe)` is sound precisely *because* the lock, not the
    /// compiler, enforces exclusive access (same contract as
    /// `MockURLProtocol.handler`).
    private nonisolated(unsafe) static var _sink: Sink?
    private static let sinkLock = NSLock()

    static var sink: Sink? {
        get {
            sinkLock.lock()
            defer { sinkLock.unlock() }
            return _sink
        }
        set {
            sinkLock.lock()
            defer { sinkLock.unlock() }
            _sink = newValue
        }
    }

    /// The single entry point `APIClient` calls from its existing failure paths.
    /// Silent for user/system cancellation — an aborted request is intent, not
    /// an endpoint that misbehaved, and logging it would drown the signal.
    static func record(
        _ error: any Error,
        method: HTTPMethod,
        path: String,
        since started: ContinuousClock.Instant
    ) {
        guard let failureClass = classify(error) else { return }
        let elapsed = ContinuousClock.now - started
        let line = formatLine(
            method: method,
            path: path,
            status: status(for: error),
            failureClass: failureClass,
            elapsedMs: Int((elapsed / .milliseconds(1)).rounded())
        )
        // The whole point of this line is that an operator can read it in a
        // sysdiagnose: it is method + templated route + status + class + duration,
        // all of it operator-grade by construction. `.public` is the deliberate
        // choice here, not an oversight.
        // swiftlint:disable:next hllog_public_privacy_interpolation
        HLLog.api.error("\(line, privacy: .public)")
        sink?(line)
    }

    /// Pure formatter — the exact wire shape of the diagnostics line.
    static func formatLine(
        method: HTTPMethod,
        path: String,
        status: Int,
        failureClass: EndpointFailureClass,
        elapsedMs: Int
    ) -> String {
        "endpoint-failure method=\(method.rawValue)"
            + " route=\(EndpointRouteTemplate.template(path))"
            + " status=\(status)"
            + " class=\(failureClass.rawValue)"
            + " elapsedMs=\(elapsedMs)"
    }

    /// Maps a thrown error onto its failure class. Returns `nil` for anything
    /// that must NOT produce a line (cancellation).
    static func classify(_ error: any Error) -> EndpointFailureClass? {
        if error is CancellationError { return nil }
        guard let hlError = error as? HLError else {
            if let urlError = error as? URLError, urlError.code == .cancelled { return nil }
            return .transport
        }
        return switch hlError {
        case .canceled: nil
        case .network(.timeout): .timeout
        case .network: .transport
        case .offline: .offline
        case .decoding: .decoding
        // Everything the server *answered* with. `.assistantDisabled` and
        // `.moduleDisabled` are only ever thrown by `ensureSuccess` for a 403.
        // `.writeConflictUnresolved` is the CU-20 give-up after a run of 409s —
        // every one of those WAS a server answer, so it classifies as `.status`.
        // `.refusedWithReason` likewise: the server understood the request and
        // answered it with a stated refusal.
        case .server, .unauthorized, .rateLimited, .assistantDisabled, .moduleDisabled,
             .writeConflictUnresolved, .refusedWithReason: .status
        // `.unknown` is the URL-construction failure; `.notPersisted` never
        // originates in `APIClient`. `.serverNotConfigured` heisst, dass es
        // noch gar keine Adresse gibt — es ging nie ein Paket raus. Alle drei
        // sind client-seitig, also transport.
        case .notPersisted, .serverNotConfigured, .unknown: .transport
        }
    }

    /// The HTTP status to report. `0` means "no HTTP response was ever seen"
    /// — deliberately numeric so the line stays machine-parseable.
    static func status(for error: any Error) -> Int {
        guard let hlError = error as? HLError else { return 0 }
        return switch hlError {
        case let .server(status, _, _): status
        case .unauthorized: 401
        case .rateLimited: 429
        case .assistantDisabled, .moduleDisabled: 403
        default: 0
        }
    }
}
