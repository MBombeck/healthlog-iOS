import Foundation

// #114 / #115 · 0.2 — AI availability as the SERVER resolves it.
//
// Server v1.39 publishes one object per AI capability on `GET /api/auth/me`
// (`ai.capabilities`), resolved for the active record from every layer that can
// say no: the operator's switches, the record, the owning modules, the person's
// own opt-out, the provider and the consent receipt. The app renders from it and
// never recomputes it. Before v1.39 the operator's assistant switches never
// reached the app at all (`/api/feature-flags` was decoded as an invented
// `{ flags }` shape), so this is the first operator signal the app actually
// reads.
//
// A server older than v1.39 sends no `ai` block. Then every capability reads as
// the 1.0.3 behaviour did: available, on-device allowed (``AICapabilityState/legacy``),
// and the older signals (`GET /api/user/ai-provider` `aiAvailable`, consent)
// keep doing what they did.

/// The closed capability vocabulary of `AiCapabilities` (server
/// `src/lib/ai/capabilities/types.ts`). A capability key this build does not
/// know is skipped when decoding; it never fails the block.
public enum AICapabilityKey: String, Sendable, CaseIterable, Hashable {
    /// Chat, fenced document chat, attachments, memory upkeep, AI nudges, every
    /// Coach launcher.
    case coach
    /// The daily briefing and every place its text is lifted into.
    case briefing
    /// The model-written half of a period narrative (the deterministic one is data).
    case periodNarrative
    /// Per-metric status notes and the AI override of a derived assessment.
    case statusText
    /// The paragraph on a workout.
    case workoutInsights
    /// The line written after a new reading.
    case reactionLines
    /// Model-written follow-up questions on the about-me profile.
    case aboutMeQuestions
    /// Suggest, summary, extract, index and chat over a stored document.
    case documentAi
    /// Reading a lab report image by the provider.
    case labsOcr
    /// Turning a typed medication description into a schedule.
    case medicationExtract

    /// The operator sub-switch covering this capability (server
    /// `AI_CAPABILITIES[key].operatorSwitch`).
    public var operatorSwitch: String {
        switch self {
        case .coach, .aboutMeQuestions: "coach"
        case .briefing, .periodNarrative: "briefing"
        case .statusText, .workoutInsights, .reactionLines: "insightStatus"
        case .documentAi, .labsOcr, .medicationExtract: "documentAi"
        }
    }

    /// The capabilities an operator sub-switch covers (server
    /// `AI_CAPABILITIES[*].operatorSwitch`). Used when a refusal names only the
    /// switch (`assistant.disabled.<switch>` without `meta.capability`). The
    /// overall switch `enabled` covers every capability.
    public static func covered(byOperatorSwitch operatorSwitch: String) -> [AICapabilityKey] {
        switch operatorSwitch {
        case "enabled": allCases
        case "coach": [.coach, .aboutMeQuestions]
        case "briefing": [.briefing, .periodNarrative]
        case "insightStatus": [.statusText, .workoutInsights, .reactionLines]
        case "documentAi": [.documentAi, .labsOcr, .medicationExtract]
        default: []
        }
    }
}

/// Why a capability is unavailable (server `AiUnavailableReason`). The server
/// reports only the outermost reason. The list is closed server-side, and a
/// value this build does not know means "unavailable" (``unknown``).
public enum AIUnavailableReason: String, Codable, Sendable, Equatable, Hashable, TolerantServerEnum {
    case checkFailed = "check_failed"
    case operatorDisabled = "operator_disabled"
    case notPermittedForRecord = "not_permitted_for_record"
    case moduleDisabled = "module_disabled"
    case userDisabled = "user_disabled"
    case noProvider = "no_provider"
    case consentRequired = "consent_required"
    /// Decode-only sentinel for a reason this build does not know. Treated as
    /// unavailable everywhere, on the device too.
    case unknown = "__UNKNOWN__"

    public static let unknownFallback = AIUnavailableReason.unknown
    public static let wireVocabulary: StaticString = "AI unavailable reason"
}

