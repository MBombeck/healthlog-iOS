import Foundation

// **Build 9 (Server-Prefs)** — the `/api/auth/me` server-pref projection + the
// `/api/auth/me/unit-preference` wire seam, split out of
// `DashboardRepository.swift` (where the `SettingsRepository` actor lives) to
// keep that file under the length budget. Pure additive extension — no behaviour
// of the existing repo methods changes here.

public extension SettingsRepository {
    /// **Build 9 (Server-Prefs)** — thin, tolerant projection of `GET /api/auth/me`
    /// carrying the four server-owned preference inputs the settings mirrors need
    /// (`unitPreference`, `glucoseUnit`, `disableCoach`, `cycleTrackingEnabled`)
    /// plus `avatarUrl`. Every field is `decodeIfPresent`-tolerant: an older
    /// server that omits a field decodes it to `nil` (the caller keeps its mirror /
    /// default) rather than throwing. The `unitPreference` / `cycleTrackingEnabled`
    /// values are the server-**resolved** ones (never the raw DB `null`) — see the
    /// plan §0.2/§0.3.1.
    func authMeServerPrefs() async throws -> AuthMeServerPrefs {
        let req: APIRequest<AuthMeServerPrefs> = .get("/api/auth/me")
        return try await api.send(req)
    }

    // MARK: - unit-preference (9.1)

    /// `GET /api/auth/me/unit-preference` → the resolved `"metric" | "imperial"`
    /// binary. The server blends a DB `null` to `"metric"`, so the raw wire value
    /// is never observable here (plan §0.3.1). Tolerant: a missing field resolves
    /// to `"metric"` rather than throwing.
    func unitPreference() async throws -> String {
        let req: APIRequest<UnitPreferenceDTO> = .get("/api/auth/me/unit-preference")
        return try await api.send(req).unitPreference
    }

    /// `PATCH /api/auth/me/unit-preference` with `{ "unitPreference": … }`; the
    /// route echoes the persisted value, which the caller hard-sets. Only ever
    /// called from an explicit user toggle or the one flag-guarded 9.1 migration —
    /// never from hydration (no ping-pong, no initial write).
    @discardableResult
    func setUnitPreference(_ value: String) async throws -> String {
        let req: APIRequest<UnitPreferenceDTO> = try .patch(
            "/api/auth/me/unit-preference",
            body: UnitPreferenceWrite(unitPreference: value)
        )
        return try await api.send(req).unitPreference
    }
}

/// **Build 9 (Server-Prefs)** — thin, tolerant projection of `GET /api/auth/me`
/// carrying the server-owned preference inputs the settings mirrors adopt on
/// hydration, plus `avatarUrl` (so one round-trip serves both the avatar splice
/// and the pref mirrors). Every field is optional + `decodeIfPresent`: an older
/// server that never learned a field decodes it to `nil`, and the consuming
/// store keeps its existing mirror / default (tolerant-decode contract). The
/// projection deliberately stays thin — an unrelated `/me` schema change must
/// not break the profile/settings load (five established precedents).
public struct AuthMeServerPrefs: Decodable, Sendable, Equatable {
    public let avatarUrl: String?
    /// `"metric" | "imperial"` — resolved binary (never the raw DB `null`).
    public let unitPreference: String?
    /// `"mg/dL" | "mmol/L" | nil` — read-only context (its own server column;
    /// no iOS write-path in Build 9, plan §0.3.2).
    public let glucoseUnit: String?
    /// Server-wide "coach unavailable" flag (default `false`).
    public let disableCoach: Bool?
    /// Server-**resolved** cycle-tracking flag (never `null` on the wire).
    public let cycleTrackingEnabled: Bool?
    /// **CU-01** — the owner's saved report profile, mirrored **read-only** onto
    /// `/api/auth/me` (server v1.32.39, `reportSelection: reportSelectionJson ??
    /// null`). Writes go exclusively through
    /// ``ReportSelectionRepository/replace(_:)`` on
    /// `PUT /api/auth/me/report-selection`; this is only a free ride on a
    /// round-trip the settings hydration already makes, so a consumer does not
    /// need a second GET just to learn whether a scope was ever chosen.
    ///
    /// Three-state on purpose: the key **absent** (older server, or a
    /// projection that never asked) and an explicit **`null`** (this account has
    /// never saved a profile) both decode to `nil`; only a well-formed v2 blob
    /// decodes to a value. Decoding is fail-soft — a blob this build cannot read
    /// resolves to `nil` rather than throwing, because an unrelated
    /// report-selection schema drift must never take down the profile/settings
    /// load (the same tolerant-decode contract the fields above carry).
    public let reportSelection: SavedReportProfile?
    /// **CU-35 (2)** — the practice name the account most recently generated a
    /// health report for (server v1.32.35; before that the column was `null`
    /// for every account, so a client reading it saw nothing).
    ///
    /// **Last-used, NOT per-device.** Whoever generated the most recent report
    /// wins — the web session, the iPad, this iPhone. That is exactly why it is
    /// only ever an *optional prefill* and never an authority: it can be stale,
    /// it can belong to a different visit, and it must never silently replace
    /// something the person is in the middle of typing. See
    /// ``ReportPracticeNameStore`` for the rule that enforces that.
    ///
    /// `nil` covers all three honest absences — key omitted (older server),
    /// explicit `null` (never generated a report), and an empty string.
    public let lastReportPracticeName: String?

