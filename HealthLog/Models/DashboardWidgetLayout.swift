import Foundation

/// Wire shape of `GET / PUT /api/dashboard/widgets`.
///
/// Server source of truth:
/// - `src/lib/dashboard-layout.ts:175-298` — `DashboardLayout` type + resolver
/// - `src/app/api/dashboard/widgets/route.ts:36-153` — GET/PUT handlers,
///   Zod-validated layout shape, `widgetIdEnum` derived from
///   `DASHBOARD_WIDGET_IDS`.
///
/// iOS consumes a strict subset — only widget visibility/order. We do
/// NOT touch `comparisonBaseline` or `chartOverlayPrefs` (web-only
/// affordances). PUT preserves those fields server-side because the
/// server's PUT handler merges them in from the existing row when our
/// payload omits them (route.ts:124-138).
public struct DashboardWidgetLayout: Codable, Sendable, Equatable {
    public let version: Int
    public let widgets: [DashboardWidgetConfig]
    /// **v1.27.7 — the user-selected hero score rings** (`selectedScoreRings` on
    /// the server `DashboardLayout`, max ``ScoreRingID/maxSelected``). Raw ids so
    /// an unknown future id round-trips through the server's dedupe/clamp/drop
    /// resolver. **Preserve-when-absent:** decoded from GET for display, but
    /// ENCODED only when non-nil — the tile-mutation helpers leave it `nil` so an
    /// unrelated save OMITS it and the server keeps the stored choice (mirrors
    /// `chartOverlayPrefs`/`heroVisible`); only `settingSelectedScoreRings`
    /// carries a value the PUT sends. `nil` means "leave unchanged", not "clear".
    public let selectedScoreRings: [String]?
    /// **v1.27.27 / parity Build 4 · 4.8 — the hero ring DISPLAY ORDER**
    /// (`heroRingOrder` on the server `DashboardLayout`, max
    /// ``HeroRingID/maxOrderLength``). Carries the always-present health-score
    /// anchor plus the selected score rings, so the user can place the anchor
    /// anywhere in the sequence instead of it being pinned to the leading edge.
    ///
    /// **This is a missing CAPABILITY, not a data-loss fix.** The server has an
    /// explicit preserve-when-absent contract for this field
    /// (`api/dashboard/widgets/route.ts:286-310`: "`selectedScoreRings` and
    /// `heroRingOrder` ride the same preserve-when-absent contract — an older
    /// client's layout save must not reset either choice"), so every iOS save
    /// that omitted it was always SAFE. An early audit claimed iOS silently
    /// deleted the field; that was investigated and disproven
    /// (`12-layout-dashboard-insights-domains.md` §F). What was genuinely
    /// missing is the ability to EDIT the order from the phone — that is what
    /// this field enables. Encoded only when non-nil, same as
    /// ``selectedScoreRings``: `nil` means "leave unchanged", never "clear".
    public let heroRingOrder: [String]?
    /// **CU-34 (Brief C6) — which item kinds may appear in the Today hero rail**
    /// (`enabledHeroItemKinds` on the server `DashboardLayout`, closed
    /// ``HeroItemKind`` set, max ``HeroItemKind/maxSelected``). Raw ids so an
    /// unknown future kind round-trips through the server's own dedupe/order
    /// resolver instead of being dropped by this client.
    ///
    /// **Two absences that mean opposite things — the whole point of this
    /// field.** The server's PUT schema (`route.ts:155-160`) marks it
    /// `.optional()` and its merge disposition is `"preserve"`
    /// (`dashboard-layout.ts:626`):
    ///
    /// | wire form                     | server does            |
    /// |-------------------------------|------------------------|
    /// | key **absent**                | keeps the stored set   |
    /// | `[]` (present, empty)         | **all kinds off**      |
    /// | `["milestone", …]`            | exactly those kinds on |
    ///
    /// So `nil` here means "leave unchanged" and `[]` means "show nothing" —
    /// two different statements that a synthesized `Encodable` would collapse
    /// into the same `null`. ``encode(to:)`` therefore uses `encodeIfPresent`,
    /// which omits on `nil` and emits `[]` on empty: the distinction survives
    /// all the way onto the wire, which is what
    /// ``DashboardHeroItemKindsPutTests`` asserts against the real request body.
    ///
    /// **Why not ``RecordPatchField``.** That primitive is tri-state
    /// (`unchanged` / `clear` → explicit `null` / `set`) because the record
    /// PATCH routes have a nullable column. This field has no `null` arm at
    /// all: the server's Zod schema is `z.array(z.enum(…)).optional()`, so a
    /// `null` is a validation error, not a clear. Reaching for the tri-state
    /// type here would add exactly one representable wire state that the server
    /// rejects. The two-state `[String]?` is the honest shape and is already the
    /// established contract of its two immediate siblings above.
    ///
    /// **Preserve-when-absent, same as the ring fields:** every layout helper
    /// leaves this `nil` so an unrelated tile save never resets the choice; only
    /// ``settingEnabledHeroItemKinds(_:)`` produces a layout that sends it.
    public let enabledHeroItemKinds: [String]?
    /// **CU-20 (#69) — optimistic-concurrency token.** Echoed back as
    /// `baseUpdatedAt` on the next PUT so a write from a stale read is rejected
    /// with `409 dashboard_layout_conflict` instead of silently clobbering
    /// whatever another session stored. Guards `User.updatedAt`
    /// (`api/dashboard/widgets/route.ts:384`).
    ///
    /// **Decode-only — deliberately NOT re-encoded** (see ``encode(to:)``): the
    /// PUT body is Zod-validated server-side and the token belongs in
    /// `baseUpdatedAt`, never in `updatedAt`. `nil` on an older server; the next
    /// write is then unconditional, which the server supports permanently
    /// (`optimistic-lock.ts:101-103`).
    public let updatedAt: String?

