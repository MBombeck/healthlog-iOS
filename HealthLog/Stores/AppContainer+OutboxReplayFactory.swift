import Foundation

// MARK: - Outbox-replay aggregator phase

extension AppContainer {
    /// Factory — constructs the cross-repo `OutboxReplayService` aggregator
    /// VERBATIM from the prior inline `init` block (same args, same order,
    /// same best-effort Mood→HealthKit mirror closures), so the move is
    /// behaviour-identical. The `outboxReplay` `public let` handle stays on
    /// `AppContainer` (this just feeds it).
    ///
    /// Every dependency is one of the already-built repos / the optional
    /// `AnyHealthKitWriter`; the service itself is `Sendable`-by-construction
    /// (the only main-actor-free phase between the repos and the stores), so
    /// the factory is non-isolated.
    static func makeOutboxReplay(
        outbox: OutboxQueue,
        measurementsRepo: MeasurementsRepository,
        moodRepo: MoodRepository,
        medicationsRepo: MedicationsRepository,
        userThresholdsRepo: UserThresholdsRepository,
        insightsLayoutRepo: InsightsLayoutRepository,
        therapyLogRepo: MedicationTherapyLogRepository,
        cycleRepo: CycleRepository,
        workoutsRepo: WorkoutsRepository,
        coachAboutMeRepo: CoachAboutMeRepository,
        labsRepo: LabsRepository,
        customMetricsRepo: CustomMetricsRepository,
        illnessRepo: IllnessRepository,
        allergiesRepo: AllergiesRepository,
        familyHistoryRepo: FamilyHistoryRepository,
        mentalHealthRepo: MentalHealthRepository,
        nutrientReadRepo: NutrientReadRepository,
        healthKit: AnyHealthKitWriter?,
        // audit-v0162 H1 (Opt 3) — shared degraded-server signal, fed by the
        // `/api/health` reachability probe. A 5xx/429 replay failure while the
        // server is known-degraded does NOT burn the write's retry budget.
        serverHealth: ServerHealthSignal
    ) -> OutboxReplayService {
        OutboxReplayService(
            outbox: outbox,
            measurementsRepo: measurementsRepo,
            moodRepo: moodRepo,
            medicationsRepo: medicationsRepo,
            // v0.7.1 W-TARGETS-EDITOR — replay offline target-range edits.
            userThresholdsRepo: userThresholdsRepo,
            // v0.8.0 W10 — replay offline Insights layout edits.
            insightsLayoutRepo: insightsLayoutRepo,
            // v0.10.0 W10 M1 — mirror replayed offline mood create/update/delete
            // into Apple Health (self-gated on the user's sync toggle), closing
            // the gap where an offline-logged mood never reached HKStateOfMind.
            // Closures (not a direct writer dep) because `OutboxReplayService`
            // also compiles into the widget extension, which doesn't link the
            // app-only `AnyHealthKitWriter`.
            // A2-M4 — keep the mirror best-effort (must NOT block the server
            // write) but make a failure loud-in-logs, not silent. A real HK
            // failure (e.g. authorization revoked mid-session) would otherwise
            // diverge server↔HealthKit with nothing observable at this seam.
            mirrorMood: healthKit.map { writer in
                { @Sendable entry in
                    do {
                        try await writer.writeMood(entry)
                    } catch {
                        HLLog.healthKit.warning(
                            "Mood→HK mirror (replay write) fehlgeschlagen — server bleibt führend: \(error.localizedDescription, privacy: .private)"
                        )
                    }
                }
            },
            mirrorMoodDelete: healthKit.map { writer in
                { @Sendable id in
                    do {
                        try await writer.deleteMood(id: id)
                    } catch {
                        HLLog.healthKit.warning(
                            "Mood→HK mirror (replay delete) fehlgeschlagen — server bleibt führend: \(error.localizedDescription, privacy: .private)"
                        )
                    }
                }
            },
            therapyLogRepo: therapyLogRepo, // v0.12 SP3+SP4 — replay offline side-effect + inventory writes
            cycleRepo: cycleRepo, // v0.14.8 — replay offline cycle day-log + period writes
            workoutsRepo: workoutsRepo, // audit C4.1 — replay enrolled workout batch uploads
            coachAboutMeRepo: coachAboutMeRepo, // W-B187 COACH-3 — replay offline adopt/dismiss
            labsRepo: labsRepo, // v1.18.6 PHI — replay offline lab + biomarker writes
            illnessRepo: illnessRepo, // v1.18.6 PHI — replay offline episode + day-log writes
            allergiesRepo: allergiesRepo, // v1.25 PHI — replay offline allergy writes
            familyHistoryRepo: familyHistoryRepo, // v1.25 PHI — replay offline family-history writes
            mentalHealthRepo: mentalHealthRepo, // v1.25 PHI — replay offline PHQ-9 / GAD-7 submits
            customMetricsRepo: customMetricsRepo, // replay offline custom-metric writes
            nutrientReadRepo: nutrientReadRepo, // Build 7.6 (GH #48) — replay offline water quick-adds
            // audit-v0162 H1 (Opt 3) — degraded-server attempt-suppression.
            serverHealthDegraded: { await serverHealth.isKnownDegraded }
        )
    }
}
