import Testing
#if canImport(HealthKit)
    import HealthKit
#endif
@testable import HealthLog

/// Unit-level coverage for the per-kind HK sync diagnostics store. Builds
/// confidence that:
/// - the per-identifier counter is monotonic across multiple `record(...)`
///   calls,
/// - the `snapshotByKind()` rollup correctly merges BP-sys + BP-dia into
///   `.bloodPressure`,
/// - logout-cleanup (`reset()`) zeroes everything,
/// - the reverse-map covers every kind in `MetricKind.allCases` that has an
///   HK read-type (the contract operator-feedback BF-5 hinges on).
@MainActor
@Suite("HKSyncDiagnostics — per-kind sync counters (BF-5)")
struct HKSyncDiagnosticsTests {
    private func freshStore() -> HKSyncDiagnostics {
        let store = HKSyncDiagnostics.shared
        store.reset()
        return store
    }

    // MARK: - Observation counter

    @Test("recordObservation accumulates samplesRead + samplesUploaded per identifier")
    func observationAccumulates() throws {
        let store = freshStore()
        let identifier = "HKQuantityTypeIdentifierBodyMass"

        store.recordObservation(identifier: identifier, samplesRead: 3, samplesUploaded: 3, anchorAdvanced: true)
        store.recordObservation(identifier: identifier, samplesRead: 2, samplesUploaded: 1, anchorAdvanced: true)

        let stats = try #require(store.byIdentifier[identifier])
        #expect(stats.samplesReadTotal == 5)
        #expect(stats.samplesUploadedTotal == 4)
        #expect(stats.lastObservationAt != nil)
        #expect(stats.lastAnchorAdvancedAt != nil)
    }

    @Test("anchorAdvanced=false bumps observation timestamp but NOT anchorAdvanced timestamp")
    func anchorAdvanceGate() throws {
        let store = freshStore()
        let id = "HKQuantityTypeIdentifierStepCount"
        let early = Date(timeIntervalSince1970: 1_000_000)

        store.recordObservation(identifier: id, samplesRead: 0, samplesUploaded: 0, anchorAdvanced: false, at: early)
        let stats = try #require(store.byIdentifier[id])
        #expect(stats.lastObservationAt == early)
        #expect(stats.lastAnchorAdvancedAt == nil)
    }

    // MARK: - HK-STATS counter

    @Test("recordStatsAction tallies posted / upserted separately")
    func statsCounters() throws {
        let store = freshStore()
        let id = "HKQuantityTypeIdentifierStepCount"

        store.recordStatsAction(identifier: id, posted: 1, reposted: 0)
        store.recordStatsAction(identifier: id, posted: 0, reposted: 1)
        store.recordStatsAction(identifier: id, posted: 2, reposted: 0)

        let stats = try #require(store.byIdentifier[id])
        #expect(stats.statsPostedTotal == 3)
        #expect(stats.statsRepostedTotal == 1)
        #expect(stats.lastStatsActionAt != nil)
    }

    // MARK: - snapshotByKind rollup

    @Test("snapshotByKind merges BP-systolic + BP-diastolic into a single .bloodPressure row")
    func bloodPressureRollup() throws {
        let store = freshStore()
        let sys = "HKQuantityTypeIdentifierBloodPressureSystolic"
        let dia = "HKQuantityTypeIdentifierBloodPressureDiastolic"

        store.recordObservation(identifier: sys, samplesRead: 4, samplesUploaded: 4, anchorAdvanced: true)
        store.recordObservation(identifier: dia, samplesRead: 4, samplesUploaded: 3, anchorAdvanced: true)

        let byKind = store.snapshotByKind()
        let bp = try #require(byKind[.bloodPressure])
        #expect(bp.samplesReadTotal == 8)
        #expect(bp.samplesUploadedTotal == 7)
        // The merged identifier should be the kind's canonical raw value so
        // the diagnostics view doesn't show "...BloodPressureSystolic" for BP.
        #expect(bp.identifier == MetricKind.bloodPressure.rawValue)
    }

    @Test("snapshotByKind drops identifiers without a kind-mapping (forward-compatible)")
    func unmappedIdentifiersDropped() {
        let store = freshStore()
        store.recordObservation(
            identifier: "HKQuantityTypeIdentifierSomeFutureAppleKind",
            samplesRead: 5,
            samplesUploaded: 5,
            anchorAdvanced: true
        )
        let byKind = store.snapshotByKind()
        // The unmapped entry stays in byIdentifier but is excluded from the rollup.
        #expect(store.byIdentifier.count == 1)
        #expect(byKind.isEmpty)
    }

