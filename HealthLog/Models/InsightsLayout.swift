import Foundation

// This file sat exactly at the 600-line `file_length` warning threshold before
// CU-20, so adding the concurrency token's explicit `encode(to:)` pushes it
// over. Disabled rather than split here: per PROJECT_GUIDE.md a split must be a pure
// move in its own `refactor` commit, and doing that inside a parallel-wave
// feature unit would collide with the other units merging alongside it. The
// natural split is lifting the `InsightsLayoutTileId` catalogue into its own
// file.
// swiftlint:disable file_length

/// Wire shape of `GET / PUT / DELETE /api/insights/layout` (server v1.5.5,
/// per `.planning/v080-marathon/SERVER-RESPONSE-v155.md`).
///
/// The endpoint makes the Insights tile order + visibility **server-first**
/// so the operator's layout syncs across devices — replacing the prior
/// iOS-local `@AppStorage` persistence in `InsightsTileCatalogue`.
///
/// - GET returns the resolved defaults-merged layout (never `null`).
/// - PUT replaces it atomically; body is `{ tiles: [{ id, visible, order }] }`.
/// - DELETE resets to server defaults.
/// - Unknown tile ids in a PUT body return HTTP 422.
///
/// **Tile-id namespace.** The server uses lowercase German-ish slugs
/// (`overview`, `blutdruck`, `puls`, `gewicht`, …) — NOT the iOS
/// `InsightsTargetsResponseDTO.TargetItem.type` enum (`WEIGHT`, `PULSE`, …).
/// `InsightsLayoutTileId` owns the translation so the store can speak the
/// server vocabulary on the wire and the iOS catalogue vocabulary in the UI.
public struct InsightsLayout: Codable, Sendable, Equatable {
    /// Layout schema version. The server route accepts `version: 1 | 2` on PUT
    /// (`src/app/api/insights/layout/route.ts`, v1.15.11+) and always persists
    /// the canonical v2 blob; a body without a version 422s with "Validation
    /// failed". Mirrors `DashboardWidgetLayout.version`.
    public let version: Int
    /// v1.15.11 layout v2 — the overview's section-level customization
    /// (`wellness-scores`, `daily-briefing`, …).
    ///
    /// **Parity Build 4 · 4.5:** iOS now renders and edits these too — see
    /// `InsightsLayoutSections.swift` for the catalogue, the defaults-merging
    /// `resolvedSections` read view, and the `reorderingSections` /
    /// `togglingSectionVisibility` mutation helpers. Before that they were a
    /// pure echo and the whole arrangement surface was unreachable from iOS.
    ///
    /// The stored array is still held VERBATIM (unknown future ids included);
    /// resolution happens on read. iOS used to MUST round-trip it as a
    /// workaround, but that is GONE (GH #19): server v1.16.13/1.16.14 now
    /// MERGE-preserves the stored sections on a PUT that omits the field, so a
    /// tiles-only iOS PUT no longer resets the web arrangement. `nil` = "never
    /// saw a v2 GET" (fresh install / legacy cache) and is simply sent as-is.
    /// Sections still round-trip through the mutation helpers when a layout
    /// already carries them (harmless). Encoded via `encodeIfPresent`, so a
    /// `nil` never serializes as an explicit `"sections": null`.
    public let sections: [InsightsLayoutSection]?
    public let tiles: [InsightsLayoutTile]
    /// CU-20 (#69) concurrency token — decode-only, see ``OptimisticWriteBody``.
    public let updatedAt: String?

    /// `INSIGHTS_LAYOUT_VERSION` literal the iOS client emits for layouts it
    /// synthesizes locally (no `sections` knowledge). The server accepts 1 and
    /// 2; a decoded server layout carries the server's own version (2) and the
    /// mutation helpers preserve it verbatim.
    public static let currentVersion = 1

    /// Explicit (not synthesized) so `decodeSectionsTolerantly` can reference
    /// the type in its signature — the implicitly synthesized `CodingKeys`
    /// is not nameable from a method parameter position.
    private enum CodingKeys: String, CodingKey {
        case version
        case sections
        case tiles
        case updatedAt
    }

