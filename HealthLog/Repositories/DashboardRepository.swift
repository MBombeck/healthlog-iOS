import Foundation

public actor DashboardRepository {
    private let api: APIClientProtocol
    /// v0.11 W2 — standalone seam. `nil` (default) → server `summary()` verbatim
    /// (paired invariant). Non-nil + live standalone → the summary is aggregated
    /// locally from the mirror + HealthKit-direct reads; no `/api/*` fires. The
    /// per-tile `MetricDataState` fan-out (`DashboardStore.refreshMetricStates`)
    /// independently routes through the already-standalone `MeasurementsRepository`
    /// — this only supplies the seed.
    private let standalone: StandaloneGate?

    /// **CU-20 (#69)** — last `updatedAt` from `/api/dashboard/widgets` (GET,
    /// PUT echo, or DELETE reset echo). `nil` → unconditional write.
    private var widgetLayoutToken: String?

    /// Test/diagnostic accessor for the held concurrency token.
    public func currentWidgetLayoutToken() -> String? {
        widgetLayoutToken
    }

    public init(api: APIClientProtocol, standalone: StandaloneGate? = nil) {
        self.api = api
        self.standalone = standalone
    }

    public func summary() async throws -> DashboardSummary {
        if standalone?.isActive == true {
            return try await standaloneSummary()
        }
        let req: APIRequest<DashboardSummary> = .get("/api/dashboard/summary")
        return try await api.send(req)
    }

    /// Builds a `DashboardSummary` from on-device data only: the latest local
    /// manual row per kind ∪ the latest HealthKit-direct sample for the
    /// adapter-supported kinds (weight / pulse / steps). Compliance is left empty
    /// in W2 — local medication compliance aggregation is the noted W2b
    /// follow-up; the tiles still populate from the metric-state fan-out.
    private func standaloneSummary() async throws -> DashboardSummary {
        guard let standalone else {
            return Self.emptyStandaloneSummary()
        }
        // Latest local manual row per kind.
        let localSnaps = try await standalone.local.standaloneMeasurements(kind: nil, limit: nil)
        var latestByKind: [MetricKind: Measurement] = [:]
        for snap in localSnaps {
            let measurement = snap.toDomainMeasurement()
            // #33 — never let a malformed 0-systolic/0-diastolic BP row become the
            // standalone tile's "latest"; the shared guard is a no-op for every
            // non-BP kind, so a valid earlier BP wins the latest slot instead.
            guard measurement.isDisplayableLatest else { continue }
            if let existing = latestByKind[measurement.kind], existing.recordedAt >= measurement.recordedAt {
                continue
            }
            latestByKind[measurement.kind] = measurement
        }
        // HealthKit-direct latest for the adapter-supported kinds (W1 coverage).
        for kind in MeasurementsRepository.standaloneHKKinds {
            let points: [SeriesPoint] = if kind.standaloneIsCumulative {
                await standalone.healthKit.standaloneDailySeries(kind: kind, days: 7)
            } else {
                await standalone.healthKit.standaloneRecentSamples(kind: kind, days: 30, limit: 1)
            }
            guard let latest = points.max(by: { $0.at < $1.at }) else { continue }
            if let existing = latestByKind[kind], existing.recordedAt >= latest.at { continue }
            latestByKind[kind] = Measurement(
                id: "hk-\(kind.rawValue)-\(latest.id)",
                kind: kind,
                recordedAt: latest.at,
                value: .scalar(latest.value),
                source: .appleHealth
            )
        }
        let metrics: [DashboardMetric] = latestByKind.values
            .sorted { $0.kind.rawValue < $1.kind.rawValue }
            .map { measurement in
                DashboardMetric(
                    id: "local-\(measurement.kind.rawValue)",
                    kind: measurement.kind,
                    title: measurement.kind.displayName,
                    latestValue: measurement.primaryValue,
                    secondaryValue: {
                        if case let .bloodPressure(_, dia) = measurement.value { return dia }
                        return nil
                    }(),
                    unit: measurement.kind.unit,
                    trend: .unknown,
                    sparkline: [],
                    updatedAt: measurement.recordedAt
                )
            }
        return DashboardSummary(
            greeting: Greeting(salutation: "", date: .now),
            compliance: ComplianceSnapshot(scheduledToday: 0, takenToday: 0),
            highlightInsight: nil,
            metrics: metrics,
            lastUpdated: .now
        )
    }

    private static func emptyStandaloneSummary() -> DashboardSummary {
        DashboardSummary(
            greeting: Greeting(salutation: "", date: .now),
            compliance: ComplianceSnapshot(scheduledToday: 0, takenToday: 0),
            highlightInsight: nil,
            metrics: [],
            lastUpdated: .now
        )
    }

    /// Thin briefing read off `GET /api/dashboard/snapshot` (server v1.7.0+).
    ///
    /// **v1.16.x tolerant-first (GH issue #15):** decodes ONLY the four
    /// briefing fields (`briefing` / `briefingState` / `briefingUpdatedAt` /
    /// `briefingStale`) via the tolerant ``DashboardSnapshotBriefing`` DTO —
    /// unknown `briefingState` values land in `.unknown`, absent
    /// `briefingStale` defaults `false`. No LLM is reachable from this route
    /// server-side (read-only lift of the pre-generated cache), so the call
    /// is NOT consent-gated — it transmits no health data to any provider.
    ///
    /// Returns `nil` in standalone mode (no `/api/*` fires) — the on-device /
    /// Statistik-Mode briefing ladder is the surface there anyway.
    public func snapshotBriefing() async throws -> DashboardSnapshotBriefing? {
        if standalone?.isActive == true { return nil }
        let req: APIRequest<DashboardSnapshotBriefing> = .get("/api/dashboard/snapshot")
        return try await api.send(req)
    }

    /// Pulls the per-user dashboard widget layout (visibility + order).
    /// Server source: `src/app/api/dashboard/widgets/route.ts:96-106`.
    ///
    /// The server resolves missing rows + defaults internally — we never
    /// see `null`; if the user has never customised, server returns the
    /// merged-with-defaults `DEFAULT_DASHBOARD_LAYOUT` shape.
    ///
    /// **v0.10 W10-PIN (server v1.7.0 LIVE):** the server's widget enum now
    /// accepts + round-trips the full 27-id catalogue (issue #11 resolved
    /// server-side), so the GET carries every iOS widget id directly. The
    /// former `byMergingIosOnlyDefaults()` drift-stabiliser is gone — no
    /// iOS-only id subset to re-attach.
    public func widgetLayout() async throws -> DashboardWidgetLayout {
        let req: APIRequest<DashboardWidgetLayout> = .get("/api/dashboard/widgets")
        let layout = try await api.send(req)
        widgetLayoutToken = layout.updatedAt // CU-20 token for the next PUT
        return layout
    }

    /// Replaces the layout atomically. Server validates via Zod
    /// (`route.ts:38-94`) over the full 27-id catalogue. The PUT preserves
    /// the server's chart-overlay prefs because the payload omits
    /// `chartOverlayPrefs` and the server merges it in (`route.ts:124-138`).
    ///
    /// **v0.10 W10-PIN (server v1.7.0 LIVE):** the server now accepts all
    /// 27 widget ids, so the former `filteringForServer()` /
    /// `byRestoringIosOnlyWidgets(from:)` round-trip workaround is gone —
    /// the layout is sent + echoed in full.
    ///
    /// **CU-20 (#69):** guarded by `baseUpdatedAt` — a stale token returns
    /// `409 dashboard_layout_conflict` with nothing written, and the retry is
    /// bounded (this GET is cached 300 s server-side, so a post-conflict
    /// re-read can keep returning the same stale token).
    @discardableResult
    public func setWidgetLayout(_ layout: DashboardWidgetLayout) async throws -> DashboardWidgetLayout {
        try await withOptimisticConflictRetry(
            conflictCode: OptimisticConflictCode.dashboardLayout,
            token: widgetLayoutToken
        ) { token in
            let req: APIRequest<DashboardWidgetLayout> = try .put(
                "/api/dashboard/widgets",
                body: OptimisticWriteBody(payload: layout, baseUpdatedAt: token)
            )
            let echoed = try await api.send(req)
            widgetLayoutToken = echoed.updatedAt
            return echoed
        } reread: {
            try await widgetLayout().updatedAt // full replace — only the token moves
        }
    }

    /// **Parity 1.2 — reset the layout the way the web does.**
    ///
    /// `DELETE /api/dashboard/widgets` (`route.ts:338-353`) nulls the
    /// `dashboardWidgetsJson` column, so the next read re-resolves the layout
    /// dynamically from the SERVER default. That is materially different from
    /// PUTting a materialised local default: `DashboardWidgetLayout.default`
    /// is missing twelve ids the server knows (`breathingDisturbances`,
    /// `cardioRecovery`, `falls`, `muscleMass`, `recentWorkouts`,
    /// `sixMinuteWalk`, `stairAscentSpeed`, `stairDescentSpeed`, `vorsorge`,
    /// `walkingSteadiness`, `waterIntake`, `wristTemperature`), which
    /// `resolveDashboardLayout` then re-appends at `visible:false,
    /// tileVisible:false` — an iOS reset left the WEB dashboard with a dozen
    /// force-hidden tiles. The PUT also omitted the ring fields, so an iOS
    /// "reset" never reset the hero rings while a web reset did.
    ///
    /// The handler echoes the server default; callers still re-GET so the
    /// resolved (defaults-merged) layout is what lands in the store.
    public func resetWidgetLayout() async throws {
        let req: APIRequest<DashboardWidgetLayout> = .delete("/api/dashboard/widgets")
        let echoed = try await api.send(req)
        // CU-20 — unlike the insights/medications resets, THIS DELETE echoes a
        // fresh token (`route.ts:413-451`), so adopt it rather than clearing.
        widgetLayoutToken = echoed.updatedAt
    }
}

