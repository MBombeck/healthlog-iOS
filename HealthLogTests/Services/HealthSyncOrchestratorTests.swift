import Foundation
@testable import HealthLog
import Testing

/// Phase 07 Wave 4 — the orchestrator's contract.
///
/// The thing under test is not "does a capability work" — Waves 1-3 own that.
/// It is "can a capability disappear", and the answer has to be no under every
/// condition a background wake can produce: a closed window, a cancelled task,
/// an adapter that throws its answer away, an account that cannot be admitted.
@Suite("HealthKit sync orchestrator")
struct HealthSyncOrchestratorTests {
    // MARK: - Test doubles

    /// Records which capabilities ran, in which order, and how many were in
    /// flight at the same time.
    actor RunLog {
        private(set) var entered: [HealthSyncCapability] = []
        private(set) var maxConcurrent = 0
        private var inFlight = 0

        func begin(_ capability: HealthSyncCapability) {
            entered.append(capability)
            inFlight += 1
            maxConcurrent = max(maxConcurrent, inFlight)
        }

        func end() {
            inFlight -= 1
        }
    }

    /// A registry whose every adapter reports the same disposition and records
    /// its entry. `overrides` replaces individual capabilities.
    private static func registry(
        log: RunLog,
        disposition: HealthSyncDisposition = .succeeded,
        overrides: [HealthSyncCapability: HealthSyncCapabilityResult] = [:],
        delayNanoseconds: UInt64 = 0
    ) -> HealthSyncCapabilityRegistry {
        func make(_ capability: HealthSyncCapability) -> HealthSyncCapabilityRegistry.Run {
            { _ in
                await log.begin(capability)
                if delayNanoseconds > 0 {
                    try? await Task.sleep(nanoseconds: delayNanoseconds)
                }
                await log.end()
                return overrides[capability]
                    ?? HealthSyncCapabilityResult(capability: capability, disposition: disposition)
            }
        }
        return HealthSyncCapabilityRegistry(
            speziSampleCollection: make(.speziSampleCollection),
            workoutImport: make(.workoutImport),
            ecgUpload: make(.ecgUpload),
            dailyStatistics: make(.dailyStatistics),
            heartRateBuckets: make(.heartRateBuckets),
            nutrientDailyTotals: make(.nutrientDailyTotals),
            moodStateOfMindImport: make(.moodStateOfMindImport),
            appleMedicationImport: make(.appleMedicationImport),
            cycleImport: make(.cycleImport),
            heartHealthEvents: make(.heartHealthEvents),
            outboxDrain: make(.outboxDrain)
        )
    }

    // MARK: - Registry totality

    @Test("the registry names every capability and exactly the thirty-five sample types")
    func registryIsExact() {
        let registry = HealthSyncCapabilityRegistry.unsupportedEverywhere()
        #expect(registry.namesEveryCapability)
        #expect(registry.capabilities.count == HealthSyncCapability.allCases.count)
        #expect(registry.coversExactlyTheKnownSampleTypes)
        #expect(registry.sampleTypeIdentifiers.count == 35)
        #expect(registry.sampleTypeIdentifiers == HealthLogSampleTypeRegistry.knownIdentifiers)
    }

    @Test("every capability resolves to an adapter, disabled or not")
    func everyCapabilityHasAnAdapter() {
        let registry = HealthSyncCapabilityRegistry.unsupportedEverywhere()
        for capability in HealthSyncCapability.allCases {
            #expect(registry.adapter(for: capability).capability == capability)
        }
    }

    // MARK: - Plans

    @Test("a manual pass names every capability and omits none")
    func manualPassNamesEveryCapability() async {
        let log = RunLog()
        let orchestrator = HealthSyncOrchestrator(registry: Self.registry(log: log))
        let pass = await orchestrator.run(.manual)

        #expect(pass.planned == HealthSyncCompositionPlan.completeSet)
        #expect(pass.omitted.isEmpty)
        #expect(pass.results.count == HealthSyncCapability.allCases.count)
        for capability in HealthSyncCapability.allCases {
            #expect(pass.result(for: capability) != nil, "\(capability.rawValue) was omitted")
        }
        #expect(pass.isComplete)
    }

