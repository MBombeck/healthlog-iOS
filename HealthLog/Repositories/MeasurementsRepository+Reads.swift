// Read paths (recent / series / availability) split out of MeasurementsRepository.swift (pure move, W-FILELEN).
import Foundation

public extension MeasurementsRepository {
    func recent(limit: Int = 50) async throws -> [Measurement] {
        if isStandalone {
            return try await standaloneRecentUnion(kind: nil, limit: limit)
        }
        if let swr {
            return try await swr.fetchCachingFirst(
                .measurementsRecent(limit: limit),
                decoding: [Measurement].self,
                fetch: { try await self.fetchRecentDirect(limit: limit) }
            )
        }
        return try await fetchRecentDirect(limit: limit)
    }

    /// Direct (uncached) fetch. Kept as the single network code-path so
    /// both the cached + non-cached branches above share semantics.
    private func fetchRecentDirect(limit: Int) async throws -> [Measurement] {
        let req: APIRequest<MeasurementListWireResponse> = .get(
            "/api/measurements",
            query: [("limit", String(limit))]
        )
        let response = try await api.send(req)
        return MeasurementAggregator.mergeBloodPressure(response.measurements)
    }

    /// Filtered list for the chart-detail drill-down. Server-side filter would
    /// be ideal once `/api/measurements?type=…` is wired; until then we pull a
    /// larger page and filter client-side. `limit=400` is generous enough for
    /// ~1y of weekly readings without paging UI.
    ///
    /// **W1-1:** the underlying `recent(limit:)` is SWR-wrapped, so the
    /// per-kind filter is computed off the cached page on warm hits — no
    /// separate cache key for the kind-filter itself (same network request,
    /// just sliced differently for each caller).
    ///
    /// **v0.7.0 W-STEPS Layer 3 — series-routed recent for `.steps`.** For
    /// `MetricKind.prefersSeriesForRecent` kinds (today: `.steps`) the global
    /// limit-400 `/api/measurements` page is the wrong source: steps are
    /// stored server-side as one `stats:<id>:<day>` row per day, but a
    /// HK-power-user who walks all day produces dozens of per-sample step
    /// rows, so 400 most-recent rows could cover just a few weeks — which is
    /// exactly the operator-reported "Schritte alle Daten zeigt nichts"
    /// symptom once the drill-down asks for a wide range. Routing through
    /// `/api/measurements/series?kind=…&days=…` returns the dense per-day
    /// frame the server already aggregates, synthesized back into lightweight
    /// `Measurement` rows for the source-count + `MetricDataState` derivation
    /// the callers run. `days` is derived from `limit` so an `.all`-range
    /// caller (`limit >= 2000`) gets the full ~10y history; the default
    /// `limit=400` keeps the ~1y behaviour.
    func recent(kind: MetricKind, limit: Int = 400) async throws -> [Measurement] {
        if isStandalone {
            return try await standaloneRecentUnion(kind: kind, limit: limit)
        }
        if kind.prefersSeriesForRecent {
            // v0.7.0 W-STEPS Layer 3 — routed through the series path. See
            // `recentCumulative(kind:limit:)` in
            // `MeasurementsRepository+Cumulative.swift`.
            return try await recentCumulative(kind: kind, limit: limit)
        }
        // I-0 Item 5 — cumulative HK kinds whose `/series` endpoint is NOT wired
        // (active energy / flights / walking-distance / time-in-daylight: server
        // returns 422, so `kindSupportsSeries == false`). The PLAIN
        // `?type=X&limit=N` list page (the `recentKindScoped` path below) hits
        // the server's RAW per-sample fall-through — for a cumulative type that
        // is partial-day increments, not a per-day chartable series, so the
        // Insights page read empty / spun. The web chart fetches these with a
        // day-grouped SUM; iOS now mirrors that via the server's `groupBy=day`
        // collapse mode (one summed row per user-tz day). Steps stays on the
        // series path above (its `/series` IS wired); the other four route here.
        if kind.isCumulative, let typeKey = kind.availabilitySummaryKey {
            // Route through the kind-scoped fetch in `groupBy=day` mode (server
            // sums each user-tz day → one chartable row per day). See
            // `recentKindScoped(groupByDay:)`.
            return try await recentKindScoped(typeKey: typeKey, kind: kind, limit: limit, groupByDay: true)
        }
        // v0.14.10 BP-PAIR FIX — blood pressure is TWO wire rows (SYS + DIA)
        // merged by `MeasurementAggregator.mergeBloodPressure` on exact
        // `measuredAt`. The generic kind-scoped arm below would query
        // `?type=BLOOD_PRESSURE_SYS` (BP's `availabilitySummaryKey`), so the
        // page carried ONLY systolic rows and every merged Measurement came
        // back `.bloodPressure(systolic: s, diastolic: 0)` — the operator-
        // reported "Letzte Messung 124/0" on the Insights BP page + the
        // drill-down rows (regression introduced by the v0.14 DATA kind-scope
        // routing, commit f5204b4f; the chart stayed correct because it reads
        // `/api/measurements/series?kind=bloodPressure`, which carries both
        // components). Route BP through a PAIRED kind-scoped fetch that pulls
        // BOTH type pages and merges them, keeping the kind-scoped window
        // benefits without losing the diastolic half.
        if kind == .bloodPressure {
            return try await recentBloodPressurePairScoped(limit: limit)
        }
        // v0.14 DATA — no-series / aggregate / low-frequency HK kinds (incl. the
        // v1.10 IC kinds: falls, six-minute-walk, stair-*, breathing-
        // disturbances, cardio-recovery, wrist-temperature) get their chart from
        // `recentInRange` (no `/series`). Reading those off the global,
        // all-kinds, recency-sorted `recent(limit:)` page means a low-frequency
        // kind's rows fall out of the newest N on a HK power-user → empty chart
        // while the all-time HeroStrip value still paints ("value but no
        // chart"). Route these through a KIND-SCOPED server fetch
        // (`/api/measurements?type=<MeasurementType>`) so the kind's own history
        // always reaches the chart. Series-backed kinds already get a real
        // series and never reach here.
        if let typeKey = kind.availabilitySummaryKey {
            return try await recentKindScoped(typeKey: typeKey, kind: kind, limit: limit)
        }
        let all = try await recent(limit: limit)
        return all.filter { $0.kind == kind }
    }