public actor InsightsRepository {
    private let api: APIClientProtocol
    public init(api: APIClientProtocol) {
        self.api = api
    }

    /// iOS-Adapter-Endpunkt der `/api/insights/comprehensive` zu Insight-Cards mappt.
    public func cards() async throws -> [Insight] {
        let req: APIRequest<[Insight]> = .get("/api/insights/cards")
        return try await api.send(req)
    }

    /// Comprehensive payload (`AIInsightResponse`) — the mother-page shape
    /// per `15-insights-architecture.md §"The AIInsightResponse Zod schema"`.
    /// Carries the daily briefing slot. Server-cached read; iOS does **not**
    /// regenerate locally on pull-to-refresh (mutation invalidates server-side).
    public func comprehensive() async throws -> AIInsightResponse {
        let req: APIRequest<AIInsightResponse> = .get("/api/insights/comprehensive")
        return try await api.send(req)
    }

    public func correlations() async throws -> [CorrelationFinding] {
        let req: APIRequest<[CorrelationFinding]> = .get("/api/insights/correlations")
        return try await api.send(req)
    }

    /// Lazily generates (or returns the cached) Daily Briefing.
    ///
    /// **Endpoint:** `POST /api/insights/generate` (server-cached per-user-per-day).
    /// **Body shape:** `{ force: Bool, scope?: String, locale?: String }`. `scope` and
    /// `locale` default server-side; iOS only sets `force` to bypass the 24h cache
    /// on user-initiated refresh.
    /// **Response shape:** `{ insights: AIInsightResponse, cached: Bool, ... }` —
    /// the `insights` slot carries the strict-schema payload with the
    /// `dailyBriefing` block (see `src/lib/ai/schema.ts:299-313`).
    ///
    /// **Idempotency-Key:** required (server expects). `APIClient.send` already
    /// supplies one for every POST.
    public func generateBriefing(force: Bool = false) async throws -> AIInsightResponse {
        struct Body: Encodable {
            let force: Bool
        }
        struct Envelope: Decodable {
            let insights: AIInsightResponse
            let cached: Bool?
        }
        let req: APIRequest<Envelope> = try .post(
            "/api/insights/generate",
            body: Body(force: force)
        )
        let envelope = try await api.send(req)
        return envelope.insights
    }

    /// Thumbs up/down + free text on a recommendation (`POST /api/insights/feedback`,
    /// schema `src/lib/validations/recommendation-feedback.ts`).
    public func submitFeedback(
        recommendationId: String,
        helpful: Bool,
        freeText: String? = nil
    ) async throws {
        struct Body: Encodable {
            let recommendationId: String
            let helpful: Bool
            let freeText: String?
        }
        let req: APIRequest<EmptyPayload> = try .post(
            "/api/insights/feedback",
            body: Body(recommendationId: recommendationId, helpful: helpful, freeText: freeText)
        )
        try await api.sendVoid(req)
    }
}

