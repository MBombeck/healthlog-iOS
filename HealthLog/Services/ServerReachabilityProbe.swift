import Foundation

/// Shared transport for the "is this a HealthLog server?" reachability
/// check used before the app re-targets itself at a new base URL.
///
/// **Why this exists (v0.7.1 H-1 — architect pass).** Both
/// `ServerURLStep` (onboarding) and `SettingsServerScreen` (settings)
/// previously built a `URLRequest`, instantiated a `CertificatePinner`,
/// spun up a pinned `URLSession.healthLogProbeSession`, issued the request,
/// and interpreted the HTTP status — *inside the View*. That is a
/// View → transport-layer boundary violation (the architecture is
/// `Views → Stores → Repositories → Services`; networking + cert-pinning
/// belong at/below the Service line) and it was duplicated near-verbatim
/// across the two screens. This actor owns the request construction, the
/// pinned session lifecycle, and the status → result mapping in one place;
/// the Views only render the resulting ``Outcome``.
///
/// The probe hits `GET /api/auth/registration-status` — a cheap,
/// unauthenticated endpoint every HealthLog server exposes. A
/// managed-cloud candidate host is SPKI-checked against the
/// bundled pin set before the host is trusted; self-hosted hosts fall back
/// to default server-trust validation (the pinner only pins hosts it has
/// a pin set for). Ephemeral session, 10 s timeout, no caching.
///
/// Behaviour matches the two former inline probes exactly: the only seam
/// is the ``Outcome`` it returns instead of each View's own localized
/// `ProbeState`, so each caller keeps its own user-facing copy.
public actor ServerReachabilityProbe {
    /// Typed result of a probe. Callers map this onto their own
    /// user-facing state (the localized strings stay in the View layer so
    /// each surface keeps its existing copy verbatim).
    public enum Outcome: Sendable, Equatable {
        /// The candidate URL could not be expanded into a probe URL.
        case malformedURL
        /// 2xx — the host answered the registration-status endpoint.
        case reachable
        /// 404 — the host answered but does not look like a HealthLog server.
        case notHealthLogServer
        /// Any other status code — surfaced verbatim so the View can show it.
        case unexpectedStatus(Int)
        /// A response without an `HTTPURLResponse` (non-HTTP transport).
        case nonHTTPResponse
        /// Transport failure (timeout / TLS / DNS / pin rejection). Carries
        /// the localized description so the View can present it.
        case transportFailure(String)
    }

    public init() {}

    /// Probes `url` for a HealthLog `registration-status` endpoint behind
    /// the pinned probe session.
    ///
    /// - Parameters:
    ///   - url: the candidate base URL the user typed / picked.
    ///   - userAgent: the `User-Agent` header value — the onboarding and
    ///     settings surfaces send distinct tags so server logs can tell
    ///     which flow issued the probe.
    public func probe(url: URL, userAgent: String) async -> Outcome {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.path = "/api/auth/registration-status"
        guard let probeURL = components?.url else {
            return .malformedURL
        }
        var request = URLRequest(url: probeURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10
        let pinner = CertificatePinner(fromBundle: .main)
        let session = URLSession.healthLogProbeSession(pinner: pinner)
        defer { session.invalidateAndCancel() }
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .nonHTTPResponse
            }
            if (200 ... 299).contains(http.statusCode) {
                return .reachable
            }
            if http.statusCode == 404 {
                return .notHealthLogServer
            }
            return .unexpectedStatus(http.statusCode)
        } catch {
            return .transportFailure(error.localizedDescription)
        }
    }
}