    public init(
        version: Int = InsightsLayout.currentVersion,
        sections: [InsightsLayoutSection]? = nil,
        tiles: [InsightsLayoutTile],
        updatedAt: String? = nil
    ) {
        self.version = version
        self.sections = sections
        self.tiles = tiles
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Tolerate an absent `version` on legacy cached payloads — default to 1.
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? InsightsLayout.currentVersion
        sections = Self.decodeSectionsTolerantly(from: container)
        tiles = try container.decode([InsightsLayoutTile].self, forKey: .tiles)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
    }

    /// Explicit (previously synthesized) so CU-20's `updatedAt` stays read-only:
    /// the token rides the write as `baseUpdatedAt`, and echoing it back would
    /// add an unexpected field to a Zod-validated PUT body.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        // `nil` sections must never serialize as an explicit null.
        try container.encodeIfPresent(sections, forKey: .sections)
        try container.encode(tiles, forKey: .tiles)
    }

    /// Tolerant `sections` decode: an absent / non-array value yields `nil`
    /// (v1 blob, legacy cache); a malformed ELEMENT is skipped instead of
    /// failing the whole layout decode. Unknown section ids are NOT filtered
    /// and NOT normalized — whatever the server returned is held verbatim so
    /// the PUT echo can never drop a section a future server release added.
    private static func decodeSectionsTolerantly(
        from container: KeyedDecodingContainer<CodingKeys>
    ) -> [InsightsLayoutSection]? {
        guard var raw = try? container.nestedUnkeyedContainer(forKey: .sections) else { return nil }
        var decoded: [InsightsLayoutSection] = []
        while !raw.isAtEnd {
            if let section = try? raw.decode(InsightsLayoutSection.self) {
                decoded.append(section)
            } else if (try? raw.decode(JSONDecodeSink.self)) == nil {
                // Sink decode can't fail (its decoder consumes nothing), but
                // guard the loop against a theoretical non-advancing container.
                break
            }
        }
        return decoded
    }
}

/// Swallows one arbitrary JSON value so a tolerant unkeyed-container loop can
/// advance past a malformed element without failing the surrounding decode.
private struct JSONDecodeSink: Decodable {
    init(from _: Decoder) throws {}
}

/// One overview section row in the v2 layout (`v1.15.11`). The `id` is a bare
/// `String` — deliberately NOT an enum — so a section id introduced by a later
/// server release round-trips through the iOS echo untouched instead of being
/// dropped by a stale client-side catalogue. The KNOWN universe (for rendering
/// + editing, not for storage) is `InsightsLayoutSectionId.allInDefaultOrder`,
/// mirroring `INSIGHTS_SECTION_IDS` in `src/lib/insights-layout.ts`.
public struct InsightsLayoutSection: Codable, Sendable, Identifiable, Equatable, Hashable {
    public let id: String
    public let visible: Bool
    public let order: Int

    public init(id: String, visible: Bool, order: Int) {
        self.id = id
        self.visible = visible
        self.order = order
    }
}

/// One Insights tile row in the layout array.
public struct InsightsLayoutTile: Codable, Sendable, Identifiable, Equatable, Hashable {
    /// Server tile-id slug, English-canonical (see `InsightsLayoutTileId`).
    public let id: String
    public let visible: Bool
    public let order: Int

    public init(id: String, visible: Bool, order: Int) {
        self.id = id
        self.visible = visible
        self.order = order
    }

    /// v1.8.0 — normalise a decoded id (a GET from an older server, or a stale
    /// pre-rename instant-paint cache, may still carry German ids) onto the
    /// English canonical form so the render + `reconciled` paths speak one
    /// vocabulary. Encoding is the synthesised default — the `id` is already
    /// canonical English in memory, so a PUT emits English.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawId = try container.decode(String.self, forKey: .id)
        id = InsightsLayoutTileId.normalize(rawId)
        visible = try container.decode(Bool.self, forKey: .visible)
        order = try container.decode(Int.self, forKey: .order)
    }
}

// MARK: - Tile-id catalogue + iOS-type mapping

