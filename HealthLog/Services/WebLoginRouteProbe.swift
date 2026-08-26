import Foundation

// MARK: - The route

/// #65 — the native web-handoff login entry, as a route rather than a string
/// in two places.
///
/// `WebLoginNativeFlow.loginURL` (app target) forwards to this. The probe below
/// needs the same URL, and it lives in `HealthLogCore` where
/// `WebLoginNativeFlow` does not, so the builder moved down rather than being
/// re-typed — a probe measuring a *different* address than the one the browser
/// opens would be worse than no probe at all.
public enum WebLoginRoute {
    public static let path = "/api/auth/native/login"

    /// `<baseURL>/api/auth/native/login?code_challenge=<S256>`. The server sets
    /// an encrypted state cookie and 307-redirects to `/auth/login?flow=native`
    /// on its own origin. There is deliberately no client-supplied
    /// `redirect_uri`: the native callback is fixed server-side, which removes
    /// the open-redirect primitive by construction.
    public static func loginURL(baseURL: URL, codeChallenge: String) -> URL? {
        var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "code_challenge", value: codeChallenge)]
        return components?.url
    }
}

// MARK: - What the probe can find

/// **13-02.** What the app knows about the server's web-handoff login route
/// after asking it — a statement about *reachability*, not about a version
/// number.
public enum WebLoginRouteStatus: Sendable, Equatable {
    /// The route answered, and where it points is somewhere this device can
    /// follow. This is the only value that grants the CTA.
    case available
    /// The server is below the frozen contract floor (v1.32.11): the routes do
    /// not exist there at all.
    case versionTooOld
    /// The server answered, but not with this route (404 / 405).
    case routeMissing
    /// The route answered and leads somewhere unreachable — the operator's
    /// instance builds its redirect from the process bind address
    /// (`https://0.0.0.0:3000/...`, measured; healthlog-iOS#96), so the browser
    /// would land on an error page and the user would have nowhere to go.
    ///
    /// The carried host is for the log line and the summary, never for a
    /// correction: the client does not rewrite the server's redirect.
    case deadEndRedirect(host: String)
    /// No answer at all — offline, TLS, DNS, timeout, pin refusal.
    case unreachable
    /// No server address is configured, so there is nothing to probe.
    case notConfigured

    /// Fail-closed by construction: exactly one case grants the CTA.
    public var isAvailable: Bool {
        self == .available
    }

    /// Closed-set, non-sensitive diagnostic word. Never carries the host.
    public var logLabel: String {
        switch self {
        case .available: "available"
        case .versionTooOld: "version_too_old"
        case .routeMissing: "route_missing"
        case .deadEndRedirect: "dead_end_redirect"
        case .unreachable: "unreachable"
        case .notConfigured: "not_configured"
        }
    }
}

/// **13-02.** Is a redirect target somewhere this device could ever reach?
///
/// The rule is deliberately narrow. It does **not** say "different host is
/// suspicious" — a redirect to an identity provider is normal. It says: a
/// wildcard bind address, a loopback address, or a reserved-invalid name is
/// not a destination, *unless it is the very origin the user configured*.
///
/// That exemption is load-bearing twice over. A self-hoster developing against
/// `http://localhost:3000` in the simulator is redirected to himself and must
/// keep working; and the test transport addresses every session at
/// `https://<token>.mock.invalid`, which is a reserved-invalid name that is
/// also the configured origin. Both are the same clause, and it is the
/// difference between "unreachable" and "not where I was told to look".
public enum WebLoginRedirectPolicy {
    /// Addresses that are never a destination. `0.0.0.0` and `::` are the
    /// wildcard bind addresses a server reports when it builds a URL from the
    /// socket it listens on instead of the host it was asked for — exactly the
    /// #96 shape.
    static let nonRoutableHosts: Set<String> = [
        "0.0.0.0",
        "::",
        "0:0:0:0:0:0:0:0",
        "127.0.0.1",
        "::1",
        "localhost"
    ]

    public static func isDeadEnd(target: URL?, configuredHost: String?) -> Bool {
        guard let host = target?.host?.lowercased(), !host.isEmpty else { return false }
        if let configuredHost = configuredHost?.lowercased(), !configuredHost.isEmpty, host == configuredHost {
            return false
        }
        if nonRoutableHosts.contains(host) { return true }
        // RFC 2606 reserves `.invalid`; nothing there can resolve.
        return host == "invalid" || host.hasSuffix(".invalid")
    }
}

// MARK: - The probe

