import Foundation

/// Fetches per-metric "Findings" (AI-Befunde) for the chart detail screen.
///
/// **Why a separate repo, not just `InsightsRepository`?** The detail view's
/// findings are driven by metric-specific server endpoints
/// (`blood-pressure-status`, `weight-status`, `pulse-status`, `mood-status`,
/// `bmi-status`, `medication-compliance-status`) that return a focused
/// `{hasProvider, text, cached, updatedAt}` envelope. The endpoints
/// gate AI behind a per-user provider config; when no provider is
/// configured, server emits `hasProvider: false, text: <hint>`.
///
/// **iOS never generates insights** — server-only
/// (PROJECT_GUIDE.md / `15-insights-architecture.md`). This repo is a thin GET
/// wrapper.
///
/// **v0.5.0+ PB1-Reconcile (H1):** the per-metric `*-status` endpoints
/// invoke a server-side LLM when the user has a provider configured —
/// identical data-flow to `/api/insights/generate` (Apple Guideline
/// 5.1.2(i)). Previously the chart-detail "Befunde" surface called
/// `fetch()` unconditionally, bypassing S7's consent gate that already
/// protected the Insights tab. The gate closure is now mandatory at the
/// call site (`ChartDetailStore.load()` skips the call when closed);
/// the repository itself stays a thin GET wrapper for testability.
public actor MetricInsightsRepository {
    private let api: APIClientProtocol
    /// Optional consent gate. When non-nil, ``fetch(metric:locale:)``
    /// short-circuits with `nil` if the gate evaluates to false — no
    /// network round-trip, no health-data leak past consent. `nil`
    /// (default) preserves the legacy unit-test ergonomics. AppContainer
    /// wires the production gate (same closure used by `InsightsStore`
    /// + `DailyBriefingStore`).
    private let consentGate: (@Sendable () async -> Bool)?
    /// W3 (v0.11 #22) — optional daily SWR cache. When wired,
    /// ``fetch(metric:locale:)`` paints from the **Berlin-day-anchored**
    /// `CachedSnapshot` first (yesterday's good assessment on a today-miss)
    /// and revalidates in the background, so the per-metric "Einschätzung"
    /// block has cache-first content on first frame. `nil` (default) keeps
    /// the legacy direct-fetch ergonomics for unit tests.
    private let swr: SWRCoordinator?

    public init(
        api: APIClientProtocol,
        consentGate: (@Sendable () async -> Bool)? = nil,
        swr: SWRCoordinator? = nil
    ) {
        self.api = api
        self.consentGate = consentGate
        self.swr = swr
    }

    /// Task #50 — whether a ``read`` may touch the daily SWR cache.
    /// `.cacheReadyText` peeks the cache for paint-first prose and writes back
    /// only ready text; `.bypass` (the poll path) hits the network directly so a
    /// transient `preparing`/null-text body never poisons the Berlin-day key.
    private enum CachePolicy {
        case cacheReadyText
        case bypass
    }

    /// Pulls the AI-Befund status envelope for a specific metric.
    ///
    /// - Parameters:
    ///   - metric: which metric the chart detail is currently showing.
    ///   - locale: BCP-47 locale tag — server uses it to localize the prose.
    /// - Returns: `nil` when (a) the metric has no assessment surface at all
    ///   (no dedicated route AND no generic-registry id — see
    ///   ``statusRequest(for:locale:)``), (b) the consent gate is closed (no
    ///   LLM call may fire), or (c) the fetch 404s (route not deployed) /
    ///   422s (registry rejects the id). UI surfaces a "no findings" state for
    ///   all nil cases. Otherwise the envelope as emitted by the dedicated
    ///   `/api/insights/{metric}-status` route or the generic
    ///   `/api/insights/metric-status?metric=<ID>` route (server v1.8.7.1).
    public func fetch(metric: MetricKind, locale: String) async throws -> MetricStatusDTO? {
        guard Self.statusRequest(for: metric, locale: locale) != nil else {
            return nil
        }
        if let consentGate {
            let allowed = await consentGate()
            guard allowed else {
                // MetricKind raw value is an enum case — operator-grade.
                // swiftlint:disable:next hllog_public_privacy_interpolation
                HLLog.api.info("MetricInsights.fetch gated by AI consent — skipped for \(metric.rawValue, privacy: .public)")
                return nil
            }
        }
        return try await read(metric: metric, locale: locale, cachePolicy: .cacheReadyText)
    }

    /// v0.11 W46 — un-gated **read** of the per-metric assessment, used by the
    /// web-mirror `InsightsMetricScreen`.
    ///
    /// **Why a second entry point that skips the consent gate.** The
    /// `/api/insights/{metric}-status` GET is *read-only* server-side (the route
    /// passes `readOnly: true`; a cache miss enqueues generation out of band and
    /// serves the last-good text — it never awaits the provider). Reading an
    /// assessment that the server has **already** generated transmits no new
    /// health data to any LLM, so Apple Guideline 5.1.2(i) — which governs the
    /// *transmission* before the *first generation* — does not apply to this
    /// path. The on-device consent gate that `fetch(metric:locale:)` enforces is
    /// for the surfaces that can *trigger* generation (the Insights-tab generate
    /// POST, the DailyBriefing POST); gating the read here only produced an
    /// iOS-vs-web divergence (operator: "web shows the BP Einschätzung, iOS does
    /// not"). The gating the operator does want — hide when standalone / no
    /// provider, show when online + provider configured — is carried by the
    /// server envelope itself (`hasProvider`) and `BackendAvailability.hasServer`
    /// at the render layer, not by this client-side consent gate.
    ///
    /// Returns `nil` for the same structural no-surface cases as
    /// ``fetch(metric:locale:)`` (no dedicated route AND no generic-registry id,
    /// or a 404/422). A non-nil result is the server envelope verbatim — incl.
    /// `hasProvider: false` + the localized "assistant disabled" hint when the
    /// user has no provider configured.
    public func fetchAssessment(metric: MetricKind, locale: String) async throws -> MetricStatusDTO? {
        guard Self.statusRequest(for: metric, locale: locale) != nil else {
            return nil
        }
        return try await read(metric: metric, locale: locale, cachePolicy: .cacheReadyText)
    }

    /// Task #50 — one un-cached poll of the per-metric assessment, used while
    /// the server is warming a cold/revalidating assessment.
    ///
    /// **Why a separate un-cached read.** The server serves the assessment
    /// stale-while-revalidate: a cold cache returns `{ hasProvider:true,
    /// text:null, preparing:true }` and generates the prose OUT OF BAND, exactly
    /// like the web — which then POLLS the endpoint until ready text lands
    /// (`src/hooks/use-insight-status.ts`, 4 s cadence, 12-attempt ceiling).
    /// iOS must mirror that poll. Routing the poll iterations through the daily
    /// SWR cache would write the transient `preparing`/null-text body THROUGH
    /// the cache (`SWRCoordinator.fetchCachingFirst` always writes-through),
    /// poisoning the Berlin-day key so the calm-cache-paint serves a null-text
    /// row instead of yesterday's good prose. So the poll always hits the
    /// network directly; only ready text is written back (by the caller, via
    /// ``cacheReadyAssessment``) so the next mount paints it instantly.
    ///
    /// Returns the server envelope verbatim (incl. `preparing`/`revalidating`/
    /// `insufficient`), or `nil` for the structural no-surface cases / a
    /// 404/422 — same contract as ``fetchAssessment``.
    public func pollAssessment(metric: MetricKind, locale: String) async throws -> MetricStatusDTO? {
        guard Self.statusRequest(for: metric, locale: locale) != nil else {
            return nil
        }
        return try await read(metric: metric, locale: locale, cachePolicy: .bypass)
    }

    /// Write a ready assessment through the daily SWR cache so the next mount of
    /// this metric page paints the prose instantly (cache-first). No-op when no
    /// SWR cache is wired (unit-test ergonomics) or the DTO carries no ready
    /// text — the cache must never store a `preparing`/null-text body.
    ///
    /// v0.14.10 W-INSIGHTSDATA — additionally requires `hasProvider`: the
    /// server's no-key fallback body carries `hasProvider:false` plus a
    /// NON-EMPTY localized hint, which satisfied `hasReadyText` and poisoned
    /// the Berlin-day key — the page then served the stale hint for the rest
    /// of the day even after the provider/consent state recovered server-side.
    public func cacheReadyAssessment(metric: MetricKind, locale: String, dto: MetricStatusDTO) async {
        guard let swr, dto.hasReadyText, dto.hasProvider else { return }
        let key = CacheKey.insightStatus(kind: metric, locale: locale, day: BerlinDayKey.string())
        await swr.writeThrough(key, value: dto)
    }

    /// Shared request → SWR/decode core for both the gated ``fetch`` and the
    /// un-gated ``fetchAssessment``. Callers pre-check the consent gate (or
    /// deliberately skip it); this method only resolves the request, runs it
    /// through the daily SWR cache when wired, and maps the 404/422
    /// "no-surface" arms onto `nil`.
    private func read(
        metric: MetricKind,
        locale: String,
        cachePolicy: CachePolicy
    ) async throws -> MetricStatusDTO? {
        guard let req = Self.statusRequest(for: metric, locale: locale) else {
            return nil
        }
        let api = api
        @Sendable func networkFetch() async throws -> MetricStatusDTO {
            try await api.send(req)
        }
        // W3 — route through the daily SWR cache when wired AND the policy allows
        // it. The key is anchored to the Berlin calendar day, so a today-miss
        // serves yesterday's cached assessment (paint-first) and the key flips to
        // a structural cache-miss → refetch the moment the Berlin day rolls over
        // (`BerlinDayKey`). Task #50: the poll path passes `.bypass` so a
        // transient `preparing`/null-text body is never written through the daily
        // key — only ready text reaches the cache (via `cacheReadyAssessment`).
        // The 404 "endpoint not deployed" arm is preserved on both paths and is
        // never cached (it surfaces empty findings).
        do {
            if cachePolicy == .cacheReadyText, let swr {
                let key = CacheKey.insightStatus(
                    kind: metric,
                    locale: locale,
                    day: BerlinDayKey.string()
                )
                // Paint-first: a non-stale cached row (today's ready text, OR —
                // since the key is Berlin-day-anchored — yesterday's good prose
                // for a metric not yet warmed today) returns instantly without a
                // round-trip. `cacheReadyAssessment` only ever stores ready text,
                // so the cache can never hand back a `preparing`/null-text body.
                // v0.14.10 W-INSIGHTSDATA — `hasProvider` is required too, so a
                // no-key hint row poisoned by the pre-fix write-through (or by
                // an older build) self-heals: it falls through to the network
                // instead of masquerading as the day's prose.
                if let cached = await swr.peek(key, as: MetricStatusDTO.self),
                   cached.value.hasReadyText,
                   cached.value.hasProvider
                {
                    return cached.value
                }
                // Cache miss / non-ready cached row → hit the network directly.
                // The result is written back ONLY when it carries ready text
                // (`cacheReadyAssessment`), so a cold `preparing` body never
                // poisons the daily key. Polling for the warmed prose is driven
                // by the call site via `pollAssessment`.
                let dto = try await networkFetch()
                await cacheReadyAssessment(metric: metric, locale: locale, dto: dto)
                return dto
            }
            return try await networkFetch()
        } catch let HLError.server(status, _, _) where status == 404 || status == 422 {
            // 404 — the generic route is not deployed yet (server v1.8.7.1 may
            // not be live at wire time). 422 — the route rejects an
            // unknown/specialised `metric` id via its closed registry enum.
            // Both mean "no findings for this metric", never a user-facing
            // error: surface empty findings.
            return nil
        }
    }

    /// v0.7.0 W-API-RENDER — pulls the per-metric ``MetricSummary`` (slopes +
    /// last-year average) out of `/api/insights/comprehensive`.
    ///
    /// The comprehensive digest already computes a 7/30/90-day regression
    /// slope and a `avg30LastYear` baseline per metric, but the chart-detail
    /// HeroStrip dropped every one of those fields. This accessor lets the
    /// `ChartDetailStore` decorate the hero with trend chips + a "vor 1 Jahr"
    /// delta sourced verbatim from the server (no on-device inference).
    ///
    /// Best-effort: returns `nil` when the metric has no entry in
    /// `digest.summaries`, when the digest is absent, or when the request
    /// fails. The caller treats `nil` as "no trend decoration" and renders
    /// the bare hero. This is **not** consent-gated here — the comprehensive
    /// digest is deterministic metric math (no LLM prose), but the
    /// `ChartDetailStore` only calls it when the chart is already loading the
    /// gated findings, so no extra surface appears past a closed gate.
    public func summary(metric: MetricKind) async throws -> MetricSummary? {
        guard let key = Self.summariesKey(for: metric) else { return nil }
        do {
            let req: APIRequest<AIInsightResponse> = .get("/api/insights/comprehensive")
            let response = try await api.send(req)
            return response.digest?.summaries?[key]
        } catch let HLError.server(status, _, _) where status == 404 {
            return nil
        } catch {
            // v0.7.1 H-1 — genuinely best-effort, per the doc above. Any
            // request failure (500 / network / decode) means "no trend
            // decoration", never a thrown error that could surface a
            // user-facing chart error on a decorative-only fetch. We trace
            // the non-404 case (404 is the expected "not deployed" arm and
            // stays silent) so the drop is never invisible, then return nil.
            HLLog.api
                .info(
                    "MetricInsights.summary best-effort drop for \(metric.rawValue, privacy: .public): \(LogSanitizer.redact(String(describing: error)))"
                )
            return nil
        }
    }

    // MARK: - Helpers

    /// Maps a `MetricKind` onto the UPPER_SNAKE key the comprehensive
    /// `digest.summaries` map uses (server `MeasurementType` enum, mirrored
    /// by `ServerMeasurementType`). Blood pressure resolves to the
    /// **systolic** summary — that's the value the BP hero leads with.
    /// Kinds the server doesn't summarise (sleep / steps / walking-* / BMI)
    /// are absent from the table, so the lookup returns `nil` and the hero
    /// renders without trend chips.
    nonisolated static func summariesKey(for metric: MetricKind) -> String? {
        summariesKeyTable[metric]
    }

    /// Static lookup table — a plain dictionary keeps `summariesKey` free of
    /// a 14-arm switch (cyclomatic-complexity budget) and makes the
    /// MetricKind → server-summaries-key contract auditable in one place.
    private nonisolated static let summariesKeyTable: [MetricKind: String] = [
        .weight: "WEIGHT",
        .bloodPressure: "BLOOD_PRESSURE_SYS",
        .pulse: "PULSE",
        .glucose: "BLOOD_GLUCOSE",
        .bodyFat: "BODY_FAT",
        .bodyTemperature: "BODY_TEMPERATURE",
        .spo2: "OXYGEN_SATURATION",
        .bodyWater: "TOTAL_BODY_WATER",
        .boneMass: "BONE_MASS",
        .restingHeartRate: "RESTING_HEART_RATE",
        .hrv: "HEART_RATE_VARIABILITY",
        .vo2Max: "VO2_MAX"
        // sleep / steps / walkingSpeed / walkingAsymmetry / walkingStepLength
        // / bmi deliberately absent — no comprehensive `summaries` entry.
    ]

    /// Resolves the status request for a metric, or `nil` when the metric has
    /// no assessment surface at all.
    ///
    /// Two-tier resolution (v0.11 W28a):
    /// 1. **Dedicated route** — the four kinds with a bespoke server generator
    ///    (`blood-pressure` / `weight` / `pulse` / `bmi`) keep their own
    ///    `*-status` path, queried by `locale` only.
    /// 2. **Generic route** — every kind present in ``metricStatusIDTable``
    ///    resolves to `/api/insights/metric-status?metric=<ID>&locale=<L>`
    ///    (server v1.8.7.1). The id is an UPPER_SNAKE `InsightMetric` key the
    ///    server's closed `metric-status-registry` accepts; an id the registry
    ///    rejects 422s and is caught as empty findings at the call site.
    /// 3. Otherwise `nil` — no request fires (cheaper than a guaranteed 404).
    nonisolated static func statusRequest(
        for metric: MetricKind,
        locale: String
    ) -> APIRequest<MetricStatusDTO>? {
        if let dedicated = dedicatedStatusPathTable[metric] {
            return .get(dedicated, query: [("locale", locale)])
        }
        if let id = metricStatusIDTable[metric] {
            return .get(
                "/api/insights/metric-status",
                query: [("metric", id), ("locale", locale)]
            )
        }
        return nil
    }

    /// The four kinds with a dedicated server-side assessment generator.
    /// Mirrors the route handlers under
    /// `src/app/api/insights/{metric}-status/route.ts`. `mood-status` and
    /// `medication-compliance-status` also exist server-side but have no
    /// chartable iOS `MetricKind`, so they stay unmapped (unreachable).
    /// These are NEVER routed through the generic `metric-status` endpoint —
    /// it 422s on the seven specialised ids by construction.
    private nonisolated static let dedicatedStatusPathTable: [MetricKind: String] = [
        .bloodPressure: "/api/insights/blood-pressure-status",
        .weight: "/api/insights/weight-status",
        .pulse: "/api/insights/pulse-status",
        // v0.11 W5 — `bmi-status` route confirmed deployed server-side.
        .bmi: "/api/insights/bmi-status"
    ]

    /// v0.11 W28a — `MetricKind` → generic `metric-status` `metric=` id.
    ///
    /// Every id here is VERIFIED present in the server's closed
    /// `METRIC_STATUS_IDS` registry (`src/lib/insights/metric-status-registry.ts`,
    /// server v1.8.7.1) — wiring these makes the "Einschätzung / KI-Auswertung"
    /// block visible on all ~29 generic metric pages instead of
    /// self-suppressing. The seven specialised ids
    /// (blood-pressure / pulse / weight / bmi / mood / medication / workouts)
    /// are deliberately absent — they keep their dedicated routes above.
    ///
    /// `bodyFat` is intentionally NOT wired: the registry contains no
    /// `BODY_FAT` id (anti-hallucination — confirmed against the source enum),
    /// so it remains the one chartable kind with no assessment surface.
    nonisolated static let metricStatusIDTable: [MetricKind: String] = [
        .spo2: "OXYGEN_SATURATION",
        .bodyTemperature: "BODY_TEMPERATURE",
        .respiratoryRate: "RESPIRATORY_RATE",
        .skinTemperature: "SKIN_TEMPERATURE",
        .glucose: "BLOOD_GLUCOSE",
        .restingHeartRate: "RESTING_HEART_RATE",
        .hrv: "HEART_RATE_VARIABILITY",
        .walkingHeartRate: "WALKING_HEART_RATE_AVERAGE",
        .pulseWaveVelocity: "PULSE_WAVE_VELOCITY",
        .vascularAge: "VASCULAR_AGE",
        .activeEnergy: "ACTIVE_ENERGY",
        .flightsClimbed: "FLIGHTS_CLIMBED",
        .distanceWalkingRunning: "WALKING_RUNNING_DISTANCE",
        .timeInDaylight: "TIME_IN_DAYLIGHT",
        .bodyWater: "TOTAL_BODY_WATER",
        .boneMass: "BONE_MASS",
        .fatFreeMass: "FAT_FREE_MASS",
        .fatMass: "FAT_MASS",
        .muscleMass: "MUSCLE_MASS",
        .leanBodyMass: "LEAN_BODY_MASS",
        .visceralFat: "VISCERAL_FAT",
        .walkingSpeed: "WALKING_SPEED",
        .walkingAsymmetry: "WALKING_ASYMMETRY",
        .walkingDoubleSupport: "WALKING_DOUBLE_SUPPORT",
        .walkingSteadiness: "WALKING_STEADINESS",
        .walkingStepLength: "WALKING_STEP_LENGTH",
        .audioExposureEnvironment: "AUDIO_EXPOSURE_ENV",
        .audioExposureHeadphone: "AUDIO_EXPOSURE_HEADPHONE",
        .sleep: "SLEEP_DURATION",
        .vo2Max: "VO2_MAX",
        .steps: "STEPS",
        // v0141 W-DATAPARITY (P2) — twelve registry-accepted ids the stale
        // table missed, so their "Einschätzung / KI-Befund" block
        // self-suppressed on the metric page even though the operator has the
        // data (STAIR_ASCENT 5645, STAIR_DESCENT 4385, SIX_MINUTE_WALK 109,
        // DAY_STRAIN 50, ENERGY_EXPENDITURE_KJ 50, CARDIO_RECOVERY 4). Every id
        // VERIFIED present in the server `METRIC_STATUS_IDS` registry
        // (`src/lib/insights/metric-status-registry.ts`, server main).
        .stairAscentSpeed: "STAIR_ASCENT_SPEED",
        .stairDescentSpeed: "STAIR_DESCENT_SPEED",
        .sixMinuteWalk: "SIX_MINUTE_WALK_DISTANCE",
        .cardioRecovery: "CARDIO_RECOVERY",
        .dayStrain: "DAY_STRAIN",
        .energyExpenditureKJ: "ENERGY_EXPENDITURE_KJ",
        .averageHeartRate: "AVERAGE_HEART_RATE",
        .maxHeartRate: "MAX_HEART_RATE",
        .painNRS: "PAIN_NRS",
        .gripStrength: "GRIP_STRENGTH",
        .waistCircumference: "WAIST_CIRCUMFERENCE",
        .waistToHeight: "WAIST_TO_HEIGHT"
    ]
}

