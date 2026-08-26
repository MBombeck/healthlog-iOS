import Foundation

// MARK: - v0.5.2 server-stats wire (V052-A7)

public extension AppContainer {
    /// Bundle of repositories backing the v0.5.2 server-stats wire-up.
    ///
    /// Endpoints covered (all additive, all server-side already shipped):
    ///   - `GET /api/sync/state` — sync-mode handshake (v1.4.30)
    ///   - `GET /api/workouts` + `GET /api/workouts/{id}` — list + detail
    ///     after server-side canonical-row dedup (v1.4.32)
    ///   - `GET /api/personal-records` — PR list (v1.4.25 W8d, schema-only)
    ///   - `GET /api/insights/targets` — personal-targets surface with
    ///     consistency strip (v1.4.36 W1)
    ///   - `GET/PUT /api/auth/me/source-priority` — per-user source ladder
    ///     (v1.4.25 W5e + W8c)
    ///
    /// The bundle lives in one place so the `AppContainer.init` body stays
    /// inside its lint budget (file_length + type_body_length). Construction
    /// is pure — no side effects, no `Task.detached`, no main-actor work.
    struct ServerStatsRepos: Sendable {
        public let syncState: SyncStateRepository
        public let workouts: WorkoutsRepository
        public let personalRecords: PersonalRecordsRepository
        public let insightsTargets: InsightsTargetsRepository
        public let sourcePriority: SourcePriorityRepository
        /// v0.7.1 W-TARGETS-EDITOR — editable per-user target-range overrides
        /// (`/api/user/thresholds`), the write half of the targets surface.
        public let userThresholds: UserThresholdsRepository
        /// v0.12 W5b — device-flagged categorical events
        /// (`GET /api/insights/rhythm-events`), the RhythmEvents overview card.
        public let rhythmEvents: RhythmEventsRepository
        /// v0.12 W5b — server-computed derived metrics
        /// (`GET /api/insights/derived`), the derived re-frames overview block.
        public let derivedMetrics: DerivedMetricsRepository
        /// v0141 W-PARITY (P7) — one local day's intraday pulse shape
        /// (`GET /api/insights/pulse/intraday`), the pulse page's day curve.
        public let intradayPulse: IntradayPulseRepository
        /// v0141 W-PARITY (P8) — the device's ECG recordings
        /// (`GET /api/insights/ecg` + `…/[id]`), the Insights ECG surface.
        public let ecg: EcgRepository
        /// v0.12 — FDR-controlled correlation discovery
        /// (`GET /api/insights/correlations`), the discovered-correlations
        /// overview block. Operator-gated → `404`/`422` hides it gracefully.
        public let correlationsDiscovery: CorrelationsDiscoveryRepository
        /// I-3 (v0.14) — the period-retrospective narrative
        /// (`GET /api/insights/narrative`), the "Zeitraum im Rückblick" card.
        public let narrative: NarrativeRepository
        /// v0.14.1 — the mood "relations" slices (`GET /api/mood/insights`,
        /// server v1.11.5): tag-influence + the "better days" board.
        public let moodRelations: MoodRelationsRepository
        /// W-B189 (#23) — the server-computed recovery family
        /// (`GET /api/insights/recovery`, server v1.17.1): strain / training-load /
        /// autonomic-charge + the daily heart-and-energy items.
        public let recovery: RecoveryInsightsRepository
        /// v1.25 (GH iOS #38) — the three read-only "clinical signals" awareness
        /// reads (`GET /api/insights/health-status` / `…/breathing-screening` /
        /// `…/labs-changes`). Server-authoritative, render-don't-recompute.
        public let clinicalSignals: ClinicalSignalsRepository
        /// Web-parity `TodayHero` — the daily-digest read (`GET /api/daily/digest`)
        /// backing the dashboard hero. Server-authoritative, no-store (no SWR).
        public let dailyDigest: DailyDigestRepository
        /// CU-33 (server v1.34.0) — the correlation-pattern decision ledger
        /// (`GET /api/insights/patterns`, `PATCH /api/insights/patterns/{id}`).
        /// Records the person's "not relevant for me" statement, reversibly.
        /// Deliberately uncached — the server can lift a dismissal on its own.
        public let patterns: PatternsRepository

