import Foundation

/// #114 / #115 · 0.2 — an AI action the server refused because its capability
/// is unavailable.
///
/// Server v1.39 answers with `{ data: null, error, meta: { errorCode,
/// capability, reason, module? } }` (`src/lib/ai/capabilities/refusal.ts`).
/// The code carries the family, `meta.capability` and `meta.reason` say which
/// capability and why. Codes this type covers:
///
/// - `assistant.disabled.<switch>` (403): the operator switched it off
///   (`enabled`, `coach`, `briefing`, `insightStatus`, `documentAi`; an unknown
///   switch name is kept verbatim).
/// - `ai.record.notPermitted` (403): AI work is not admitted for this record.
/// - `ai.provider.none` (422; `medications/extract` keeps 503): no provider can
///   serve it.
/// - `ai.unavailable` (503): an input could not be read, the answer failed closed.
///
/// `module.disabled` stays ``HLError/moduleDisabled(_:)`` (it already mirrors
/// into ``ModuleGate``) and `consent.ai.required` stays a plain
/// ``HLError/server(status:code:message:)`` with its code, because both have
/// long-standing handling at their call sites.
public struct AIRefusal: Sendable, Equatable, Hashable {
    /// The machine code, from `meta.errorCode` (or the pre-v1.39 top-level
    /// `errorCode`).
    public let errorCode: String
    /// `meta.capability`, when the server named one this build knows.
    public let capability: AICapabilityKey?
    /// `meta.reason`, tolerant.
    public let reason: AIUnavailableReason?
    /// `meta.module`, when present.
    public let module: String?
    /// The HTTP status the refusal came with (403, 422 or 503).
    public let httpStatus: Int

    public init(
        errorCode: String,
        capability: AICapabilityKey? = nil,
        reason: AIUnavailableReason? = nil,
        module: String? = nil,
        httpStatus: Int = 403
    ) {
        self.errorCode = errorCode
        self.capability = capability
        self.reason = reason
        self.module = module
        self.httpStatus = httpStatus
    }

    public static let operatorDisabledPrefix = "assistant.disabled."
    public static let recordNotPermittedCode = "ai.record.notPermitted"
    public static let providerNoneCode = "ai.provider.none"
    public static let unavailableCode = "ai.unavailable"
    public static let consentRequiredCode = "consent.ai.required"

    /// The refusal family, derived from the code alone (the code is the stable
    /// contract; `reason` only refines it).
    public enum Kind: Sendable, Equatable, Hashable {
        /// `assistant.disabled.<switch>`.
        case operatorDisabled(operatorSwitch: String)
        /// `ai.record.notPermitted`.
        case recordNotPermitted
        /// `ai.provider.none`.
        case noProvider
        /// `module.disabled` (only on a refusal the client built itself; the
        /// transport keeps that code as ``HLError/moduleDisabled(_:)``).
        case moduleDisabled
        /// `consent.ai.required` (idem).
        case consentRequired
        /// `ai.unavailable`, or a code this build does not know.
        case unavailable
    }

    public var kind: Kind {
        if errorCode.hasPrefix(Self.operatorDisabledPrefix) {
            return .operatorDisabled(operatorSwitch: String(errorCode.dropFirst(Self.operatorDisabledPrefix.count)))
        }
        switch errorCode {
        case Self.recordNotPermittedCode: return .recordNotPermitted
        case Self.providerNoneCode: return .noProvider
        case "module.disabled": return .moduleDisabled
        case Self.consentRequiredCode: return .consentRequired
        default: return .unavailable
        }
    }

    /// The capabilities this refusal says are unavailable: the named one, or —
    /// when an older envelope names only the operator switch — every capability
    /// that switch covers.
    public var affectedCapabilities: [AICapabilityKey] {
        if let capability { return [capability] }
        if case let .operatorDisabled(operatorSwitch) = kind {
            return AICapabilityKey.covered(byOperatorSwitch: operatorSwitch)
        }
        return []
    }