// MARK: - Wire shape (v1.4.26)

/// Wire envelope of `/api/insights/{metric}-status`. Server source-of-truth:
/// `<server-repo>/src/lib/insights/{blood-pressure,weight,pulse,mood,bmi,medication-compliance}-status.ts`.
///
/// **Pre-v0.4.0 drift:** iOS expected `{ recommendations: [Insight] }`
/// (fictional). Decoding silently threw `keyNotFound("recommendations")`
/// which `ChartDetailStore` caught and swallowed — "Befunde" never
/// rendered for any user (A1-Audit §3.4, A4-Audit row 1).
///
/// - `hasProvider`: false when the user has not configured an AI provider
///   (settings → AI). In that state `text` is a localized hint.
/// - `text`: the localized prose paragraph (nil if no provider AND no
///   fallback hint emitted — current server always emits a string in
///   that case so optional is purely future-proofing).
/// - `cached`: true when the server reused a same-day cached generation.
/// - `updatedAt`: ISO8601 timestamp of the last generation; nil when no
///   provider configured.
public struct MetricStatusDTO: Codable, Sendable, Equatable {
    public let hasProvider: Bool
    public let text: String?
    public let cached: Bool
    public let updatedAt: Date?
    /// Task #50 — the server's read-only stale-while-revalidate signals.
    ///
    /// On a cold cache the route returns `{ hasProvider:true, text:null,
    /// preparing:true }` and warms the assessment OUT OF BAND; on an open-card
    /// refresh it serves the last-good text with `revalidating:true` while a
    /// fresh generation lands. Both mean **"keep polling until ready text
    /// arrives"** — the web (`use-insight-status.ts`) polls on
    /// `preparing || revalidating` and stops on a terminal payload. iOS
    /// previously DROPPED these keys (decoded only the four above), so a cold
    /// `preparing` body looked like "provider present, empty prose" →
    /// `AssessmentCard` self-suppressed → the text never surfaced even though
    /// the server produced it seconds later. Server source-of-truth:
    /// `src/lib/insights/metric-status.ts:MetricStatusResult`.
    public let preparing: Bool
    public let revalidating: Bool
    /// True when the metric has no readings at all — the server skipped the
    /// provider entirely (no LLM call). The card shows the calm
    /// "not enough data" state, NOT a spinner, and the caller stops polling.
    public let insufficient: Bool

