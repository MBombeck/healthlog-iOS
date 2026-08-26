import CryptoKit
import Foundation

/// Typed key for the SWR cache. Mirrors web's TanStack-Query `queryKeys.*`
/// factory (see server doc-pack `13-state-management.md` §3). Cases carry only
/// value-type discriminators so two keys can never collide structurally.
///
/// **Lifecycle:** the persistent SQLite row stores `persistentHash` (stable
/// SHA-256 of a canonical string form). Adding a new case is a no-op for
/// existing rows; renaming a case shifts its hash and is a soft cache wipe.
public enum CacheKey: Hashable, Sendable {
    /// v0.14.8 INV-home-compliance-slot — the dashboard summary
    /// (`GET /api/dashboard/summary`). `day` is a `yyyy-MM-dd` discriminator in
    /// the **user/profile timezone** (the same zone the medication
    /// "today"/compliance bucket uses — see `MedicationDayKey`). It was
    /// previously a static, non-day-anchored key: a prior-day
    /// `summary.compliance` snapshot ("2 scheduled / 2 taken") survived the
    /// midnight rollover, was SWR-served via the `.cached` arm, and the Home
    /// `ComplianceRingCard` rendered a phantom "2 von 2 genommen" on a day where
    /// nothing was taken (the medications-tab card was already correct because
    /// `.medicationsTodayIntakes` IS day-anchored — the b160 fix). Anchoring this
    /// key to the user-tz day makes a new calendar day a STRUCTURAL cache miss,
    /// so a prior-day compliance snapshot can never carry across midnight.
    /// `DashboardStore` always builds this case via
    /// `DashboardStore.dashboardSummaryKey`; the static invalidation matrix
    /// (`CacheInvalidator`) and the kind-context-free
    /// `MeasurementsRepository` anchor on the device-tz day (no profile-tz
    /// context), mirroring the `.medicationsTodayIntakes` precedent.
    case dashboardSummary(day: String)
    case healthScore
    case insightsComprehensive
    case insightsCards
    case correlations
    case measurementsRecent(limit: Int)
    /// v0.14 DATA — kind-scoped recent page (`GET /api/measurements?type=…`).
    /// Distinct from `measurementsRecent` so a no-series / low-frequency kind's
    /// chart reads its OWN history instead of being pushed out of the global
    /// newest-N page by a high-frequency kind on a HealthKit power-user.
    case measurementsRecentKind(type: String, limit: Int)
    case measurementSeries(kind: MetricKind, days: Int)
    /// v0.13.1 IC — per-kind has-data availability slice
    /// (`GET /api/analytics?slice=summaries`). Carries an all-time
    /// `count` per server `MeasurementType`, the same per-kind signal the
    /// web tab-strip gates its pills on. Distinct from `measurementsRecent`
    /// (a last-N-rows page that under-reports low-frequency kinds on a
    /// HealthKit power-user — the operator-reported "BP/pulse missing" bug).
    case measurementAvailability
    case medicationsList
    /// v0.14.1 INV-med-cadence-phantom (BUG 2) — the today-scope intake list
    /// (`GET /api/medications/intake?scope=today`). `day` is a `yyyy-MM-dd`
    /// discriminator in the **user/profile timezone** (the same zone the app
    /// uses for medication "today"/compliance — see `MedicationDayKey`). It was
    /// previously a static, non-day-anchored key with a flat 30s TTL: an
    /// optimistic `.taken` snapshot writeThrough'd to disk replayed via SWR's
    /// `.cached` arm on the next launch and rendered a PHANTOM "taken today" the
    /// server no longer agreed with (and DISABLED the Genommen button, masking a
    /// real pending dose — a dose-safety failure for a BP drug). Anchoring the
    /// key to the user-tz day makes a new calendar day a STRUCTURAL cache miss,
    /// so a prior-day `.taken` snapshot can never carry across midnight. The
    /// store always builds this case via `MedicationsStore.todayIntakesKey`.
    case medicationsTodayIntakes(day: String)
    case medicationsCompliance(days: Int)

