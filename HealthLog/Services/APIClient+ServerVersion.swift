import Foundation

// MARK: - Server version

/// Public `/api/version` payload — surfaces in Settings → Server's
/// "Server-Version"-Karte. The server route lives at
/// `src/app/api/version/route.ts` (`apiSuccess({ version, buildSha,
/// builtAt, license, repository, changelog, docs, offlineGeoEnabled })`).
/// We decode the three fields the iOS UI consumes and ignore the rest
/// so future server additions don't break the decoder.
public struct ServerVersionInfo: Decodable, Sendable, Equatable {
    /// `package.json` version string, e.g. `"1.4.39"`. Always present.
    public let version: String
    /// Short Git SHA baked into the production image at build time.
    /// `nil` in development (`pnpm dev`) — the route returns `null` then.
    public let buildSha: String?
    /// ISO-8601 build timestamp, baked alongside `buildSha`. Same
    /// nil-on-dev semantics.
    public let builtAt: String?

    public init(version: String, buildSha: String? = nil, builtAt: String? = nil) {
        self.version = version
        self.buildSha = buildSha
        self.builtAt = builtAt
    }
}

public extension ServerVersionInfo {
    /// Parses a dotted-integer version (`"1.32.9"`) into numeric components,
    /// stopping at the first non-numeric fragment (drops any `-rc.1` / build
    /// suffix). A leading `v` is tolerated. Returns `[]` on a wholly
    /// unparseable string so a comparison degrades to "not known ≥ target"
    /// (fail-closed for a feature gate) rather than crashing.
    static func components(_ raw: String) -> [Int] {
        let trimmed = raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
        var out: [Int] = []
        for part in trimmed.split(separator: ".") {
            // Cut a trailing pre-release/build suffix off the numeric head
            // (e.g. "3-rc.1" → 3). An empty numeric head ends the parse.
            let head = part.prefix { $0.isNumber }
            guard let n = Int(head), !head.isEmpty else { break }
            out.append(n)
        }
        return out
    }

    /// Whether `version` is greater than or equal to `target` (dotted-integer
    /// semver, component-wise — so `1.32.9 ≥ 1.9.0` is `true`, which a lexical
    /// or `.numeric` string compare gets wrong). Missing trailing components are
    /// treated as `0` (`"1.32" ≥ "1.32.0"`). An unparseable running version
    /// fails closed (returns `false`).
    func isAtLeast(_ target: String) -> Bool {
        let lhs = Self.components(version)
        let rhs = Self.components(target)
        guard !lhs.isEmpty else { return false }
        let count = max(lhs.count, rhs.count)
        for i in 0 ..< count {
            let l = i < lhs.count ? lhs[i] : 0
            let r = i < rhs.count ? rhs[i] : 0
            if l != r { return l > r }
        }
        return true
    }
}

public enum TwoFactorManagement {
    /// The server version at which the native 2FA-management surface (step-up
    /// elevation contract) landed. Below this, self-hosted instances keep the
    /// honest "manage 2FA on the web" card. Verified live in server v1.32.9,
    /// announced for v1.32.3 (`REST-PLAN.md` §1 / OpenAPI).
    public static let minimumServerVersion = "1.32.3"

    /// Whether the given server build exposes the native 2FA-management routes.
    public static func isAvailable(on server: ServerVersionInfo) -> Bool {
        server.isAtLeast(minimumServerVersion)
    }
}

public enum WebHandoffLogin {
    /// #65 — the server version at which the native web-handoff login contract
    /// (`/api/auth/native/login` → `/complete` → `/token`, PKCE-S256) landed.
    /// Below this a self-hosted instance has no such endpoints, so the app must
    /// keep the native password form rather than opening a web sheet that would
    /// 404. Frozen live in v1.32.11 (#65 plan / REST-PLAN §1).
    public static let minimumServerVersion = "1.32.11"

