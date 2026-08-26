import Foundation

// Phase 07 Wave 4 — the capability registry, and the reason it is a compiler
// problem rather than a review problem.
//
// The registry is total by construction in three independent ways, and all
// three are deliberate:
//
//   1. `init` takes one labelled adapter per capability. A new
//      `HealthSyncCapability` case makes every construction site fail to
//      compile with a missing-argument error naming the capability.
//   2. The `switch` that binds those arguments and the `switch` in `lane(for:)`
//      are exhaustive with no `default`, so a new case is a compile error here
//      too — including for a case someone adds without touching a call site.
//   3. `adapter(for:)` returns a non-optional adapter, because the map is built
//      from `allCases` rather than accumulated. There is no path that can ask
//      for a capability and be told nothing.
//
// The sample half is pinned the same way: `sampleTypeIdentifiers` IS
// `HealthLogSampleTypeRegistry.knownIdentifiers`, not a copy of it, and
// `coversExactlyTheKnownSampleTypes` compares the two sets rather than their
// counts. No reflection, no `default:`, no "if we forgot one it just does not
// run".

/// One capability's executable adapter.
struct HealthSyncCapabilityAdapter: Sendable {
    /// Whether this capability may run beside another.
    ///
    /// `sharedUpload` names every path that posts through the one
    /// `MeasurementBatchUploader` (and therefore shares its 60/min sliding
    /// window) or mutates the outbox as its main job. Those serialize against
    /// each other; everything else is independent and may pair up.
    enum Lane: String, Sendable, Equatable {
        case independent
        case sharedUpload
    }

    let capability: HealthSyncCapability
    let lane: Lane
    let run: @Sendable (HealthSyncRunContext) async -> HealthSyncCapabilityResult
}

/// The exact set of work "sync everything" means.
struct HealthSyncCapabilityRegistry: Sendable {
    typealias Run = @Sendable (HealthSyncRunContext) async -> HealthSyncCapabilityResult

    private let adapters: [HealthSyncCapability: HealthSyncCapabilityAdapter]

    init(
        speziSampleCollection: @escaping Run,
        workoutImport: @escaping Run,
        ecgUpload: @escaping Run,
        dailyStatistics: @escaping Run,
        heartRateBuckets: @escaping Run,
        nutrientDailyTotals: @escaping Run,
        moodStateOfMindImport: @escaping Run,
        appleMedicationImport: @escaping Run,
        cycleImport: @escaping Run,
        heartHealthEvents: @escaping Run,
        outboxDrain: @escaping Run
    ) {
        var built: [HealthSyncCapability: HealthSyncCapabilityAdapter] = [:]
        for capability in HealthSyncCapability.allCases {
            let run: Run =
                switch capability {
                case .speziSampleCollection: speziSampleCollection
                case .workoutImport: workoutImport
                case .ecgUpload: ecgUpload
                case .dailyStatistics: dailyStatistics
                case .heartRateBuckets: heartRateBuckets
                case .nutrientDailyTotals: nutrientDailyTotals
                case .moodStateOfMindImport: moodStateOfMindImport
                case .appleMedicationImport: appleMedicationImport
                case .cycleImport: cycleImport
                case .heartHealthEvents: heartHealthEvents
                case .outboxDrain: outboxDrain
                }
            built[capability] = HealthSyncCapabilityAdapter(
                capability: capability,
                lane: Self.lane(for: capability),
                run: run
            )
        }
        adapters = built
    }