    // MARK: - Reset

    @Test("reset() clears all counters and lastActivityAt")
    func resetClears() {
        let store = freshStore()
        store.recordObservation(
            identifier: "HKQuantityTypeIdentifierBodyMass",
            samplesRead: 1,
            samplesUploaded: 1,
            anchorAdvanced: true
        )
        #expect(!store.byIdentifier.isEmpty)
        #expect(store.lastActivityAt != nil)

        store.reset()
        #expect(store.byIdentifier.isEmpty)
        #expect(store.lastActivityAt == nil)
    }

    // MARK: - #66 P0.1 (Baustein 4) — background-wake persistence

    @Test("recordWake persists each channel's timestamp and reloads across a fresh instance")
    func wakePersistenceRoundTrips() throws {
        let suiteName = "hl.hksync.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = HKSyncDiagnostics.makeForTesting(defaults: defaults)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        store.recordWake(.processing, at: base)
        store.recordWake(.appRefresh, at: base.addingTimeInterval(1))
        store.recordWake(.push, at: base.addingTimeInterval(2))
        store.recordWake(.observer, at: base.addingTimeInterval(3))

        #expect(store.lastProcessingWakeAt == base)
        #expect(store.lastAppRefreshWakeAt == base.addingTimeInterval(1))
        #expect(store.lastPushWakeAt == base.addingTimeInterval(2))
        #expect(store.lastBackgroundObservationAt == base.addingTimeInterval(3))

        // A fresh instance backed by the same defaults reloads them — the #66
        // evidence must survive the cold-launch counter reset.
        let reloaded = HKSyncDiagnostics.makeForTesting(defaults: defaults)
        #expect(reloaded.lastProcessingWakeAt == base)
        #expect(reloaded.lastAppRefreshWakeAt == base.addingTimeInterval(1))
        #expect(reloaded.lastPushWakeAt == base.addingTimeInterval(2))
        #expect(reloaded.lastBackgroundObservationAt == base.addingTimeInterval(3))
    }

    @Test("reset() clears the persisted wake timestamps")
    func wakeResetClears() throws {
        let suiteName = "hl.hksync.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = HKSyncDiagnostics.makeForTesting(defaults: defaults)
        store.recordWake(.appRefresh)
        store.recordWake(.push)
        #expect(store.lastAppRefreshWakeAt != nil)

        store.reset()
        #expect(store.lastAppRefreshWakeAt == nil)
        #expect(store.lastPushWakeAt == nil)

        let reloaded = HKSyncDiagnostics.makeForTesting(defaults: defaults)
        #expect(reloaded.lastAppRefreshWakeAt == nil)
        #expect(reloaded.lastPushWakeAt == nil)
    }

    // MARK: - #66 P0.1 (Baustein 2) — trigger-source provenance

    @Test("recordCollectionTrigger persists the .push source (silent-push provenance)")
    func collectionTriggerPushSourcePersists() throws {
        let suiteName = "hl.hksync.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = HKSyncDiagnostics.makeForTesting(defaults: defaults)
        // The new provenance case flows straight from the enum raw value; pin
        // that it round-trips through persistence (the diagnostics-internal home
        // of the source until the server specs its ingest field).
        store.recordCollectionTrigger(source: SpeziCollectionTrigger.Source.push.rawValue)
        #expect(store.lastCollectionTriggerSource == "push")

        let reloaded = HKSyncDiagnostics.makeForTesting(defaults: defaults)
        #expect(reloaded.lastCollectionTriggerSource == "push")
    }

    // MARK: - Phase 07 / plan 07-07 — orchestrated-pass and withheld-item counters