    public init(
        version: Int = DashboardWidgetLayout.currentVersion,
        widgets: [DashboardWidgetConfig],
        selectedScoreRings: [String]? = nil,
        heroRingOrder: [String]? = nil,
        enabledHeroItemKinds: [String]? = nil,
        updatedAt: String? = nil
    ) {
        self.version = version
        self.widgets = widgets
        self.selectedScoreRings = selectedScoreRings
        self.heroRingOrder = heroRingOrder
        self.enabledHeroItemKinds = enabledHeroItemKinds
        self.updatedAt = updatedAt
    }

    /// `DASHBOARD_LAYOUT_VERSION` constant on the server (1 as of v1.4.27).
    public static let currentVersion: Int = 1

    private enum CodingKeys: String, CodingKey {
        case version, widgets, selectedScoreRings, heroRingOrder, enabledHeroItemKinds, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        widgets = try c.decode([DashboardWidgetConfig].self, forKey: .widgets)
        // Tolerant: older servers omit the field → nil. The server always
        // resolves it on GET (defaults-merged), so a paired client normally
        // sees a concrete array here.
        selectedScoreRings = try c.decodeIfPresent([String].self, forKey: .selectedScoreRings)
        // Same tolerance: a server older than v1.27.27 omits the field → nil.
        heroRingOrder = try c.decodeIfPresent([String].self, forKey: .heroRingOrder)
        // CU-34 — absent on a server older than v1.34.0. `nil` then means "this
        // server does not filter the rail at all", which is why
        // ``resolvedEnabledHeroItemKinds`` resolves it to the FULL catalogue and
        // NOT to the empty set. A paired server always resolves the field on
        // GET, so a concrete array is the normal case; `[]` there is a real
        // "everything off" the user chose, never a decode artefact.
        enabledHeroItemKinds = try c.decodeIfPresent([String].self, forKey: .enabledHeroItemKinds)
        // CU-20 — absent on a pre-v1.32.22 server; nil then means "no token
        // yet", i.e. the next write goes out unconditional.
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(widgets, forKey: .widgets)
        // Preserve-when-absent: omit entirely when nil so an unrelated tile
        // save never resets the server's stored ring selection.
        try c.encodeIfPresent(selectedScoreRings, forKey: .selectedScoreRings)
        try c.encodeIfPresent(heroRingOrder, forKey: .heroRingOrder)
        // CU-34 — `encodeIfPresent`, deliberately: it omits the key on `nil`
        // ("keep what is stored") and emits `[]` on an empty array ("all kinds
        // off"). A plain `encode` would turn `nil` into an explicit `null`,
        // which the server's `z.array(...).optional()` rejects; `?? []` would
        // turn every unrelated tile save into a silent "switch the whole rail
        // off". Both forms are asserted on the real request body in
        // `DashboardHeroItemKindsPutTests`.
        try c.encodeIfPresent(enabledHeroItemKinds, forKey: .enabledHeroItemKinds)
        // CU-20 — `updatedAt` is READ-ONLY. The token travels on the write as
        // `baseUpdatedAt` (via `OptimisticWriteBody`), never echoed back under
        // its own key.
    }
}