/// The server tile-id catalogue + the translation layer between the wire
/// slugs and the iOS `InsightsTargetsResponseDTO.TargetItem.type` vocabulary.
///
/// **v1.8.0 rename (English canonical).** The server renamed the Insights
/// tile-ids German→English in v1.8.0 (`docs/api/openapi.yaml` →
/// `InsightsLayoutBody`; `src/lib/insights-layout.ts` → `INSIGHTS_TILE_IDS`).
/// `GET` now returns the canonical English ids; `PUT` accepts either set but
/// normalises legacy German → English before persisting. So the iOS-canonical
/// vocabulary is now **English** (`overview`, `blood-pressure`, `pulse`,
/// `oxygen`, `body-temperature`, `weight`, `bmi`, `active-energy`, `workouts`,
/// `sleep`, `resting-pulse`, `hrv`, `mood`, `medications`).
///
/// The legacy German ids (`blutdruck`, `puls`, `sauerstoff`,
/// `koerpertemperatur`, `gewicht`, `aktive-energie`, `schlaf`, `ruhepuls`,
/// `stimmung`, `medikamente`) survive only as **decode aliases**
/// (`legacyAliases`) so a layout persisted before v1.8.0 (or a stale
/// instant-paint cache) still resolves — `normalize(_:)` collapses any
/// decoded id onto its English canonical form. iOS emits English on PUT.
public enum InsightsLayoutTileId {
    public static let overview = "overview"
    public static let bloodPressure = "blood-pressure"
    public static let pulse = "pulse"
    public static let oxygen = "oxygen"
    public static let bodyTemperature = "body-temperature"
    public static let respiratoryRate = "respiratory-rate"
    public static let weight = "weight"
    public static let bmi = "bmi"
    public static let bodyWater = "body-water"
    public static let boneMass = "bone-mass"
    public static let fatFreeMass = "fat-free-mass"
    public static let fatMass = "fat-mass"
    public static let muscleMass = "muscle-mass"
    public static let visceralFat = "visceral-fat"
    public static let leanBodyMass = "lean-body-mass"
    public static let activeEnergy = "active-energy"
    /// v0152 I2 — the daily-step-count Insights slug. The Home dashboard renders a
    /// distinct `MetricKind.steps` tile (steps ≠ `active-energy`/kcal), but no
    /// Insights subpage existed for it, so the Home steps tile tapped into nowhere
    /// (`selectInsightsMetric(.steps)` no-op'd — `.steps` had no slug). This slug
    /// maps `.steps` end-to-end (`InsightsTabSlug.slugToKind`).
    ///
    /// **Parity Build 4 / 4.1 — the tail-append workaround is gone.** The "server
    /// layout doesn't carry a steps tile" premise the append rested on has not
    /// been true since web v1.12: `steps` is a first-class `SUB_PAGE_METRIC` key
    /// (`src/lib/insights/sub-page-metric.ts:85`), so it is part of
    /// `INSIGHTS_TILE_IDS` and the server's layout resolver auto-merges it onto
    /// any older persisted layout (`src/lib/insights-layout.ts:229-243`, the v1.22
    /// fix that names `steps` explicitly). It is therefore in ``serverKnownIds``
    /// now and reaches the strip through its curated layout slot like every other
    /// metric — which also means the operator's order/visibility choice for Steps
    /// finally survives a PUT instead of being filtered out.
    public static let steps = "steps"
    public static let workouts = "workouts"
    public static let flightsClimbed = "flights-climbed"
    public static let walkingDistance = "walking-distance"
    /// v0.11 W28d — wired end-to-end: maps to `MetricKind.walkingSteadiness`
    /// (`appleWalkingSteadiness`, a 0–100 % fall-risk mobility quantity) via
    /// the HK registry + `InsightsTabSlug.slugToKind`. Renders a real activity-
    /// cluster pill once the user has ≥1 steadiness sample.
    public static let walkingSteadiness = "walking-steadiness"
    public static let walkingHeartRate = "walking-heart-rate"
    public static let walkingAsymmetry = "walking-asymmetry"
    public static let doubleSupportTime = "double-support-time"
    public static let stepLength = "step-length"
    public static let walkingSpeed = "walking-speed"
    public static let sleep = "sleep"
    public static let restingPulse = "resting-pulse"
    public static let hrv = "hrv"
    public static let pulseWaveVelocity = "pulse-wave-velocity"
    public static let vascularAge = "vascular-age"
    public static let environmentalAudio = "environmental-audio"
    public static let headphoneAudio = "headphone-audio"
    /// v0.11 W28b — server-accepted but no iOS `MetricKind` yet
    /// (`audioExposureEvent` is a supervised HK-registry addition for a later
    /// wave). Round-trips in the layout; no strip pill until the kind lands.
    public static let audioEvents = "audio-events"
    public static let daylight = "daylight"
    public static let bloodGlucose = "blood-glucose"
    public static let skinTemperature = "skin-temperature"
    public static let mood = "mood"
    public static let medications = "medications"
    /// W-B189 (#23) — the server-computed recovery sub-page slug (web
    /// `/insights/recovery`, server v1.17.1). A composite special page (strain /
    /// training-load / autonomic-charge + heart-and-energy family), NOT a single
    /// chartable `MetricKind`.
    ///
    /// **Parity Build 4 — deliberately NOT in ``serverKnownIds``.** The doc here
    /// used to claim it was ("included in `serverKnownIds` so the layout PUT
    /// round-trips it"); it never was, and it must not become one. `recovery` is a
    /// routed page (`src/app/insights/recovery/`) but NOT a `SUB_PAGE_METRIC` key,
    /// so it is absent from `INSIGHTS_TILE_IDS` / `ACCEPTED_INSIGHTS_TILE_IDS` and
    /// the layout route's `z.enum` would reject the WHOLE PUT body with a 422
    /// (`src/app/api/insights/layout/route.ts:53,84`). Recovery reaches the strip
    /// as a fixed pill instead (see `InsightsTabSelection.ordered`), exactly like
    /// the web tab strip pushes it as a hard-coded entry rather than a layout row
    /// (`insights-tab-strip.tsx:540-548`).
    public static let recovery = "recovery"