/// Wraps `GET/PATCH /api/user/ai-provider` (server route:
/// `src/app/api/user/ai-provider/route.ts`).
///
/// **Why this is its own repo (B2 fix per M2-A3 §2):** the previous
/// implementation lived as `InsightsRepository.setProvider` and POSTed an
/// invalid lowercase provider value. The server has never exposed POST on
/// this route and the enum did not match the server vocabulary. Every write 405'd; the
/// picker silently snapped back to a phantom default. This repo speaks
/// the correct verbs + vocabulary.
public actor AIProviderRepository {
    private let api: APIClientProtocol
    public init(api: APIClientProtocol) {
        self.api = api
    }

    public func config() async throws -> AIProviderConfig {
        let req: APIRequest<AIProviderConfig> = .get("/api/user/ai-provider")
        return try await api.send(req)
    }

    /// Partial-update PATCH. Server validates each field; sending an unknown
    /// provider triggers `HttpError(422, "Invalid provider")` which the API
    /// layer surfaces as `HLError.server(status: 422, …)`.
    @discardableResult
    public func update(_ patch: AIProviderUpdate) async throws -> AIProviderConfig {
        // We don't trust the PATCH response shape (server returns `{ updated: true }`,
        // not the full config — see route.ts:135). Re-fetch after the write so the
        // store can render the actually-persisted state without guessing.
        let req: APIRequest<UpdateResponse> = try .patch("/api/user/ai-provider", body: patch)
        _ = try await api.send(req)
        return try await config()
    }

    public struct UpdateResponse: Decodable, Sendable {
        public let updated: Bool?
    }
}