    @Test("an orchestrated pass counts dispositions, hold reasons and admission refusals")
    func healthSyncPassCountersAccumulate() throws {
        let suiteName = "hl.hksync.pass.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = HKSyncDiagnostics.makeForTesting(defaults: defaults)
        let pass = HealthSyncPassResult(
            trigger: .processing,
            planned: [.cycleImport, .heartHealthEvents, .outboxDrain],
            results: [
                .refused(.cycleImport, .notAdmitted),
                HealthSyncCapabilityResult(
                    capability: .heartHealthEvents,
                    disposition: .retryPersisted,
                    itemsHeld: 6,
                    holdReason: .nonterminalEntry
                ),
                .succeeded(.outboxDrain)
            ],
            startedAt: Date(),
            durationMilliseconds: 40,
            wasCancelled: false,
            wasExpired: false
        )
        store.recordHealthSyncPass(pass.publicSnapshot)

        #expect(store.healthSync.lastPassTrigger == "processing")
        #expect(store.healthSync.lastPassWasComplete == false)
        #expect(store.healthSync.lastPassHeldItems == 6)
        #expect(store.healthSync.admissionRefusalsTotal == 1)
        #expect(store.healthSync.lastPassRefusedForMissingAdmission == ["cycleImport"])
        #expect(store.healthSync.holdReasonTotals["nonterminalEntry"] == 1)
        #expect(store.healthSync.holdReasonTotals["leaseLost"] == 1)
        #expect(store.healthSync.dispositionTotals["retryPersisted"] == 1)

        // A second pass accumulates rather than replacing the totals.
        store.recordHealthSyncPass(pass.publicSnapshot)
        #expect(store.healthSync.admissionRefusalsTotal == 2)

        let reloaded = HKSyncDiagnostics.makeForTesting(defaults: defaults)
        #expect(reloaded.healthSync.admissionRefusalsTotal == 2)
        #expect(reloaded.healthSync.lastPassHeldItems == 6)
    }

    @Test("withheld-item counts persist and a missing half leaves the other alone")
    func withheldCountsPersistIndependently() throws {
        let suiteName = "hl.hksync.withheld.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = HKSyncDiagnostics.makeForTesting(defaults: defaults)
        store.recordWithheldCounts(pendingAppleDoses: 3)
        store.recordWithheldCounts(quarantinedLegacyRows: 11)
        #expect(store.healthSync.pendingAppleDoseCount == 3)
        #expect(store.healthSync.quarantinedLegacyRowCount == 11)

        // The stats sweep reporting its own number must not zero the dose count.
        store.recordWithheldCounts(quarantinedLegacyRows: 9)
        #expect(store.healthSync.pendingAppleDoseCount == 3)
        #expect(store.healthSync.quarantinedLegacyRowCount == 9)

        let reloaded = HKSyncDiagnostics.makeForTesting(defaults: defaults)
        #expect(reloaded.healthSync.pendingAppleDoseCount == 3)
        #expect(reloaded.healthSync.quarantinedLegacyRowCount == 9)
    }

    @Test("logout clears the orchestrated-pass counters too")
    func resetClearsHealthSyncCounters() throws {
        let suiteName = "hl.hksync.passreset.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = HKSyncDiagnostics.makeForTesting(defaults: defaults)
        store.recordWithheldCounts(pendingAppleDoses: 5, quarantinedLegacyRows: 2)
        store.reset()
        #expect(store.healthSync == HKSyncDiagnostics.HealthSyncSnapshot())

        let reloaded = HKSyncDiagnostics.makeForTesting(defaults: defaults)
        #expect(reloaded.healthSync.pendingAppleDoseCount == 0)
    }

    @Test("the AppRefresh wake is a distinct collection-trigger source")
    func appRefreshSourceIsDistinct() {
        #expect(SpeziCollectionTrigger.Source.appRefresh.healthSyncTrigger == .appRefresh)
        #expect(SpeziCollectionTrigger.Source.background.healthSyncTrigger == .processing)
        // The budget difference is the reason the case exists.
        #expect(HealthSyncBudget.required(for: .appRefresh).incrementalOnly)
        #expect(!HealthSyncBudget.required(for: .processing).incrementalOnly)
    }

    // MARK: - Phase 1 / Plan 04 — privacy-safe workout delivery truth

    @Test("failed workout attempt advances only lastAttemptedAt")
    func failedWorkoutAttemptDoesNotClaimUsefulCompletion() throws {
        let suiteName = "hl.hksync.workout.attempt.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = HKSyncDiagnostics.makeForTesting(defaults: defaults)
        let attemptedAt = Date(timeIntervalSince1970: 1_700_100_000)
        store.recordWorkoutAttempt(source: .processing, at: attemptedAt)
        store.recordWorkoutFailure(.transport)

        #expect(store.workout.lastAttemptedAt == attemptedAt)
        #expect(store.workout.lastCompletedUsefulAt == nil)
        #expect(store.workout.lastSource == .processing)
        #expect(store.workout.lastFailure == .transport)
    }

