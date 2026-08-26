import Foundation
@testable import HealthLog
import Testing

/// Tests around the outcome-to-bubble role mapping (C4 + integration).
///
/// The bubble view itself is rendered offline; what we lock here is the
/// invariant that every `MiniCoachOutcome.disposition` maps to exactly
/// one `MiniCoachStore.Message.Role` so the UI can never render a
/// refusal as a regular assistant bubble (felt-quality + MDR).
@Suite("MiniCoach — bubble role mapping (C4)")
@MainActor
struct MiniCoachBubbleRoleTests {
    @Test("answered outcome lands as assistant bubble")
    func answeredLandsAsAssistant() async {
        let store = makeStore()
        store.appendSystem("ignore me") // ensure clean tail check
        store.seedMessagesForTesting([])
        await sendStubbed(outcome: .answered("Du hast letzte Woche an drei Tagen gemessen."), store: store)
        #expect(store.messages.last?.role == .assistant)
    }

    @Test("refusedByClassifier outcome lands as refused bubble")
    func classifierRefusalLandsAsRefused() async {
        let store = makeStore()
        await sendStubbed(outcome: .refusedByClassifier("Außerhalb meines Bereichs"), store: store)
        #expect(store.messages.last?.role == .refused)
    }

    @Test("refusedBySafetyFilter outcome lands as refused bubble")
    func safetyRefusalLandsAsRefused() async {
        let store = makeStore()
        await sendStubbed(outcome: .refusedBySafetyFilter("Außerhalb meines Bereichs"), store: store)
        #expect(store.messages.last?.role == .refused)
    }

    @Test("unsupported outcome lands as system bubble")
    func unsupportedLandsAsSystem() async {
        let store = makeStore()
        await sendStubbed(outcome: .unsupported("Mini-Coach erfordert iOS 26+ mit Apple Intelligence."), store: store)
        #expect(store.messages.last?.role == .system)
    }

    @Test("featureFlagDisabled outcome lands as system bubble")
    func featureFlagDisabledLandsAsSystem() async {
        let store = makeStore()
        await sendStubbed(outcome: .featureFlagDisabled("Mini-Coach ist deaktiviert."), store: store)
        #expect(store.messages.last?.role == .system)
    }

    @Test("generationFailed outcome lands as system bubble (not refused)")
    func generationFailedLandsAsSystem() async {
        let store = makeStore()
        await sendStubbed(outcome: .generationFailed("Generation fehlgeschlagen"), store: store)
        #expect(store.messages.last?.role == .system)
    }

    @Test("answered turn increments completedAssistantTurns")
    func answeredIncrementsCounter() async {
        let store = makeStore()
        #expect(store.completedAssistantTurns == 0)
        await sendStubbed(outcome: .answered("ok"), store: store)
        #expect(store.completedAssistantTurns == 1)
        await sendStubbed(outcome: .answered("ok2"), store: store)
        #expect(store.completedAssistantTurns == 2)
    }

    @Test("system outcomes do NOT increment completedAssistantTurns")
    func systemOutcomesDoNotCountTurn() async {
        let store = makeStore()
        await sendStubbed(outcome: .unsupported("nope"), store: store)
        await sendStubbed(outcome: .featureFlagDisabled("off"), store: store)
        await sendStubbed(outcome: .generationFailed("bad"), store: store)
        #expect(store.completedAssistantTurns == 0)
    }

    @Test("refusal counts as a completed turn for cadence")
    func refusalCountsAsTurn() async {
        let store = makeStore()
        await sendStubbed(outcome: .refusedByClassifier("nope"), store: store)
        #expect(store.completedAssistantTurns == 1)
    }

    // MARK: - Helpers

    /// Drives the store through a synthetic outcome without going through
    /// the real `MiniCoachService.respond(...)` — keeps the test offline
    /// and deterministic. We piggy-back on the store's user-message-append
    /// + appendOutcomeMessage flow by seeding the user-line manually and
    /// asking the store to honour the outcome via the test-only API.
    private func sendStubbed(outcome: MiniCoachOutcome, store: MiniCoachStore) async {
        // The store mutates messages on send; we mirror the steps the
        // production path takes: append user-line, then bridge the outcome.
        store.appendOutcomeForTesting(userAsk: "stub", outcome: outcome)
    }

    private func makeStore() -> MiniCoachStore {
        let suite = "MiniCoachBubbleRoleTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("could not allocate isolated UserDefaults suite")
        }
        defaults.removePersistentDomain(forName: suite)
        return MiniCoachStore(
            service: MiniCoachService(featureFlags: StubFlags(enabled: true)),
            defaults: defaults
        )
    }
}