    // MARK: - Parity Build 4 / 4.1 — the v1.25 clinical slugs

    /// v1.25 web slugs (`sub-page-metric.ts:64,78,79,111`) whose `MetricKind` and
    /// Dashboard tile already shipped on iOS but which carried **no slug**, so
    /// `InsightsTabSlug.metricKind(forSlug:)` returned `nil`, the pill never
    /// rendered, and the visible Dashboard tile tapped into nothing. Wiring them
    /// here is the real fix behind Build 1's `AppRouter.selectInsightsMetric`
    /// fallback net (which stays, guarding the next kind added without a slug).
    public static let pain = "pain"
    public static let waist = "waist"
    public static let waistToHeight = "waist-to-height"
    public static let gripStrength = "grip-strength"

    // MARK: - v0.13.1 IC — v1.10.0 web-parity additive metric slugs

    /// `cardio-fitness` → `MetricKind.vo2Max`. The enum case + descriptor + a
    /// Dashboard tile already existed; only the slug was missing, so VO₂ max
    /// never produced an Insights pill. Now wired through `slugToKind`.
    public static let cardioFitness = "cardio-fitness"
    public static let falls = "falls"
    public static let sixMinuteWalk = "six-minute-walk"
    public static let stairAscentSpeed = "stair-ascent-speed"
    public static let stairDescentSpeed = "stair-descent-speed"
    public static let breathingDisturbances = "breathing-disturbances"
    public static let cardioRecovery = "cardio-recovery"
    public static let wristTemperature = "wrist-temperature"

    /// v0141 W-DATAPARITY (P4) — the v1.29 `nutrients` sub-page slug
    /// (`sub-page-metric.ts:149` → `SUB_PAGE_SLUGS` → `INSIGHTS_TILE_IDS`). No
    /// chartable iOS `MetricKind` yet (no strip pill), but it MUST be in
    /// ``serverKnownIds`` so `filteringForServer()` stops dropping the nutrients
    /// tile on every iOS layout PUT (identical class to the earlier `steps` bug).
    public static let nutrients = "nutrients"