    public init(
        avatarUrl: String?,
        unitPreference: String?,
        glucoseUnit: String?,
        disableCoach: Bool?,
        cycleTrackingEnabled: Bool?,
        reportSelection: SavedReportProfile? = nil,
        lastReportPracticeName: String? = nil
    ) {
        self.avatarUrl = avatarUrl
        self.unitPreference = unitPreference
        self.glucoseUnit = glucoseUnit
        self.disableCoach = disableCoach
        self.cycleTrackingEnabled = cycleTrackingEnabled
        self.reportSelection = reportSelection
        self.lastReportPracticeName = lastReportPracticeName
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        avatarUrl = try c.decodeIfPresent(String.self, forKey: .avatarUrl)
        unitPreference = try c.decodeIfPresent(String.self, forKey: .unitPreference)
        glucoseUnit = try c.decodeIfPresent(String.self, forKey: .glucoseUnit)
        disableCoach = try c.decodeIfPresent(Bool.self, forKey: .disableCoach)
        cycleTrackingEnabled = try c.decodeIfPresent(Bool.self, forKey: .cycleTrackingEnabled)
        reportSelection = try? c.decodeIfPresent(SavedReportProfile.self, forKey: .reportSelection)
        // An empty / whitespace-only value is the same absence as a `null`: it
        // is not a practice name and must never be prefilled as one.
        let practice = try c.decodeIfPresent(String.self, forKey: .lastReportPracticeName)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        lastReportPracticeName = (practice?.isEmpty ?? true) ? nil : practice
    }

    private enum CodingKeys: String, CodingKey {
        case avatarUrl, unitPreference, glucoseUnit, disableCoach, cycleTrackingEnabled
        case reportSelection, lastReportPracticeName
    }
}

/// Wire shape for `GET / PATCH /api/auth/me/unit-preference`
/// (`{ "unitPreference": "metric" | "imperial" }`). Tolerant decode: a missing
/// field resolves to `"metric"` (the server's own blend of a DB `null`).
public struct UnitPreferenceDTO: Decodable, Sendable, Equatable {
    public let unitPreference: String

    public init(unitPreference: String) {
        self.unitPreference = unitPreference
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        unitPreference = try c.decodeIfPresent(String.self, forKey: .unitPreference) ?? "metric"
    }

    private enum CodingKeys: String, CodingKey {
        case unitPreference
    }
}

/// PATCH body for `/api/auth/me/unit-preference` — the single enum the server's
/// zod guard validates (`["metric", "imperial"]`).
public struct UnitPreferenceWrite: Encodable, Sendable {
    public let unitPreference: String

    public init(unitPreference: String) {
        self.unitPreference = unitPreference
    }
}