/// One capability, resolved for one record (server `AiCapabilityState`).
public struct AICapabilityState: Codable, Sendable, Equatable, Hashable {
    public let available: Bool
    /// `nil` exactly when `available` is true.
    public let reason: AIUnavailableReason?
    /// Whether an on-device model may do this work. The server resolves it so
    /// the app never decides which reasons apply off the server.
    public let onDeviceAllowed: Bool

    public init(available: Bool, reason: AIUnavailableReason?, onDeviceAllowed: Bool) {
        self.available = available
        self.reason = reason
        self.onDeviceAllowed = onDeviceAllowed
    }

    private enum CodingKeys: String, CodingKey {
        case available, reason, onDeviceAllowed
    }

    /// Tolerant: a missing or mistyped boolean reads as `false` (fail closed),
    /// an unknown reason lands on ``AIUnavailableReason/unknown``.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        available = (try? c.decodeIfPresent(Bool.self, forKey: .available)) ?? false
        reason = try? c.decodeIfPresent(AIUnavailableReason.self, forKey: .reason)
        onDeviceAllowed = (try? c.decodeIfPresent(Bool.self, forKey: .onDeviceAllowed)) ?? false
    }

    /// Encodes the wire shape (for the SWR caches that persist a digest).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(available, forKey: .available)
        try c.encodeIfPresent(reason, forKey: .reason)
        try c.encode(onDeviceAllowed, forKey: .onDeviceAllowed)
    }

    /// The server path may run and its text may be shown. A reason next to
    /// `available: true` contradicts the contract, so it fails closed.
    public var isAvailable: Bool {
        available && reason == nil
    }

    /// An on-device (Foundation Models) or device-to-own-provider path may run.
    /// An unknown reason fails closed on the device too.
    public var allowsOnDevice: Bool {
        onDeviceAllowed && reason != .unknown
    }

    /// Whether an ENTRY POINT to the capability is offered at all: either the
    /// server can serve it, or the person's own device can. This is exactly
    /// "not blocked by a decision" (operator, record, module, the person's own
    /// opt-out, a failed check); a missing provider or a missing consent keep
    /// the entry point, because the app has its own flow for both (on-device
    /// arm, consent sheet).
    public var offersEntryPoint: Bool {
        isAvailable || allowsOnDevice
    }

    /// The 1.0.3 behaviour: a server without the `ai` block (< v1.39) gates
    /// nothing here; the older signals keep deciding.
    public static let legacy = AICapabilityState(available: true, reason: nil, onDeviceAllowed: true)

    /// A capability key the server's `ai` block did not carry. The block is
    /// required to be complete, so a hole is treated as unavailable.
    public static let absent = AICapabilityState(available: false, reason: .unknown, onDeviceAllowed: false)
}

/// Where the serving credential comes from (server `AiProviderState.managedBy`).
public enum AIProviderManagedBy: String, Sendable, Equatable, TolerantServerEnum {
    case user
    case local
    case server
    case unknown = "__UNKNOWN__"

    public static let unknownFallback = AIProviderManagedBy.unknown
    public static let wireVocabulary: StaticString = "AI provider managedBy"
}

/// The account-level companion to the capability map (server `AiProviderState`).
public struct AIProviderState: Decodable, Sendable, Equatable {
    public let configured: Bool
    public let managedBy: AIProviderManagedBy?
    public let canConfigure: Bool

    public init(configured: Bool, managedBy: AIProviderManagedBy?, canConfigure: Bool) {
        self.configured = configured
        self.managedBy = managedBy
        self.canConfigure = canConfigure
    }

    private enum CodingKeys: String, CodingKey {
        case configured, managedBy, canConfigure
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        configured = (try? c.decodeIfPresent(Bool.self, forKey: .configured)) ?? false
        managedBy = try? c.decodeIfPresent(AIProviderManagedBy.self, forKey: .managedBy)
        canConfigure = (try? c.decodeIfPresent(Bool.self, forKey: .canConfigure)) ?? false
    }
}

/// The `ai` block on `GET /api/auth/me` (server `AiAccountBlock`).
public struct AIAccountBlock: Decodable, Sendable, Equatable {
    public let capabilities: [AICapabilityKey: AICapabilityState]
    public let provider: AIProviderState?

    public init(capabilities: [AICapabilityKey: AICapabilityState], provider: AIProviderState? = nil) {
        self.capabilities = capabilities
        self.provider = provider
    }

