import Foundation
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// #114 / #115 · 0.2 — capability states in the exact shape server v1.39
/// resolves them (`src/lib/ai/capabilities/types.ts`: `reason` is null exactly
/// when `available`; `onDeviceAllowed` is true only for `no_provider` and
/// `consent_required`).
enum AICaps {
    static let available = AICapabilityState(available: true, reason: nil, onDeviceAllowed: true)
    static let operatorDisabled = AICapabilityState(available: false, reason: .operatorDisabled, onDeviceAllowed: false)
    static let notPermitted = AICapabilityState(available: false, reason: .notPermittedForRecord, onDeviceAllowed: false)
    static let moduleDisabled = AICapabilityState(available: false, reason: .moduleDisabled, onDeviceAllowed: false)
    static let userDisabled = AICapabilityState(available: false, reason: .userDisabled, onDeviceAllowed: false)
    static let noProvider = AICapabilityState(available: false, reason: .noProvider, onDeviceAllowed: true)
    static let consentRequired = AICapabilityState(available: false, reason: .consentRequired, onDeviceAllowed: true)
    static let checkFailed = AICapabilityState(available: false, reason: .checkFailed, onDeviceAllowed: false)

    /// Every capability available, with `overrides` applied.
    static func block(_ overrides: [AICapabilityKey: AICapabilityState] = [:]) -> AIAccountBlock {
        var map: [AICapabilityKey: AICapabilityState] = [:]
        for key in AICapabilityKey.allCases {
            map[key] = overrides[key] ?? available
        }
        return AIAccountBlock(
            capabilities: map,
            provider: AIProviderState(configured: true, managedBy: .server, canConfigure: true)
        )
    }

    /// A fixed reader: every capability available, with `overrides` applied.
    static func reader(_ overrides: [AICapabilityKey: AICapabilityState] = [:]) -> FixedAICapabilities {
        FixedAICapabilities(block(overrides))
    }
}

/// Minimal capability stub for the on-device services: every capability is
/// either fully open (`enabled`) or closed by the operator.
struct StubFlags: AICapabilityReading {
    let enabled: Bool
    func state(_: AICapabilityKey) -> AICapabilityState {
        enabled ? AICaps.available : AICaps.operatorDisabled
    }
}
