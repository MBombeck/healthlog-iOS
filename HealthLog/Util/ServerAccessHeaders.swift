import Foundation

/// One extra HTTP header the app sends to the configured HealthLog server.
///
/// GH-iOS #27: a self-hosted instance behind a zero-trust proxy (Cloudflare
/// Access, Pangolin, an nginx `auth_request` gate) only lets a request reach
/// the origin when it carries the proxy's service credentials. Until 1.4.1 the
/// app could only take them from `Info.plist`, so the distributed build had no
/// way in, and the Cloudflare secret travelled under the wrong name
/// (`cf-access-client-token` instead of `CF-Access-Client-Secret`).
public struct ServerAccessHeader: Codable, Equatable, Hashable, Sendable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// The per-install list of extra headers, stored as JSON in the Keychain.
///
/// Per install, not per account: the proxy sits in front of the server, so the
/// headers are needed before anyone has signed in (onboarding's
/// `registration-status` probe is the first request that must get through).
///
/// The headers are attached only where a request targets the configured
/// server (`APIClient`, the health and web-login probes, the onboarding and
/// settings reachability probe). Requests to anything else (BYO model
/// providers, WHOOP, learn-more links) never see them, and a redirect to a
/// different host strips them (`PinningDelegate`).
public enum ServerAccessHeaders {
    /// Upper bound on how many headers one install can carry. Proxies need one
    /// or two; the cap keeps a pasted mistake from bloating every request.
    public static let maximumCount = 8
    static let maximumNameLength = 64
    static let maximumValueLength = 4096

    /// Header names the app itself owns or the transport manages. Letting a
    /// user header override them would break auth, idempotency or framing.
    /// `origin` and `referer` (#151): the server's cross-site write guard
    /// reads them, and a user header of that name could trip it.
    static let reservedNames: Set<String> = [
        "accept", "accept-encoding", "authorization", "connection",
        "content-length", "content-type", "cookie", "host", "idempotency-key",
        "keep-alive", "origin", "proxy-authorization", "proxy-connection",
        "referer", "te", "trailer", "transfer-encoding", "upgrade", "user-agent",
        "x-client-type", "x-device-id"
    ]

    /// Ready-made name pairs for the proxies people actually ask about.
    public enum Preset: String, CaseIterable, Sendable {
        case cloudflareAccess
        case pangolin

        public var headerNames: [String] {
            switch self {
            case .cloudflareAccess: ["CF-Access-Client-Id", "CF-Access-Client-Secret"]
            case .pangolin: ["P-Access-Token-Id", "P-Access-Token"]
            }
        }
    }

    public enum ValidationError: Error, Equatable, Sendable {
        case emptyName(index: Int)
        case invalidName(index: Int)
        case reservedName(index: Int)
        case duplicateName(index: Int)
        case emptyValue(index: Int)
        case invalidValue(index: Int)
        case tooMany
    }

    // MARK: - Validation

    /// Trims every entry, drops rows the user left completely empty and checks
    /// the rest. Returns the list exactly as it will be stored and sent.
    public static func normalized(_ headers: [ServerAccessHeader]) throws -> [ServerAccessHeader] {
        var seen = Set<String>()
        var result: [ServerAccessHeader] = []
        for (index, raw) in headers.enumerated() {
            let name = raw.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = raw.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty, value.isEmpty { continue }
            guard !name.isEmpty else { throw ValidationError.emptyName(index: index) }
            guard isValidName(name) else { throw ValidationError.invalidName(index: index) }
            let lower = name.lowercased()
            guard !isReserved(lower) else { throw ValidationError.reservedName(index: index) }
            guard seen.insert(lower).inserted else { throw ValidationError.duplicateName(index: index) }
            guard !value.isEmpty else { throw ValidationError.emptyValue(index: index) }
            guard isValidValue(value) else { throw ValidationError.invalidValue(index: index) }
            result.append(ServerAccessHeader(name: name, value: value))
        }
        guard result.count <= maximumCount else { throw ValidationError.tooMany }
        return result
    }