        public init(
            syncState: SyncStateRepository,
            workouts: WorkoutsRepository,
            personalRecords: PersonalRecordsRepository,
            insightsTargets: InsightsTargetsRepository,
            sourcePriority: SourcePriorityRepository,
            userThresholds: UserThresholdsRepository,
            rhythmEvents: RhythmEventsRepository,
            derivedMetrics: DerivedMetricsRepository,
            intradayPulse: IntradayPulseRepository,
            ecg: EcgRepository,
            correlationsDiscovery: CorrelationsDiscoveryRepository,
            narrative: NarrativeRepository,
            moodRelations: MoodRelationsRepository,
            recovery: RecoveryInsightsRepository,
            clinicalSignals: ClinicalSignalsRepository,
            dailyDigest: DailyDigestRepository,
            patterns: PatternsRepository
        ) {
            self.syncState = syncState
            self.workouts = workouts
            self.personalRecords = personalRecords
            self.insightsTargets = insightsTargets
            self.sourcePriority = sourcePriority
            self.userThresholds = userThresholds
            self.rhythmEvents = rhythmEvents
            self.derivedMetrics = derivedMetrics
            self.intradayPulse = intradayPulse
            self.ecg = ecg
            self.correlationsDiscovery = correlationsDiscovery
            self.narrative = narrative
            self.moodRelations = moodRelations
            self.recovery = recovery
            self.clinicalSignals = clinicalSignals
            self.dailyDigest = dailyDigest
            self.patterns = patterns
        }

        /// Logout cache-wipe — the v0.5.2 server-stats repos sit outside the
        /// shared `SWRCoordinator`, so `SWRCoordinator.invalidateAll()` does
        /// not reach them. Without this hop the next user can paint with the
        /// previous user's workouts / PRs / targets / source-priority for up
        /// to the per-repo TTL (60-300s). `SyncStateRepository` has no cache
        /// and is intentionally skipped.
        public func invalidateAll() async {
            await workouts.invalidateCache()
            await personalRecords.invalidateCache()
            await insightsTargets.invalidateCache()
            await sourcePriority.invalidateCache()
            await userThresholds.invalidateCache()
            await correlationsDiscovery.invalidateCache()
            await intradayPulse.invalidateCache()
            await ecg.invalidateCache()
            await moodRelations.invalidateCache()
            await recovery.invalidateCache()
            await clinicalSignals.invalidateCache()
        }
    }

    /// Observable stores wrapping the v0.5.2 server-stats repos.
    ///
    /// **v0.5.3-F3 update:** the read-only `SourcePriorityStore` joins the
    /// bundle so `SettingsSourcesScreen` can surface the per-metric ladder
    /// without bypassing the cleanup hooks. A future two-axis editor will
    /// promote this slot to a read-write store.
    ///
    /// `@MainActor`-isolated because the inner stores are `@MainActor`
    /// `@Observable` classes (reference types). The previous
    /// `@unchecked Sendable` claim of a "by-value snapshot" was wrong —
    /// struct fields are reference handles, not copies. With the wrapper
    /// itself main-actor-bound the compiler enforces MainActor access at
    /// every call site, which is the actual concurrency invariant we want.
    @MainActor
    struct ServerStatsStores {
        public let syncState: SyncStateStore
        public let workouts: WorkoutsStore
        public let personalRecords: PersonalRecordsStore
        public let insightsTargets: InsightsTargetsStore
        public let sourcePriority: SourcePriorityStore
        /// v0.7.1 W-TARGETS-EDITOR — editable target-range overrides store.
        public let userThresholds: UserThresholdsStore
        /// v0.12 W5b — RhythmEvents overview card store.
        public let rhythmEvents: RhythmEventsStore
        /// v0.12 W5b — derived re-frames overview block store.
        public let derivedMetrics: DerivedInsightsStore
        /// v0141 W-PARITY (P7) — the pulse page's intraday day-curve store.
        public let intradayPulse: IntradayPulseStore
        /// v0141 W-PARITY (P8) — the Insights ECG surface store. Its
        /// `hasRecordings` flag is the pill's data gate.
        public let ecg: EcgStore
        /// v0.12 — discovered-correlations overview block store.
        public let correlationsDiscovery: CorrelationsDiscoveryStore
        /// I-3 (v0.14) — "Zeitraum im Rückblick" retrospective card store.
        public let narrative: NarrativeStore
        /// v0.14.1 — mood "relations" cards store (tag-influence + better-days).
        public let moodRelations: MoodRelationsStore
        /// W-B189 (#23) — the Insights → Recovery sub-page store (strain /
        /// training-load / autonomic-charge + heart-and-energy family).
        public let recovery: RecoveryInsightsStore
        /// v1.25 (GH iOS #38) — the three read-only "clinical signals" awareness
        /// cards' store (health-status / breathing-screening / labs-changes).
        public let clinicalSignals: ClinicalSignalsStore
        /// Web-parity `TodayHero` — the daily-digest store backing the dashboard
        /// `TodayHeroCard`. Server-authoritative; self-hides on absent / gated-off.
        public let dailyDigest: DailyDigestStore