/// One widget row in the layout array.
///
/// `id` is a server-side widget identifier — NOT the iOS `MetricKind`
/// raw value. Translation lives in `DashboardWidgetId.metricKind`.
///
/// `visible` controls the chart-row (web-only on today's render path).
/// `tileVisible` controls the tile strip — this is what iOS reads. When
/// the server omits `tileVisible` on a legacy save, the server-side
/// resolver mirrors `visible`. The iOS-side helper `effectiveTileVisible`
/// applies the same fallback locally so an iOS-only client sees the
/// same effective state.
public struct DashboardWidgetConfig: Codable, Sendable, Identifiable, Equatable, Hashable {
    public let id: String
    public let visible: Bool
    public let tileVisible: Bool?
    public let order: Int

    public init(id: String, visible: Bool, tileVisible: Bool? = nil, order: Int) {
        self.id = id
        self.visible = visible
        self.tileVisible = tileVisible
        self.order = order
    }

    public var effectiveTileVisible: Bool {
        tileVisible ?? visible
    }
}

// MARK: - Widget id mapping

/// Strongly-typed map between server widget ids and iOS `MetricKind`s.
///
/// Server source: `src/lib/dashboard-layout.ts:17-38` (`DASHBOARD_WIDGET_IDS`).
///
/// **v0.5.5.2 — non-metric widgets explicitly listed** (W-DATA-FLOW-AUDIT
/// HIGH #4). The server's widget catalogue includes several rows that
/// surface as DEDICATED iOS cards elsewhere (MoodSummary, BPStatusCard,
/// ComplianceRingCard) — they have no metric
/// tile to render and intentionally fall through to `nil` in
/// `metricKind(forId:)`. Documenting them explicitly (instead of the
/// silent `default: nil` fall-through) keeps the gap reviewable + stops
/// a future regression that tries to paint empty placeholder tiles for
/// kinds that don't belong in the metric-tile strip.
public enum DashboardWidgetId {
    public static let weight = "weight"
    public static let bp = "bp"
    public static let pulse = "pulse"
    public static let bodyFat = "bodyFat"
    public static let mood = "mood"
    public static let medications = "medications"
    public static let sleep = "sleep"
    public static let steps = "steps"
    public static let glucose = "glucose"
    public static let totalBodyWater = "totalBodyWater"
    public static let boneMass = "boneMass"
    public static let bpInTarget = "bpInTarget"
    public static let oxygenSaturation = "oxygenSaturation"
    public static let achievements = "achievements"
    public static let vo2Max = "vo2Max"
    /// **v0.5.5.2** — server includes `recentWorkouts` in the widget
    /// catalogue + emits `tileVisible: true` by default on demo
    /// accounts, but iOS has no workout surface yet. Tracked as an
    /// explicit non-mapping in `metricKind(forId:)` rather than
    /// silently falling through the `default` case, so the gap shows
    /// up in code review when the workouts feature ships.
    public static let recentWorkouts = "recentWorkouts"
    // v0.5.2 F2 HK-completeness — new widget ids. They are additive in the
    // local default layout (tile-visible-true by default, just like the
    // v0.4.1 sweep flipped sleep/steps/glucose). Server `DASHBOARD_WIDGET_IDS`
    // will follow in a separate iOS-driven PUT once the tiles ship.
    public static let restingHeartRate = "restingHeartRate"
    public static let hrv = "hrv"
    public static let walkingSpeed = "walkingSpeed"
    public static let walkingAsymmetry = "walkingAsymmetry"
    public static let walkingStepLength = "walkingStepLength"
    public static let bmi = "bmi"
    public static let bodyTemperature = "bodyTemperature"
    /// v0.7.0 HK adopt-and-stream — fourth gait metric in Apple's
    /// Mobility cluster. iOS-only until the server widens `MeasurementType`
    /// (tracked under `WALKING_DOUBLE_SUPPORT_PERCENTAGE`).
    public static let walkingDoubleSupport = "walkingDoubleSupport"
    /// v0.7.0 HK adopt-and-stream — respiratory rate + the two audio-exposure
    /// readings. iOS-only until the server widens `MeasurementType`. Hidden by
    /// default; operator opts in via the dashboard customisation screen.
    public static let respiratoryRate = "respiratoryRate"
    /// Environmental ambient-sound exposure (dBA) widget id.
    public static let audioExposureEnvironment = "audioExposureEnvironment"
    /// Headphone playback-level exposure (dBA) widget id.
    public static let audioExposureHeadphone = "audioExposureHeadphone"
    /// v0158 — v1.25 clinical measurement types. iOS-only widget ids (the server
    /// `DASHBOARD_WIDGET_IDS` may follow). Tile-visible by DEFAULT (`tileVisible:
    /// true`) per the "every MetricKind tile is visible by default" invariant; the
    /// empty-tile policy keeps a fresh dashboard uncluttered (an unrecorded metric
    /// never paints). The ids map to a `MetricKind` so they also surface in the
    /// customisation screen for explicit pin/hide.
    public static let painNRS = "painNRS"
    public static let gripStrength = "gripStrength"
    public static let waistCircumference = "waistCircumference"
    public static let waistToHeight = "waistToHeight"

