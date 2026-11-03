import Foundation

// V1 (1.2) — the wire word a pass stands for. Moved here from
// `HealthSyncContracts.swift` unchanged in 1.4 (A2), so that file stays under
// its length gate as the page outcome grows.

extension SyncTrigger {
    /// **V1** — the wire word a `HealthSyncTrigger` stands for, or `nil` when the
    /// pass does not know whether the app is in front (cold activation, a fresh
    /// authorization, account teardown) and the context's own fallback decides.
    init?(pass trigger: HealthSyncTrigger) {
        switch trigger {
        case .manual: self = .manual
        case .foreground: self = .foreground
        case .processing, .appRefresh, .observer: self = .background
        case .silentPush: self = .push
        case .coldActivation, .postAuthentication, .accountTeardown: return nil
        }
    }
}

extension SyncTriggerContext {
    /// **V1** — runs one pass with the wire trigger it stands for bound to its
    /// task tree (``SyncTrigger/init(pass:)``); a pass without one runs
    /// unbound and the context's fallback decides.
    func runningPass<T>(
        _ trigger: HealthSyncTrigger,
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async -> T
    ) async -> T {
        guard let wire = SyncTrigger(pass: trigger) else { return await body() }
        return await bind(wire, body)
    }
}