        public init(
            syncState: SyncStateStore,
            workouts: WorkoutsStore,
            personalRecords: PersonalRecordsStore,
            insightsTargets: InsightsTargetsStore,
            sourcePriority: SourcePriorityStore,
            userThresholds: UserThresholdsStore,
            rhythmEvents: RhythmEventsStore,
            derivedMetrics: DerivedInsightsStore,
            intradayPulse: IntradayPulseStore,
            ecg: EcgStore,
            correlationsDiscovery: CorrelationsDiscoveryStore,
            narrative: NarrativeStore,
            moodRelations: MoodRelationsStore,
            recovery: RecoveryInsightsStore,
            clinicalSignals: ClinicalSignalsStore,
            dailyDigest: DailyDigestStore
        ) {
            self.syncState = syncState
            self.workouts = workouts
            self.personalRecords = personalRecords
            self.insightsTargets = insightsTargets
            self.sourcePriority = sourcePriority
            self.userThresholds = userThresholds
            self.rhythmEvents = rhythmEvents
            self.derivedMetrics = derivedMetrics
            self.intradayPulse = intradayPulse
            self.ecg = ecg
            self.correlationsDiscovery = correlationsDiscovery
            self.narrative = narrative
            self.moodRelations = moodRelations
            self.recovery = recovery
            self.clinicalSignals = clinicalSignals
            self.dailyDigest = dailyDigest
        }

        /// Logout cleanup — wipes per-user wire snapshots so the next
        /// session never paints previous-user workouts / targets / PRs /
        /// sync handshake / source-priority ladder.
        public func clearOnLogout() {
            syncState.clearOnLogout()
            workouts.clearOnLogout()
            personalRecords.clearOnLogout()
            insightsTargets.clearOnLogout()
            sourcePriority.clearOnLogout()
            userThresholds.clearOnLogout()
            rhythmEvents.clearOnLogout()
            derivedMetrics.clearOnLogout()
            intradayPulse.clearOnLogout()
            ecg.clearOnLogout()
            correlationsDiscovery.clearOnLogout()
            narrative.clearOnLogout()
            moodRelations.clearOnLogout()
            recovery.clearOnLogout()
            clinicalSignals.clearOnLogout()
            dailyDigest.clearOnLogout()
        }
    }

    /// Factory — constructs the repos against the shared `APIClient`.
    /// Static so the `AppContainer.init` body can call it before `self`
    /// is fully initialised.
    static func makeServerStatsRepos(
        apiClient: APIClient,
        outbox: OutboxQueue,
        swr: SWRCoordinator? = nil
    ) -> ServerStatsRepos {
        ServerStatsRepos(
            syncState: SyncStateRepository(api: apiClient),
            // Audit v0.14.8 C4.1 — outbox-backed so a retriably-failed workout
            // batch upload survives a restart + replays on reachability.
            workouts: WorkoutsRepository(api: apiClient, outbox: outbox),
            personalRecords: PersonalRecordsRepository(api: apiClient),
            // W3 (v0.11 #22) — targets read routes through the persistent
            // `.insightsTargets` SWR cache so the "Ziel" block paints
            // cache-first on launch + is warmed by the prefetch service.
            insightsTargets: InsightsTargetsRepository(api: apiClient, swr: swr),
            sourcePriority: SourcePriorityRepository(api: apiClient),
            // v0.7.1 W-TARGETS-EDITOR — outbox-backed so an offline target
            // edit survives an app restart + replays on reachability.
            userThresholds: UserThresholdsRepository(api: apiClient, outbox: outbox),
            // v0.12 W5b — both route through the shared daily SWR cache so the
            // RhythmEvents card + derived block paint cache-first on launch +
            // revalidate on the Berlin-day-anchored key.
            rhythmEvents: RhythmEventsRepository(api: apiClient, swr: swr),
            derivedMetrics: DerivedMetricsRepository(api: apiClient, swr: swr),
            // v0141 W-PARITY (P7) — the intraday day curve fetches DIRECT (no
            // SWR): the server answers `no-store` because today's shape keeps
            // growing, so a persisted snapshot would paint a stale morning.
            // Past days are memoized inside the actor instead.
            intradayPulse: IntradayPulseRepository(api: apiClient),
            // v0141 W-PARITY (P8) — the ECG LIST routes through the shared daily
            // SWR cache (Berlin-day-anchored `.insightsEcg`); the per-recording
            // waveform is fetched direct and never cached (server `no-store`,
            // decrypted health data).
            ecg: EcgRepository(api: apiClient, swr: swr),
            // v0.12 — discovery routes through the shared daily SWR cache
            // (Berlin-day-anchored `.correlations`) so the block paints
            // cache-first on launch + revalidates once per day.
            correlationsDiscovery: CorrelationsDiscoveryRepository(api: apiClient, swr: swr),
            // I-3 — the period narrative routes through the shared daily SWR
            // cache (Berlin-day-anchored `.insightsNarrative`) so the
            // retrospective card paints cache-first + revalidates once per day.
            narrative: NarrativeRepository(api: apiClient, swr: swr),
            // v0.14.1 — the mood relations slices route through the shared SWR
            // cache (`.moodInsights`, ~60s) so the tag-influence + better-days
            // cards paint cache-first on the Mood page + revalidate.
            moodRelations: MoodRelationsRepository(api: apiClient, swr: swr),
            // W-B189 (#23) — recovery routes through the shared daily SWR cache
            // (Berlin-day-anchored `.insightsRecovery`) so the recovery sub-page
            // paints cache-first on launch + revalidates once per day.
            recovery: RecoveryInsightsRepository(api: apiClient, swr: swr),
            // v1.25 (GH iOS #38) — the three clinical-signal reads route through
            // the shared daily SWR cache (Berlin-day-anchored) so each card paints
            // cache-first on launch + revalidates once per day.
            clinicalSignals: ClinicalSignalsRepository(api: apiClient, swr: swr),
            // Web-parity `TodayHero` — the digest is `no-store` + must reflect a
            // fresh dismiss / keep / let-go, so it fetches direct (no SWR).
            dailyDigest: DailyDigestRepository(api: apiClient),
            // CU-33 — the pattern ledger is deliberately NOT cached: the
            // correlations recomputation can clear a dismissal server-side, so a
            // cached row would paint a statement the server already lifted.
            patterns: PatternsRepository(api: apiClient)
        )
    }

