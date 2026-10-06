import Foundation

// MARK: - #114 / #115 · 0.2 — AI capability reads for SwiftUI surfaces

extension AppContainer {
    /// Hands the capability gate to the stores whose server reads carry
    /// model-written text, so they stop asking for (and stop showing cached)
    /// text while its capability is unavailable. Weak captures: the closures
    /// never extend the gate's lifetime.
    static func wireAICapabilityGates(
        gate: AICapabilityGate,
        dailyBriefing: DailyBriefingStore,
        narrative: NarrativeStore
    ) {
        dailyBriefing.briefingAvailable = { [weak gate] in
            gate?.isAvailable(.briefing) ?? true
        }
        narrative.modelNarrativeAvailable = { [weak gate] in
            gate?.isAvailable(.periodNarrative) ?? true
        }
    }
}

public extension AppContainer {
    /// Whether any Coach launcher (header circle, prompt chips, "Ask the coach
    /// about this" links, cadence cards) is offered. Reading it inside a
    /// `body` observes ``AICapabilityGate``, so launchers appear / disappear
    /// when the next `/api/auth/me` load (or a refusal) changes the capability.
    /// A server older than v1.39 always answers `true` here; the 1.0.3 gates
    /// (assistant mode, provider, consent) still apply on top.
    var offersCoach: Bool {
        aiCapabilityGate.offersEntryPoint(.coach)
    }
}

public extension AppContainer? {
    /// ``AppContainer/offersCoach`` for views that hold an optional container
    /// (previews and test hosts have none — then nothing is gated here).
    @MainActor
    var offersCoach: Bool {
        self?.offersCoach ?? true
    }
}
