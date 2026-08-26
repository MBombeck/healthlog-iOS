import Foundation

/// Server-authoritative feature-module keys (server brief #30, v1.18.0).
///
/// `GET /api/auth/me` returns a `modules: { <key>: boolean }` map that resolves
/// per-user which optional feature modules are switched on. The map is the
/// **single source of truth** — iOS never re-derives module state locally
/// (the lone exception is the cycle gate, which keeps its gender/opt-in
/// resolution as a *fallback* for servers that do not yet ship the map).
///
/// **Semantics (server brief #30 / v1.18.1 §4 Q5; v1.18.3):**
/// - key present + `false`  → module is OFF (hide the surface).
/// - key absent OR `true`   → module is ON (default-on).
///
/// Every toggleable key follows the same default-ON rule. (`illness` was a
/// born-gated default-OFF exception through v1.18.2; v1.18.3 dropped the
/// born-gating and made it a normal default-ON toggle — see the addendum.)
///
/// The cases below mirror the server registry's `MODULE_KEYS`
/// (`src/lib/modules/registry.ts`) **1:1** — 18 keys. The only always-on CORE
/// domains are `weight` / `bloodPressure` / `pulse`, and those are *not*
/// `ModuleKey`s at all (server `CORE_DOMAIN_KEYS`); they never appear in the
/// map and have no case here.
///
/// `medications` graduated from CORE to a real user toggle server-side
/// (registry D3, web v1.18.1) — it is a normal toggleable key now. The
/// ``coreNonToggleable`` set that used to pre-stage it is consequently empty.
///
/// `cycle` and `coach` are already folded into the server map (per #30) — the
/// app still keeps the richer `CycleGate` gender/opt-in resolution as a
/// fallback when the map is absent (older server).
///
/// **Drift guard:** ``ModuleKeyServerRegistryFixture`` (tests) pins this set
/// against a checked-in copy of the server registry's advertised keys. iOS fell
/// three keys behind twice before that guard existed — extend the fixture in
/// the same commit whenever the server adds a module.
public enum ModuleKey: String, CaseIterable, Sendable, Identifiable {
    case cycle
    case mood
    case sleep
    case glucose
    case workouts
    case recovery
    case labs
    case achievements
    case coach
    case insights
    case doctorReport
    /// Condition/symptom journal. Default-ON since v1.18.3 (the born-gating was
    /// dropped — absent/`true` → ON, like every other toggleable key). A user
    /// can still disable it; the operator availability override is unchanged.
    case illness
    /// Inbound document vault ("Dokumente"). Opt-in module — the server ships it
    /// OFF by default (`inboundDocuments`). The whole vault surface + the illness
    /// episode-documents card gate on this key; every `/api/documents/inbound*`
    /// route 403s with `meta.errorCode: "module.disabled"` +
    /// `meta.module: "inboundDocuments"` when it is off. Wire key == rawValue.
    case inboundDocuments
    /// Micronutrient daily-totals sync (GH #48, server v1.28). Opt-in module —
    /// the server ships it OFF by default (`nutrients`). Gates the HealthKit
    /// `Dietary*` vitamin/mineral/water/caffeine sync: read-authorization is only
    /// requested and day-totals are only posted while this key is ON. Every
    /// `/api/nutrients*` route 403s with `meta.errorCode: "module.disabled"` +
    /// `meta.module: "nutrients"` when off. Wire key == rawValue.
    case nutrients
    /// Medication tracking. A **real user toggle** since server registry D3
    /// (web v1.18.1) — it is listed in `MODULE_KEYS`, not `CORE_DOMAIN_KEYS`,
    /// and `PATCH /api/auth/me/modules` accepts it. iOS listed it as CORE
    /// "always on" until Build 2 / 2.6, which told the user something false.
    case medications
    /// Environmental context (weather / daylight). Default-ON tracking module
    /// (server v1.29.1) — no egress happens until the user configures a home
    /// location, so default-on carries no silent outbound fetch.
    case environment
    /// Mental-health self-assessment (WHO-5 / PHQ-9 / GAD-7). Default-ON
    /// (server v1.29.1). Gates the `/mental-wellbeing` check-in surface; the
    /// `/api/mental-health*` routes 403 with `module.disabled` when off.
    case mentalHealth
    /// Remote MCP connector endpoint. **Opt-in / default-OFF** (`optIn: true`
    /// server-side, ADR-007 / REQ-OPS-1): it exposes an external-assistant
    /// surface onto the health record, so it must be switched on deliberately.
    /// The `/mcp` endpoint answers 404 until this is on.
    case mcp

    public var id: String {
        rawValue
    }

    /// Keys the server's `PATCH /api/auth/me/modules` rejects with
    /// `422 modules.invalid` (v1.18.1 §4 Q3) — DELEGATED modules whose state is
    /// owned by another resolver (cycle/coach). They render via ``ModuleGate``
    /// but must never appear in a PATCH body.
    public static let delegated: Set<ModuleKey> = [.cycle, .coach]

    /// Keys that are CORE / always-on and not yet disable-able server-side, so
    /// a PATCH naming them would `422`.
    ///
    /// **Empty since Build 2 / 2.6.** `medications` used to sit here as a
    /// pre-stage, but the server graduated it to a real toggle (registry D3 /
    /// web v1.18.1) and iOS never followed — the switchboard hid a toggle the
    /// server accepts. The true always-on domains (`weight` / `bloodPressure` /
    /// `pulse`) are server `CORE_DOMAIN_KEYS` and are not `ModuleKey`s at all,
    /// so they can never reach a PATCH body. The set is kept (rather than
    /// deleted) as the seam for the next CORE→toggle transition.
    public static let coreNonToggleable: Set<ModuleKey> = []

    /// Whether this module may be sent in a `PATCH /api/auth/me/modules` body.
    /// Excludes DELEGATED (cycle/coach) keys the server would `422` on. This is
    /// the canonical "offer a toggle" set for the settings switchboard.
    public var isUserToggleable: Bool {
        !ModuleKey.delegated.contains(self) && !ModuleKey.coreNonToggleable.contains(self)
    }

    /// The wire key as emitted by the server `modules` map. Identical to the
    /// Swift `rawValue` for every case (server uses the same camelCase keys,
    /// incl. `doctorReport`).
    public var wireKey: String {
        rawValue
    }

    /// Parse a server wire key into a known module. Returns `nil` for keys the
    /// client does not recognise (forward-compat — a future server module key
    /// the app has no surface for is ignored, not crashed on).
    public static func from(wireKey: String) -> ModuleKey? {
        ModuleKey(rawValue: wireKey)
    }

    /// The dashboard `MetricKind`s that belong to this module. When the module
    /// is OFF, ``DashboardScreen`` drops tiles for these kinds. Core metric
    /// kinds (weight / blood pressure / pulse) are intentionally absent — they
    /// are never gated. Modules without a dedicated metric tile (coach,
    /// insights, achievements, doctorReport, workouts, recovery, mood, labs,
    /// illness, medications) return an empty set; their surfaces are gated
    /// structurally elsewhere. (`medications` has no dedicated `MetricKind`;
    /// `illness` is a journal, not a metric tile.)
    public var dashboardMetricKinds: Set<MetricKind> {
        switch self {
        case .sleep: [.sleep]
        case .glucose: [.glucose]
        case .cycle, .mood, .workouts, .recovery, .labs,
             .achievements, .coach, .insights, .doctorReport,
             .illness, .inboundDocuments, .nutrients, .medications,
             .environment, .mentalHealth, .mcp:
            []
        }
    }
}
