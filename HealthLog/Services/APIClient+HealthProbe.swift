import Foundation

// MARK: - Captive-portal reachability probe (QoL-3-H-3)

public extension APIClient {
    /// Lightweight liveness probe against the public `/api/health` route.
    ///
    /// `NWPathMonitor` reports `.satisfied` on captive-portal Wi-Fi
    /// (hotel / airport) even though real API traffic is blocked or
    /// redirected to a login page. Gating the Outbox replay + SWR fanout
    /// on interface state alone therefore fires writes that hang until
    /// the URLSession resource-timeout and then fail. This probe closes
    /// that gap: it returns `true` only when our server answers with the
    /// expected `{ "status": … }` health envelope.
    ///
    /// **Why decode the body, not just check 2xx:** a captive portal
    /// typically returns `200 OK` with an HTML login page (or a redirect
    /// to a foreign host). Requiring the `status` field to decode rules
    /// those out — only our Next.js `/api/health` handler emits that
    /// shape. The route is public (no session cookie / bearer required,
    /// see server `proxy.ts` PUBLIC_PATHS) and returns `200` when healthy
    /// or `503 { status: "degraded" }` when the DB / worker is down — a
    /// `503` from *our* server still proves real API reachability, so we
    /// treat any decodable health envelope (regardless of HTTP status)
    /// as "truly reachable".
    ///
    /// Runs on the pinned `session` so the SPKI-pin contract is honoured
    /// for any host the build pins. Uses a short per-request timeout so a
    /// captive portal cannot make the probe itself hang — it does **not**
    /// inherit the 20 s authenticated-request timeout. No retry: a single
    /// failed probe simply reports "not reachable" and the caller backs
    /// off (the replay loop re-evaluates on the next reachability edge).
    ///
    /// - Parameter timeout: Per-request timeout in seconds. Default 4 s —
    ///   long enough for a slow-but-real network, short enough that a
    ///   captive portal surfaces "connected, no internet" quickly.
    func probeReachable(timeout: TimeInterval = 4) async -> Bool {
        await probeHealth(timeout: timeout).reachable
    }

    /// **audit-v0162 H1 (Opt 3) — richer probe.** Same request as
    /// ``probeReachable(timeout:)`` but returns BOTH signals: whether the server
    /// answered our health route at all (`reachable`) and whether that answer
    /// reported `degraded` (`degraded`, i.e. confirmed-reachable-but-unhealthy —
    /// the DB / worker is down and the server is emitting 5xx). The outbox replay
    /// path uses `degraded` to avoid burning a PHI write's retry budget on a
    /// server-side outage; ``probeReachable`` stays the captive-portal gate.
    func probeHealth(timeout: TimeInterval = 4) async -> HealthProbeOutcome {
        // Ohne eingerichteten Server gibt es nichts zu sondieren. Wir melden
        // `.unreachable` (nicht erreichbar ist sachlich richtig), aber ohne
        // vorher einen erfundenen Host anzufassen — es fliegt kein Paket.
        guard let baseURL = environment.baseURL else { return .unreachable }
        let url = baseURL.appendingPathComponent("/api/health")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        // Always hit the network — a cached health row would defeat the
        // purpose of detecting a live captive portal.
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        req.timeoutInterval = max(1, timeout)
        // CF-Access headers travel on every request when configured; the
        // public health route ignores them, but a Cloudflare-Access-fronted
        // instance still needs them to reach the origin at all.
        if let id = environment.cfAccessClientID {
            req.setValue(id, forHTTPHeaderField: "cf-access-client-id")
        }
        if let token = environment.cfAccessClientToken {
            req.setValue(token, forHTTPHeaderField: "cf-access-client-token")
        }

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { return .unreachable }
            return Self.healthOutcome(data: data, statusCode: http.statusCode)
        } catch {
            // Timeout / SSL-pin-fail / portal-redirect-to-foreign-host all
            // land here → not reachable. Static message, no PII to sanitise.
            HLLog.api.debug("health probe failed: not reachable")
            return .unreachable
        }
    }

    /// Decodes the `/api/health` response body and confirms it carries the
    /// `status` field our server emits. `nonisolated` + `static` so it is a
    /// pure, unit-testable function with no actor hop.
    nonisolated static func isHealthEnvelope(_ data: Data) -> Bool {
        guard !data.isEmpty,
              let probe = try? JSONDecoder().decode(HealthProbeResponse.self, from: data) else { return false }
        return !probe.status.isEmpty
    }

    /// Classify a `/api/health` reply into a ``HealthProbeOutcome``. Reachable
    /// iff the body is our health envelope (rules out captive-portal HTML). A
    /// `503` HTTP status OR a `status: "degraded"` envelope marks it degraded —
    /// a `503` from OUR server still proves real API reachability, so the row
    /// stays `reachable == true`. `nonisolated` + `static` so it is pure + unit-
    /// testable with no actor hop.
    nonisolated static func healthOutcome(data: Data, statusCode: Int) -> HealthProbeOutcome {
        guard !data.isEmpty,
              let probe = try? JSONDecoder().decode(HealthProbeResponse.self, from: data),
              !probe.status.isEmpty else { return .unreachable }
        let degraded = statusCode == 503 || probe.status.lowercased() == "degraded"
        return HealthProbeOutcome(reachable: true, degraded: degraded)
    }
}

// MARK: - Health probe DTO + outcome

/// Minimal decode target for the public `/api/health` route. The server
/// returns `{ "status": "ok" }` (200) when healthy or
/// `{ "status": "degraded" }` (503) when the DB / worker is down; admins
/// additionally get `timestamp` / `database` / `worker` fields, which we
/// intentionally ignore — only `status` is needed to prove that the
/// response came from our API rather than a captive-portal HTML page.
struct HealthProbeResponse: Decodable {
    let status: String
}

/// audit-v0162 H1 (Opt 3) — the two signals a health probe yields.
public struct HealthProbeOutcome: Sendable, Equatable {
    /// The server answered our health route (not a captive portal). A `503`
    /// from our own server still counts as reachable.
    public let reachable: Bool
    /// The server reported `degraded` (or 503): confirmed reachable but its
    /// DB / worker is down and it is emitting server-side errors.
    public let degraded: Bool

    public init(reachable: Bool, degraded: Bool) {
        self.reachable = reachable
        self.degraded = degraded
    }

    /// No answer / captive portal / TLS-pin fail — neither reachable nor degraded.
    public static let unreachable = HealthProbeOutcome(reachable: false, degraded: false)
}

/// **audit-v0162 H1 (Opt 3) — shared degraded-server signal.** Records the most
/// recent `/api/health` probe outcome so the outbox replay path can ask "is the
/// server confirmed-reachable but degraded?" without issuing its own probe. The
/// composition root records into this from the same probe that gates reachability
/// (`Reachability.setProbe`); `OutboxReplayService` reads ``isKnownDegraded``.
public actor ServerHealthSignal {
    public private(set) var lastOutcome: HealthProbeOutcome = .unreachable

    public init() {}

    /// Record a fresh probe result (called from the composition-root probe).
    public func record(_ outcome: HealthProbeOutcome) {
        lastOutcome = outcome
    }

    /// The server answered but reported degraded — a 5xx/429 replay failure
    /// under this condition must NOT be counted toward the dead-letter budget.
    public var isKnownDegraded: Bool {
        lastOutcome.reachable && lastOutcome.degraded
    }
}
