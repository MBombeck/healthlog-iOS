import Foundation

/// Feature-flag service surface — LOCAL build flags only.
///
/// **#114 / #115 · 0.2:** the assistant keys and `GET /api/feature-flags` are
/// gone. That route never reached the app (it was decoded as an invented
/// `{ flags }` shape while the server sent `{ assistant }`), so every assistant
/// flag always sat at its default "on". AI availability now comes from
/// `GET /api/auth/me` `ai` through ``AICapabilityGate``; the on-device services
/// read it through ``AICapabilityReading``. What remains here are the
/// device-local HealthKit ingest switches and the cycle-tracking default, none
/// of which the server ever sent.
public protocol FeatureFlagsServicing: Sendable {
    func isEnabled(_ flag: FeatureFlag) -> Bool
}

/// Known local feature flag keys. None of them is operator-controlled.
public enum FeatureFlag: String, Sendable, CaseIterable {
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
    /// shapes during cutover). Device-local — never deployed server-side.
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
    /// Local only: the server never sent this key (the `/api/feature-flags`
    /// read that was meant to carry it is gone, #115 · 0.2). The server-side
    /// gate is the `cycle` module in `/api/auth/me` `modules`, which
    /// `CycleGate` reads.
    case cycleTracking = "cycle.tracking"

    /// Default state.
    ///
    /// - `enableDailyStats` defaults ON (cutover-build); a local override
    ///   reverts to the legacy per-sample batch path for cumulative types.
    public var defaultValue: Bool {
        switch self {
        case .enableDailyStats,
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
    /// UserDefaults stub. Keys a previous build may have written for the
    /// removed assistant flags (`feature_flag.assistant.*`) are no longer read
    /// by anything.
    public var defaultsKey: String {
        "feature_flag.\(rawValue)"
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

/// Sendable snapshot of a flag map.
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

/// Closure-backed `FeatureFlagsServicing` that reads from a live store on
/// every call. Bridges the @MainActor `FeatureFlagsStore` into a Sendable
/// adaptor the HealthKit coordinators can capture at construction.
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