/// Reads the composite Health Score off `GET /api/dashboard/snapshot`.
///
/// **v1.34.0 source move.** The score used to ride the `/api/analytics`
/// envelope as a flat `{ score, band, delta, components }` object. That release
/// replaced the whole engine: `/api/analytics.healthScore` is now the server's
/// internal `HealthScoreReport` (`{ composite, pillars, weightGoal, … }`, no
/// top-level `score`), while the **dashboard snapshot** carries the flat,
/// client-shaped DTO. Reading the snapshot keeps iOS on the one wire the server
/// actually shapes for clients — and it is the cheaper of the two calls.
///
/// iOS **renders only** — never recomputes the score; the server's
/// deterministic compute is authoritative.
public actor AnalyticsRepository {
    private let api: APIClientProtocol
    public init(api: APIClientProtocol) {
        self.api = api
    }

    /// Fetches the latest score from the dashboard snapshot. The `asOf`
    /// argument is ignored — no route accepts it — but is kept on the
    /// signature so callers stay stable.
    ///
    /// Throws ``HLError.server`` with a friendly empty-state message when
    /// the server returns `healthScore: null` (cold rollup coverage or a
    /// non-`ok` composite — an honest "not yet", never a zero).
    public func healthScore(asOf _: Date? = nil) async throws -> HealthScore {
        let req: APIRequest<DashboardSnapshotBriefing> = .get("/api/dashboard/snapshot")
        let snapshot = try await api.send(req)
        guard let score = snapshot.healthScore else {
            throw HLError.server(
                status: 200,
                code: "no_health_score",
                message: String(localized: "Not enough data for your Health Score yet.")
            )
        }
        return score
    }
}

public actor AchievementsRepository {
    private let api: APIClientProtocol
    public init(api: APIClientProtocol) {
        self.api = api
    }

    public func list() async throws -> [Achievement] {
        let req: APIRequest<[Achievement]> = .get(
            "/api/gamification/achievements",
            query: [("format", "ios")]
        )
        // Server's `format=ios` adapter currently strips `points` (route.ts:879-888,
        // A7 §1.2). Hydrate them client-side from the static `AchievementPoints`
        // lookup so the cell + detail sheet can show a value. Once the server
        // widens its iOS adapter, `resolvingPoints()` becomes a no-op (it only
        // fills when `points == nil`).
        let raw = try await api.send(req)
        return raw.map { $0.resolvingPoints() }
    }
}