    // swiftlint:disable cyclomatic_complexity
    /// Translates a server widget id to the matching iOS `MetricKind`,
    /// or returns `nil` for non-metric widgets.
    ///
    /// **v0.5.5.2 — explicit non-metric branches** instead of the silent
    /// `default: nil` fall-through:
    /// - `mood` → **Build 7 / item 7.3:** now a first-class metric tile
    ///   (`.mood`). The summary route emits a `kind: "mood"` card (#51), so the
    ///   grid renders it like any scalar tile; it also drives the Insights mood
    ///   surface + the StatistikMode briefing floor as before.
    /// - `medications` → `ComplianceRingCard` on the dashboard (outside
    ///   the metric tile-strip; the old `UpcomingMedicationsCard` was
    ///   consolidated into `AnstehendeEinnahmenSheet` in v0.5.6 and the
    ///   dead file deleted in v0.14.8 AUDIT-HOME M6).
    /// - `bpInTarget` → BPStatusCard on Insights (`bpPctInTarget`).
    ///   Not a standalone dashboard tile.
    /// - `achievements` → MoreScreen badge surface; default layout
    ///   keeps `tileVisible: false` so the grid skips it anyway.
    /// - `recentWorkouts` → No iOS surface yet (v0.5.x has no workouts
    ///   feature). Server may emit `tileVisible: true` on demo, but
    ///   the explicit `nil` keeps `synthesiseMissingTiles` from
    ///   trying to paint a placeholder for a non-existent kind.
    ///
    /// Exhaustiveness over the widget-id catalogue + every supported
    /// MetricKind drives the case-count past the default lint budget;
    /// splitting would lose the single-table audit point.
    public static func metricKind(forId id: String) -> MetricKind? {
        switch id {
        case weight: .weight
        case bp: .bloodPressure
        case pulse: .pulse
        case bodyFat: .bodyFat
        // Build 7 / item 7.3 — mood graduated to a first-class metric tile when
        // the summary route started emitting a `kind: "mood"` card (#51). It now
        // maps to `.mood` so the tile renders through the standard grid path,
        // respects the `mood` widget row's order/visibility, and appears in the
        // customisation screen (`hasHomeSurface`).
        case mood: .mood
        case sleep: .sleep
        case steps: .steps
        case glucose: .glucose
        case totalBodyWater: .bodyWater
        case boneMass: .boneMass
        case oxygenSaturation: .spo2
        case vo2Max: .vo2Max
        case restingHeartRate: .restingHeartRate
        case hrv: .hrv
        case walkingSpeed: .walkingSpeed
        case walkingAsymmetry: .walkingAsymmetry
        case walkingStepLength: .walkingStepLength
        case walkingDoubleSupport: .walkingDoubleSupport
        case respiratoryRate: .respiratoryRate
        case audioExposureEnvironment: .audioExposureEnvironment
        case audioExposureHeadphone: .audioExposureHeadphone
        case bmi: .bmi
        case bodyTemperature: .bodyTemperature
        // v0158 — v1.25 clinical measurement types.
        case painNRS: .painNRS
        case gripStrength: .gripStrength
        case waistCircumference: .waistCircumference
        case waistToHeight: .waistToHeight
        // v0.5.5.2 — non-metric widgets surface as dedicated cards
        // outside the dashboard tile-strip. See doc-comment for the
        // per-widget surface mapping. `nil` is intentional + reviewed.
        // Build 7 / item 7.3 — `mood` LEFT this list: it now maps to `.mood`
        // (a first-class metric tile) since the summary route emits a mood card.
        case medications, bpInTarget, achievements, recentWorkouts: nil
        default: nil
        }
    }

