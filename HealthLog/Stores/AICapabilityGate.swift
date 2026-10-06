import Foundation
import Observation

/// **#114 / #115 · 0.2 — the single source of truth for AI availability.**
///
/// Holds the `ai` block from `GET /api/auth/me` (server v1.39). Every AI surface
/// asks THIS gate, by capability:
///
/// - ``isAvailable(_:)`` — the server path may run and model-written text may be
///   shown (`capabilities[key].available`).
/// - ``allowsOnDevice(_:)`` — an on-device model (Foundation Models) or the
///   person's own-key arm may run (`onDeviceAllowed`).
/// - ``offersEntryPoint(_:)`` — a launcher (the Coach button, a prompt chip) is
///   shown: the server can serve it, or the device can. A missing provider or a
///   missing consent keeps the launcher, because the app has its own flow for
///   both; a decision (operator, record, module, the person's own opt-out) hides it.
///
/// **Server older than v1.39 (no `ai` block):** every capability reads
/// ``AICapabilityState/legacy`` — nothing is gated here, and the 1.0.3
/// signals (`GET /api/user/ai-provider` `aiAvailable`, consent) keep deciding.
/// With the block present it is the only operator signal.
///
/// **Refusal mirror.** A route that refuses an AI action (``HLError/aiUnavailable(_:)``)
/// flips the named capabilities off here on the same tick; the next
/// `/api/auth/me` load replaces the overrides with the server's answer.
///
/// Loaded by ``ModuleGate/load()`` from the same `/api/auth/me` response it
/// already reads, so there is no extra request.
@MainActor
@Observable
public final class AICapabilityGate {
    /// The last `ai` block the server sent. `nil` before the first load and on
    /// a server older than v1.39.
    public private(set) var account: AIAccountBlock?

    /// Capability states implied by refusals since the last load.
    public private(set) var refusalOverrides: [AICapabilityKey: AICapabilityState] = [:]

    /// `Sendable` shadow for the on-device service actors.
    public nonisolated let reader: AICapabilityCell

    public init(account: AIAccountBlock? = nil) {
        self.account = account
        reader = AICapabilityCell()
        publish()
    }

    /// True once the server has sent an `ai` block (v1.39+).
    public var reportsCapabilities: Bool {
        account != nil
    }

    /// The resolved state of one capability.
    public func state(_ key: AICapabilityKey) -> AICapabilityState {
        if let override = refusalOverrides[key] { return override }
        guard let account else { return .legacy }
        return account.state(key)
    }

    public func isAvailable(_ key: AICapabilityKey) -> Bool {
        state(key).isAvailable
    }

    public func allowsOnDevice(_ key: AICapabilityKey) -> Bool {
        state(key).allowsOnDevice
    }

    public func offersEntryPoint(_ key: AICapabilityKey) -> Bool {
        state(key).offersEntryPoint
    }

    /// The reason a capability is unavailable, `nil` when it is available or no
    /// block is known.
    public func reason(_ key: AICapabilityKey) -> AIUnavailableReason? {
        let resolved = state(key)
        return resolved.isAvailable ? nil : resolved.reason
    }

    /// Apply a `/api/auth/me` load. `nil` = the server sent no `ai` block
    /// (older server) — back to the legacy behaviour. Clears refusal overrides:
    /// the fresh server answer supersedes them.
    public func apply(_ block: AIAccountBlock?) {
        account = block
        refusalOverrides = [:]
        publish()
    }

    /// Mirror a refusal (see type doc).
    public func applyRefusal(_ refusal: AIRefusal) {
        let implied = refusal.impliedState
        let keys = refusal.affectedCapabilities
        guard !keys.isEmpty else { return }
        for key in keys {
            refusalOverrides[key] = implied
        }
        publish()
    }

    /// Reset on logout — the next account loads its own block.
    public func clearOnLogout() {
        account = nil
        refusalOverrides = [:]
        publish()
    }

    /// Recomputes the shadow cell. With neither a block nor an override the
    /// cell reads legacy for every key.
    private func publish() {
        guard account != nil || !refusalOverrides.isEmpty else {
            reader.store(nil)
            return
        }
        var resolved: [AICapabilityKey: AICapabilityState] = [:]
        for key in AICapabilityKey.allCases {
            resolved[key] = state(key)
        }
        reader.store(resolved, reportsCapabilities: account != nil)
    }
}