    /// v0.14 DATA — server-side kind-scoped page via `?type=<MeasurementType>`.
    /// The route accepts a `type` filter (`src/app/api/measurements/route.ts`),
    /// so this returns ONLY the requested kind's rows — a kind-scoped wide
    /// window that survives a HK power-user's high-frequency noise in other
    /// kinds. SWR-cached under a per-type key. Filtered to `kind` defensively
    /// (BP sys/dia share a `type` family). A failure falls back to the global
    /// page so the chart never regresses to worse than before.
    ///
    /// I-0 Item 5 — `groupByDay` opts into the server's `groupBy=day` collapse
    /// mode for cumulative HK kinds (active energy / flights / walking-distance /
    /// time-in-daylight). Those are partial-day increments: the plain page hits
    /// the raw per-sample fall-through (empty/noisy chart), while `groupBy=day`
    /// returns one user-tz-day SUM row per day — the SAME daily-SUM contract the
    /// web chart uses (`CUMULATIVE_HK_TYPES` → `useSum`). The synthesized day
    /// rows (`id = day:<TYPE>:<dayKey>`) decode through `MeasurementWireDTO`. The
    /// cache key carries a `:day` suffix so the two modes never collide.
    ///
    /// v0.14.8 W3 (v1.15.13 adoption) — `sourceEq` threads the server-side
    /// management-list source filter into the query (validated against
    /// `measurementSourceEnum`, backed by the `(userId, source, measuredAt)`
    /// index, migration 0136). The cache key carries a `:src:<WIRE>` suffix so
    /// filtered pages never collide with the unfiltered page; the fallback arm
    /// re-applies the filter client-side so an older deploy degrades honestly.
    /// `internal` (not `private`) so `+SourceFiltered.swift` can route here.
    internal func recentKindScoped(
        typeKey: String,
        kind: MetricKind,
        limit: Int,
        groupByDay: Bool = false,
        sourceEq: MeasurementSource? = nil
    ) async throws -> [Measurement] {
        let fetch: @Sendable () async throws -> [Measurement] = { [api] in
            var query: [(String, String)] = [("limit", String(limit)), ("type", typeKey)]
            if groupByDay { query.append(("groupBy", "day")) }
            if let sourceEq { query.append(("sourceEq", sourceEq.wire.rawValue)) }
            let req: APIRequest<MeasurementListWireResponse> = .get(
                "/api/measurements",
                query: query
            )
            let response = try await api.send(req)
            return MeasurementAggregator.mergeBloodPressure(response.measurements)
        }
        var cacheType = groupByDay ? "\(typeKey):day" : typeKey
        if let sourceEq { cacheType += ":src:\(sourceEq.wire.rawValue)" }
        let rows: [Measurement]
        do {
            if let swr {
                rows = try await swr.fetchCachingFirst(
                    .measurementsRecentKind(type: cacheType, limit: limit),
                    decoding: [Measurement].self,
                    fetch: fetch
                )
            } else {
                rows = try await fetch()
            }
        } catch {
            // Defensive: a server that doesn't honour `type=` (older deploy)
            // must not blank the chart — fall back to the global page.
            let all = try await recent(limit: limit)
            return all.filter { $0.kind == kind && (sourceEq == nil || $0.source == sourceEq) }
        }
        return rows.filter { $0.kind == kind }
    }