    /// Every server-known (English canonical) tile-id. A PUT body containing an
    /// id outside this set is rejected by the server with a 422; the store
    /// filters unknown ids out of its wire payload defensively so an iOS-only
    /// future tile can never wedge the endpoint.
    ///
    /// v0.11 W28b — widened from the narrow 14-id set to the full
    /// `overview` + 37-slug universe the server's layout enum now accepts
    /// (`v0.11-server-to-ios-insights-layout-enum-WIDENED.md`). The layout enum
    /// and the metric universe now stay in lockstep with the server by
    /// construction. `audio-events` is accepted here so a persisted layout
    /// round-trips, even though it has no chartable `MetricKind` (and thus no
    /// strip pill) — `audioExposureEvent` is a HealthKit category/event type,
    /// not a continuous series (W28d). `walking-steadiness` now DOES map to a
    /// chartable kind (W28d).
    public static let serverKnownIds: Set<String> = [
        overview, bloodPressure, pulse, oxygen, bodyTemperature, respiratoryRate,
        weight, bmi, bodyWater, boneMass, fatFreeMass, fatMass, muscleMass,
        visceralFat, leanBodyMass, activeEnergy, workouts, flightsClimbed,
        walkingDistance, walkingSteadiness, walkingHeartRate, walkingAsymmetry,
        doubleSupportTime, stepLength, walkingSpeed, sleep, restingPulse, hrv,
        pulseWaveVelocity, vascularAge, environmentalAudio, headphoneAudio,
        audioEvents, daylight, bloodGlucose, skinTemperature, mood, medications,
        // v0.13.1 IC — v1.10.0 additive slugs (server `INSIGHTS_TILE_IDS` =
        // `overview` + `SUB_PAGE_SLUGS`, which now includes all eight). All
        // except `cardio-fitness` map to a brand-new `MetricKind`; the layout
        // PUT round-trips them since the server's enum accepts them.
        cardioFitness, falls, sixMinuteWalk, stairAscentSpeed, stairDescentSpeed,
        breathingDisturbances, cardioRecovery, wristTemperature,
        // Parity Build 4 / 4.1 — `steps` (a `SUB_PAGE_METRIC` key since web
        // v1.12) plus the four v1.25 clinical slugs. All five are in the server's
        // `INSIGHTS_TILE_IDS`, so they PUT cleanly; keeping `steps` out was what
        // made `filteringForServer()` silently drop the operator's Steps
        // order/visibility choice on every write.
        steps, pain, waist, waistToHeight, gripStrength,
        // v0141 W-DATAPARITY (P4) — `nutrients` (a v1.29 `SUB_PAGE_METRIC` key in
        // `INSIGHTS_TILE_IDS`); omitting it dropped the tile on every PUT (old `steps` bug).
        nutrients
        // NOTE: `recovery` is deliberately NOT here — it is a routed web page but
        // not a `SUB_PAGE_METRIC` key, so the layout route's enum 422s the whole
        // body. See the doc on `InsightsLayoutTileId.recovery`.
    ]

    /// Legacy (≤ v1.7.x) German tile-id → canonical English id. Mirrors the
    /// server's `LEGACY_INSIGHTS_TILE_ID_ALIASES` (`src/lib/insights-layout.ts`)
    /// so a GET from an older server, or a stale instant-paint cache persisted
    /// before the rename, decodes onto the English canon rather than being
    /// dropped by `reconciled(knownIds:)`. `overview`, `bmi`, `hrv`, `workouts`
    /// were already language-neutral and need no alias.
    public static let legacyAliases: [String: String] = [
        "blutdruck": bloodPressure,
        "puls": pulse,
        "sauerstoff": oxygen,
        "koerpertemperatur": bodyTemperature,
        "gewicht": weight,
        "aktive-energie": activeEnergy,
        "schlaf": sleep,
        "ruhepuls": restingPulse,
        "stimmung": mood,
        "medikamente": medications
    ]

    /// Collapse a legacy German id onto its canonical English id. Canonical
    /// ids (and genuinely-unknown ids) pass through unchanged — the
    /// `reconciled(knownIds:)` filter handles anything truly unrecognised.
    public static func normalize(_ id: String) -> String {
        legacyAliases[id] ?? id
    }

