import Foundation

// MARK: - AI refusal + module mirror wiring

extension AppContainer {
    /// #114 / #115 · 0.2 — wires `APIClient` → ``AICapabilityGate`` so an AI
    /// refusal (``HLError/aiUnavailable(_:)``) flips the named capabilities off
    /// on the same tick the route refuses, and hands the gate to ``ModuleGate``
    /// so every `/api/auth/me` load (which ModuleGate already performs) also
    /// applies the `ai` block. No extra request.
    ///
    /// Detached because APIClient is an actor and the gate is `@MainActor`;
    /// idempotent on the APIClient side (`setAIRefusalHandler` overwrites).
    static func wireAIRefusalMirror(
        apiClient: APIClient,
        gate: AICapabilityGate,
        moduleGate: ModuleGate
    ) {
        moduleGate.aiCapabilityGate = gate
        Task.detached {
            await apiClient.setAIRefusalHandler { @Sendable [weak gate] refusal in
                await MainActor.run {
                    gate?.applyRefusal(refusal)
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

    /// Constructs the on-device assistant service singletons, each reading the
    /// live ``AICapabilityGate`` shadow on every call, so a capability the
    /// server switches off mid-session stops the next inference (#115 · 0.2:
    /// `onDeviceAllowed`). Daily briefing and the smart reminder phrase follow
    /// `briefing`; per-metric trend observations follow `statusText`.
    static func makeAssistantServices(aiCapabilities: any AICapabilityReading) -> AssistantServiceBundle {
        AssistantServiceBundle(
            briefing: OnDeviceBriefingService(aiCapabilities: aiCapabilities),
            trend: TrendObservationsService(aiCapabilities: aiCapabilities),
            smartReminder: SmartReminderPhraseService(aiCapabilities: aiCapabilities)
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