public actor SettingsRepository {
    /// Internal (not `private`) so the Build 9 `SettingsRepository+ServerPrefs`
    /// extension — split into its own file for length — can reach the client.
    let api: APIClientProtocol
    public init(api: APIClientProtocol) {
        self.api = api
    }

    public func profile() async throws -> UserProfile {
        let req: APIRequest<UserProfile> = .get("/api/user/profile")
        return try await api.send(req)
    }

    /// **v0.8.1 WD — avatar-persist fix.** Fetches `GET /api/auth/me`, which is
    /// the only route that currently echoes `avatarUrl` (server v1.5.5;
    /// `src/app/api/auth/me/route.ts`). `GET /api/user/profile` does *not* select
    /// the avatar columns, so a profile-driven reload would otherwise revert the
    /// uploaded photo to the initials monogram (it reads as "save failed").
    /// `SettingsStore.load()` merges this `avatarUrl` into the in-memory profile
    /// so the photo persists across reloads, app relaunch, and post-upload
    /// refresh. Decodes a thin projection of the `/me` payload — only the field
    /// we need — so an unrelated `/me` schema change can't break the profile load.
    ///
    /// **Build 9 (Server-Prefs):** delegates onto ``authMeServerPrefs()`` so a
    /// single `/me` round-trip supplies both the avatar splice AND the new
    /// server-pref mirror inputs — the `mergeAvatarURLIfMissing` semantics are
    /// unchanged (this still returns only the `avatarUrl`).
    ///
    /// The `authMeServerPrefs()` projection + the unit-preference wire seam live
    /// in `SettingsRepository+ServerPrefs.swift` (file-length discipline).
    public func authMeAvatarURL() async throws -> String? {
        try await authMeServerPrefs().avatarUrl
    }

    public func update(profile: UserProfile) async throws -> UserProfile {
        let req: APIRequest<UserProfile> = try .patch("/api/user/profile", body: profile)
        return try await api.send(req)
    }

    /// Diff-only profile-update. Server's `applyProfileUpdate` accepts a
    /// partial object — sending only the fields the user actually changed
    /// avoids unnecessary writes (and an audit-log entry per untouched field).
    ///
    /// Added v0.4.1 / M2-A6 to back `SettingsStore.updateProfile(patch:)`
    /// from `EditProfileScreen`.
    public func patchProfile(_ patch: ProfilePatch) async throws -> UserProfile {
        let req: APIRequest<UserProfile> = try .patch("/api/user/profile", body: patch)
        return try await api.send(req)
    }

    public func healthKitConfig() async throws -> HealthKitSyncConfig {
        let req: APIRequest<HealthKitSyncConfig> = .get("/api/integrations/healthkit")
        return try await api.send(req)
    }

    public func updateHealthKit(config: HealthKitSyncConfig) async throws -> HealthKitSyncConfig {
        let req: APIRequest<HealthKitSyncConfig> = try .patch("/api/integrations/healthkit", body: config)
        return try await api.send(req)
    }
}

/// Thin projection of the `GET /api/auth/me` payload — only `avatarUrl`, the
/// one field the profile load needs and the only avatar source the server
/// currently exposes (v0.8.1 WD). `avatarUrl` is optional on the wire (older
/// servers omit it; a user without a photo gets `null`) so the decode is
/// tolerant and the caller falls back to the initials monogram on `nil`.
public struct AuthMeAvatar: Decodable, Sendable, Equatable {
    public let avatarUrl: String?

    public init(avatarUrl: String?) {
        self.avatarUrl = avatarUrl
    }
}

/// Diff payload for `PATCH /api/user/profile`. All fields optional — the
/// caller sets only the keys whose value changed. Server-side
/// `applyProfileUpdate` (`src/lib/auth/profile-update.ts`) validates the body
/// as **one** `extendedProfileSchema.safeParse` and writes it as **one**
/// transaction: a single invalid key 422s the whole patch and takes every
/// sibling edit with it. Send only values the server's schema accepts —
/// verbatim, in the server's own spelling (`gender` is the uppercase
/// `MALE | FEMALE | OTHER`, see ``GenderOption``). Clearing a nullable field
/// is `null`; the server also folds `""` to `null` for `gender`, but we never
/// rely on that.
///
/// `displayName`, `gender`, and `locale` are intentionally `String??`
/// (double-optional) so the on-wire payload can disambiguate between
/// "leave unchanged" (key absent) and "clear it to null" (key present, value
/// null). The custom `encode(to:)` writes `null` for `.some(nil)` and omits
/// the key entirely for `.none`.
public struct ProfilePatch: Encodable, Sendable, Equatable {
    public var displayName: String??
    public var dateOfBirth: Date??
    public var gender: String??
    public var heightCm: Int??
    public var locale: String??
    /// v0.5.4.3 HP5 — mood-reminder opt-in. Bool (not Bool??) because
    /// the server treats `moodReminderEnabled` as a non-nullable bool
    /// (default `false`); we send it only when the toggle actually
    /// changed. Use `.some(true)` / `.some(false)` to set, `.none` to
    /// omit from the wire payload.
    public var moodReminderEnabled: Bool?
    /// v0.10.0 — extended patient-identity fields (server v1.7.0). Like the
    /// other text fields these are `String??` so the wire payload can
    /// disambiguate "leave unchanged" (`.none`, key omitted) from "clear to
    /// null" (`.some(nil)`, explicit `null`). The server collapses an empty
    /// string to null, so the caller may send either to clear.
    public var fullName: String??
    public var insurerName: String??
    /// German insurance number (KVNR). Sensitive PII — travels only over the
    /// existing cert-pinned TLS in the PATCH body and is **never** logged.
    public var insuranceNumber: String??
    /// v0.11.0 — insurer IKNR (Institutionskennzeichen, 9 digits). `String??`
    /// for the same leave-unchanged / clear-to-null disambiguation. Identifying
    /// PII — travels only over the cert-pinned PATCH body, **never** logged.
    public var insurerIkNumber: String??
    /// M3 (AUDIT-PARITY-v11612) — time-format preference (`AUTO | H12 | H24`).
    /// Server `applyProfileUpdate` accepts `timeFormat` as a non-nullable enum;
    /// `String??` keeps it uniform with the other text fields (we only ever
    /// send `.some(value)` — never clear it). `.none` omits the key.
    public var timeFormat: String??
    /// A360-1 H1 — date-format preference (`AUTO | DMY | MDY | YMD`). Server
    /// `applyProfileUpdate` accepts `dateFormat` as a non-nullable enum;
    /// `String??` keeps it uniform with `timeFormat` (we only ever send
    /// `.some(value)` — never clear it). `.none` omits the key.
    public var dateFormat: String??