    /// The capability state this refusal implies, for mirroring into
    /// ``AICapabilityGate`` until the next `/api/auth/me` load. A missing
    /// provider still allows the device; every other refusal does not.
    public var impliedState: AICapabilityState {
        let resolvedReason: AIUnavailableReason = reason ?? {
            switch kind {
            case .operatorDisabled: .operatorDisabled
            case .recordNotPermitted: .notPermittedForRecord
            case .noProvider: .noProvider
            case .moduleDisabled: .moduleDisabled
            case .consentRequired: .consentRequired
            case .unavailable: .checkFailed
            }
        }()
        let onDevice = resolvedReason == .noProvider || resolvedReason == .consentRequired
        return AICapabilityState(available: false, reason: resolvedReason, onDeviceAllowed: onDevice)
    }

    /// Reads an AI refusal off an error envelope, or `nil` when the envelope is
    /// something else.
    ///
    /// - `assistant.disabled.*` is honoured on a `403` only (a different status
    ///   with that code is not the refusal shape).
    /// - The three `ai.*` codes are specific enough to be honoured on any status
    ///   (`ai.provider.none` is 422 on most routes, 503 on `medications/extract`).
    /// - `meta.errorCode` wins over the pre-v1.39 top-level `errorCode`.
    public static func from(status: Int, meta: APIEnvelopeMeta?, topLevelCode: String?) -> AIRefusal? {
        guard let code = meta?.errorCode ?? topLevelCode, !code.isEmpty else { return nil }
        let isOperator = code.hasPrefix(operatorDisabledPrefix) && code.count > operatorDisabledPrefix.count
        let isAICode = code == recordNotPermittedCode || code == providerNoneCode || code == unavailableCode
        guard (isOperator && status == 403) || isAICode else { return nil }
        let capability = meta?.capability.flatMap(AICapabilityKey.init(rawValue:))
        let reason = meta?.reason.flatMap { $0.isEmpty ? nil : AIUnavailableReason(wireValue: $0) }
        let module = meta?.module.flatMap { $0.isEmpty ? nil : $0 }
        return AIRefusal(errorCode: code, capability: capability, reason: reason, module: module, httpStatus: status)
    }

    /// The refusal the server would answer with for a capability in `state`,
    /// built on the client when a surface is refused BEFORE any request
    /// (server mapping, `refusal.ts`): `operator_disabled` →
    /// `assistant.disabled.<switch>`, `not_permitted_for_record` →
    /// `ai.record.notPermitted`, `module_disabled` / `user_disabled` →
    /// `module.disabled`, `no_provider` → `ai.provider.none`,
    /// `consent_required` → `consent.ai.required`, `check_failed` (and an
    /// unknown reason) → `ai.unavailable`.
    public static func implied(by state: AICapabilityState, for capability: AICapabilityKey) -> AIRefusal {
        let reason = state.reason ?? .unknown
        let code = switch reason {
        case .operatorDisabled: operatorDisabledPrefix + capability.operatorSwitch
        case .notPermittedForRecord: recordNotPermittedCode
        case .moduleDisabled, .userDisabled: "module.disabled"
        case .noProvider: providerNoneCode
        case .consentRequired: consentRequiredCode
        case .checkFailed, .unknown: unavailableCode
        }
        return AIRefusal(errorCode: code, capability: capability, reason: reason, httpStatus: 0)
    }

    /// The AI side of a `403 module.disabled` that names a capability
    /// (`meta.capability`), for the capability mirror. `nil` for a plain module
    /// refusal. The transport still throws ``HLError/moduleDisabled(_:)``.
    public static func moduleRefusal(meta: APIEnvelopeMeta) -> AIRefusal? {
        guard let capability = meta.capability.flatMap(AICapabilityKey.init(rawValue:)) else { return nil }
        let reason = meta.reason.flatMap { $0.isEmpty ? nil : AIUnavailableReason(wireValue: $0) }
        return AIRefusal(
            errorCode: "module.disabled",
            capability: capability,
            reason: reason ?? .moduleDisabled,
            module: meta.module,
            httpStatus: 403
        )
    }
}
