import Foundation

// Phase 07 Wave 4 — the bounded execution plan for one trigger.
//
// Three rules, and every one of them exists because its absence produced a real
// defect in this codebase:
//
//   * **Nothing is omitted.** Every planned capability gets a result, including
//     the ones a cancelled or expiring pass never reached. The pre-Phase-07
//     shape returned early and the capabilities after the return point simply
//     were not mentioned, which is how a "complete" background pass could
//     never once have touched the cycle import.
//   * **Concurrency is at most two, and only between independent capabilities.**
//     Everything that posts through the single `MeasurementBatchUploader` (or
//     whose job is draining the outbox) runs in one serialized lane, because
//     that uploader owns a 60/min sliding window and a shared throttle: running
//     four of them at once does not make the wake faster, it makes the window
//     the bottleneck and the results non-deterministic.
//   * **Expiration is checked before admission, not after work.** A BGTask that
//     is about to be terminated must not start a capability it cannot finish,
//     because an interrupted sweep that already advanced a cursor is precisely
//     the data-loss shape Waves 1-3 closed.

extension HealthSyncOrchestrator {
    /// Runs the plan for `trigger` and returns exactly one named result per
    /// planned capability.
    ///
    /// The caller's task cancellation and the injected expiry both stop
    /// *admission* of further capabilities; neither truncates the answer.
    func executePass(
        _ trigger: HealthSyncTrigger,
        observedSource: HealthSyncSource?,
        isExpired: @escaping @Sendable () -> Bool = { false }
    ) async -> HealthSyncPassResult {
        let startedAt = Date()
        let startedNanoseconds = DispatchTime.now().uptimeNanoseconds
        let planned = registry.plannedCapabilities(for: trigger, observedSource: observedSource)
        let ordered = registry.orderedPlan(planned)

        guard !ordered.isEmpty else {
            return HealthSyncPassResult.empty(trigger, startedAt: startedAt)
        }

        let context = HealthSyncRunContext(
            trigger: trigger,
            budget: HealthSyncBudget.required(for: trigger),
            observedSource: observedSource,
            isExpired: isExpired
        )

        var results: [HealthSyncCapabilityResult] = []
        results.reserveCapacity(ordered.count)

        // Independent capabilities pair up two at a time; shared-lane ones run
        // one after another. Both walks stop *admitting* work the moment the
        // window closes, and both name what they did not admit.
        let independent = ordered.filter { registry.adapter(for: $0).lane == .independent }
        let shared = ordered.filter { registry.adapter(for: $0).lane == .sharedUpload }

        results += await runPaired(independent, context: context)
        results += await runSerially(shared, context: context)

        // Restore the plan's order so a reader sees the registry's order rather
        // than the lane split, and so `outboxDrain` is last.
        let byCapability = Dictionary(uniqueKeysWithValues: results.map { ($0.capability, $0) })
        let orderedResults = ordered.compactMap { byCapability[$0] }

        let elapsed = Int((DispatchTime.now().uptimeNanoseconds - startedNanoseconds) / 1_000_000)
        let cancelled = orderedResults.contains { $0.failure == .cancelled }
        let expired = orderedResults.contains { $0.failure == .expired }
        return HealthSyncPassResult(
            trigger: trigger,
            planned: planned,
            results: orderedResults,
            startedAt: startedAt,
            durationMilliseconds: elapsed,
            wasCancelled: cancelled,
            wasExpired: expired
        )
    }

    /// At most two independent capabilities in flight. Deliberately a rolling
    /// pair rather than an unbounded group: a background wake that starts nine
    /// HealthKit queries at once is a battery and memory event, and the OS
    /// terminates it before any of them commit.
    private func runPaired(
        _ capabilities: [HealthSyncCapability],
        context: HealthSyncRunContext
    ) async -> [HealthSyncCapabilityResult] {
        var results: [HealthSyncCapabilityResult] = []
        var index = 0
        while index < capabilities.count {
            if let stop = Self.stopResult(for: context) {
                results += capabilities[index...].map(stop)
                return results
            }
            let pair = capabilities[index ..< min(index + 2, capabilities.count)]
            let adapters = pair.map { registry.adapter(for: $0) }
            results += await withTaskGroup(of: HealthSyncCapabilityResult.self) { group in
                for adapter in adapters {
                    group.addTask { await Self.invoke(adapter, context: context) }
                }
                var collected: [HealthSyncCapabilityResult] = []
                for await result in group {
                    collected.append(result)
                }
                return collected
            }
            index += 2
        }
        return results
    }

    /// One at a time, in plan order. The uploader's throttle and the outbox are
    /// shared mutable state; serializing here is what makes "at most two" safe.
    private func runSerially(
        _ capabilities: [HealthSyncCapability],
        context: HealthSyncRunContext
    ) async -> [HealthSyncCapabilityResult] {
        var results: [HealthSyncCapabilityResult] = []
        for (offset, capability) in capabilities.enumerated() {
            if let stop = Self.stopResult(for: context) {
                results += capabilities[offset...].map(stop)
                return results
            }
            await results.append(Self.invoke(registry.adapter(for: capability), context: context))
        }
        return results
    }

    /// The named answer for every capability a closed window forbids admitting.
    ///
    /// Returns `nil` while the window is open. Cancellation and expiration are
    /// kept apart: an app suspension and an account teardown hold a cursor for
    /// different reasons, and a diagnostic that conflates them cannot tell them
    /// apart afterwards.
    private static func stopResult(
        for context: HealthSyncRunContext
    ) -> ((HealthSyncCapability) -> HealthSyncCapabilityResult)? {
        if Task.isCancelled { return HealthSyncCapabilityResult.cancelled }
        if context.isExpired() { return HealthSyncCapabilityResult.expired }
        return nil
    }

    /// Runs one adapter and times it. An adapter that returns a result for a
    /// different capability than the one asked for is corrected here, so a
    /// mis-wired composition cannot make a capability disappear from the plan.
    private static func invoke(
        _ adapter: HealthSyncCapabilityAdapter,
        context: HealthSyncRunContext
    ) async -> HealthSyncCapabilityResult {
        let started = DispatchTime.now().uptimeNanoseconds
        let result = await adapter.run(context)
        let elapsed = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        guard result.capability == adapter.capability else {
            return HealthSyncCapabilityResult(
                capability: adapter.capability,
                disposition: .failed,
                durationMilliseconds: elapsed,
                failure: .unknown
            )
        }
        guard result.durationMilliseconds == 0 else { return result }
        return HealthSyncCapabilityResult(
            capability: result.capability,
            disposition: result.disposition,
            itemsSubmitted: result.itemsSubmitted,
            itemsSettled: result.itemsSettled,
            itemsHeld: result.itemsHeld,
            durationMilliseconds: elapsed,
            failure: result.failure,
            holdReason: result.holdReason
        )
    }
}