    /// **#13 (2026-06-11) — canonical compliance-window length (days).**
    /// 182 = the 26-week MAXIMUM of the Settings -> Erscheinungsbild
    /// heatmap-window picker (4/8/12/26 weeks), so every pick renders fully
    /// populated from the one cached payload. Lives on `CacheKey` (not on
    /// `MedicationsStore`) because the `MutationKind.*.affectedKeys` matrix in
    /// `CacheInvalidator` must reference it too, and the Cache layer is shared
    /// into the Intents extension which does not compile the Stores layer.
    /// `MedicationsStore.complianceDaysWindow` aliases this constant.
    static let complianceWindowDays = 182
    case moodEntries(days: Int)
    /// v0.14.1 — the mood "relations" slices (`GET /api/mood/insights`,
    /// server v1.11.5): tag-influence + the "better days" board. The server
    /// caches the aggregate ~60s; this row mirrors that so the Mood-page cards
    /// paint cache-first on launch + revalidate in the background.
    case moodInsights
    case userProfile
    case hkSyncConfig
    case notificationsPreferences
    case metricInsights(kind: MetricKind, locale: String)
    /// AUD-6 Critical #1 — the advisor daily briefing
    /// (`GET /api/insights/generate`). Day-anchored on the Berlin calendar day
    /// (`BerlinDayKey.string`) like every sibling daily-scoped key
    /// (`.insightStatus`, `.insightsNarrative`, `.derivedMetric`, `.rhythmEvents`,
    /// `.insightsRecovery`). It was previously a STATIC key with a flat 24h TTL:
    /// yesterday morning's briefing was SWR-served via the `.cached` arm all of
    /// today (with a fresh-looking timestamp), so the user saw stale prose every
    /// morning until a manual pull-to-refresh. Anchoring to the Berlin day makes a
    /// new calendar day a STRUCTURAL cache miss, so the briefing refetches at the
    /// rollover. `DailyBriefingStore` always builds this via
    /// `CacheKey.dailyBriefing(day: BerlinDayKey.string())`.
    case dailyBriefing(day: String)
    case dashboardWidgetLayout
    /// W3 (v0.11 #22) — per-metric **daily** assessment / "Einschätzung"
    /// (`GET /api/insights/{slug}-status`). Server regenerates ~1×/day keyed
    /// by Berlin calendar day; `day` is the `BerlinDayKey.string` discriminator
    /// so the row structurally misses + refetches when the Berlin day rolls
    /// over (see `BerlinDayKey`). `locale` keeps the de/en prose separate.
    case insightStatus(kind: MetricKind, locale: String, day: String)
    /// W3 (v0.11 #22) — persistent SWR cache for `GET /api/insights/targets`
    /// (the single payload backing every metric's "Ziel" block). Mirrors the
    /// server 60s `cached()` wrapper so the per-metric screen paints the Ziel
    /// from disk on first frame and revalidates in the background.
    case insightsTargets
    /// `GET /api/user/ai-provider` — user's active AI provider config
    /// (provider + model + base URL + key-preview). Added v0.5.x for the
    /// PA5 Bottleneck #2 fix; mirrors `.userProfile` semantics
    /// (per-user, server-owned, changes infrequently).
    case aiProviderConfig
    /// v0.12 W5b — device-flagged categorical events
    /// (`GET /api/insights/rhythm-events`). The timeline shifts at most a few
    /// times a year, so a Berlin-day-anchored daily key paints the
    /// RhythmEvents overview card cache-first on launch + revalidates in the
    /// background; `day` flips the row to a structural miss when the day rolls.
    case rhythmEvents(day: String)
    /// v0.12 W5b — a single server-derived metric
    /// (`GET /api/insights/derived?metric=<ID>`). The compute is recomputed
    /// ~daily server-side, so a Berlin-day-anchored key per metric paints the
    /// derived overview block cache-first + revalidates. `metric` is the
    /// UPPER_SNAKE derived id.
    case derivedMetric(metric: String, day: String)
    /// v0.12 next — the whole derived-overview grid in ONE request
    /// (`GET /api/insights/derived/batch?metrics=<CSV>`). Collapses the
    /// per-metric fan-out the server flags as Prisma-pool starvation. `token`
    /// is the sorted CSV of requested ids so the same grid hits one key;
    /// Berlin-day-anchored like the single-metric key.
    case derivedBatch(token: String, day: String)
    /// I-3 (v0.14) — the period-retrospective narrative
    /// (`GET /api/insights/narrative?period=week|month`). The server warms it at
    /// most ~once per period, so a Berlin-day-anchored key per period+locale
    /// paints the retrospective card cache-first on launch + revalidates; `day`
    /// flips the row to a structural miss when the day rolls. `period` is the
    /// lowercase `NarrativeDTO.Period.rawValue`; `locale` keeps de/en prose apart.
    case insightsNarrative(period: String, locale: String, day: String)
    /// W-B189 (#23) — the server-computed recovery family
    /// (`GET /api/insights/recovery`, server v1.17.1): strain / training-load /
    /// autonomic-charge + the daily heart-and-energy items. Recomputed ~once per
    /// Berlin day server-side, so a Berlin-day-anchored key paints the recovery
    /// sub-page cache-first on launch + revalidates; `day` flips the row to a
    /// structural miss when the day rolls.
    case insightsRecovery(day: String)
    /// v1.25 (GH iOS #38) — the three read-only "clinical signals" awareness
    /// reads. Each is pure server compute recomputed ~once per Berlin day, so a
    /// Berlin-day-anchored key paints the host card cache-first on launch +
    /// revalidates; `day` flips the row to a structural miss when the day rolls
    /// (same model as `.insightsRecovery` / `.derivedMetric`).
    ///   - health-status:       `GET /api/insights/health-status`
    ///   - breathing-screening: `GET /api/insights/breathing-screening`
    ///   - labs-changes:        `GET /api/insights/labs-changes`
    /// v0141 W-PARITY (P8) — the ECG recording METADATA list
    /// (`GET /api/insights/ecg`, server v1.28.50). The list changes at most a
    /// handful of times a year (a new strip per device recording), so a
    /// Berlin-day-anchored key paints the ECG surface cache-first on launch +
    /// revalidates once per day; `day` flips the row to a structural miss when
    /// the day rolls over. The per-recording WAVEFORM is deliberately NOT
    /// cached anywhere — the detail route answers `no-store` and the samples
    /// are decrypted health data.
    case insightsEcg(day: String)
    case insightsHealthStatus(day: String)
    case insightsBreathingScreening(day: String)
    case insightsLabsChanges(day: String)
    /// v0.14.8 cycle marathon — the cycle calendar window
    /// (`GET /api/cycle/calendar?from&to`). Day-anchored on the user-tz day so a
    /// new calendar day is a structural cache-miss (a prior-day prediction /
    /// "today" phase highlight can never carry across midnight — same posture as
    /// `.dashboardSummary`). `from`/`to` carry the requested window so a narrow
    /// drill-down never collides with the default −90…+180 window.
    case cycleCalendar(from: String, to: String, day: String)
    /// v0.14.8 — the cycle history + stats (`GET /api/cycle/cycles?limit`).
    /// Changes only when a cycle closes; 5min TTL mirrors near-static lists.
    case cycleCycles(limit: Int)
    /// v0.14.8 — the full cycle profile (`GET /api/cycle/profile`). Per-user,
    /// server-owned, changes infrequently — mirrors `.userProfile` semantics.
    case cycleProfile
    /// Active per-user custom cycle symptom catalogue.
    case cycleCustomSymptoms
    /// Server-computed, FDR-guarded cycle insights. The store loads this lazily
    /// once per screen lifetime; a 5-minute cache additionally protects remounts.
    case cycleInsights
    /// **Z1 (#72) — the last server-resolved cycle verdict + the moment the
    /// server computed it.** Deliberately NOT day-anchored, unlike
    /// `.cycleCalendar`: the whole point is that it survives the midnight
    /// rollover so an offline device can show the last known assessment WITH its
    /// date instead of inventing a current one. Read via `peek` (never through
    /// the freshness ladder), so its TTL only governs the maintenance sweep; the
    /// age that matters travels inside the payload as `asOf` and is bounded by
    /// `CycleVerdictSnapshot.horizon`.
    case cycleVerdict
    /// W-REMINDERS (#23 v1.18.1) — the Vorsorge measurement-reminder list
    /// (`GET /api/measurement-reminders`). Near-static (changes only on an
    /// explicit create/edit/satisfy/delete or a server-side auto-satisfy); a
    /// 60s TTL mirrors the medications list so the manage screen paints from
    /// disk on a warm bounce + revalidates. Optimistic writes write-through.
    case measurementReminders
    /// QOL-OFF-2 — the unfiltered labs list page (`GET /api/labs`, the store's
    /// canonical `limit=500` read). Cache-first so the Labs screen is READABLE
    /// on a cold offline launch (was network-only — an offline start rendered
    /// the empty "add your first…" state). Near-static (changes only on an
    /// explicit lab create/edit/delete/restore); a 60s TTL mirrors the meds
    /// list. `LabsRepository` invalidates it on every successful write.
    case labsResults
    /// QOL-OFF-2 — the biomarker catalog (`GET /api/biomarkers`). Per-user,
    /// changes only on an explicit catalog edit; a 5min TTL mirrors
    /// `.userProfile`. Invalidated by `LabsRepository` on a biomarker write.
    case biomarkers
    /// QOL-OFF-2 — the structured-records ALLERGY list (`GET /api/allergies`,
    /// the store's default all-non-deleted read). Cache-first for offline
    /// readability; 60s TTL. `AllergiesRepository` invalidates it on write.
    case allergies
    /// QOL-OFF-2 — the FAMILY-HISTORY list (`GET /api/family-history`).
    /// Cache-first for offline readability; 60s TTL. `FamilyHistoryRepository`
    /// invalidates it on write.
    case familyHistory
    /// QOL-OFF-2 — the opt-in mental-health screener history
    /// (`GET /api/mental-health/assessments` — derived DTOs only, never the raw
    /// item answers). Cache-first so the PHQ-9 / GAD-7 history is READABLE
    /// offline; append-only, so `MentalHealthRepository` invalidates it on
    /// submit. Purged on logout via `SWRCoordinator.invalidateAll()`.
    case mentalHealthHistory
    /// The user-defined custom-metric catalog (`GET /api/custom-metrics`).
    /// Cache-first so the metric list under Messwerte is READABLE on a cold
    /// offline launch. Near-static (changes only on an explicit definition edit
    /// or a logged value — the row embeds `latest` + `entryCount`), so a 60s TTL
    /// mirrors the labs list. `CustomMetricsRepository` invalidates it on every
    /// successful write, including entry writes.
    case customMetrics
}