    public init(
        displayName: String?? = .none,
        dateOfBirth: Date?? = .none,
        gender: String?? = .none,
        heightCm: Int?? = .none,
        locale: String?? = .none,
        moodReminderEnabled: Bool? = nil,
        fullName: String?? = .none,
        insurerName: String?? = .none,
        insuranceNumber: String?? = .none,
        insurerIkNumber: String?? = .none,
        timeFormat: String?? = .none,
        dateFormat: String?? = .none
    ) {
        self.displayName = displayName
        self.dateOfBirth = dateOfBirth
        self.gender = gender
        self.heightCm = heightCm
        self.locale = locale
        self.moodReminderEnabled = moodReminderEnabled
        self.fullName = fullName
        self.insurerName = insurerName
        self.insuranceNumber = insuranceNumber
        self.insurerIkNumber = insurerIkNumber
        self.timeFormat = timeFormat
        self.dateFormat = dateFormat
    }

    /// True when no fields are set — caller should skip the PATCH.
    public var isEmpty: Bool {
        displayName == .none
            && dateOfBirth == .none
            && gender == .none
            && heightCm == .none
            && locale == .none
            && moodReminderEnabled == nil
            && fullName == .none
            && insurerName == .none
            && insuranceNumber == .none
            && insurerIkNumber == .none
            && timeFormat == .none
            && dateFormat == .none
    }

    enum CodingKeys: String, CodingKey {
        case displayName, dateOfBirth, gender, heightCm, locale, moodReminderEnabled
        case fullName, insurerName, insuranceNumber, insurerIkNumber, timeFormat, dateFormat
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if case let .some(value) = displayName {
            try c.encode(value, forKey: .displayName)
        }
        if case let .some(value) = dateOfBirth {
            try c.encode(value, forKey: .dateOfBirth)
        }
        if case let .some(value) = gender {
            try c.encode(value, forKey: .gender)
        }
        if case let .some(value) = heightCm {
            try c.encode(value, forKey: .heightCm)
        }
        if case let .some(value) = locale {
            try c.encode(value, forKey: .locale)
        }
        if let value = moodReminderEnabled {
            try c.encode(value, forKey: .moodReminderEnabled)
        }
        if case let .some(value) = fullName {
            try c.encode(value, forKey: .fullName)
        }
        if case let .some(value) = insurerName {
            try c.encode(value, forKey: .insurerName)
        }
        if case let .some(value) = insuranceNumber {
            try c.encode(value, forKey: .insuranceNumber)
        }
        if case let .some(value) = insurerIkNumber {
            try c.encode(value, forKey: .insurerIkNumber)
        }
        if case let .some(value) = timeFormat {
            try c.encode(value, forKey: .timeFormat)
        }
        if case let .some(value) = dateFormat {
            try c.encode(value, forKey: .dateFormat)
        }
    }
}