/// **13-02.** The capability the availability gate needs: ask the login route
/// where it leads, and classify the answer.
///
/// Declared as its own protocol rather than as bare `APIClientProtocol`
/// members so the default below can be stated once, for all 67 stub conformers,
/// without any of them having to implement a transport they do not own.
public protocol WebLoginRouteProbing: Sendable {
    func probeWebLoginRoute(codeChallenge: String) async -> WebLoginRouteStatus
}

public extension WebLoginRouteProbing {
    /// A conformer with no real transport cannot make a reachability
    /// statement, and the honest value for "cannot say" on a fail-closed gate
    /// is "no". Deliberately not `.available`: a default that granted the CTA
    /// would silently restore the version-only gate this plan exists to remove,
    /// and it would do so in exactly the tests meant to prove otherwise.
    func probeWebLoginRoute(codeChallenge _: String) async -> WebLoginRouteStatus {
        .unreachable
    }
}

extension APIClient: WebLoginRouteProbing {
    /// Asks `/api/auth/native/login` where it leads, on the same pinned session
    /// every other request rides (mirrors `probeHealth(timeout:)`).
    ///
    /// **Three signals, all honest, because the loading system delivers the
    /// evidence differently depending on what the server did.**
    ///
    /// 1. A 3xx whose `Location` this session did not follow — classify the
    ///    `Location`.
    /// 2. The response's own URL, which after a followed redirect chain is
    ///    where the chain *ended*.
    /// 3. A `URLError` whose failing URL names the address the chain died on.
    ///    This is the production signature of healthlog-iOS#96: `URLSession`
    ///    follows the 307 to `https://0.0.0.0:3000/...` and cannot connect.
    ///
    /// The client classifies; it never corrects. No rewritten redirect, no
    /// substituted host — #96 stays the server's to fix, and until it is fixed
    /// the only thing that changes here is that the app stops offering a door
    /// that leads nowhere.
    ///
    /// - Parameter codeChallenge: a throwaway PKCE S256 challenge. The probe's
    ///   state cookie is discarded with the response; the real flow mints its
    ///   own inside `ASWebAuthenticationSession`, which has a separate cookie
    ///   jar, so the two cannot interfere.
    public func probeWebLoginRoute(codeChallenge: String) async -> WebLoginRouteStatus {
        guard let baseURL = environment.baseURL,
              let url = WebLoginRoute.loginURL(baseURL: baseURL, codeChallenge: codeChallenge) else
        {
            return .notConfigured
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("native", forHTTPHeaderField: "X-Client-Type")
        // Always ask the network: a cached answer would defeat the purpose of
        // a reachability statement.
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 8
        // A Cloudflare-Access-fronted instance needs these to reach the origin
        // at all; the login route itself ignores them.
        if let id = environment.cfAccessClientID {
            request.setValue(id, forHTTPHeaderField: "cf-access-client-id")
        }
        if let token = environment.cfAccessClientToken {
            request.setValue(token, forHTTPHeaderField: "cf-access-client-token")
        }

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .unreachable }
            return Self.classify(response: http, configuredHost: baseURL.host)
        } catch {
            return Self.classify(transportError: error, configuredHost: baseURL.host)
        }
    }

    /// Signals 1 and 2. `nonisolated` + `static` so the rule is a pure,
    /// unit-testable function with no actor hop (the `healthOutcome` pattern).
    nonisolated static func classify(
        response: HTTPURLResponse,
        configuredHost: String?
    ) -> WebLoginRouteStatus {
        if response.statusCode == 404 || response.statusCode == 405 { return .routeMissing }
        let location = response.value(forHTTPHeaderField: "Location")
            .flatMap { URL(string: $0, relativeTo: response.url) }
        for candidate in [location, response.url] where WebLoginRedirectPolicy.isDeadEnd(
            target: candidate,
            configuredHost: configuredHost
        ) {
            return .deadEndRedirect(host: candidate?.host ?? "")
        }
        // A 5xx from the login route is not a door either. Fail closed.
        guard (200 ... 399).contains(response.statusCode) else { return .unreachable }
        return .available
    }

    /// Signal 3.
    nonisolated static func classify(
        transportError: any Error,
        configuredHost: String?
    ) -> WebLoginRouteStatus {
        let failingURL = (transportError as? URLError).flatMap { urlError in
            urlError.failingURL ?? urlError.userInfo[NSURLErrorFailingURLErrorKey] as? URL
        }
        if WebLoginRedirectPolicy.isDeadEnd(target: failingURL, configuredHost: configuredHost) {
            return .deadEndRedirect(host: failingURL?.host ?? "")
        }
        return .unreachable
    }
}