public extension CacheKey {
    /// Canonical wire-form — the string we hash for `persistentHash`. Keep
    /// stable across builds: any change shifts every key's hash and invalidates
    /// the entire on-disk cache (which is bounded — re-fetch on next launch
    /// works as before, just one network round-trip is wasted).
    var canonicalString: String {
        switch self {
        case let .dashboardSummary(day): "dashboardSummary:\(day)"
        case .healthScore: "healthScore"
        case .insightsComprehensive: "insightsComprehensive"
        case .insightsCards: "insightsCards"
        case .correlations: "correlations"
        case let .measurementsRecent(limit): "measurementsRecent:\(limit)"
        case let .measurementsRecentKind(type, limit): "measurementsRecentKind:\(type):\(limit)"
        case let .measurementSeries(kind, days): "measurementSeries:\(kind.rawValue):\(days)"
        case .measurementAvailability: "measurementAvailability"
        case .medicationsList: "medicationsList"
        case let .medicationsTodayIntakes(day): "medicationsTodayIntakes:\(day)"
        case let .medicationsCompliance(days): "medicationsCompliance:\(days)"
        case let .moodEntries(days): "moodEntries:\(days)"
        case .moodInsights: "moodInsights"
        case .userProfile: "userProfile"
        case .hkSyncConfig: "hkSyncConfig"
        case .notificationsPreferences: "notificationsPreferences"
        case let .metricInsights(kind, locale): "metricInsights:\(kind.rawValue):\(locale)"
        case let .dailyBriefing(day): "dailyBriefing:\(day)"
        case .dashboardWidgetLayout: "dashboardWidgetLayout"
        case let .insightStatus(kind, locale, day): "insightStatus:\(kind.rawValue):\(locale):\(day)"
        case .insightsTargets: "insightsTargets"
        case .aiProviderConfig: "aiProviderConfig"
        case let .rhythmEvents(day): "rhythmEvents:\(day)"
        case let .derivedMetric(metric, day): "derivedMetric:\(metric):\(day)"
        case let .derivedBatch(token, day): "derivedBatch:\(token):\(day)"
        case let .insightsNarrative(period, locale, day): "insightsNarrative:\(period):\(locale):\(day)"
        case let .insightsRecovery(day): "insightsRecovery:\(day)"
        case let .insightsEcg(day): "insightsEcg:\(day)"
        case let .insightsHealthStatus(day): "insightsHealthStatus:\(day)"
        case let .insightsBreathingScreening(day): "insightsBreathingScreening:\(day)"
        case let .insightsLabsChanges(day): "insightsLabsChanges:\(day)"
        case let .cycleCalendar(from, to, day): "cycleCalendar:\(from):\(to):\(day)"
        case let .cycleCycles(limit): "cycleCycles:\(limit)"
        case .cycleProfile: "cycleProfile"
        case .cycleCustomSymptoms: "cycleCustomSymptoms"
        case .cycleInsights: "cycleInsights"
        case .cycleVerdict: "cycleVerdict"
        case .measurementReminders: "measurementReminders"
        case .labsResults: "labsResults"
        case .biomarkers: "biomarkers"
        case .allergies: "allergies"
        case .familyHistory: "familyHistory"
        case .mentalHealthHistory: "mentalHealthHistory"
        case .customMetrics: "customMetrics"
        }
    }