    /// iOS catalogue tile-type (`InsightsTargetsResponseDTO.TargetItem.type`
    /// / `InsightsTileCatalogue` id) → server layout slug (English canonical).
    /// Static table so the lookup stays a single audit point + dodges the
    /// cyclomatic-complexity budget a fat `switch` would trip.
    private static let catalogueTypeToServerId: [String: String] = [
        "WEIGHT": weight,
        "PULSE": pulse,
        "RESTING_HR": restingPulse,
        "MOOD_SCORE": mood,
        "MOOD_STABILITY": mood,
        "ACTIVITY_STEPS": activeEnergy,
        "MEDICATION_COMPLIANCE": medications,
        "SLEEP_DURATION": sleep,
        "BMI": bmi,
        "BLOOD_PRESSURE": bloodPressure,
        "OXYGEN_SATURATION": oxygen,
        "BODY_TEMPERATURE": bodyTemperature,
        "HRV": hrv
    ]

    /// Maps an iOS catalogue tile-type to its server layout slug, or `nil` for
    /// iOS-catalogue ids the server layout doesn't track.
    public static func serverId(forCatalogueType type: String) -> String? {
        catalogueTypeToServerId[type]
    }

    // MARK: - W-WIDGET-DEEPLINK (v0152) — canonical kind ⇄ slug map

    /// **The single source of truth mapping a chartable `MetricKind` to its
    /// kebab Insights layout slug** (e.g. `.weight` → `"weight"`,
    /// `.bloodPressure` → `"blood-pressure"`).
    ///
    /// This lives here on `InsightsLayoutTileId` (compiled into BOTH the app and
    /// the widget extension via the `HealthLog/Models` source membership) rather
    /// than on the app-only `InsightsTabSlug` so the widget process can build a
    /// per-metric `healthlog://insights/<slug>` deep link from the App-Group
    /// snapshot's camelCase `kindRaw`. `InsightsTabSlug.slugToKind` (app-only)
    /// is derived FROM this table by inversion so the forward + reverse views
    /// can never drift. Pairs mirror the server-canonical slug allowlist.
    static let kindToSlug: [MetricKind: String] = [
        .bloodPressure: bloodPressure,
        .pulse: pulse,
        .spo2: oxygen,
        .bodyTemperature: bodyTemperature,
        .respiratoryRate: respiratoryRate,
        .weight: weight,
        .bmi: bmi,
        .bodyWater: bodyWater,
        .boneMass: boneMass,
        .fatFreeMass: fatFreeMass,
        .fatMass: fatMass,
        .muscleMass: muscleMass,
        .visceralFat: visceralFat,
        .leanBodyMass: leanBodyMass,
        .activeEnergy: activeEnergy,
        .steps: steps,
        .flightsClimbed: flightsClimbed,
        .distanceWalkingRunning: walkingDistance,
        .walkingHeartRate: walkingHeartRate,
        .walkingAsymmetry: walkingAsymmetry,
        .walkingDoubleSupport: doubleSupportTime,
        .walkingSteadiness: walkingSteadiness,
        .walkingStepLength: stepLength,
        .walkingSpeed: walkingSpeed,
        .sleep: sleep,
        .restingHeartRate: restingPulse,
        .hrv: hrv,
        .pulseWaveVelocity: pulseWaveVelocity,
        .vascularAge: vascularAge,
        .audioExposureEnvironment: environmentalAudio,
        .audioExposureHeadphone: headphoneAudio,
        .timeInDaylight: daylight,
        .glucose: bloodGlucose,
        .skinTemperature: skinTemperature,
        .vo2Max: cardioFitness,
        .falls: falls,
        .sixMinuteWalk: sixMinuteWalk,
        .stairAscentSpeed: stairAscentSpeed,
        .stairDescentSpeed: stairDescentSpeed,
        .breathingDisturbances: breathingDisturbances,
        .cardioRecovery: cardioRecovery,
        .wristTemperature: wristTemperature,
        // Parity Build 4 / 4.1 — the four v1.25 clinical kinds. Each already had
        // a `MetricKind` + a Dashboard tile; without these rows the tile was a
        // dead tap (audit 02-insights §B).
        .painNRS: pain,
        .waistCircumference: waist,
        .waistToHeight: waistToHeight,
        .gripStrength: gripStrength
    ]