    /// Factory — constructs the observable stores from the repos.
    ///
    /// **v0.5.4-BF7:** the `PersonalRecordsStore` now takes an optional
    /// `derivedSource`. When supplied, the store surfaces client-derived
    /// records (Steps streak / Steps best-day) for the cumulative kinds
    /// the server-side detection worker hasn't started populating yet
    /// (worker lands in v1.4.26 / v1.5). The screen contract is unchanged
    /// — derived records share the wire `PersonalRecordDTO` shape and
    /// flow through the same grouping helper.
    @MainActor
    static func makeServerStatsStores(
        repos: ServerStatsRepos,
        measurementsRepo: MeasurementsRepository
    ) -> ServerStatsStores {
        // v0.5.4-BF7 — client-side derivation surface for PersonalRecords. Reads
        // cached `/api/measurements/series` + computes Schritte best-day +
        // 10k-streak records until the server detection worker lights up the route.
        // v0.5.5.6 POLISH-PR — 30-day trajectory provider for the redesigned
        // `PersonalRecordsScreen` (hero + grid mini sparklines with peak markers).
        // Re-uses the same `MeasurementsRepository` series cache so one fetch
        // serves both call-sites.
        let personalRecordsDerivedSource = PersonalRecordsDerivedSourceLive(
            measurementsRepo: measurementsRepo
        )
        let personalRecordsSparklineProvider = PersonalRecordsSparklineProviderLive(
            measurementsRepo: measurementsRepo
        )
        return ServerStatsStores(
            syncState: SyncStateStore(repo: repos.syncState),
            // v0.5.4-SP5 — HR-time-series for workout-detail is read
            // from HealthKit directly (server only exposes avg/max/min).
            // `HealthKitWorkoutDetailService` is iOS-only; the
            // `canImport(HealthKit)` shim inside the service keeps the
            // SPM build happy.
            workouts: WorkoutsStore(
                repo: repos.workouts,
                hkDetail: HealthKitWorkoutDetailService()
            ),
            // v0.5.4-BF7 — `PersonalRecordsStore` takes an optional
            // `derivedSource`. v0.5.5.6 POLISH-PR adds the
            // `sparklineProvider` for the redesigned record cards.
            personalRecords: PersonalRecordsStore(
                repo: repos.personalRecords,
                derivedSource: personalRecordsDerivedSource,
                sparklineProvider: personalRecordsSparklineProvider
            ),
            insightsTargets: InsightsTargetsStore(repo: repos.insightsTargets),
            sourcePriority: SourcePriorityStore(repo: repos.sourcePriority),
            userThresholds: UserThresholdsStore(repo: repos.userThresholds),
            rhythmEvents: RhythmEventsStore(repo: repos.rhythmEvents),
            derivedMetrics: DerivedInsightsStore(repo: repos.derivedMetrics),
            intradayPulse: IntradayPulseStore(repo: repos.intradayPulse),
            ecg: EcgStore(repo: repos.ecg),
            correlationsDiscovery: CorrelationsDiscoveryStore(
                repo: repos.correlationsDiscovery,
                patterns: repos.patterns
            ),
            narrative: NarrativeStore(repo: repos.narrative),
            moodRelations: MoodRelationsStore(repo: repos.moodRelations),
            recovery: RecoveryInsightsStore(repo: repos.recovery),
            clinicalSignals: ClinicalSignalsStore(repo: repos.clinicalSignals),
            dailyDigest: DailyDigestStore(repo: repos.dailyDigest)
        )
    }
}