    /// Unified data-state for one (kind, range) pair — the single source of
    /// truth callers should use for empty-vs-ready predicates. Eliminates the
    /// PA4 class of bug where a tile reads `/api/dashboard/summary` while the
    /// detail screen reads `/api/measurements/series` and the two disagree.
    ///
    /// Internally calls `recent(kind:, limit: 400)` (the same path the chart
    /// detail uses for `sourceCountsForRange`), then `MetricDataState.derive`
    /// to bucket the result into `.empty(.noData) / .empty(.outsideRange) /
    /// .empty(.sourceFiltered) / .ready`.
    ///
    /// `range` is expressed in days back from `now` — `30` matches the chart
    /// detail's `.month` default. `sourceFilter` mirrors the same enum the
    /// chart-detail SourcesChipStrip applies; `nil` = all sources.
    ///
    /// **Note (F1 perf):** Single-kind convenience. For multi-kind fan-out
    /// (e.g. dashboard tile-grid), prefer `recentAll(limit:)` + per-kind
    /// `MetricDataState.derive` locally to avoid N parallel network round-
    /// trips returning the same 400-row page.
    func state(
        kind: MetricKind,
        rangeDays: Int,
        sourceFilter: MeasurementSource? = nil,
        now: Date = .now
    ) async throws -> MetricDataState {
        let all = try await recent(kind: kind, limit: 400)
        return Self.deriveState(
            allSamples: all,
            rangeDays: rangeDays,
            sourceFilter: sourceFilter,
            now: now
        )
    }

    /// Multi-kind fan-out friendly: one wide fetch returning every kind, so
    /// the dashboard can derive per-kind `MetricDataState` locally without
    /// triggering N parallel `/api/measurements?limit=400` round-trips that
    /// each return the same page (F1 fix from PB5 review).
    ///
    /// Returns the raw merged page — callers route through `Self.deriveState`
    /// (or `MetricDataState.derive`) per kind to bucket into the four-way
    /// state enum.
    func recentAll(limit: Int = 400) async throws -> [Measurement] {
        try await recent(limit: limit)
    }

    /// Pure derivation helper — splits `allSamples` by `kind`, applies the
    /// `rangeDays` + optional `sourceFilter` window, and returns the four-
    /// way `MetricDataState`. Nonisolated + `Sendable`-safe so callers can
    /// dispatch it across kinds from any context (notably the dashboard
    /// `refreshMetricStates` fan-out).
    nonisolated static func deriveState(
        allSamples: [Measurement],
        kind: MetricKind,
        rangeDays: Int,
        sourceFilter: MeasurementSource? = nil,
        now: Date = .now
    ) -> MetricDataState {
        let perKind = allSamples.filter { $0.kind == kind }
        return deriveState(
            allSamples: perKind,
            rangeDays: rangeDays,
            sourceFilter: sourceFilter,
            now: now
        )
    }