    /// Every capability answers, and every capability answers `.unsupported`.
    /// Used by contexts that compose the orchestrator without any HealthKit
    /// (the widget/watch surfaces and the plan-shape unit tests): an empty
    /// registry would be indistinguishable from a forgotten one.
    static func unsupportedEverywhere() -> Self {
        Self(
            speziSampleCollection: { _ in .unsupported(.speziSampleCollection) },
            workoutImport: { _ in .unsupported(.workoutImport) },
            ecgUpload: { _ in .unsupported(.ecgUpload) },
            dailyStatistics: { _ in .unsupported(.dailyStatistics) },
            heartRateBuckets: { _ in .unsupported(.heartRateBuckets) },
            nutrientDailyTotals: { _ in .unsupported(.nutrientDailyTotals) },
            moodStateOfMindImport: { _ in .unsupported(.moodStateOfMindImport) },
            appleMedicationImport: { _ in .unsupported(.appleMedicationImport) },
            cycleImport: { _ in .unsupported(.cycleImport) },
            heartHealthEvents: { _ in .unsupported(.heartHealthEvents) },
            outboxDrain: { _ in .unsupported(.outboxDrain) }
        )
    }

    /// Non-optional: the map is built from `allCases`, so there is no capability
    /// this registry can be asked about and fail to name.
    func adapter(for capability: HealthSyncCapability) -> HealthSyncCapabilityAdapter {
        guard let adapter = adapters[capability] else {
            // Unreachable by construction; a named refusal rather than a trap so
            // a hypothetical gap can never crash a background wake.
            return HealthSyncCapabilityAdapter(
                capability: capability,
                lane: Self.lane(for: capability),
                run: { _ in .refused(capability, .unknown) }
            )
        }
        return adapter
    }

    var capabilities: Set<HealthSyncCapability> {
        Set(adapters.keys)
    }

    /// The sample identifiers this registry's collection capability covers.
    /// Identity, not a copy — the exact-35 claim cannot drift from the registry.
    var sampleTypeIdentifiers: Set<String> {
        HealthLogSampleTypeRegistry.knownIdentifiers
    }

    /// Set equality against the shipped sample registry, plus the count the
    /// product documentation states.
    var coversExactlyTheKnownSampleTypes: Bool {
        sampleTypeIdentifiers == HealthLogSampleTypeRegistry.knownIdentifiers
            && sampleTypeIdentifiers.count == 35
    }

    /// Every capability the registry knows, including the ten non-sample
    /// importers, each present exactly once.
    var namesEveryCapability: Bool {
        capabilities == Set(HealthSyncCapability.allCases)
    }

    /// What `trigger` plans to reach.
    ///
    /// An observer pass resolves to the single capability whose source was
    /// signalled — never a fan-out, which is the whole point of an observer.
    func plannedCapabilities(
        for trigger: HealthSyncTrigger,
        observedSource: HealthSyncSource?
    ) -> Set<HealthSyncCapability> {
        guard trigger == .observer else {
            return HealthSyncCompositionPlan.required(for: trigger).intersection(capabilities)
        }
        guard let observedSource,
              let capability = HealthSyncCapability.allCases.first(where: { $0.source == observedSource }) else
        {
            return []
        }
        return [capability]
    }

    /// Deterministic execution order. `outboxDrain` is deliberately last: a page
    /// that was held during this pass becomes an outbox row, and draining after
    /// the importers gives that row its first replay in the same wake.
    func orderedPlan(_ planned: Set<HealthSyncCapability>) -> [HealthSyncCapability] {
        HealthSyncCapability.allCases.filter { planned.contains($0) && $0 != .outboxDrain }
            + (planned.contains(.outboxDrain) ? [.outboxDrain] : [])
    }

    /// Exhaustive by design — a new capability must state whether it shares the
    /// batch uploader before it can compile.
    private static func lane(for capability: HealthSyncCapability) -> HealthSyncCapabilityAdapter.Lane {
        switch capability {
        case .speziSampleCollection,
             .workoutImport,
             .dailyStatistics,
             .heartRateBuckets,
             .nutrientDailyTotals,
             .heartHealthEvents,
             .outboxDrain:
            .sharedUpload
        case .ecgUpload, .moodStateOfMindImport, .appleMedicationImport, .cycleImport:
            .independent
        }
    }
}
