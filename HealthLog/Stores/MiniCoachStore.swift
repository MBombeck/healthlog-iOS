import Foundation
import Observation

/// Nonisolated UserDefaults keys for the Mini-Coach surface — kept in a
/// plain enum so `@AppStorage(...)` callers don't drag MainActor
/// isolation into otherwise nonisolated contexts (e.g. the Settings hub
/// `destination` enum that constructs `SettingsAIScreen()` from a
/// nonisolated `@ViewBuilder`).
public enum MiniCoachDefaultsKeys {
    public static let onboarded: String = "hl.minicoach.onboarded"
    public static let enabled: String = "hl.minicoach.enabled"
}

/// In-session message log + service-wrapper for the Mini-Coach UI (C4).
///
/// **Contract (operator-locked, COACH-SUB-QUEUE Q-MC-3):**
///   - No cross-session persistence. The `messages` array lives entirely
///     in memory and dies with the store / app process. Nothing flows to
///     SwiftData, UserDefaults, or Keychain.
///   - 8-turn in-session cap mirrors ``MiniCoachHistory`` (each "turn" =
///     one user line + one assistant or refusal line). The store keeps
///     its own array for SwiftUI rendering; the actor-side `MiniCoachHistory`
///     is still the source of truth for prompt-building.
///   - The refusal sentinel is preserved verbatim — the bubble layer
///     renders it with a distinct visual marker so the user can tell
///     scope-refusals from successful answers at a glance.
///
/// **Why `@Observable @MainActor`?** Views read `messages` synchronously
/// during `body` evaluation. The store hands a `Task` to a `respond(...)`
/// call, awaits the actor reply, and writes back onto the MainActor —
/// no `nonisolated`-shenanigans needed.
@MainActor
@Observable
public final class MiniCoachStore: BoxBackedPHIStore {
    /// One row in the conversation surface. Renders as a bubble.
    public struct Message: Identifiable, Sendable, Equatable {
        public let id: UUID
        public let role: Role
        public let text: String
        public let createdAt: Date

        public enum Role: Sendable, Equatable {
            case user
            case assistant
            /// Refusal sentinel — distinct from `.assistant` so the bubble
            /// view can render a clear "scope-out-of-bounds" visual.
            case refused
            /// System status message — onboarding-info, availability
            /// fall-off etc. Rendered in muted style.
            case system
        }

        public init(id: UUID = UUID(), role: Role, text: String, createdAt: Date = Date()) {
            self.id = id
            self.role = role
            self.text = text
            self.createdAt = createdAt
        }
    }

    /// In-session 8-turn cap. Each user message + assistant/refused/system
    /// counterpart counts as a turn pair; we cap at 16 entries (8 pairs)
    /// to mirror ``MiniCoachHistory/turnCap``.
    public static let visibleMessageCap = 16

    /// Disclaimer banner pulse cadence — every 5th assistant turn the
    /// banner gets a pulse animation (matches C3 contract).
    public static let disclaimerPulseEvery = 5

    /// Public messages array. SwiftUI renders this directly.
    public private(set) var messages: [Message] = []

    /// True while a model call is in flight — toggles the typing indicator.
    public private(set) var isThinking: Bool = false

    /// Count of completed assistant turns (answered + refused). Drives the
    /// disclaimer-banner pulse cadence in the conversation view.
    public private(set) var completedAssistantTurns: Int = 0

    /// True after the onboarding sheet has been acknowledged this session.
    /// Reads ``MiniCoachStore/isOnboardedKey`` from UserDefaults on init so
    /// onboarding only re-shows on a fresh install or after the operator
    /// flips the flag from Settings.
    public private(set) var isOnboarded: Bool

    public let service: MiniCoachService

    /// UserDefaults key recording the user has acknowledged the scope
    /// statement. Exposed for tests + the onboarding sheet that writes it.
    public static let isOnboardedKey = MiniCoachDefaultsKeys.onboarded
    /// UserDefaults key for the Settings toggle. The toggle owns this
    /// key via `@AppStorage`; the store reads it only as a courtesy when
    /// constructed in tests.
    public static let isEnabledKey = MiniCoachDefaultsKeys.enabled

    private let defaults: UserDefaults

    public init(
        service: MiniCoachService,
        defaults: UserDefaults = .standard
    ) {
        self.service = service
        self.defaults = defaults
        isOnboarded = defaults.bool(forKey: Self.isOnboardedKey)
    }

    // MARK: - Onboarding