    /// Reverse map — used when persisting an iOS-driven layout change.
    /// Same rationale as `metricKind(forId:)` — exhaustive MetricKind switch.
    public static func id(forMetricKind kind: MetricKind) -> String? {
        switch kind {
        case .weight: weight
        case .bloodPressure: bp
        case .pulse: pulse
        case .bodyFat: bodyFat
        // Build 7 / item 7.3 — mood tile round-trips through the `mood` widget id.
        case .mood: mood
        case .sleep: sleep
        case .steps: steps
        case .glucose: glucose
        case .bodyWater: totalBodyWater
        case .boneMass: boneMass
        case .spo2: oxygenSaturation
        case .bodyTemperature: bodyTemperature
        case .vo2Max: vo2Max
        case .restingHeartRate: restingHeartRate
        case .hrv: hrv
        case .walkingSpeed: walkingSpeed
        case .walkingAsymmetry: walkingAsymmetry
        case .walkingStepLength: walkingStepLength
        case .walkingDoubleSupport: walkingDoubleSupport
        case .respiratoryRate: respiratoryRate
        case .audioExposureEnvironment: audioExposureEnvironment
        case .audioExposureHeadphone: audioExposureHeadphone
        case .bmi: bmi
        // v0.8.3 W-D — the four render-backlog activity aggregates surface via
        // the measurements list + chart-detail path, not the dashboard tile
        // grid. They have no `DashboardWidgetLayout` widget id (the reorder
        // grid owns that catalogue), so `nil` keeps them out of the grid +
        // its persisted layout. Follow-up: add grid widget ids in the reorder
        // wave if operator wants them as reorderable tiles (operator, 2026-05-29).
        case .activeEnergy, .flightsClimbed, .distanceWalkingRunning, .timeInDaylight: nil
        // v0.11 W21 — server/Withings-sourced web-parity kinds surface via the
        // measurements list + chart-detail path, not the dashboard reorder grid.
        // No widget id, so `nil` keeps them out of the grid + persisted layout.
        case .fatFreeMass, .leanBodyMass, .muscleMass, .skinTemperature,
             .pulseWaveVelocity, .vascularAge, .visceralFat, .walkingHeartRate,
             .fatMass: nil
        // W28d — walking steadiness surfaces via the Insights strip + chart-
        // detail path, not the dashboard reorder grid; no widget id → `nil`.
        case .walkingSteadiness: nil
        // v0.13.1 IC — v1.10.0 additive signals are Insights-only (display
        // parity); they have no dashboard reorder-grid widget id → `nil`.
        case .falls, .sixMinuteWalk, .stairAscentSpeed, .stairDescentSpeed,
             .breathingDisturbances, .cardioRecovery, .wristTemperature: nil
        // v0.14.6 — v1.12.8 WHOOP-native types are Insights/list-only; no
        // dashboard reorder-grid widget id → `nil`.
        case .averageHeartRate, .maxHeartRate, .sleepDisturbanceCount: nil
        // v0.14.1 W-B189 — v1.17.1 source-fixed render-only signals (#23) are
        // Insights/list-only (display parity); no dashboard reorder-grid widget
        // id → `nil`.
        case .ansCharge, .cardioLoad, .sleepScore, .bodyTemperatureDeviation: nil
        // v0158 — v1.25 clinical measurement types. All four DO get a dashboard
        // widget id so they are tile-capable + appear in the customisation
        // screen; they default to hidden (see `DashboardWidgetLayout.default`).
        case .painNRS: painNRS
        case .gripStrength: gripStrength
        case .waistCircumference: waistCircumference
        case .waistToHeight: waistToHeight
        // Build 3 / item 3.3 — the 21 decoder catch-up types are list/detail-
        // only (display parity). They have no dashboard reorder-grid widget id
        // → `nil` keeps them out of the grid + its persisted layout.
        case .phq9Score, .gad7Score, .who5Score, .sciScore,
             .recoveryScore, .stressScore, .strainScore, .hrvRMSSD,
             .dayStrain, .workoutStrain, .sleepPerformance, .sleepEfficiency,
             .sleepConsistency, .sleepNeed, .energyExpenditureKJ, .resilience,
             .irregularRhythmNotification, .highHeartRateEvent, .lowHeartRateEvent,
             .walkingSteadinessEvent, .breathingDisturbanceEvent: nil
        }
    }
    // swiftlint:enable cyclomatic_complexity
}