    /// Variant for inputs already filtered to a single kind — used by the
    /// single-kind `state(kind:)` entry point above.
    private nonisolated static func deriveState(
        allSamples: [Measurement],
        rangeDays: Int,
        sourceFilter: MeasurementSource?,
        now: Date
    ) -> MetricDataState {
        let cutoff = now.addingTimeInterval(-Double(rangeDays) * 86400)
        let inRange = allSamples
            .filter { $0.recordedAt >= cutoff }
            .filter { sourceFilter == nil || $0.source == sourceFilter }
        return MetricDataState.derive(
            allSamples: allSamples,
            inRange: inRange,
            sourceFilterApplied: sourceFilter != nil
        )
    }

    /// - Parameter forceRevalidate: when `true`, bypasses the SWR fresh-enough
    ///   cache short-circuit and revalidates against the server (the offline
    ///   stale-serve fallback still applies). v0.11 W56 wires this for the
    ///   chart-detail post-preload pass: after the HK daily-stats refresh POSTs
    ///   today's fresh cumulative day-total (which invalidates this key), the
    ///   chart re-reads the series with `forceRevalidate: true` so today's bar
    ///   catches up without blocking the first paint. Default `false` keeps
    ///   every other caller cache-first.
    func series(kind: MetricKind, days: Int, forceRevalidate: Bool = false) async throws -> MeasurementSeries {
        // W1 Fix 1 / W-SERVER-SYNC — clamp to the server cap (see `clampDays` /
        // `serverDaysCap` in `+SeriesDaysCap.swift`). With the server v1.5.5
        // cap raised to 3650 the clamp is a no-op for every shipped range
        // (including `.all` = 3650), but it stays as a defensive ceiling. The
        // clamped value drives BOTH cache key + wire query so warm + cold
        // agree.
        let cappedDays = Self.clampDays(days)
        if isStandalone {
            return try await standaloneSeries(kind: kind, days: cappedDays)
        }
        if let swr {
            return try await swr.fetchCachingFirst(
                .measurementSeries(kind: kind, days: cappedDays),
                decoding: MeasurementSeries.self,
                forceRevalidate: forceRevalidate,
                fetch: { try await self.fetchSeriesDirect(kind: kind, days: cappedDays) }
            )
        }
        return try await fetchSeriesDirect(kind: kind, days: cappedDays)
    }

    private func fetchSeriesDirect(kind: MetricKind, days: Int) async throws -> MeasurementSeries {
        let req: APIRequest<MeasurementSeries> = .get(
            "/api/measurements/series",
            query: [("kind", kind.seriesKindKey), ("days", String(days))]
        )
        return try await api.send(req)
    }

    /// v0.13.1 IC — per-kind **has-data availability**, the signal the Insights
    /// strip gates each metric pill on. Sourced from the cheap slim summaries
    /// slice (`GET /api/analytics?slice=summaries`) — the SAME per-kind
    /// `count` map the web tab-strip uses (`metric-availability.ts`). Crucially
    /// this is an **all-time count per `MeasurementType`**, NOT a last-N-rows
    /// recency window, so a low-frequency kind (blood-pressure / weight) with
    /// months of history lights up its pill even on a HealthKit power-user whose
    /// recent rows are all steps/energy/HR — the operator-reported "BP and pulse
    /// just aren't in the Insights list" bug.
    ///
    /// Returns the set of `MetricKind`s with `count > 0`. **Standalone:** no
    /// `/api/*` request fires (server analytics is unreachable offline); returns
    /// an empty set — the caller unions it with the on-device `recent` snapshot,
    /// which is already the standalone HealthKit ∪ local union, so standalone
    /// availability is unchanged.
    func availableKinds() async throws -> Set<MetricKind> {
        if isStandalone { return [] }
        let summaries: MeasurementAvailabilityDTO = if let swr {
            try await swr.fetchCachingFirst(
                .measurementAvailability,
                decoding: MeasurementAvailabilityDTO.self,
                fetch: { try await self.fetchAvailabilityDirect() }
            )
        } else {
            try await fetchAvailabilityDirect()
        }
        return Self.kinds(withDataIn: summaries)
    }

