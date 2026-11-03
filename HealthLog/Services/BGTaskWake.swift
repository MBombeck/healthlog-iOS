import Foundation

/// **R-A1 (1.4) — one background wake's completion contract, armed first.**
///
/// iOS calls a `BGTask`'s expiration handler when the grant runs out, and it
/// expects the task to be completed from there. The two BGTask cores in
/// ``BackgroundSyncCoordinator`` used to install that handler only after the
/// wake had recorded its heartbeat (a hop to the main actor), submitted the
/// next request and started its work. An expiry inside that window found no
/// handler, so the task was never completed and iOS counted it against the app.
///
/// Creating a wake installs the handler and does nothing else, so the core can
/// make it its first statement. The handler sets the flag the pass reads,
/// cancels the work, and completes the task with `success: false`. Work that
/// has not started when the grant ends is never started.
final class BGTaskWake: @unchecked Sendable {
    /// The flag the pass polls to stop admitting capabilities.
    let expiration = ExpirationFlag()

    private let task: any BGTaskCompleting
    private let completion = OneShotCompletion()
    private let lock = NSLock()
    private var work: Task<Void, Never>?

    /// Installs the expiration handler on `task` before returning.
    ///
    /// - Parameter onExpire: a side note for the log; it runs inside the
    ///   handler, before the completion.
    init(task: some BGTaskCompleting, onExpire: @escaping @Sendable () -> Void) {
        self.task = task
        task.setExpirationHandler { [self] in
            expiration.set()
            lock.withLock { work }?.cancel()
            onExpire()
            completion.complete(task: self.task, success: false)
        }
    }

    /// Runs `body` as this wake's cancellable work and waits for it. A wake
    /// whose grant has already ended starts nothing.
    func run(_ body: @escaping @Sendable (ExpirationFlag) async -> Void) async {
        let expiration = expiration
        guard !expiration.value else { return }
        let started = Task { await body(expiration) }
        lock.withLock { work = started }
        // An expiry between the check above and the store found no work to
        // cancel; the flag it set is still here.
        if expiration.value { started.cancel() }
        await started.value
    }

    /// Completes the task once: with `success` unless the grant expired. A
    /// no-op after the expiration handler has completed it.
    func finish(success: Bool = true) {
        completion.complete(task: task, success: success && !expiration.value)
    }
}

/// Atomisches Flag für den Expiration-Handler. NSLock-basiert weil `BGTask.expirationHandler`
/// auf einer beliebigen Thread läuft — wir wollen kein Actor-Hopping in einem Code-Pfad,
/// der vom System "harten" Cutoff hat.
final class ExpirationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var didExpire = false

    func set() {
        lock.withLock { didExpire = true }
    }

    var value: Bool {
        lock.withLock { didExpire }
    }
}
