import Foundation
#if canImport(AuthenticationServices)
    import AuthenticationServices
#endif

/// SEC (1.5, #151) — the way the native SSO leg comes back into the app.
///
/// **Today every sign-in takes the custom scheme** (`healthlog://oidc-callback`),
/// and that is the only way that works against any released server:
/// - The server compiles its native redirect in
///   (`NATIVE_OIDC_REDIRECT_URI = "healthlog://oidc-callback"`,
///   `src/lib/auth/oidc-native-handoff.ts`, read at v1.47.0) and never sends
///   the code to an `https` address. A session waiting for an `https` return
///   would never see the scheme redirect and the sign-in would hang.
/// - The shipped build carries no Associated Domains on purpose: a client for
///   self-hosted servers cannot name one operator's domain without disclosing
///   and privileging it (`project.yml`, `AppReviewConfigurationTests`). An
///   `https` callback needs its host to be one of the app's associated
///   domains (`ASWebAuthenticationSession.Callback.https(host:path:)`), so a
///   server under its own domain can never use it with this build.
///
/// The `https` return is taken only when all of these hold: the configured
/// server is `https`, its host is one the build associates with
/// (``bundleHosts(_:)``, the Info.plist mirror `HLAppLinkHosts` an operator's
/// own build sets next to its `applinks:`/`webcredentials:` entries), and the
/// server names the path it returns to (`serverReturnPath`; no released server
/// does, see the SEC report for the request). Anything else, and every
/// unknown, stays on the scheme with PKCE, as before.
///
/// What the `https` return adds: a scheme can be registered by any app, a
/// verified domain only by the app its AASA names, so nothing else on the
/// device can be handed the URL. The PKCE verifier still guards the code on
/// both ways; `ASWebAuthenticationSession` matches the callback inside its own
/// browser session either way, the system never routes it to another app.
public enum OidcReturnRoute: Sendable, Equatable {
    /// `healthlog://oidc-callback?…` — every released server.
    case customScheme(String)
    /// `https://<server host><path>?…` — only for an associated host whose
    /// server announced the path.
    case https(host: String, path: String)

    /// The scheme every sign-in falls back to.
    public static let scheme = OidcReturnRoute.customScheme(OidcNativeFlow.callbackScheme)

    /// Info.plist key with the hosts this build associates with. Absent in the
    /// shipped build; set only by an operator overlay (`Config/local.yml`).
    public static let infoPlistKey = "HLAppLinkHosts"

    /// The login query parameter that asks a server for the `https` return.
    /// Sent only with ``https(host:path:)``; a server that does not know it
    /// ignores it, and the app only sends it to a server that announced it.
    static let returnQueryItem = URLQueryItem(name: "return", value: "https")

    /// Decides the return for a sign-in against `serverURL`.
    public static func resolve(
        serverURL: URL?,
        appLinkHosts: [String] = OidcReturnRoute.bundleHosts(),
        serverReturnPath: String?
    ) -> OidcReturnRoute {
        guard let serverURL,
              serverURL.scheme?.lowercased() == "https",
              let host = serverURL.host?.lowercased(), !host.isEmpty,
              serverURL.port == nil || serverURL.port == 443,
              appLinkHosts.contains(where: { $0.lowercased() == host }),
              let path = serverReturnPath, isSafePath(path) else { return scheme }
        return .https(host: host, path: path)
    }

    /// The hosts the running build associates with (`HLAppLinkHosts`).
    public static func bundleHosts(_ bundle: Bundle = .main) -> [String] {
        (bundle.object(forInfoDictionaryKey: infoPlistKey) as? [String]) ?? []
    }

    /// A plain absolute path: no query, fragment, dot segments or anything a
    /// server could use to point the return somewhere else.
    static func isSafePath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.count <= 128, !path.contains("//") else { return false }
        let segments = path.split(separator: "/")
        guard !segments.contains(where: { $0 == "." || $0 == ".." }) else { return false }
        return path.unicodeScalars.allSatisfy { scalar in
            (scalar.isASCII && CharacterSet.alphanumerics.contains(scalar)) || "/-_.".unicodeScalars.contains(scalar)
        }
    }

    /// The custom scheme, `nil` for the `https` return.
    public var customScheme: String? {
        if case let .customScheme(scheme) = self { return scheme }
        return nil
    }

    #if canImport(AuthenticationServices)
        /// What the session matches the return against.
        public var sessionCallback: ASWebAuthenticationSession.Callback {
            switch self {
            case let .customScheme(scheme): .customScheme(scheme)
            case let .https(host, path): .https(host: host, path: path)
            }
        }
    #endif
}