    private func fetchAvailabilityDirect() async throws -> MeasurementAvailabilityDTO {
        let req: APIRequest<MeasurementAvailabilityDTO> = .get(
            "/api/analytics",
            query: [("slice", "summaries")]
        )
        return try await api.send(req)
    }

    /// Pure: map the summaries slice → the set of `MetricKind`s with ≥1
    /// observation all-time. A kind lights up when its server-summaries key
    /// (`MetricKind.availabilitySummaryKey`) carries `count > 0`. `nonisolated`
    /// + pure so the `MeasurementAvailabilityTests` can pin the contract without
    /// the actor.
    internal nonisolated static func kinds(withDataIn dto: MeasurementAvailabilityDTO) -> Set<MetricKind> {
        var result: Set<MetricKind> = []
        for kind in MetricKind.allCases {
            guard let key = kind.availabilitySummaryKey,
                  let summary = dto.summaries[key],
                  (summary.count ?? 0) > 0 else { continue }
            result.insert(kind)
        }
        return result
    }
}

private extension MetricKind {
    /// Mapping zum Server-`/api/measurements/series` `kind`-Query-Param.
    /// Dort verwendet der Server **camelCase Domain-Keys** (siehe Zod-Schema in
    /// `src/app/api/measurements/series/route.ts:20-31`), NICHT die Prisma-
    /// `MeasurementType`-Enum-Werte (`BLOOD_PRESSURE_SYS` etc.). BP wird auf
    /// `bloodPressure` gemappt — der Endpoint liefert sys + dia in einem Frame.
    var seriesKindKey: String {
        // Server `kindEnum` (`/api/measurements/series` zod schema) covers
        // weight, bloodPressure, pulse, glucose, bodyFat, oxygenSaturation,
        // totalBodyWater, boneMass, sleep, steps. NOT bodyTemperature
        // (server rejects with 422). We keep MetricKind.bodyTemperature for
        // HK readbacks but route the series query as `glucose` placeholder —
        // callers that ship bodyTemperature must short-circuit before query.
        //
        // **v0.5.2 F2 additions:** restingHeartRate / hrv / vo2Max have
        // server enum support (`RESTING_HEART_RATE` / `HEART_RATE_VARIABILITY`
        // / `VO2_MAX` since v1.4.30); their camelCase series-keys here are
        // the form the server zod schema accepts. walkingSpeed, walkingAsymmetry,
        // walkingStepLength and bmi have no server enum yet — pre-validate
        // through `ChartDetailStore.kindSupportsSeries` before querying.
        switch self {
        case .weight: "weight"
        case .bloodPressure: "bloodPressure"
        case .pulse: "pulse"
        case .glucose: "glucose"
        case .bodyFat: "bodyFat"
        case .bodyTemperature: "bodyTemperature" // not supported server-side; pre-validate before calling
        case .spo2: "oxygenSaturation"
        case .bodyWater: "totalBodyWater"
        case .boneMass: "boneMass"
        case .sleep: "sleep"
        case .steps: "steps"
        case .restingHeartRate: "restingHeartRate"
        case .hrv: "heartRateVariability"
        case .vo2Max: "vo2Max"
        // v0.5.2 F2 iOS-local kinds — server enum NOT yet present. The
        // string here is the camelCase form the server *would* accept once
        // the enum lands; until then `kindSupportsSeries` short-circuits.
        case .walkingSpeed: "walkingSpeed"
        case .walkingAsymmetry: "walkingAsymmetryPercentage"
        case .walkingStepLength: "walkingStepLength"
        case .walkingDoubleSupport: "walkingDoubleSupportPercentage"
        case .walkingSteadiness: "appleWalkingSteadiness"
        case .respiratoryRate: "respiratoryRate"
        case .audioExposureEnvironment: "environmentalAudioExposure"
        case .audioExposureHeadphone: "headphoneAudioExposure"
        case .bmi: "bodyMassIndex"
        // v0.8.3 W-D — camelCase form the server series route *would* accept;
        // today `kindSupportsSeries` short-circuits before the query fires.
        case .activeEnergy: "activeEnergyBurned"
        case .flightsClimbed: "flightsClimbed"
        case .distanceWalkingRunning: "walkingRunningDistance"
        case .timeInDaylight: "timeInDaylight"
        // v0.11 W21 — server/Withings-sourced web-parity kinds. camelCase form
        // the series route *would* accept; today `kindSupportsSeries`
        // short-circuits before the query fires (detail reads off the list page).
        case .fatFreeMass: "fatFreeMass"
        case .leanBodyMass: "leanBodyMass"
        case .muscleMass: "muscleMass"
        case .skinTemperature: "skinTemperature"
        case .pulseWaveVelocity: "pulseWaveVelocity"
        case .vascularAge: "vascularAge"
        case .visceralFat: "visceralFat"
        case .walkingHeartRate: "walkingHeartRateAverage"
        case .fatMass: "fatMass"
        // v0.13.1 IC — v1.10.0 additive signals. camelCase form the series
        // route *would* accept; today `kindSupportsSeries` short-circuits before
        // the query fires (detail reads off the list page + HK cache).
        case .falls: "fallCount"
        case .sixMinuteWalk: "sixMinuteWalkTestDistance"
        case .stairAscentSpeed: "stairAscentSpeed"
        case .stairDescentSpeed: "stairDescentSpeed"
        case .breathingDisturbances: "breathingDisturbances"
        case .cardioRecovery: "cardioRecovery"
        case .wristTemperature: "wristTemperature"
        // v0.14.6 — v1.12.8 WHOOP-native read types. camelCase form; detail
        // reads off the list page (no dedicated series query for these today).
        case .averageHeartRate: "averageHeartRate"
        case .maxHeartRate: "maxHeartRate"
        case .sleepDisturbanceCount: "sleepDisturbanceCount"
        // v0.14.1 W-B189 — v1.17.1 source-fixed render-only signals (#23).
        // camelCase form the series route *would* accept; today these are
        // list/detail-only (no dedicated series query), so the key is unused at
        // runtime but kept exhaustive + auditable.
        case .ansCharge: "ansCharge"
        case .cardioLoad: "cardioLoad"
        case .sleepScore: "sleepScore"
        case .bodyTemperatureDeviation: "bodyTemperatureDeviation"
        // v0158 — v1.25 clinical types. camelCase form the series route *would*
        // accept; today these are list/detail-only (no dedicated series query —
        // server `surfaces.detailPage == false`), so the key is unused at runtime
        // but kept exhaustive + auditable.
        case .painNRS: "painNRS"
        case .gripStrength: "gripStrength"
        case .waistCircumference: "waistCircumference"
        case .waistToHeight: "waistToHeight"
        // Build 3 / item 3.3 — the 21 decoder catch-up types. camelCase form the
        // series route *would* accept; today `kindSupportsSeries` short-circuits
        // before the query fires (list/detail-only), so the key is unused at
        // runtime but kept exhaustive + auditable like its predecessors.
        case .phq9Score: "phq9Score"
        case .gad7Score: "gad7Score"
        case .who5Score: "who5Score"
        case .sciScore: "sciScore"
        case .recoveryScore: "recoveryScore"
        case .stressScore: "stressScore"
        case .strainScore: "strainScore"
        case .hrvRMSSD: "hrvRmssd"
        case .dayStrain: "dayStrain"
        case .workoutStrain: "workoutStrain"
        case .sleepPerformance: "sleepPerformance"
        case .sleepEfficiency: "sleepEfficiency"
        case .sleepConsistency: "sleepConsistency"
        case .sleepNeed: "sleepNeed"
        case .energyExpenditureKJ: "energyExpenditureKj"
        case .resilience: "resilience"
        case .irregularRhythmNotification: "irregularRhythmNotification"
        case .highHeartRateEvent: "highHeartRateEvent"
        case .lowHeartRateEvent: "lowHeartRateEvent"
        case .walkingSteadinessEvent: "walkingSteadinessEvent"
        case .breathingDisturbanceEvent: "breathingDisturbanceEvent"
        // Build 7 / item 7.3 — mood is not a `Measurement` and has no
        // `/api/measurements/series` kind; `kindSupportsSeries` short-circuits
        // before this key is ever used, so the token is unused-but-auditable.
        case .mood: "mood"
        }
    }
}