    /// Whether the given server build exposes the web-handoff login routes.
    /// `isAtLeast` itself fails closed on an unparseable running version.
    public static func isAvailable(on server: ServerVersionInfo) -> Bool {
        server.isAtLeast(minimumServerVersion)
    }
}

public enum MedicationSlotMaterialization {
    /// audit-v0162 M-7 — the server version from which `GET /api/medications
    /// /intake?scope=today` (and `/api/dashboard/summary`) **materialise every
    /// one of today's dose slots** as real `MedicationIntakeEvent` rows before
    /// answering. From here on the client's own slot synthesis
    /// (`MedicationsStore.deriveTodayIntakes`) is redundant — and harmful,
    /// because a server slot whose `scheduledFor` diverges >5 min from the
    /// client projection escapes the ±5-min dedup and lands ALONGSIDE the real
    /// row (inflated "N offen", phantom overdue ring dose, inflated badge).
    ///
    /// **Why 1.8.1 and not the 1.15.17 PROJECT_GUIDE.md names.** v1.15.18 is where the
    /// *dose-history ledger* landed ("a traceable medication dose history") —
    /// that is the boundary for the compliance/history contract the PROJECT_GUIDE.md
    /// bullet is really about, and the slot-derivation sentence was attached to
    /// it by proximity, not by evidence. The slot **materialisation** boundary
    /// is older and verifiable in the server tree:
    ///
    /// - pre-v1.4.41 — both today-routes already projected + `createMany`'d the
    ///   missing rows inline; v1.4.41 folded the two copies into
    ///   `src/lib/medications/scheduling/project-today-intakes.ts`.
    /// - v1.6.0 — every "does this schedule emit today?" decision routed
    ///   through the canonical recurrence engine, so `intervalWeeks > 1`,
    ///   rolling, RRULE and one-shot cadences stopped being skipped.
    /// - v1.7.0 — PRN short-circuits to zero slots, CYCLIC gates on the
    ///   on/off-week phase.
    /// - **v1.8.1** (`fcb517df8`, "fan out the today-tile projector over every
    ///   time-of-day") — the projector stopped minting a single row at
    ///   `windowStart` and now emits one row per `timesOfDay` entry. This was
    ///   the last gap: before it, a twice-daily Lisinopril surfaced only its
    ///   morning dose — which is exactly the operator pain that made iOS
    ///   synthesise placeholders in the first place (TestFlight build 21,
    ///   2026-05-21, against a ~v1.4.41 server).
    ///
    /// So v1.8.1 is the first build on which the server answers with the FULL
    /// set of today's slots for every cadence. Picking the (higher) 1.15.18
    /// instead would leave synthesis switched on for v1.8.1…v1.15.17 servers
    /// that already materialise — i.e. exactly the double-count this gate
    /// exists to stop.
    public static let minimumServerVersion = "1.8.1"

    /// Whether the given server build materialises today's dose slots itself.
    /// `isAtLeast` fails closed on an unparseable running version — see
    /// ``MedicationSlotMaterializationGate`` for what "closed" costs here.
    public static func isAvailable(on server: ServerVersionInfo) -> Bool {
        server.isAtLeast(minimumServerVersion)
    }
}

public extension APIClientProtocol {
    /// Fetches the running server build's version + SHA + built-at via
    /// the public `GET /api/version` endpoint (unauthenticated). Used by
    /// Settings → Server to display "Version: vX.Y.Z" alongside the
    /// host the operator currently targets.
    ///
    /// Returns the decoded `ServerVersionInfo` on 2xx. Throws the usual
    /// `HLError` shape on transport / decoding failure so the UI can
    /// surface a "Version nicht ermittelbar" retry affordance without
    /// special-casing the call site.
    func fetchServerVersion() async throws -> ServerVersionInfo {
        let req: APIRequest<ServerVersionInfo> = .get("/api/version")
        return try await send(req)
    }
}
