import Foundation

/// Feature-flag service surface.
///
/// **F-1 (v0.5.x server-coord):** the protocol is now backed by the
/// server's `GET /api/feature-flags` endpoint via
/// ``FeatureFlagsRepository`` + ``FeatureFlagsStore``. The historical
/// `UserDefaults`-backed stub remains as ``UserDefaultsFeatureFlagsService``
/// — it stays the production default in two narrow scopes:
///
/// 1. Bootstrap window before ``FeatureFlagsStore`` has a snapshot. We
///    fail-open (mirror server's pre-deploy defaults) so on-device AI
///    doesn't blink off during the first network round-trip.
/// 2. Unit tests that exercise the on-device services in isolation.
///
/// The HTTP-backed implementation is ``FeatureFlagsStoreSnapshot`` (a
/// `Sendable` value-type view over the store's current cache) — it is
/// what AppContainer wires into `OnDeviceBriefingService` /
/// `TrendObservationsService` per R5 (server brief §5b: gate
/// both on-device + server-AI behind the same operator flag).
public protocol FeatureFlagsServicing: Sendable {
    func isEnabled(_ flag: FeatureFlag) -> Bool
}

/// Known feature flag keys.
///
/// **Source of truth:** server brief `v1.4.31 §c.1` — the namespace is
/// `assistant.<surface>` and the server emits `errorCode:
/// "assistant.disabled.<surface>"` when the corresponding flag is off
/// on a route the user just hit (`/api/insights/*`,
/// `/api/insights/chat`, `/api/insights/comprehensive`, etc.).
///
/// Per R5: we gate BOTH server-AI AND on-device AI paths behind the
/// same surface flag — operator-control philosophy. The on-device
/// services consult these flags before spending any FoundationModels
/// inference; the surface placeholders (rendered by
/// `FeatureDisabledCard`) render whenever the flag is off, regardless
/// of who would have generated the content.
public enum FeatureFlag: String, Sendable, CaseIterable {
    /// Daily Briefing — gates the server-AI
    /// `POST /api/insights/generate` path AND the on-device
    /// `OnDeviceBriefingService` (I-1).
    case assistantBriefing = "assistant.briefing"

    /// Conversational coach — gates the server-Coach-SSE
    /// `GET /api/insights/chat` path AND any future on-device coach
    /// surface (deferred to v0.7.0 per R4).
    case assistantCoach = "assistant.coach"

    /// Per-metric trend observations — gates the on-device
    /// `TrendObservationsService` (I-2). Server side this maps to the
    /// per-metric `/api/insights/{metric}-status` family.
    case assistantTrend = "assistant.trend"

    /// Insights mother-page cards — BMI / BP / Correlations /
    /// Recommendations / Mood-Summary / Health-Alerts on the
    /// `/api/insights/comprehensive` family. Off → the mother-page
    /// renders a neutral placeholder above the cards block (no AI
    /// summary, no recommendations, no correlations).
    case assistantInsights = "assistant.insights"

    /// HK-STATS daily-stats path (v1.4.30 R-A Option A). When ON, the five
    /// cumulative HK types (steps, active-energy, flights, walking-running-
    /// distance, time-in-daylight) ingest via `HKStatisticsCollectionQuery`
    /// → one row/day/type with `externalId="stats:<id>:<YYYY-MM-DD>"`,
    /// bypassing the per-sample batch path. Spot metrics stay per-sample.
    /// Default ON on cutover-build; operator-toggleable via UserDefaults
    /// in case TestFlight feedback flags a regression — server tolerates
    /// BOTH ingest shapes during cutover (per brief §4), so flipping the
    /// flag is reversible without server coordination.
    case enableDailyStats = "healthkit.enableDailyStats"

    /// HK 10-minute heart-rate `stats:` bucket upload (GH #34). When ON,
    /// heart-rate ingests as one row per 10-minute UTC bucket
    /// (`stats:HKQuantityTypeIdentifierHeartRate:<UTC-bucket-start>`, bucket
    /// average bpm as `value` + the bucket low/high as `valueMin`/`valueMax`,
    /// PULSE/count/min) for every UTC day on-or-after the per-User
    /// `hrBucketCutoverDayUTC` boundary, and the per-sample HR upload is
    /// suppressed for those days (see ``HRBucketCutoverStore`` — per-day
    /// exclusivity, no double-count in the server's nightly PULSE rollup).
    /// Pre-cutover days stay raw per-sample. Default ON on cutover-build;
    /// operator-toggleable via UserDefaults so TestFlight feedback can revert to
    /// all-per-sample HR without a server-side flip (server tolerates both ingest
    /// shapes during cutover). Device-local — never deployed server-side, so it
    /// does not appear in `mapWireFlags`.
    case enableHRBuckets = "healthkit.enableHRBuckets"

    // v0162 cleanup — the 7 `useSpeziFor*` HK-cutover flags (steps/active-energy,
    // vital-signs, blood-chemistry, mass, walking, blood-pressure, sleep) were
    // removed. They gated the legacy per-sample `HealthKitService` observer's
    // skip-filter during the Spezi coexistence window; that legacy observer
    // pipeline was fully removed in W-A5 (see PROJECT_GUIDE.md — `HealthLogStandard` is
    // the sole receiver now), so the flags had zero live readers.