    /// RFC 9110 `token`: visible ASCII without separators.
    static func isValidName(_ name: String) -> Bool {
        guard (1 ... maximumNameLength).contains(name.count) else { return false }
        let allowed = Set("!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        return name.allSatisfy { allowed.contains($0) }
    }

    /// Visible ASCII and inner spaces only. Rejecting CR, LF and every other
    /// control character is what keeps a pasted value from splitting the
    /// request into a second header.
    static func isValidValue(_ value: String) -> Bool {
        guard (1 ... maximumValueLength).contains(value.utf8.count) else { return false }
        return value.unicodeScalars.allSatisfy { (0x20 ... 0x7E).contains($0.value) }
    }

    static func isReserved(_ lowercasedName: String) -> Bool {
        reservedNames.contains(lowercasedName)
            || lowercasedName.hasPrefix("sec-")
            || lowercasedName.hasPrefix("proxy-")
    }

    // MARK: - Persistence

    /// Reads the stored list. A missing, unreadable or no-longer-valid entry
    /// reads as "no headers": a request without them fails at the proxy with a
    /// clear status, which beats sending something malformed.
    ///
    /// One exception, for installs that stored a list before a name became
    /// reserved (1.4.1 accepted `Origin` and `Referer`): such an entry is left
    /// out and the rest still travels, so the update does not silently drop a
    /// working Cloudflare pair. The entry goes away with the next save.
    public static func load(keychain: KeychainStoring) -> [ServerAccessHeader] {
        guard let json = keychain.getString(forKey: KeychainKey.serverAccessHeaders),
              let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([ServerAccessHeader].self, from: data),
              let valid = try? normalized(decoded.filter { !isReservedStoredName($0.name) }) else
        {
            return []
        }
        return valid
    }

    private static func isReservedStoredName(_ name: String) -> Bool {
        isReserved(name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// Validates and stores `headers`; an empty list removes the entry.
    /// - Returns: the list as stored.
    @discardableResult
    public static func save(_ headers: [ServerAccessHeader], keychain: KeychainStoring) throws -> [ServerAccessHeader] {
        let valid = try normalized(headers)
        if valid.isEmpty {
            try keychain.remove(forKey: KeychainKey.serverAccessHeaders)
            return []
        }
        let data = try JSONEncoder().encode(valid)
        guard let json = String(data: data, encoding: .utf8) else { throw KeychainError.encoding }
        try keychain.setString(json, forKey: KeychainKey.serverAccessHeaders)
        return valid
    }

    // MARK: - Requests

    /// Sets every header on `request`. Values replace anything already there
    /// under the same name, so a stored Cloudflare pair wins over the
    /// build-time `Info.plist` one.
    public static func apply(_ headers: [ServerAccessHeader], to request: inout URLRequest) {
        for header in headers {
            request.setValue(header.value, forHTTPHeaderField: header.name)
        }
    }

    /// Header fields that may follow a redirect to a different host. Anything
    /// else on the request (bearer, device id, idempotency key, proxy
    /// credentials) stays with the server the user configured.
    static let crossHostRedirectAllowlist: Set<String> = [
        "accept", "accept-language", "content-type", "user-agent", "x-client-type"
    ]

    /// The request URLSession is about to follow, with every credential-bearing
    /// header removed when the redirect leaves the original host or port.
    /// A same-host redirect (including http to https) passes unchanged.
    public static func redirectRequest(original: URLRequest?, proposed: URLRequest) -> URLRequest {
        guard let from = original?.url, let to = proposed.url,
              !isSameHost(from, to) else
        {
            return proposed
        }
        var stripped = proposed
        for name in (proposed.allHTTPHeaderFields ?? [:]).keys
            where !crossHostRedirectAllowlist.contains(name.lowercased())
        {
            stripped.setValue(nil, forHTTPHeaderField: name)
        }
        return stripped
    }

    /// Same host and same explicit port. Scheme is ignored on purpose: an
    /// http to https upgrade on the same host is the one redirect that must
    /// keep its headers.
    static func isSameHost(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let lhsHost = lhs.host?.lowercased(), let rhsHost = rhs.host?.lowercased() else {
            return false
        }
        return lhsHost == rhsHost && lhs.port == rhs.port
    }
}
