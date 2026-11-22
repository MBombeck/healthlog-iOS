import Foundation

/// One failed request the server answered, as support needs it (#134).
///
/// Only operator-grade facts: the method, the templated route (every id
/// collapsed to `:id` by ``EndpointRouteTemplate``), the HTTP status, the
/// server's error code and request id, and the time. Never a request or
/// response body, a query string, a server address, a health value or a
/// message text.
public struct RecentFailure: Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// The server answered with a non-2xx status.
        case status
        /// The server answered 2xx, but the body could not be read.
        case decoding
    }

    public let at: Date
    public let method: String
    public let route: String
    public let status: Int
    public let errorCode: String?
    public let requestId: String?
    public let kind: Kind

    public init(
        at: Date,
        method: String,
        route: String,
        status: Int,
        errorCode: String?,
        requestId: String?,
        kind: Kind
    ) {
        self.at = at
        self.method = method
        self.route = route
        self.status = status
        self.errorCode = errorCode
        self.requestId = requestId
        self.kind = kind
    }
}

/// **The last few failures of this session, in memory only.**
///
/// `APIClient` records every failure the server answered (a non-2xx status or
/// an unreadable 2xx), with or without an id, so the newest entry always
/// belongs to the newest failure. The buffer keeps ``capacity`` entries and
/// drops the oldest. It is never written to disk and is cleared on logout:
/// the ids belong to the session that made the requests.
///
/// Two readers:
/// - the error banner asks ``displayID(for:)`` for the id of the failure it
///   is showing;
/// - "Support-Info kopieren" (and, at integration, W5's Sync Diagnostics
///   report) prints ``snapshot()`` through ``RecentFailureLines``.
public final class RecentFailureLog: @unchecked Sendable {
    /// The process-wide log `APIClient` writes to.
    public static let shared = RecentFailureLog()

    /// "Keep the last 5 IDs of the session".
    public static let defaultCapacity = 5

    /// How long a banner may name an entry's id. A banner that is still up
    /// after this is showing an old failure; better no id than a stale one.
    public static let displayWindow: TimeInterval = 15 * 60

    public let capacity: Int
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    /// Oldest first. Only touched under `lock`.
    private var entries: [RecentFailure] = []

    public init(capacity: Int = RecentFailureLog.defaultCapacity, now: @escaping @Sendable () -> Date = { Date() }) {
        self.capacity = max(1, capacity)
        self.now = now
    }

    public func record(_ failure: RecentFailure) {
        lock.lock()
        defer { lock.unlock() }
        entries.append(failure)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    /// Newest first.
    public func snapshot() -> [RecentFailure] {
        lock.lock()
        defer { lock.unlock() }
        return entries.reversed()
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
    }

    /// Records a failed `APIClient` call that had a response. Errors the
    /// server did not answer (offline, timeout, cancellation) are not
    /// recorded: they have no id and would push the useful ones out.
    func record(
        _ error: any Error,
        method: HTTPMethod,
        path: String,
        response: HTTPURLResponse,
        body: Data
    ) {
        let kind: RecentFailure.Kind
        switch EndpointFailureDiagnostics.classify(error) {
        case .status: kind = .status
        case .decoding: kind = .decoding
        default: return
        }
        let isSuccessBody = (200 ... 299).contains(response.statusCode)
        record(RecentFailure(
            at: now(),
            method: method.rawValue,
            route: EndpointRouteTemplate.template(path),
            status: response.statusCode,
            errorCode: isSuccessBody ? nil : ServerErrorID.fields(in: body).errorCode,
            requestId: ServerErrorID.extract(from: response, body: body),
            kind: kind
        ))
    }

    /// The full request id a banner shows for `error`, or `nil`.
    ///
    /// Only for the failures #134 names: a 5xx and an unexpected failure (an
    /// unreadable answer). A 4xx carries the server's own sentence and needs
    /// no id. The banner only holds the `HLError`, so the match is the newest
    /// entry of the same kind and status within ``displayWindow``. Because
    /// every answered failure is recorded, that is the failure the banner
    /// shows, unless two requests failed the same way at the same moment, in
    /// which case both ids point at the same fault.
    public func displayID(for error: HLError) -> String? {
        let matches: (RecentFailure) -> Bool
        switch error {
        case let .server(status, _, _) where status >= 500:
            matches = { $0.kind == .status && $0.status == status }
        case .decoding:
            matches = { $0.kind == .decoding }
        default:
            return nil
        }
        let cutoff = now().addingTimeInterval(-Self.displayWindow)
        guard let newest = snapshot().first(where: matches), newest.at >= cutoff else { return nil }
        return newest.requestId
    }
}

/// **The plain-text lines for recent failures, shared by every report.**
///
/// "Support-Info kopieren" prints them, and W5's Sync Diagnostics report
/// (`SyncDiagnosticsReport`) appends them at integration with
/// `lines += RecentFailureLines.lines(RecentFailureLog.shared.snapshot())`.
/// Fixed English words, like W5's report, so two reports compare line by line
/// whatever the phone's language. ASCII only.
public enum RecentFailureLines {
    public static func lines(_ failures: [RecentFailure]) -> [String] {
        guard !failures.isEmpty else { return ["recent errors: none"] }
        return ["recent errors:"] + failures.map { "  " + line($0) }
    }

    /// `2026-10-16T09:12:03Z GET /api/medications/:id 500 internal_error id 3f9a2c1b-...`
    public static func line(_ failure: RecentFailure) -> String {
        var parts = [
            failure.at.formatted(.iso8601),
            failure.method,
            failure.route,
            failure.kind == .decoding ? "\(failure.status) unreadable" : "\(failure.status)"
        ]
        if let code = failure.errorCode { parts.append(code) }
        parts.append(failure.requestId.map { "id \($0)" } ?? "no id")
        return parts.joined(separator: " ")
    }
}
