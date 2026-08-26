import Foundation

// MARK: - F-1 assistant-disabled mirror wiring

extension AppContainer {
    /// Wires `APIClient` → `FeatureFlagsStore` so a `403 +
    /// errorCode: "assistant.disabled.<surface>"` (server brief
    /// v1.4.31 §c.1) flips the matching flag in the store on the
    /// same tick the route 403's. Without this hop, the store would
    /// only update on the next `/api/feature-flags` foreground
    /// refresh — the placeholder would race the user's tap.
    ///
    /// The store mirror is a **convenience**: the typed
    /// `HLError.assistantDisabled(_:)` returned by APIClient stays
    /// the authoritative signal for surface guards. The mirror just
    /// short-circuits the latency window between "route 403's" and
    /// "store knows".
    ///
    /// Detached because APIClient is an actor and the store is
    /// @MainActor — the wiring is fire-and-forget at init time;
    /// idempotent on the APIClient side
    /// (`setAssistantDisabledHandler` overwrites).
    static func wireAssistantDisabledMirror(
        apiClient: APIClient,
        store: FeatureFlagsStore
    ) {
        Task.detached {
            await apiClient.setAssistantDisabledHandler { @Sendable flag in
                await MainActor.run {
                    store.applyDisabled(flag)
                }
            }
        }
    }

    /// #30 — wires `APIClient` → `ModuleGate` so a `403 + meta.errorCode:
    /// "module.disabled"` flips the matching module OFF in the gate on the same
    /// tick the route 403's. Without this hop the gate would only update on the
    /// next `/api/auth/me` refresh — the surface would race the user's tap.
    ///
    /// The gate mirror is a **convenience**: the typed
    /// `HLError.moduleDisabled(_:)` returned by APIClient stays the
    /// authoritative signal. Detached + fire-and-forget at init time;
    /// idempotent on the APIClient side (`setModuleDisabledHandler` overwrites).
    static func wireModuleDisabledMirror(
        apiClient: APIClient,
        gate: ModuleGate
    ) {
        Task.detached {
            await apiClient.setModuleDisabledHandler { @Sendable module in
                await MainActor.run {
                    gate.applyDisabled(wireKey: module)
                }
            }
        }
    }

    /// Constructs the on-device assistant service singletons with a
    /// `LiveFeatureFlagsService` bridge so the actors honour
    /// server-deployed operator-flag state on every
    /// `generate(...)` / `observe(...)` call (F-1 / R5).
    ///
    /// Returned as a value-type bundle (vs three separate factories)
    /// because all services share the same live-flag adaptor —
    /// keeping the allocation in one place makes the wiring intent
    /// explicit. D-1 added `smartReminder` as the third entry; it is
    /// gated by `.assistantBriefing` (same operator-flag as the daily
    /// briefing — per R5 the AI surfaces collapse to a single
    /// operator-control knob until we have a reason to split them).
    static func makeAssistantServices(store: FeatureFlagsStore) -> AssistantServiceBundle {
        let liveFlags = store.liveService()
        return AssistantServiceBundle(
            briefing: OnDeviceBriefingService(featureFlags: liveFlags),
            trend: TrendObservationsService(featureFlags: liveFlags),
            smartReminder: SmartReminderPhraseService(featureFlags: liveFlags)
        )
    }

    /// Value-type bundle for the three on-device assistant services. Lives
    /// at file-scope (vs nested in `AppContainer`) so the factory return
    /// type stays nameable from the call site without `AppContainer.…`
    /// prefix churn.
    struct AssistantServiceBundle {
        let briefing: OnDeviceBriefingService
        let trend: TrendObservationsService
        let smartReminder: SmartReminderPhraseService
    }
}