// MARK: - Order/visibility lookup (W-B187 memoization)

/// A pure, value-type projection of a layout's widgets into the two lookups
/// `DashboardScreen.orderedMetrics(_:)` needs: widget-id → `order` and widget-id
/// → effective tile visibility.
///
/// **W-B187 perf.** The screen used to rebuild both `Dictionary`s on every body
/// eval — and the dashboard observes ~11 stores, so unrelated churn (mood / HK /
/// insights) re-ran the build. These dictionaries depend ONLY on the layout, so
/// they're computed ONCE here and memoized on `DashboardLayoutStore`
/// (`widgetOrderLookup`), recomputed only when the layout actually changes.
///
/// `Sendable` + `Equatable` so it's unit-testable without a SwiftUI host or the
/// store, and so the cache key check is cheap.
public struct WidgetOrderLookup: Sendable, Equatable {
    /// Widget id → layout `order`. Lower sorts first; ids absent here are
    /// unknown to the layout and float to the end (`.max`) at the call site.
    public let orderById: [String: Int]
    /// Widget id → `effectiveTileVisible`. A `false` here hides the tile; an
    /// absent id is treated as visible by the call site (defensive against the
    /// server adding a kind before the layout endpoint catches up).
    public let visibilityById: [String: Bool]

    public init(widgets: [DashboardWidgetConfig]) {
        orderById = Dictionary(uniqueKeysWithValues: widgets.map { ($0.id, $0.order) })
        visibilityById = Dictionary(uniqueKeysWithValues: widgets.map { ($0.id, $0.effectiveTileVisible) })
    }
}

// MARK: - Default layout (offline-first guess)