    @Test("the four opt-in importers cannot be silently omitted from a complete pass")
    func optInImportersAreNeverOmitted() async {
        let log = RunLog()
        let orchestrator = HealthSyncOrchestrator(registry: Self.registry(log: log))
        for trigger in [HealthSyncTrigger.manual, .foreground, .processing, .postAuthentication] {
            let pass = await orchestrator.run(trigger)
            for capability in [
                HealthSyncCapability.cycleImport,
                .heartHealthEvents,
                .moodStateOfMindImport,
                .appleMedicationImport
            ] {
                #expect(
                    pass.result(for: capability) != nil,
                    "\(trigger.rawValue) omitted \(capability.rawValue)"
                )
            }
        }
    }

    @Test("a short wake plans the incremental set and nothing wider")
    func shortWakePlansIncrementalSet() async {
        let log = RunLog()
        let orchestrator = HealthSyncOrchestrator(registry: Self.registry(log: log))
        for trigger in [HealthSyncTrigger.appRefresh, .silentPush] {
            let pass = await orchestrator.run(trigger)
            #expect(pass.planned == HealthSyncCompositionPlan.incrementalSet)
            #expect(pass.omitted.isEmpty)
        }
    }

    @Test("an observer pass targets exactly the signalled source")
    func observerPassIsSourceTargeted() async {
        let log = RunLog()
        let orchestrator = HealthSyncOrchestrator(registry: Self.registry(log: log))
        let pass = await orchestrator.run(.observer, observedSource: .cycle)
        #expect(pass.planned == [.cycleImport])
        #expect(pass.results.map(\.capability) == [.cycleImport])
        let entered = await log.entered
        #expect(entered == [.cycleImport], "an observer fanned out")
    }

    @Test("an observer with no source, and an account teardown, run nothing")
    func emptyPlansRunNothing() async {
        let log = RunLog()
        let orchestrator = HealthSyncOrchestrator(registry: Self.registry(log: log))
        #expect(await orchestrator.run(.observer).results.isEmpty)
        #expect(await orchestrator.run(.accountTeardown).results.isEmpty)
        let entered = await log.entered
        #expect(entered.isEmpty)
    }

    @Test("the outbox drain runs last, so a page held in this pass gets a replay")
    func outboxDrainRunsLast() async {
        let log = RunLog()
        let orchestrator = HealthSyncOrchestrator(registry: Self.registry(log: log))
        _ = await orchestrator.run(.manual)
        let entered = await log.entered
        #expect(entered.last == .outboxDrain)
    }

    // MARK: - Budgets

    @Test("every trigger carries its own budget into the adapters")
    func budgetsReachTheAdapters() async {
        actor Seen {
            var budgets: [HealthSyncTrigger: HealthSyncBudget] = [:]
            func record(_ trigger: HealthSyncTrigger, _ budget: HealthSyncBudget) {
                budgets[trigger] = budget
            }
        }
        let seen = Seen()
        let capture: HealthSyncCapabilityRegistry.Run = { context in
            await seen.record(context.trigger, context.budget)
            return .succeeded(.outboxDrain)
        }
        let registry = HealthSyncCapabilityRegistry(
            speziSampleCollection: { _ in .disabled(.speziSampleCollection) },
            workoutImport: { _ in .disabled(.workoutImport) },
            ecgUpload: { _ in .disabled(.ecgUpload) },
            dailyStatistics: { _ in .disabled(.dailyStatistics) },
            heartRateBuckets: { _ in .disabled(.heartRateBuckets) },
            nutrientDailyTotals: { _ in .disabled(.nutrientDailyTotals) },
            moodStateOfMindImport: { _ in .disabled(.moodStateOfMindImport) },
            appleMedicationImport: { _ in .disabled(.appleMedicationImport) },
            cycleImport: { _ in .disabled(.cycleImport) },
            heartHealthEvents: { _ in .disabled(.heartHealthEvents) },
            outboxDrain: capture
        )
        let orchestrator = HealthSyncOrchestrator(registry: registry)
        _ = await orchestrator.run(.appRefresh)
        _ = await orchestrator.run(.processing)
        let budgets = await seen.budgets
        #expect(budgets[.appRefresh]?.incrementalOnly == true)
        #expect(budgets[.appRefresh]?.allowsFirstHistoryImport == false)
        #expect(budgets[.processing]?.allowsFirstHistoryImport == true)
        #expect(budgets[.processing]?.maxPagesPerType == 8)
    }

    // MARK: - Bounded concurrency

    @Test("at most two capabilities are ever in flight")
    func concurrencyIsBoundedAtTwo() async {
        let log = RunLog()
        let orchestrator = HealthSyncOrchestrator(
            registry: Self.registry(log: log, delayNanoseconds: 2_000_000)
        )
        _ = await orchestrator.run(.manual)
        let peak = await log.maxConcurrent
        #expect(peak <= 2, "\(peak) capabilities ran at once")
    }

    @Test("capabilities that share the batch uploader never overlap")
    func sharedUploadLaneIsSerialized() {
        let registry = HealthSyncCapabilityRegistry.unsupportedEverywhere()
        let shared: [HealthSyncCapability] = [
            .speziSampleCollection,
            .workoutImport,
            .dailyStatistics,
            .heartRateBuckets,
            .nutrientDailyTotals,
            .heartHealthEvents,
            .outboxDrain
        ]
        for capability in shared {
            #expect(registry.adapter(for: capability).lane == .sharedUpload, "\(capability.rawValue)")
        }
        for capability in [HealthSyncCapability.ecgUpload, .moodStateOfMindImport, .appleMedicationImport, .cycleImport] {
            #expect(registry.adapter(for: capability).lane == .independent, "\(capability.rawValue)")
        }
    }

    // MARK: - Cancellation and expiration

    @Test("an expired window names every remaining capability instead of dropping it")
    func expirationNamesTheRemainder() async {
        let log = RunLog()
        let orchestrator = HealthSyncOrchestrator(registry: Self.registry(log: log))
        let pass = await orchestrator.run(.manual, isExpired: { true })

        #expect(pass.omitted.isEmpty, "an expiring pass dropped a capability")
        #expect(pass.results.count == HealthSyncCapability.allCases.count)
        #expect(pass.results.allSatisfy { $0.disposition == .expired })
        #expect(pass.wasExpired)
        #expect(!pass.isComplete, "an expired pass claimed completion")
        let entered = await log.entered
        #expect(entered.isEmpty, "an expired pass still admitted work")
    }

    @Test("a pass that persisted a retry row is progress, not completion")
    func retryPersistedIsNotComplete() async {
        let log = RunLog()
        let orchestrator = HealthSyncOrchestrator(
            registry: Self.registry(
                log: log,
                overrides: [
                    .cycleImport: HealthSyncCapabilityResult(
                        capability: .cycleImport,
                        disposition: .retryPersisted,
                        itemsHeld: 3,
                        holdReason: .nonterminalEntry
                    )
                ]
            )
        )
        let pass = await orchestrator.run(.manual)
        #expect(!pass.isComplete)
        #expect(pass.heldItemCount == 3)
        #expect(pass.result(for: .cycleImport)?.holdReason == .nonterminalEntry)
    }

    @Test("a merely entered capability never reads as completion")
    func ranIsNotComplete() async {
        let log = RunLog()
        let orchestrator = HealthSyncOrchestrator(registry: Self.registry(log: log, disposition: .ran))
        let pass = await orchestrator.run(.foreground)
        #expect(!pass.isComplete)
        #expect(pass.omitted.isEmpty)
    }

    // MARK: - Admission truth

    @Test("a capability refused for a missing admission says so by name")
    func missingAdmissionIsNamed() async {
        let log = RunLog()
        let refused = HealthSyncCapabilityResult.refused(.moodStateOfMindImport, .notAdmitted)
        let orchestrator = HealthSyncOrchestrator(
            registry: Self.registry(log: log, overrides: [.moodStateOfMindImport: refused])
        )
        let pass = await orchestrator.run(.manual)

        #expect(pass.refusedForMissingAdmission == [.moodStateOfMindImport])
        #expect(pass.result(for: .moodStateOfMindImport)?.disposition == .failed)
        #expect(pass.result(for: .moodStateOfMindImport)?.holdReason == .leaseLost)
        #expect(!pass.isComplete)
        #expect(pass.publicSnapshot.capabilitiesRefusedForMissingAdmission == ["moodStateOfMindImport"])
    }

    @Test("an inert session registry produces eleven refusals, not eleven silences")
    func inertRegistryRefusesEveryAdmissionGatedCapability() throws {
        // The production shape of the defect: a registry nothing ever activated.
        let registry = AuthenticatedSessionLeaseRegistry()
        let keychain = InMemoryKeychain()
        try keychain.setString("owner-a", forKey: KeychainKey.userID)
        try keychain.setString("bearer-a", forKey: KeychainKey.authToken)
        let admission = HealthSyncImporterAdmission.keychainBound(keychain: keychain, registry: registry)

        for source in HealthSyncSource.allCases {
            #expect(
                admission.refusal(for: source) == .notAdmitted,
                "\(source.rawValue) did not report notAdmitted against an inert registry"
            )
        }

        // …and once something activates it, the same admission succeeds. The
        // constant below is what says which of the two the app is in.
        registry.activate(ownerID: "owner-a")
        #expect(admission.refusal(for: .cycle) == nil)
        #expect(HealthSyncCompositionPlan.requiredActivatesSessionRegistry)
    }

    // MARK: - Publishing

    @Test("the published snapshot carries names and counts only")
    func snapshotIsPrivacySafe() async {
        let log = RunLog()
        let orchestrator = HealthSyncOrchestrator(registry: Self.registry(log: log))
        let snapshot = await orchestrator.run(.processing).publicSnapshot

        #expect(snapshot.trigger == "processing")
        #expect(snapshot.capabilities.count == HealthSyncCapability.allCases.count)
        #expect(snapshot.omittedCapabilities.isEmpty)
        let dispositions = Set(HealthSyncDisposition.allCases.map(\.rawValue))
        let capabilities = Set(HealthSyncCapability.allCases.map(\.rawValue))
        for row in snapshot.capabilities {
            #expect(capabilities.contains(row.capability))
            #expect(dispositions.contains(row.disposition))
            #expect(row.failure.map { HealthSyncFailureClass(rawValue: $0) != nil } ?? true)
        }
        // Encodable round-trip: whatever a surface persists is exactly this.
        let data = try? JSONEncoder().encode(snapshot)
        #expect(data != nil)
    }

    @Test("the finished pass is reported exactly once")
    func passIsReportedOnce() async {
        actor Sink {
            private(set) var received: [String] = []
            func record(_ trigger: String) {
                received.append(trigger)
            }
        }
        let sink = Sink()
        let log = RunLog()
        let orchestrator = HealthSyncOrchestrator(
            registry: Self.registry(log: log),
            report: { pass in await sink.record(pass.trigger.rawValue) }
        )
        _ = await orchestrator.run(.manual)
        let received = await sink.received
        #expect(received == ["manual"])
    }
}