    /// SHA-256 of `canonicalString`, hex-encoded. Stable across processes +
    /// builds (modulo `canonicalString` changes). 64-char hex string used as
    /// the SwiftData `@Attribute(.unique)` primary key.
    var persistentHash: String {
        let digest = SHA256.hash(data: Data(canonicalString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Staleness threshold — return cached value if
    /// `Date().timeIntervalSince(updatedAt) < staleAfter`. `0` means always
    /// revalidate but serve cache during. `nil` means never serve without
    /// revalidation (no such key today; preserved for future expansion).
    ///
    /// Values mirror the web TanStack-Query config (`13-state-management.md` §3).
    var staleAfter: TimeInterval {
        switch self {
        case .userProfile: 5 * 60
        // W8-B1 — short TTL on the hot keys so a quick background→foreground
        // bounce serves fully from cache (no redundant auto-revalidation
        // inside the window). Pull-to-refresh bypasses this via the
        // `forceRevalidate` SWR path, so explicit refresh still hits the
        // network. The window is tuned per key: dashboard + recent page are
        // the warm-bounce surfaces (45s comfortably covers a tab-switch /
        // app-bounce), the meds list is near-static (60s), today-intakes
        // change when the user marks a dose so it stays tighter (30s).
        case .dashboardSummary: 45
        case .healthScore: 60
        case .insightsComprehensive: 60
        case .insightsCards: 60
        case .correlations: 5 * 60
        case .measurementsRecent: 45
        case .measurementsRecentKind: 45
        case .measurementSeries: 30
        // Availability is near-static (a kind only ever GAINS data); a 5min
        // window comfortably covers a tab-switch / app-bounce without a
        // redundant round-trip. The first upload of a new kind surfaces its
        // pill on the next revalidation past the window.
        case .measurementAvailability: 5 * 60
        case .medicationsList: 60
        case .medicationsTodayIntakes: 30
        case .medicationsCompliance: 5 * 60
        case .moodEntries: 60
        // Mirrors the server-side 60s `cached()` window on the mood-insights
        // aggregate so the relations cards paint from disk on a warm bounce.
        case .moodInsights: 60
        case .hkSyncConfig: 5 * 60
        case .notificationsPreferences: 5 * 60
        case .metricInsights: 60
        case .dailyBriefing: 24 * 60 * 60
        // Widget layout changes infrequently (user-driven via the
        // customisation screen). 5min mirrors the userProfile TTL.
        case .dashboardWidgetLayout: 5 * 60
        // W3 — the assessment is regenerated by the server only once per
        // Berlin day, and the Berlin-day discriminator baked into the key
        // (see `BerlinDayKey`) already forces a structural cache-miss +
        // refetch the instant the day rolls over. So the daily ROLLOVER is
        // owned by the key, not by `staleAfter`; within a single Berlin day a
        // cached row is served without a redundant revalidation (matching the
        // server cadence + the web "serve yesterday's, regenerate out-of-band"
        // model). A 24h ceiling keeps `staleAfter` deterministic (no
        // wall-clock dependency) and can never out-live the day-key flip.
        case .insightStatus: 24 * 60 * 60
        // Targets mirror the server-side 60s `cached()` wrapper so an iOS-side
        // write surfaces the new band shape on the first re-mount inside the
        // minute (same window `InsightsTargetsRepository` used in-memory).
        case .insightsTargets: 60
        // AI provider config: changes only when user explicitly edits
        // (provider/key/model/baseUrl). 5min TTL mirrors `.userProfile`.
        case .aiProviderConfig: 5 * 60
        // W5b — both server-derived insights surfaces are recomputed ~once per
        // Berlin day; the Berlin-day discriminator baked into each key already
        // forces the structural miss + refetch on day-rollover. A 24h ceiling
        // keeps `staleAfter` deterministic and can never out-live the day-key
        // flip (same model as `.insightStatus` / `.dailyBriefing`).
        case .rhythmEvents: 24 * 60 * 60
        case .derivedMetric: 24 * 60 * 60
        case .derivedBatch: 24 * 60 * 60
        // I-3 — the narrative is warmed at most ~once per period server-side; the
        // Berlin-day discriminator baked into the key forces the structural miss
        // + refetch on day rollover. A 24h ceiling keeps `staleAfter`
        // deterministic (same model as `.derivedMetric` / `.insightStatus`).
        case .insightsNarrative: 24 * 60 * 60
        // W-B189 — recovery is recomputed ~once per Berlin day server-side; the
        // Berlin-day discriminator baked into the key forces the structural miss
        // + refetch on day rollover (same model as `.derivedMetric`).
        case .insightsRecovery: 24 * 60 * 60
        // v1.25 clinical signals — recomputed ~once per Berlin day server-side;
        // the Berlin-day discriminator baked into each key forces the structural
        // miss + refetch on day rollover (same model as `.insightsRecovery`).
        // P8 — the ECG list is near-static; the Berlin-day discriminator in the
        // key forces the structural miss + refetch on day rollover (same model
        // as `.insightsRecovery`).
        case .insightsEcg: 24 * 60 * 60
        case .insightsHealthStatus: 24 * 60 * 60
        case .insightsBreathingScreening: 24 * 60 * 60
        case .insightsLabsChanges: 24 * 60 * 60
        // Cycle calendar: the day-anchored key already forces a structural miss
        // at midnight; within a day a 60s window lets a fresh log surface on a
        // warm bounce. Cycles list near-static (5min). Profile mirrors
        // `.userProfile` (5min).
        case .cycleCalendar: 60
        case .cycleCycles: 5 * 60
        case .cycleProfile: 5 * 60
        case .cycleCustomSymptoms: 5 * 60
        case .cycleInsights: 5 * 60
        // The stored verdict is read by `peek`, never through the freshness
        // ladder — this TTL only keeps the maintenance sweep from treating the
        // row as immortal. Its real bound is `CycleVerdictSnapshot.horizon`.
        case .cycleVerdict: 24 * 60 * 60
        // W-REMINDERS — near-static reminder list; 60s mirrors the meds list so
        // a warm bounce serves from disk + revalidates.
        case .measurementReminders: 60
        // QOL-OFF-2 — near-static PHI lists; 60s mirrors the meds/reminders
        // lists so a warm bounce serves from disk + revalidates. Each repo
        // invalidates its key on a successful write so a mutation is never
        // masked by a fresh-enough cached row. The biomarker CATALOG changes
        // less often (explicit edits only), so it gets the 5min userProfile TTL.
        case .labsResults: 60
        case .biomarkers: 5 * 60
        case .allergies: 60
        case .familyHistory: 60
        case .mentalHealthHistory: 60
        case .customMetrics: 60
        }
    }
}