    /// Flip onboarding to acknowledged. Idempotent — the second call is
    /// a no-op. The Settings toggle calls this from
    /// ``MiniCoachOnboardingSheet`` when the user taps "Aktivieren".
    public func markOnboarded() {
        guard !isOnboarded else { return }
        isOnboarded = true
        defaults.set(true, forKey: Self.isOnboardedKey)
    }

    /// Reset onboarding state. Reserved for the operator-walkthrough
    /// re-onboarding flow + tests.
    public func resetOnboarding() {
        isOnboarded = false
        defaults.removeObject(forKey: Self.isOnboardedKey)
    }

    // MARK: - Conversation

    /// Append a system-status message — used for unsupported devices,
    /// onboarding-info banners, etc.
    public func appendSystem(_ text: String) {
        messages.append(Message(role: .system, text: text))
        trimToCap()
    }

    /// Clear the in-session conversation (and the actor-side history).
    /// Onboarding state survives — only the messages reset.
    public func clear() async {
        messages.removeAll()
        completedAssistantTurns = 0
        await service.history.reset()
    }

    /// **W-B187 (AUDIT-SEC-b187 High)** — full conversation wipe for the logout
    /// cascade. Drops the in-memory `messages` log AND the actor-side
    /// ``MiniCoachHistory`` (the prompt-building source of truth), plus the
    /// in-flight indicator, so the next user on the same device can never see
    /// the previous user's leftover coach chat. Unlike ``clear()`` this also
    /// resets `isThinking` — a logout can land mid-turn.
    public func wipe() async {
        messages.removeAll()
        completedAssistantTurns = 0
        isThinking = false
        await service.history.reset()
    }

    /// **W-PHI-HARDENING (G5)** — box-backed PHI conformance so the
    /// ``MiniCoachBox`` logout registry can clear this store generically and the
    /// completeness suite can verify it. Forwards to ``wipe()``.
    public func clearPHIOnLogout() async {
        await wipe()
    }

    /// Send a user ask and append the assistant reply once it lands.
    /// Returns the resulting outcome so the caller can branch on it
    /// (tests use this; production code can ignore the return value).
    @discardableResult
    public func send(
        ask: String,
        context: MiniCoachContext,
        locale: Locale = .current
    ) async -> MiniCoachOutcome {
        let trimmed = ask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .refusedByClassifier("")
        }
        messages.append(Message(role: .user, text: trimmed))
        trimToCap()
        isThinking = true
        defer { isThinking = false }

        let outcome = await service.respond(to: trimmed, context: context, locale: locale)
        appendOutcomeMessage(outcome)
        return outcome
    }

    // MARK: - Internals

    private func appendOutcomeMessage(_ outcome: MiniCoachOutcome) {
        let role: Message.Role = switch outcome.disposition {
        case .answered:
            .assistant
        case .refusedByClassifier, .refusedBySafetyFilter:
            .refused
        case .unsupported, .featureFlagDisabled, .generationFailed:
            .system
        }
        messages.append(Message(role: role, text: outcome.reply))
        if role != .system { completedAssistantTurns += 1 }
        trimToCap()
    }

    private func trimToCap() {
        if messages.count > Self.visibleMessageCap {
            let drop = messages.count - Self.visibleMessageCap
            messages.removeFirst(drop)
        }
    }

    // MARK: - Disclaimer cadence

    /// Returns `true` whenever the in-session pulse cadence should fire
    /// for the disclaimer banner (every 5th assistant turn). Tests pin
    /// this via the `completedAssistantTurns` setter; production code
    /// reads it inline during view-body evaluation.
    public var shouldPulseDisclaimer: Bool {
        guard completedAssistantTurns > 0 else { return false }
        return completedAssistantTurns.isMultiple(of: Self.disclaimerPulseEvery)
    }

    /// Test-only setter — production code mutates the counter through
    /// ``send(ask:context:locale:)``.
    func setCompletedAssistantTurnsForTesting(_ value: Int) {
        completedAssistantTurns = value
    }

    /// Test-only seed — production code accumulates messages through
    /// ``send`` / ``appendSystem``.
    func seedMessagesForTesting(_ next: [Message]) {
        messages = next
        trimToCap()
    }

    /// Test-only — drive the outcome-to-bubble mapping without calling the
    /// real `MiniCoachService.respond(...)`. Lets the C4 tests stay
    /// offline + deterministic on iOS-Simulator runners without a model.
    func appendOutcomeForTesting(userAsk: String, outcome: MiniCoachOutcome) {
        messages.append(Message(role: .user, text: userAsk))
        appendOutcomeMessage(outcome)
    }
}