    @Test("accepted workout response advances useful completion and aggregate counters")
    func acceptedWorkoutResponseClaimsUsefulCompletion() throws {
        let suiteName = "hl.hksync.workout.useful.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = HKSyncDiagnostics.makeForTesting(defaults: defaults)
        let attemptedAt = Date(timeIntervalSince1970: 1_700_200_000)
        let completedAt = attemptedAt.addingTimeInterval(4)
        store.recordWorkoutAttempt(source: .observer, at: attemptedAt)
        store.recordWorkoutFetch(fetched: 3, mapped: 2)
        store.recordWorkoutSend(count: 2)
        store.recordWorkoutResponse(
            accepted: 2,
            skipped: 0,
            completeAcceptance: true,
            at: completedAt
        )

        #expect(store.workout.lastAttemptedAt == attemptedAt)
        #expect(store.workout.lastCompletedUsefulAt == completedAt)
        #expect(store.workout.lastSource == .observer)
        #expect(store.workout.fetchedTotal == 3)
        #expect(store.workout.mappedTotal == 2)
        #expect(store.workout.sentTotal == 2)
        #expect(store.workout.acceptedTotal == 2)
        #expect(store.workout.skippedTotal == 0)
        #expect(store.workout.lastFailure == nil)
    }

    @Test("zero accepted entries never advance useful completion")
    func rejectedWorkoutResponseDoesNotClaimUsefulCompletion() throws {
        let suiteName = "hl.hksync.workout.rejected.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = HKSyncDiagnostics.makeForTesting(defaults: defaults)
        store.recordWorkoutAttempt(source: .push, at: Date(timeIntervalSince1970: 1_700_300_000))
        store.recordWorkoutSend(count: 1)
        store.recordWorkoutResponse(
            accepted: 0,
            skipped: 1,
            completeAcceptance: false,
            at: Date(timeIntervalSince1970: 1_700_300_010)
        )

        #expect(store.workout.lastCompletedUsefulAt == nil)
        #expect(store.workout.acceptedTotal == 0)
        #expect(store.workout.skippedTotal == 1)
        #expect(store.workout.lastFailure == .serverRejected)
    }

    @Test("partial acceptance never advances useful completion")
    func partiallyAcceptedWorkoutResponseDoesNotClaimUsefulCompletion() throws {
        let suiteName = "hl.hksync.workout.partial.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = HKSyncDiagnostics.makeForTesting(defaults: defaults)
        store.recordWorkoutAttempt(source: .processing, at: Date(timeIntervalSince1970: 1_700_350_000))
        store.recordWorkoutSend(count: 2)
        store.recordWorkoutResponse(
            accepted: 1,
            skipped: 1,
            completeAcceptance: false,
            at: Date(timeIntervalSince1970: 1_700_350_010)
        )

        #expect(store.workout.lastCompletedUsefulAt == nil)
        #expect(store.workout.acceptedTotal == 1)
        #expect(store.workout.skippedTotal == 1)
        #expect(store.workout.lastFailure == .serverRejected)
    }

    @Test("workout diagnostics persist only redacted aggregate state")
    func workoutDiagnosticsPersistWithoutHealthPayloadFields() throws {
        let suiteName = "hl.hksync.workout.privacy.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = HKSyncDiagnostics.makeForTesting(defaults: defaults)
        store.recordWorkoutRegistration(.succeeded, at: Date(timeIntervalSince1970: 1_700_400_000))
        store.recordWorkoutAttempt(source: .appRefresh, at: Date(timeIntervalSince1970: 1_700_400_010))
        store.recordWorkoutBackfill(.progressed, enriched: 2)

        let persistedDescription = defaults.dictionaryRepresentation().description.lowercased()
        for forbidden in ["uuid", "externalid", "samples", "route", "heartrate", "pulse", "payload"] {
            #expect(!persistedDescription.contains(forbidden))
        }

        let reloaded = HKSyncDiagnostics.makeForTesting(defaults: defaults)
        #expect(reloaded.workout.registrationState == .succeeded)
        #expect(reloaded.workout.lastSource == .appRefresh)
        #expect(reloaded.workout.backfillState == .progressed)
        #expect(reloaded.workout.backfillEnrichedTotal == 2)
    }