    public init(
        hasProvider: Bool,
        text: String?,
        cached: Bool,
        updatedAt: Date?,
        preparing: Bool = false,
        revalidating: Bool = false,
        insufficient: Bool = false
    ) {
        self.hasProvider = hasProvider
        self.text = text
        self.cached = cached
        self.updatedAt = updatedAt
        self.preparing = preparing
        self.revalidating = revalidating
        self.insufficient = insufficient
    }

    private enum CodingKeys: String, CodingKey {
        case hasProvider, text, cached, updatedAt, preparing, revalidating, insufficient
    }

    /// b177 W-ASSESS2 — **tolerant-first decode.** This fetch must NEVER die
    /// on an additive/missing/drifted field: the server ships faster than the
    /// app (production v1.16.x enriched the status family), and
    /// `APIClient.decodePayload` masks any inner envelope-decode failure as a
    /// misleading top-level `keyNotFound 'hasProvider'` (the `try?` envelope
    /// arm swallows the real error, the fallback re-decodes the raw
    /// `{data,error}` envelope as the DTO). A thrown decode here killed the
    /// whole per-metric Einschätzung surface, so every field is now optional
    /// with a safe default:
    /// - `hasProvider` missing → `true` (only an EXPLICIT `false` means the
    ///   server's no-provider arm; a missing key on a newer/older server must
    ///   not suppress prose that is present).
    /// - `updatedAt` unparseable/odd-typed → `nil` (provenance line
    ///   self-suppresses) instead of sinking the entire body.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hasProvider = (try? c.decodeIfPresent(Bool.self, forKey: .hasProvider)) ?? true
        text = try? c.decodeIfPresent(String.self, forKey: .text)
        cached = (try? c.decodeIfPresent(Bool.self, forKey: .cached)) ?? false
        updatedAt = try? c.decodeIfPresent(Date.self, forKey: .updatedAt)
        // The three SWR signals are optional on the wire (the server omits a
        // false flag), so a missing key decodes to `false` — a terminal body.
        preparing = (try? c.decodeIfPresent(Bool.self, forKey: .preparing)) ?? false
        revalidating = (try? c.decodeIfPresent(Bool.self, forKey: .revalidating)) ?? false
        insufficient = (try? c.decodeIfPresent(Bool.self, forKey: .insufficient)) ?? false
    }

    // MARK: - Lifecycle classification (mirrors the web poll predicate)

    /// Non-empty ready prose is present. The card paints the assessment and the
    /// caller stops polling.
    public var hasReadyText: Bool {
        guard let text else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The server is still warming the assessment out of band: a provider is
    /// configured, ready text has NOT landed yet, the metric has data, and the
    /// preparing/revalidating signal is set. Mirrors the web's
    /// `preparing || revalidating` poll predicate, but iOS additionally gates on
    /// `!hasReadyText` so a `revalidating:true` body that already carries
    /// last-good prose still paints immediately (and keeps polling for the
    /// upgrade). Terminal (`false`) for no-provider, insufficient-data, and any
    /// body that already carries ready text with no in-flight refresh.
    public var isPreparing: Bool {
        guard hasProvider, !insufficient else { return false }
        if hasReadyText { return revalidating }
        return preparing || revalidating
    }
}