    private enum CodingKeys: String, CodingKey {
        case capabilities, provider
    }

    /// Per-key tolerant: an unknown capability key is skipped (logged once),
    /// a malformed entry drops only that entry (it then reads as ``AICapabilityState/absent``).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var resolved: [AICapabilityKey: AICapabilityState] = [:]
        if let map = try? c.nestedContainer(keyedBy: AnyCapabilityKey.self, forKey: .capabilities) {
            for wireKey in map.allKeys {
                guard let key = AICapabilityKey(rawValue: wireKey.stringValue) else {
                    UnknownServerEnumLog.noteFirstSighting(
                        of: wireKey.stringValue,
                        vocabulary: "AI capability key",
                        consequence: "skipped"
                    )
                    continue
                }
                if let state = try? map.decode(AICapabilityState.self, forKey: wireKey) {
                    resolved[key] = state
                }
            }
        }
        capabilities = resolved
        provider = try? c.decodeIfPresent(AIProviderState.self, forKey: .provider)
    }

    /// The state of one capability. A key missing from a present block is
    /// unavailable (the server always sends all ten).
    public func state(_ key: AICapabilityKey) -> AICapabilityState {
        capabilities[key] ?? .absent
    }

    private struct AnyCapabilityKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil

        init?(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue _: Int) {
            nil
        }
    }
}

// MARK: - Reading capabilities off the main actor

/// What the on-device AI services consult before they spend any inference. The
/// services are actors; this is the `Sendable` read side of ``AICapabilityGate``.
public protocol AICapabilityReading: Sendable {
    func state(_ key: AICapabilityKey) -> AICapabilityState
    /// True once the server has sent an `ai` block (v1.39+). Such a server
    /// resolves operator, module and consent for its AI routes itself, so a
    /// client-side gate that only duplicates that can step aside (#115 B7).
    /// A refusal mirrored on an older server does NOT make this true.
    var reportsCapabilities: Bool { get }
}

public extension AICapabilityReading {
    func isAvailable(_ key: AICapabilityKey) -> Bool {
        state(key).isAvailable
    }

    func allowsOnDevice(_ key: AICapabilityKey) -> Bool {
        state(key).allowsOnDevice
    }

    /// Default: no `ai` block known (legacy readers, test stubs).
    var reportsCapabilities: Bool {
        false
    }
}

/// Every capability in its legacy state. The default for services built outside
/// the app composition root (unit tests, previews); it deliberately does NOT
/// read any persisted flag, so nothing a previous build stored can gate here.
public struct LegacyAICapabilities: AICapabilityReading {
    public init() {}

    public func state(_: AICapabilityKey) -> AICapabilityState {
        .legacy
    }
}

/// A fixed capability map, for tests and previews.
public struct FixedAICapabilities: AICapabilityReading {
    private let block: AIAccountBlock?

    public init(_ block: AIAccountBlock?) {
        self.block = block
    }

    public func state(_ key: AICapabilityKey) -> AICapabilityState {
        block?.state(key) ?? .legacy
    }

    public var reportsCapabilities: Bool {
        block != nil
    }
}

/// Lock-guarded shadow of the gate's resolved map. Written on the main actor by
/// ``AICapabilityGate``, read synchronously from the service actors.
public final class AICapabilityCell: AICapabilityReading, @unchecked Sendable {
    private let lock = NSLock()
    private var resolved: [AICapabilityKey: AICapabilityState]?
    private var accountReported = false

    public init() {}

    /// `nil` = no `ai` block known (legacy / not loaded yet).
    /// `reportsCapabilities` = the map comes from a real `ai` block, not only
    /// from refusals mirrored on an older server.
    public func store(_ next: [AICapabilityKey: AICapabilityState]?, reportsCapabilities: Bool = false) {
        lock.withLock {
            resolved = next
            accountReported = reportsCapabilities && next != nil
        }
    }

    public var reportsCapabilities: Bool {
        lock.withLock { accountReported }
    }

    public func state(_ key: AICapabilityKey) -> AICapabilityState {
        lock.withLock {
            guard let resolved else { return .legacy }
            return resolved[key] ?? .absent
        }
    }
}
