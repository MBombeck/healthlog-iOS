import Foundation

/// Wire shape for `GET` / `PATCH /api/auth/me/injection-site-prefs` (server
/// v1.8.5). Carries the user-level global injection-site **deny-list** — a
/// site the user globally excluded is never valid for ANY medication, even
/// one that lists it as preferred (deny always wins in the effective-set
/// computation).
///
/// `globalExcludedInjectionSites` holds the server enum strings
/// (`ABDOMEN_LEFT`, …). Default-tolerant: an older server / empty list
/// decodes as `[]`.
public struct InjectionSitePrefsDTO: Codable, Sendable, Hashable {
    public let globalExcludedInjectionSites: [String]

    public init(globalExcludedInjectionSites: [String]) {
        self.globalExcludedInjectionSites = globalExcludedInjectionSites
    }

    /// Decode-tolerant: a server that omits the key (older build) yields an
    /// empty deny-list rather than a decode error.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        globalExcludedInjectionSites = try container.decodeIfPresent(
            [String].self,
            forKey: .globalExcludedInjectionSites
        ) ?? []
    }
}

/// Server-owned user-level injection-site deny-list. Wraps the two
/// `/api/auth/me/injection-site-prefs` verbs:
///
/// - `GET`   — current deny-list.
/// - `PATCH` — **hard-sets** the deny-list (empty array clears it). 60/min.
///
/// **Fail-open:** the picker treats a fetch failure as "no global excludes"
/// so a transient network blip never hides a valid site. The server is the
/// final gate (422 on an out-of-set submit), so an over-broad local effective
/// set degrades to a graceful re-fetch, never silent data loss.
public actor InjectionSitePrefsRepository {
    private let api: APIClientProtocol

    public init(api: APIClientProtocol) {
        self.api = api
    }

    /// Fetch the current deny-list as local ``InjectionSite`` cases. Unknown
    /// server strings are dropped (forward-compat).
    public func fetch() async throws -> [InjectionSite] {
        let req: APIRequest<InjectionSitePrefsDTO> = .get("/api/auth/me/injection-site-prefs")
        let dto = try await api.send(req)
        return dto.globalExcludedInjectionSites.compactMap(InjectionSite.parse)
    }

    /// Hard-set the deny-list. The PATCH replaces the full list server-side;
    /// an empty array clears it. Returns the server-confirmed list.
    @discardableResult
    public func update(excluded: [InjectionSite]) async throws -> [InjectionSite] {
        let body = InjectionSitePrefsDTO(
            globalExcludedInjectionSites: excluded.map(\.serverRawValue)
        )
        let req: APIRequest<InjectionSitePrefsDTO> = try .patch(
            "/api/auth/me/injection-site-prefs",
            body: body
        )
        let dto = try await api.send(req)
        return dto.globalExcludedInjectionSites.compactMap(InjectionSite.parse)
    }
}
