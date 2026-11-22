import Foundation

/// **Anchored-sweep interleave guard.**
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
///
/// **W1 (1.3.0, HealthLog#1173) — logging and a watchdog.** `inFlight` was
/// cleared only by the running call's `defer`. A body whose await never
/// returned (a HealthKit query callback that never fires is the suspect) kept
/// its key in flight for the rest of the process, and every later trigger was
/// folded into a run that would never finish, without a trace. Every run now
/// logs its start and end (`notice`, category `healthkit`, so it persists), a
/// trigger folded into a run older than a minute says how old, and a trigger
/// that finds a body running longer than `staleAfter` starts a new run. The
/// stale run is fenced by its id: it neither clears the new run's slot nor
/// starts another trailing re-run.
actor SweepCoalescer {
    private struct Run {
        let id: UInt64
        var bodyStartedAt: Date
    }

    private var inFlight: [String: Run] = [:]
    private var queued: Set<String> = []
    private var nextRunID: UInt64 = 0

    /// Names this coalescer in the log (`orchestrator`, `cycle`, …).
    let label: String
    /// How long one body may run before a trigger replaces it.
    let staleAfter: TimeInterval
    private let now: @Sendable () -> Date

    /// Twenty minutes: above the longest bounded pass (a BGProcessing wake or a
    /// manual full sync), far below "until the app is restarted".
    static let defaultStaleAfter: TimeInterval = 20 * 60

    init(
        label: String = "sweep",
        staleAfter: TimeInterval = SweepCoalescer.defaultStaleAfter,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.label = label
        self.staleAfter = staleAfter
        self.now = now
    }

    /// Runs `body` if no run for `key` is in flight; otherwise coalesces this
    /// trigger into one trailing re-run of the in-flight caller's body.
    func run(key: String = "", _ body: @Sendable () async -> Void) async {
        guard admits(key) else { return }
        nextRunID &+= 1
        let id = nextRunID
        inFlight[key] = Run(id: id, bodyStartedAt: now())
        // Label, key and id are fixed vocabulary; no identifier, no value.
        // swiftlint:disable:next hllog_public_privacy_interpolation
        HLLog.healthKit.notice("\(label, privacy: .public)[\(key, privacy: .public)] run \(id, privacy: .public) begins")
        let started = now()
        defer { finish(key, id: id, started: started) }
        repeat {
            guard !Task.isCancelled, inFlight[key]?.id == id else {
                if inFlight[key]?.id == id { queued.remove(key) }
                return
            }
            queued.remove(key)
            inFlight[key]?.bodyStartedAt = now()
            await body()
        } while queued.contains(key) && !Task.isCancelled && inFlight[key]?.id == id
    }

    /// `true` when this trigger runs the body itself: nothing is in flight, or
    /// what is in flight is older than `staleAfter`.
    private func admits(_ key: String) -> Bool {
        guard let running = inFlight[key] else { return true }
        let age = now().timeIntervalSince(running.bodyStartedAt)
        guard age >= staleAfter else {
            queued.insert(key)
            if age >= 60 {
                // swiftlint:disable:next hllog_public_privacy_interpolation
                HLLog.healthKit.notice(
                    "\(label, privacy: .public)[\(key, privacy: .public)] trigger folded into run \(running.id, privacy: .public), in flight \(Int(age), privacy: .public)s"
                )
            }
            return false
        }
        // swiftlint:disable:next hllog_public_privacy_interpolation
        HLLog.healthKit.error(
            "\(label, privacy: .public)[\(key, privacy: .public)] run \(running.id, privacy: .public) stuck \(Int(age), privacy: .public)s: watchdog starts a new run"
        )
        return true
    }

    private func finish(_ key: String, id: UInt64, started: Date) {
        let seconds = Int(now().timeIntervalSince(started))
        if inFlight[key]?.id == id {
            inFlight[key] = nil
            // swiftlint:disable:next hllog_public_privacy_interpolation
            HLLog.healthKit.notice(
                "\(label, privacy: .public)[\(key, privacy: .public)] run \(id, privacy: .public) ended after \(seconds, privacy: .public)s"
            )
        } else {
            // swiftlint:disable:next hllog_public_privacy_interpolation
            HLLog.healthKit.notice(
                "\(label, privacy: .public)[\(key, privacy: .public)] run \(id, privacy: .public) returned after \(seconds, privacy: .public)s, superseded"
            )
        }
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
