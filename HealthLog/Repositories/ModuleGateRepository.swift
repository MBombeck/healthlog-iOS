import Foundation

/// Thin projection of the `GET /api/auth/me` payload — only the `modules` map
/// (server brief #30, v1.18.0). Decoupled from `UserProfile` so an unrelated
/// `/me` schema change can't break the module load, mirroring `AuthMeAvatar`.
///
/// **Decode-tolerant:** a server that omits `modules` (prod ≤ v1.17.1, the #30
/// deploy is "in flight") yields `nil` rather than a decode error. `nil` means
/// "all modules on" downstream (``ModuleGate.isEnabled(_:)``).
public struct AuthMeModules: Decodable, Sendable, Equatable {
    public let modules: [String: Bool]?
    /// **CU-20 (#69) — optimistic-concurrency token.** Echoed as
    /// `baseUpdatedAt` on the next PATCH; a stale one yields
    /// `409 modules_conflict` and nothing is written. Guards the shared
    /// `User.updatedAt` (`api/auth/me/modules/route.ts:128`).
    ///
    /// Present on `GET /api/auth/me/modules` and on the PATCH echo. **Absent on
    /// `GET /api/auth/me`**, which is where ``ModuleGateRepository/fetchModules()``
    /// reads the map from — so the token is bootstrapped from the PATCH echo
    /// (or from an explicit re-read after a 409), and the very first write of a
    /// session goes out unconditional. That is the documented, permanently
    /// supported backward-compat arm (`optimistic-lock.ts:101-103`).
    public let updatedAt: String?

    public init(modules: [String: Bool]?, updatedAt: String? = nil) {
        self.modules = modules
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modules = try container.decodeIfPresent([String: Bool].self, forKey: .modules)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case modules
        case updatedAt
    }
}

/// Request body for `PATCH /api/auth/me/modules` (v1.18.1 §4 Q3). A **per-key**
/// `{ <moduleKey>: boolean }` patch — NOT a `disabled: [key]` allowlist. The
/// server merges it field-by-field into the persisted DISABLED set and is
/// `strict()` over the toggleable key space: a CORE key
/// (weight/bloodPressure/pulse/medications), a DELEGATED key (cycle/coach) or
/// any unknown key → `422 modules.invalid`. The client must therefore send
/// **only** user-toggleable keys (`ModuleGate.setEnabled` enforces this).
///
/// Encodes as a flat object so a `["illness": true]` payload serialises to
/// `{"illness":true}` — the exact per-key shape the server validates.
public struct ModulesPatchDTO: Encodable, Sendable, Equatable {
    public let changes: [String: Bool]

    public init(changes: [String: Bool]) {
        self.changes = changes
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: WireKey.self)
        for (key, value) in changes {
            // swiftlint:disable:next force_unwrapping
            try container.encode(value, forKey: WireKey(stringValue: key)!)
        }
    }

    /// Dynamic coding key so the module wire-keys become top-level JSON fields.
    private struct WireKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil

        init?(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue _: Int) {
            nil
        }
    }
}

/// Server-owned per-user module map. Wraps the two `/api/auth/me/modules`-
/// adjacent verbs:
///
/// - `GET  /api/auth/me`         — resolved `modules` map (read).
/// - `PATCH /api/auth/me/modules` — set the disabled-allowlist (write).
///
/// **Fail-open:** ``ModuleGate`` treats a fetch failure as "all modules on",
/// so a transient network blip never hides a valid surface. The server is the
/// final gate (403 `module.disabled` on a disabled route).
public actor ModuleGateRepository {
    private let api: APIClientProtocol

    /// **CU-20 (#69)** — last `updatedAt` seen from the modules surface (the
    /// PATCH echo, or the dedicated `GET /api/auth/me/modules` re-read after a
    /// conflict). `nil` until the first of those lands, which makes a session's
    /// first PATCH unconditional — the permanently supported arm.
    private var baseUpdatedAt: String?

    public init(api: APIClientProtocol) {
        self.api = api
    }

    /// Test/diagnostic accessor for the currently held concurrency token.
    public func currentModulesToken() -> String? {
        baseUpdatedAt
    }

    /// Fetch the resolved per-user module map from `GET /api/auth/me`. Returns
    /// `nil` when the server omits the field (older server) — the gate then
    /// defaults to all-on.
    public func fetchModules() async throws -> [String: Bool]? {
        let req: APIRequest<AuthMeModules> = .get("/api/auth/me")
        return try await api.send(req).modules
    }

    /// Apply a per-key module patch (v1.18.1 §4 Q3) and return the
    /// server-confirmed resolved map (the server echoes the full freshly-resolved
    /// `modules` map after applying the patch). `changes` MUST contain only
    /// user-toggleable keys — a CORE/DELEGATED/unknown key would `422`.
    @discardableResult
    public func updateModules(changes: [String: Bool]) async throws -> [String: Bool] {
        let body = ModulesPatchDTO(changes: changes)
        return try await withOptimisticConflictRetry(
            conflictCode: OptimisticConflictCode.modules,
            token: baseUpdatedAt
        ) { token in
            let req: APIRequest<AuthMeModules> = try .patch(
                "/api/auth/me/modules",
                body: OptimisticWriteBody(payload: body, baseUpdatedAt: token)
            )
            let echoed = try await api.send(req)
            baseUpdatedAt = echoed.updatedAt
            return echoed.modules ?? [:]
        } reread: {
            // The patch is per-key and the server merges it field-by-field, so
            // the pending change stays correct against the refreshed state —
            // only the token needs refreshing. Note this re-reads the DEDICATED
            // modules route, not `GET /api/auth/me`, because only the former
            // carries `updatedAt`.
            try await fetchModulesToken()
        }
    }

    /// **CU-20 (#69)** — re-read the token from `GET /api/auth/me/modules`
    /// after a conflict. Distinct from ``fetchModules()``, which reads the map
    /// off `GET /api/auth/me` (a route that carries no `updatedAt`).
    private func fetchModulesToken() async throws -> String? {
        let req: APIRequest<AuthMeModules> = .get("/api/auth/me/modules")
        let fresh = try await api.send(req)
        baseUpdatedAt = fresh.updatedAt
        return fresh.updatedAt
    }
}