public extension DashboardWidgetLayout {
    /// Local default — bootstrap layout before the first GET round-trip
    /// completes, and fallback when the server returns `null` for legacy
    /// users.
    ///
    /// **v0.4.1 — defaults flipped to "tile-visible by default".** Pre-v0.4.1
    /// shipped seven MetricKinds (`sleep`, `steps`, `glucose`,
    /// `totalBodyWater`, `boneMass`, `oxygenSaturation`, `vo2Max`) with
    /// `tileVisible: false`. Combined with the layout-gate filter in
    /// `DashboardScreen.orderedMetrics(_:)` this caused a fresh install
    /// (or any user without a customised layout) to render only 4 metric
    /// tiles (weight / BP / pulse / bodyFat) even when the server emitted
    /// 7-10 cards. See M2-A1 audit for the trace.
    ///
    /// Apple-Health-pattern: every supported kind should surface as a tile
    /// by default and the user opts OUT via the customisation screen. The
    /// `visible` flag (which the server uses to control web-chart-row
    /// visibility) stays unchanged for the seven kinds — only the iOS
    /// tile-strip flag flips. Server `DEFAULT_DASHBOARD_LAYOUT` may follow
    /// in a separate PR; iOS no longer depends on it.
    static let `default` = DashboardWidgetLayout(
        widgets: [
            DashboardWidgetConfig(id: DashboardWidgetId.weight, visible: true, tileVisible: true, order: 0),
            DashboardWidgetConfig(id: DashboardWidgetId.bp, visible: true, tileVisible: true, order: 1),
            DashboardWidgetConfig(id: DashboardWidgetId.pulse, visible: true, tileVisible: true, order: 2),
            DashboardWidgetConfig(id: DashboardWidgetId.bodyFat, visible: true, tileVisible: true, order: 3),
            DashboardWidgetConfig(id: DashboardWidgetId.mood, visible: true, tileVisible: true, order: 4),
            DashboardWidgetConfig(id: DashboardWidgetId.bpInTarget, visible: true, tileVisible: true, order: 5),
            DashboardWidgetConfig(id: DashboardWidgetId.medications, visible: true, tileVisible: true, order: 6),
            DashboardWidgetConfig(id: DashboardWidgetId.sleep, visible: false, tileVisible: true, order: 7),
            DashboardWidgetConfig(id: DashboardWidgetId.steps, visible: false, tileVisible: true, order: 8),
            DashboardWidgetConfig(id: DashboardWidgetId.glucose, visible: false, tileVisible: true, order: 9),
            DashboardWidgetConfig(
                id: DashboardWidgetId.totalBodyWater,
                visible: false,
                tileVisible: true,
                order: 10
            ),
            DashboardWidgetConfig(id: DashboardWidgetId.boneMass, visible: false, tileVisible: true, order: 11),
            DashboardWidgetConfig(
                id: DashboardWidgetId.oxygenSaturation,
                visible: false,
                tileVisible: true,
                order: 12
            ),
            DashboardWidgetConfig(
                id: DashboardWidgetId.achievements,
                visible: true,
                tileVisible: false,
                order: 13
            ),
            DashboardWidgetConfig(id: DashboardWidgetId.vo2Max, visible: false, tileVisible: true, order: 14),
            // v0.5.2 F2 HK-completeness additions — `visible: false` keeps
            // them off the web-chart-row (server-side renderer), but
            // `tileVisible: true` surfaces them in the iOS tile-strip per
            // the v0.4.1 Apple-Health-pattern (opt-out, not opt-in).
            DashboardWidgetConfig(
                id: DashboardWidgetId.restingHeartRate,
                visible: false,
                tileVisible: true,
                order: 15
            ),
            DashboardWidgetConfig(id: DashboardWidgetId.hrv, visible: false, tileVisible: true, order: 16),
            DashboardWidgetConfig(
                id: DashboardWidgetId.bodyTemperature,
                visible: false,
                tileVisible: true,
                order: 17
            ),
            DashboardWidgetConfig(
                id: DashboardWidgetId.walkingSpeed,
                visible: false,
                tileVisible: true,
                order: 18
            ),
            DashboardWidgetConfig(
                id: DashboardWidgetId.walkingAsymmetry,
                visible: false,
                tileVisible: true,
                order: 19
            ),
            DashboardWidgetConfig(
                id: DashboardWidgetId.walkingStepLength,
                visible: false,
                tileVisible: true,
                order: 20
            ),
            DashboardWidgetConfig(id: DashboardWidgetId.bmi, visible: false, tileVisible: true, order: 21),
            // v0.7.0 HK adopt-and-stream — iOS-only until server enum catches
            // up. `visible: false` keeps them out of the pinned hero strip but
            // `tileVisible: true` keeps the M2-A1 contract (every MetricKind
            // tile shows in the tile-grid on a fresh install); operator can
            // pin/hide via the dashboard customisation screen.
            DashboardWidgetConfig(
                id: DashboardWidgetId.walkingDoubleSupport,
                visible: false,
                tileVisible: true,
                order: 22
            ),
            DashboardWidgetConfig(
                id: DashboardWidgetId.respiratoryRate,
                visible: false,
                tileVisible: true,
                order: 23
            ),
            DashboardWidgetConfig(
                id: DashboardWidgetId.audioExposureEnvironment,
                visible: false,
                tileVisible: true,
                order: 24
            ),
            DashboardWidgetConfig(
                id: DashboardWidgetId.audioExposureHeadphone,
                visible: false,
                tileVisible: true,
                order: 25
            ),
            // v0158 — v1.25 clinical measurement types. `visible: false` keeps
            // them off the web-chart-row, but `tileVisible: true` holds the
            // established "every MetricKind tile is visible by DEFAULT" invariant
            // (DashboardWidgetLayoutDecodingTests) just like every HK-streamed
            // addition above. This does NOT clutter a fresh dashboard: the
            // `DashboardEmptyTilePolicy` hides EMPTY tiles at render time, so a
            // niche clinical metric with no readings simply never paints until the
            // operator records one (or pins it). Opt-OUT via the customisation
            // screen, consistent with the Apple-Health pattern.
            DashboardWidgetConfig(
                id: DashboardWidgetId.painNRS,
                visible: false,
                tileVisible: true,
                order: 26
            ),
            DashboardWidgetConfig(
                id: DashboardWidgetId.gripStrength,
                visible: false,
                tileVisible: true,
                order: 27
            ),
            DashboardWidgetConfig(
                id: DashboardWidgetId.waistCircumference,
                visible: false,
                tileVisible: true,
                order: 28
            ),
            DashboardWidgetConfig(
                id: DashboardWidgetId.waistToHeight,
                visible: false,
                tileVisible: true,
                order: 29
            )
        ]
    )
}