    /// Slug → chartable `MetricKind`, derived once by inverting ``kindToSlug``
    /// so the two views stay in lockstep by construction. Keys are the kebab
    /// layout slugs (`InsightsLayoutTileId` constants). `InsightsTabSlug`
    /// (app-only) wraps this with normalisation; the widget uses ``slug(forKind:)``
    /// directly.
    static let slugToKind: [String: MetricKind] = {
        var map: [String: MetricKind] = [:]
        for (kind, slug) in kindToSlug {
            map[slug] = kind
        }
        return map
    }()

    /// The kebab Insights slug for a chartable `MetricKind`, or `nil` for a kind
    /// with no Insights page. Widget-reachable (plattform-free) so the
    /// `LatestMeasurement` widget can build `healthlog://insights/<slug>` from
    /// the snapshot's `kindRaw`.
    public static func slug(forKind kind: MetricKind) -> String? {
        kindToSlug[kind]
    }

    /// The chartable `MetricKind` for a kebab Insights slug, or `nil` for a
    /// non-chart / unknown slug. Normalises legacy German aliases first.
    public static func kind(forSlug slug: String) -> MetricKind? {
        slugToKind[normalize(slug)]
    }
}

// MARK: - Defaults

public extension InsightsLayout {
    /// Local bootstrap layout — rendered before the first GET round-trip
    /// completes and used as the offline fallback. Mirrors the server's
    /// default catalogue ordering with every tile visible (Apple-Health
    /// opt-out, not opt-in). The Insights surface still auto-hides empty
    /// tiles regardless of this flag.
    static let `default` = InsightsLayout(tiles: [
        InsightsLayoutTile(id: InsightsLayoutTileId.overview, visible: true, order: 0),
        InsightsLayoutTile(id: InsightsLayoutTileId.weight, visible: true, order: 1),
        InsightsLayoutTile(id: InsightsLayoutTileId.bloodPressure, visible: true, order: 2),
        InsightsLayoutTile(id: InsightsLayoutTileId.pulse, visible: true, order: 3),
        InsightsLayoutTile(id: InsightsLayoutTileId.restingPulse, visible: true, order: 4),
        InsightsLayoutTile(id: InsightsLayoutTileId.mood, visible: true, order: 5),
        InsightsLayoutTile(id: InsightsLayoutTileId.activeEnergy, visible: true, order: 6),
        InsightsLayoutTile(id: InsightsLayoutTileId.medications, visible: true, order: 7),
        InsightsLayoutTile(id: InsightsLayoutTileId.sleep, visible: false, order: 8),
        InsightsLayoutTile(id: InsightsLayoutTileId.bmi, visible: false, order: 9),
        InsightsLayoutTile(id: InsightsLayoutTileId.oxygen, visible: false, order: 10),
        InsightsLayoutTile(id: InsightsLayoutTileId.bodyTemperature, visible: false, order: 11),
        InsightsLayoutTile(id: InsightsLayoutTileId.hrv, visible: false, order: 12),
        InsightsLayoutTile(id: InsightsLayoutTileId.workouts, visible: false, order: 13),
        // Parity Build 4 / 4.1 — `steps` plus the four v1.25 clinical slugs. Each
        // ships a Dashboard tile whose tap deep-links into Insights, so the
        // BOOTSTRAP layout (used before the first GET completes, and offline) has
        // to enumerate them or the deep link parks a slug no pager page exists
        // for. `visible: true` matches the server resolver's auto-merge semantics
        // (v1.22 — late-added tiles inherit the default's visibility); the
        // per-metric availability gate still keeps an empty metric off the strip.
        InsightsLayoutTile(id: InsightsLayoutTileId.steps, visible: true, order: 14),
        InsightsLayoutTile(id: InsightsLayoutTileId.pain, visible: true, order: 15),
        InsightsLayoutTile(id: InsightsLayoutTileId.waist, visible: true, order: 16),
        InsightsLayoutTile(id: InsightsLayoutTileId.waistToHeight, visible: true, order: 17),
        InsightsLayoutTile(id: InsightsLayoutTileId.gripStrength, visible: true, order: 18)
    ])
}

// MARK: - Helpers

public extension InsightsLayout {
    /// Tiles whose `visible` flag is true, sorted ascending by `order`.
    var visibleTiles: [InsightsLayoutTile] {
        tiles.filter(\.visible).sorted { $0.order < $1.order }
    }

