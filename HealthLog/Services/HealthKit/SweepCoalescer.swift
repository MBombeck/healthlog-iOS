import Foundation

/// **Audit v0.14.8 N5.3 — anchored-sweep interleave guard.**
///
/// The HK importers (`WorkoutHealthKitImporter`, `CycleHealthKitImporter`) run
/// `runAnchoredSweep()` from every observer fire. The sweep is actor-isolated,
/// but it suspends across `await fetch(...)` / `await drain(...)` — and actors
/// are reentrant at suspension points, so two rapid observer fires interleave
/// two sweeps **from the same persisted anchor**: duplicate uploads (benign —
/// server-deduped via externalId UPSERT) plus redundant network and battery.
///
/// This actor serializes the sweep body per key:
///   - while a body runs, further `run` calls return immediately;
///   - but they set a `queued` flag, so the in-flight call re-runs the body
///     once more after it finishes (exactly one trailing re-run, no matter how
///     many triggers landed mid-flight).
///
/// The trailing re-run matters: a plain `inFlight`-bool would DROP a mid-sweep
/// observer fire, and the sample that caused it would wait for the next HK
/// wakeup / app launch. With the re-run, the second pass starts from the
/// anchor the first pass just advanced, picks up only the new samples, and a
/// quiet pass is a cheap empty anchored query.
///
/// **Semantics note:** only the FIRST caller's closure is (re-)executed; a
/// coalesced caller's closure is never invoked. The importers always pass the
/// same operation for a given key, so this is the intended behaviour.
actor SweepCoalescer {
    private var inFlight: Set<String> = []
    private var queued: Set<String> = []

    /// Runs `body` if no run for `key` is in flight; otherwise coalesces this
    /// trigger into one trailing re-run of the in-flight caller's body.
    func run(key: String = "", _ body: @Sendable () async -> Void) async {
        guard !inFlight.contains(key) else {
            queued.insert(key)
            return
        }
        inFlight.insert(key)
        defer { inFlight.remove(key) }
        repeat {
            guard !Task.isCancelled else {
                queued.remove(key)
                return
            }
            queued.remove(key)
            await body()
        } while queued.contains(key) && !Task.isCancelled
    }
}

/// Shares direct-workout pass results per authenticated partition while keeping
/// the globally-scoped HealthKit workout-delivery lifecycle serialized.
actor WorkoutSyncPassCoordinator {
    private struct Slot: Sendable {
        let id: UUID
        let task: Task<Bool, Never>
    }

    private var slots: [String: [WorkoutSyncPassMode: Slot]] = [:]
    private var laneTail: Task<Void, Never>?

    func run(
        partition: String,
        mode: WorkoutSyncPassMode,
        isCurrent: @escaping @Sendable () async -> Bool = { true },
        operation: @escaping @Sendable (WorkoutSyncPassMode) async -> Bool
    ) async -> Bool {
        if let slot = compatibleSlot(partition: partition, mode: mode) {
            let result = await slot.task.value
            return !Task.isCancelled && result
        }

        let id = UUID()
        let predecessor = laneTail
        let task = Task { [weak self] in
            await predecessor?.value
            guard !Task.isCancelled, await isCurrent() else {
                await self?.complete(partition: partition, mode: mode, id: id)
                return false
            }
            let result = await operation(mode)
            await self?.complete(partition: partition, mode: mode, id: id)
            return !Task.isCancelled && result
        }
        var partitionSlots = slots[partition, default: [:]]
        partitionSlots[mode] = Slot(id: id, task: task)
        slots[partition] = partitionSlots
        laneTail = Task { _ = await task.value }

        return await withTaskCancellationHandler {
            let result = await task.value
            return !Task.isCancelled && result
        } onCancel: {
            Task { await self.cancel(partition: partition, mode: mode, id: id) }
        }
    }

    private func compatibleSlot(partition: String, mode: WorkoutSyncPassMode) -> Slot? {
        let partitionSlots = slots[partition]
        switch mode {
        case .incrementalOnly:
            return partitionSlots?[.incrementalOnly] ?? partitionSlots?[.processing]
        case .processing:
            return partitionSlots?[.processing]
        }
    }

    private func complete(partition: String, mode: WorkoutSyncPassMode, id: UUID) {
        guard var partitionSlots = slots[partition], partitionSlots[mode]?.id == id else { return }
        partitionSlots[mode] = nil
        slots[partition] = partitionSlots.isEmpty ? nil : partitionSlots
    }

    private func cancel(partition: String, mode: WorkoutSyncPassMode, id: UUID) {
        guard let slot = slots[partition]?[mode], slot.id == id else { return }
        slot.task.cancel()
    }

    func cancelAll() {
        for partitionSlots in slots.values {
            partitionSlots.values.forEach { $0.task.cancel() }
        }
        slots.removeAll()
        laneTail?.cancel()
        laneTail = nil
    }
}