// MARK: - Helpers

public extension DashboardWidgetLayout {
    /// Returns the ordered list of widget configs whose `effectiveTileVisible`
    /// is true, sorted ascending by `order`. Driver for tile-strip rendering.
    var visibleTiles: [DashboardWidgetConfig] {
        widgets
            .filter(\.effectiveTileVisible)
            .sorted { $0.order < $1.order }
    }

    /// Reorders widget rows by replacing each row's `order` with its
    /// position in `newOrder` (matched by `id`). Widgets not in `newOrder`
    /// (e.g. hidden tiles the partial visible-only order omits) keep their
    /// relative sequence after the listed entries.
    ///
    /// A2 (v0.8.2 W1a) — `remaining` is seeded from the widgets sorted by
    /// `order` (NOT the raw array order). The reorder is fed a partial,
    /// visible-only id list from the grid; the hidden rows fall into the
    /// unmatched tail. Sorting first guarantees the hidden rows keep their
    /// `order`-relative sequence — so a hidden tile that sat between two
    /// now-visible tiles still trails them in its original relative position,
    /// and the AddTileSheet (which sorts hidden rows by `order`) stays stable.
    func reordering(_ newOrder: [String]) -> DashboardWidgetLayout {
        var remaining = widgets.sorted { $0.order < $1.order }
        var output: [DashboardWidgetConfig] = []
        for (index, id) in newOrder.enumerated() {
            if let i = remaining.firstIndex(where: { $0.id == id }) {
                let original = remaining.remove(at: i)
                output.append(DashboardWidgetConfig(
                    id: original.id,
                    visible: original.visible,
                    tileVisible: original.tileVisible,
                    order: index
                ))
            }
        }
        // Append unmatched widgets at the end (defensive — preserves rows
        // the caller didn't include).
        let baseOrder = output.count
        for (offset, row) in remaining.enumerated() {
            output.append(DashboardWidgetConfig(
                id: row.id,
                visible: row.visible,
                tileVisible: row.tileVisible,
                order: baseOrder + offset
            ))
        }
        return DashboardWidgetLayout(version: version, widgets: output)
    }

    /// v0.14 A — sets the `tileVisible` flag for one widget id to an explicit
    /// value, optionally re-homing the row to the tail (`order = max + 1`) when
    /// it is being shown. No-op (returns an equal layout) when the id is
    /// unknown or the flag already matches AND no move is needed.
    ///
    /// `moveToTailWhenShowing` is set on the long-press "pin to home" path so a
    /// freshly pinned tile lands last in the strip; the customisation screen's
    /// plain toggle leaves the order untouched.
    func settingTileVisible(
        forId id: String,
        visible: Bool,
        moveToTailWhenShowing: Bool
    ) -> DashboardWidgetLayout {
        guard widgets.contains(where: { $0.id == id }) else { return self }
        let tailOrder = (widgets.map(\.order).max() ?? -1) + 1
        let updatedWidgets = widgets.map { row -> DashboardWidgetConfig in
            guard row.id == id else { return row }
            let newOrder = (visible && moveToTailWhenShowing) ? tailOrder : row.order
            return DashboardWidgetConfig(
                id: row.id,
                visible: row.visible,
                tileVisible: visible,
                order: newOrder
            )
        }
        return DashboardWidgetLayout(version: version, widgets: updatedWidgets)
    }

    /// Toggles the `tileVisible` flag for one widget id and returns the
    /// updated layout. No-op when the id is unknown — defensive against a
    /// stale customisation screen referencing a widget the server has
    /// since removed.
    func togglingTileVisibility(forId id: String) -> DashboardWidgetLayout {
        let updatedWidgets = widgets.map { row -> DashboardWidgetConfig in
            guard row.id == id else { return row }
            return DashboardWidgetConfig(
                id: row.id,
                visible: row.visible,
                tileVisible: !row.effectiveTileVisible,
                order: row.order
            )
        }
        return DashboardWidgetLayout(version: version, widgets: updatedWidgets)
    }
}