    /// All tiles sorted ascending by `order` (visible + hidden).
    var orderedTiles: [InsightsLayoutTile] {
        tiles.sorted { $0.order < $1.order }
    }

    /// v0.14.1 — the strip-customise model: every tile, sorted by `order`,
    /// EXCLUDING the mandatory `overview` row. "Übersicht" is always the first,
    /// non-hideable pill (see `InsightsTabSelection.ordered`), so it does not
    /// appear as a reorderable/hideable row in the customise sheet. The screen
    /// further narrows this to strip-renderable tabs (chartable metrics +
    /// special pages) — that narrowing lives in the app target because the
    /// slug↔kind table is app-only; this Core helper just drops `overview`.
    var stripCustomizableTiles: [InsightsLayoutTile] {
        orderedTiles.filter { $0.id != InsightsLayoutTileId.overview }
    }

    /// Re-orders rows by replacing each row's `order` with its position in
    /// `newOrder` (matched by id). Rows not present in `newOrder` (hidden tiles
    /// the partial visible-only order omits) keep their relative sequence after
    /// the listed entries.
    ///
    /// A2 (v0.8.2 W1a) — `remaining` is seeded from the tiles sorted by `order`
    /// (NOT the raw array order), so the hidden tail preserves its `order`-
    /// relative sequence regardless of how the decoded server array happened to
    /// be ordered. Keeps the AddTileSheet hidden-tile gallery stable.
    func reordering(_ newOrder: [String]) -> InsightsLayout {
        var remaining = tiles.sorted { $0.order < $1.order }
        var output: [InsightsLayoutTile] = []
        for (index, id) in newOrder.enumerated() {
            if let i = remaining.firstIndex(where: { $0.id == id }) {
                let original = remaining.remove(at: i)
                output.append(InsightsLayoutTile(id: original.id, visible: original.visible, order: index))
            }
        }
        let baseOrder = output.count
        for (offset, row) in remaining.enumerated() {
            output.append(InsightsLayoutTile(id: row.id, visible: row.visible, order: baseOrder + offset))
        }
        return InsightsLayout(version: version, sections: sections, tiles: output)
    }

    /// Flips the `visible` flag for one tile id. No-op for unknown ids.
    func togglingVisibility(forId id: String) -> InsightsLayout {
        let updated = tiles.map { row -> InsightsLayoutTile in
            guard row.id == id else { return row }
            return InsightsLayoutTile(id: row.id, visible: !row.visible, order: row.order)
        }
        return InsightsLayout(version: version, sections: sections, tiles: updated)
    }

    /// Drops rows whose id is not in `InsightsLayoutTileId.serverKnownIds`.
    /// The filtered layout is what iOS sends on PUT; the server rejects any
    /// unknown id with a 422, so this guard keeps the write path resilient
    /// to an iOS-only future tile that the server doesn't yet model.
    func filteringForServer() -> InsightsLayout {
        let known = InsightsLayoutTileId.serverKnownIds
        let filtered = tiles.filter { known.contains($0.id) }
        guard filtered.count != tiles.count else { return self }
        return InsightsLayout(version: version, sections: sections, tiles: filtered)
    }

    /// Reconciles a freshly-decoded server layout: drops any tile id the iOS
    /// catalogue doesn't recognise (forward-compat — server adds a tile iOS
    /// can't render yet) while keeping the known ids in their server order.
    /// Unknown-but-present ids are preserved at the tail so a server-driven
    /// addition still round-trips through a later PUT instead of being
    /// silently dropped on the next write. `sections` pass through VERBATIM —
    /// no filter, no renumber — they are the web client's customization and
    /// the iOS contract is a byte-faithful echo (A1).
    func reconciled(knownIds: Set<String> = InsightsLayoutTileId.serverKnownIds) -> InsightsLayout {
        let ordered = orderedTiles
        let known = ordered.filter { knownIds.contains($0.id) }
        let unknown = ordered.filter { !knownIds.contains($0.id) }
        // Renumber so order is contiguous after the partition.
        let merged = (known + unknown).enumerated().map { offset, row in
            InsightsLayoutTile(id: row.id, visible: row.visible, order: offset)
        }
        return InsightsLayout(version: version, sections: sections, tiles: merged)
    }
}

// swiftlint:enable file_length