    // MARK: - Identifier coverage contract

    /// Locks in the contract that the diagnostics reverse-map covers every
    /// `MetricKind` that has an HK read-type. If a future contributor adds
    /// a new kind without extending `identifierToKind`, this test breaks
    /// at the boundary instead of silently dropping rows in the UI.
    ///
    /// `bodyWater` + `boneMass` are deliberately excluded — they have no
    /// direct HK quantity type (smart-scale-derived; flow over the wire as
    /// custom rows that don't pass through the observation path).
    ///
    /// v0.11 W21 + F3 — the nine web-parity body-composition / arterial /
    /// walking-HR additions are **server/Withings-sourced only**: they are NOT
    /// collected through the iOS HK observer path (not in
    /// `HealthLogSampleTypeRegistry`), so they have no reverse-map entry by
    /// design and are exempt for the same reason as bodyWater/boneMass.
    @Test("Every MetricKind with an HK read-type has a reverse-map entry")
    func identifierMapCoversAllKinds() {
        let mappedKinds = Set(HKSyncDiagnostics.identifierToKind.values)
        let kindsWithoutHKType: Set<MetricKind> = [
            .bodyWater, .boneMass,
            // v0.11 W21 + F3 — server/Withings-sourced, not on the HK observer path.
            .fatFreeMass, .leanBodyMass, .muscleMass, .skinTemperature,
            .pulseWaveVelocity, .vascularAge, .visceralFat, .walkingHeartRate,
            .fatMass,
            // v0.13.1 IC — v1.10.0 additive signals are display-only (server
            // ingest, not collected via the iOS HK observer registry), so they
            // have no reverse-map entry by design — same exemption as above.
            .falls, .sixMinuteWalk, .stairAscentSpeed, .stairDescentSpeed,
            .breathingDisturbances, .cardioRecovery, .wristTemperature,
            // v0.14.6 — WHOOP-native aggregates are server-ingested read-only
            // (no iOS HK observer path), so they have no reverse-map entry by
            // design — same exemption as the v1.10.0 additive signals above.
            .averageHeartRate, .maxHeartRate, .sleepDisturbanceCount,
            // v0.14.1 W-REGFIX — v1.17.1 source-fixed render-only signals (#23)
            // are server-computed, have no HK read-type, and are not on the iOS
            // HK observer registry, so they have no reverse-map entry by design
            // — same exemption as the WHOOP / v1.10.0 additive signals above.
            .ansCharge, .cardioLoad, .sleepScore, .bodyTemperatureDeviation,
            // v0158 — v1.25 clinical measurement types are MANUAL / server-side
            // (entered via the measure sheet, not collected through the iOS HK
            // observer registry), so they have no reverse-map entry by design —
            // same exemption as the WHOOP / v1.10.0 additive signals above.
            .painNRS, .gripStrength, .waistCircumference, .waistToHeight,
            // Build 3 / item 3.3 — the 21 decoder catch-up kinds are
            // server-computed or wearable-ingested read-only. None is on the
            // iOS HK observer registry (adding them would risk sample
            // duplication for data the app does not author), so they have no
            // reverse-map entry by design — same exemption as above.
            .phq9Score, .gad7Score, .who5Score, .sciScore,
            .recoveryScore, .stressScore, .strainScore, .hrvRMSSD,
            .dayStrain, .workoutStrain, .sleepPerformance, .sleepEfficiency,
            .sleepConsistency, .sleepNeed, .energyExpenditureKJ, .resilience,
            .irregularRhythmNotification, .highHeartRateEvent, .lowHeartRateEvent,
            .walkingSteadinessEvent, .breathingDisturbanceEvent,
            .mood // Build 7.3 — dashboard mood tile (server-sourced), not an HK sync type
        ]
        let expectedKinds = Set(MetricKind.allCases).subtracting(kindsWithoutHKType)
        // `mappedKinds` must be a SUPERSET of the expected kinds.
        let missing = expectedKinds.subtracting(mappedKinds)
        #expect(missing.isEmpty, "Missing reverse-map entries for: \(missing.map(\.rawValue).sorted())")
    }
}