    /// v0.14.8 — women-only cycle tracking. **Default OFF** — the entire
    /// feature (capture row, settings entry, calendar surface, prediction)
    /// stays invisible/inert until this flips on. While off, `CycleGate`
    /// reports `isCycleTrackingAvailable == false` regardless of gender, so
    /// the contract-free foundation ships dormant behind the flag.
    ///
    /// Wire-mappable: the namespace mirrors the server `cycle.tracking`
    /// surface so the operator CAN deploy it server-side when the cycle
    /// contract lands. Until then it resolves to its local default (OFF) on
    /// every device. RECONCILE-WITH-SERVER: confirm the wire key + whether
    /// the server gates this per-account.
    case cycleTracking = "cycle.tracking"

    /// Default state on first launch / pre-snapshot.
    ///
    /// - All four assistant surfaces default ON so the on-device path
    ///   runs immediately on a fresh install. Operator turns them off
    ///   via server config, and the next foreground refresh propagates
    ///   the disabled state — there is no client-side default-deny.
    /// - `enableDailyStats` defaults ON (cutover-build); operator
    ///   override reverts to the legacy per-sample batch path for
    ///   cumulative types.
    public var defaultValue: Bool {
        switch self {
        case .assistantBriefing,
             .assistantCoach,
             .assistantTrend,
             .assistantInsights,
             .enableDailyStats,
             .enableHRBuckets:
            true
        // v0.14.8 — cycle tracking is feature-complete (capture, calendar,
        // ring, phase explainer + highlight art). Default ON; still hard-gated
        // per-user by CycleGate (server gender == female → HK biologicalSex
        // fallback → explicit opt-in), so nothing surfaces for ineligible users.
        case .cycleTracking:
            true
        }
    }

    /// `UserDefaults` key under which the flag is persisted by the
    /// legacy stub. The HTTP-backed store does not touch UserDefaults.
    public var defaultsKey: String {
        "feature_flag.\(rawValue)"
    }

    /// Surface-suffix in the server's `errorCode` envelope. Used by
    /// ``HLError.assistantDisabled`` to look up the matching flag
    /// from a 403 response. Mirrors the server's
    /// `"assistant.disabled.<surface>"` shape so the iOS side never
    /// has to grep the raw string.
    public static func from(serverSurface surface: String) -> FeatureFlag? {
        switch surface {
        case "briefing": .assistantBriefing
        case "coach": .assistantCoach
        case "trend", "trendObservations": .assistantTrend
        case "insights": .assistantInsights
        default: nil
        }
    }
}

/// `UserDefaults`-backed implementation. Thread-safe by virtue of
/// `UserDefaults` itself being a thread-safe Foundation primitive.
///
/// `UserDefaults` itself is not annotated `Sendable` by Apple, but is
/// documented thread-safe. We use `@unchecked` so the surrounding struct
/// satisfies `FeatureFlagsServicing: Sendable`.
public struct UserDefaultsFeatureFlagsService: FeatureFlagsServicing, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func isEnabled(_ flag: FeatureFlag) -> Bool {
        if defaults.object(forKey: flag.defaultsKey) == nil {
            return flag.defaultValue
        }
        return defaults.bool(forKey: flag.defaultsKey)
    }

    /// Test-only setter. Production code should not flip flags from the
    /// client; the HTTP-backed store is the only legitimate writer.
    public func setEnabled(_ flag: FeatureFlag, value: Bool) {
        defaults.set(value, forKey: flag.defaultsKey)
    }
}

/// Sendable snapshot of the server-fetched feature flags. Built by
/// ``FeatureFlagsStore`` after every successful refresh; injected into
/// the on-device assistant services so they read the same operator
/// state the surface guards do.
///
/// Why a snapshot value-type (vs the store directly)?
/// `OnDeviceBriefingService` + `TrendObservationsService` are `actor`
/// types and their initialiser captures `featureFlags` as
/// `any FeatureFlagsServicing`. The store is `@MainActor`-isolated, so
/// passing it directly would force a main-actor hop inside the actor.
/// A frozen snapshot is cheap (one enum→bool map) and lets the actor
/// stay on its own queue.
public struct FeatureFlagsStoreSnapshot: FeatureFlagsServicing, Sendable {
    /// Map of `FeatureFlag` → enabled. Missing keys default to the
    /// flag's own ``FeatureFlag/defaultValue`` (fail-open during
    /// bootstrap).
    public let flags: [FeatureFlag: Bool]

    public init(flags: [FeatureFlag: Bool]) {
        self.flags = flags
    }

    public func isEnabled(_ flag: FeatureFlag) -> Bool {
        flags[flag] ?? flag.defaultValue
    }
}

/// Closure-backed `FeatureFlagsServicing` that reads from a live
/// store on every call. Bridges the @MainActor `FeatureFlagsStore`
/// into a Sendable adaptor the on-device-AI actors can capture at
/// construction.
///
/// Why a closure instead of a static snapshot? The on-device
/// services are long-lived actors (constructed in `AppContainer.init`
/// and held for the lifetime of the session). If the operator flips
/// a flag mid-session, the next `generate(...)` call must see the
/// new value rather than the snapshot captured at init time. The
/// closure indirection trades one MainActor hop per gate-check for
/// up-to-date state — acceptable cost because the on-device path
/// is gate-checked O(1)/inference, not in tight loops.
public struct LiveFeatureFlagsService: FeatureFlagsServicing, Sendable {
    /// Resolver — invoked synchronously from the actor. AppContainer
    /// wires this to a closure that hops to MainActor to read the
    /// store; the closure body uses a weak-captured store reference
    /// so the wiring never leaks the store past its owning container.
    private let resolve: @Sendable (FeatureFlag) -> Bool

    public init(resolve: @escaping @Sendable (FeatureFlag) -> Bool) {
        self.resolve = resolve
    }

    public func isEnabled(_ flag: FeatureFlag) -> Bool {
        resolve(flag)
    }
}
