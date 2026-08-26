import Foundation
@testable import HealthLog
import Testing

/// Primary test suite for the Mini-Coach UI store (C4).
///
/// Covers the in-session contract:
///   - 8-pair (16 entry) message cap matches the actor-side
///     ``MiniCoachHistory/turnCap``.
///   - Refusal sentinels are preserved as a distinct `Message.Role` and
///     are NOT lost when the store reaches its cap.
///   - The disclaimer-banner pulse fires every 5th completed assistant
///     turn (C3 cadence).
///   - Onboarding flips `hl.minicoach.onboarded` in UserDefaults and is
///     idempotent on re-call.
///   - `clear()` empties the conversation AND the actor-side history.
@Suite("MiniCoach — store (C4)")
@MainActor
struct MiniCoachStoreTests {
    // MARK: - Onboarding

    @Test("Onboarding starts false on a fresh defaults bucket")
    func onboardingDefaultsFalse() {
        let defaults = makeIsolatedDefaults()
        let store = makeStore(defaults: defaults)
        #expect(!store.isOnboarded)
    }

    @Test("markOnboarded flips state + persists in defaults")
    func markOnboardedFlipsAndPersists() {
        let defaults = makeIsolatedDefaults()
        let store = makeStore(defaults: defaults)
        store.markOnboarded()
        #expect(store.isOnboarded)
        #expect(defaults.bool(forKey: MiniCoachDefaultsKeys.onboarded))
    }

    @Test("markOnboarded is idempotent")
    func markOnboardedIdempotent() {
        let defaults = makeIsolatedDefaults()
        let store = makeStore(defaults: defaults)
        store.markOnboarded()
        store.markOnboarded()
        #expect(store.isOnboarded)
    }

    @Test("resetOnboarding clears the persisted flag")
    func resetOnboardingClearsFlag() {
        let defaults = makeIsolatedDefaults()
        defaults.set(true, forKey: MiniCoachDefaultsKeys.onboarded)
        let store = makeStore(defaults: defaults)
        #expect(store.isOnboarded)
        store.resetOnboarding()
        #expect(!store.isOnboarded)
        #expect(!defaults.bool(forKey: MiniCoachDefaultsKeys.onboarded))
    }

    // MARK: - In-session cap

    @Test("Visible message cap stays at 16 (= 8 turn pairs)")
    func visibleCapMatchesActorTurnCap() {
        #expect(MiniCoachStore.visibleMessageCap == MiniCoachHistory.turnCap * 2)
    }

    @Test("Seed beyond cap trims to 16 entries from the tail")
    func capTrimsTail() {
        let store = makeStore()
        let seed: [MiniCoachStore.Message] = (0 ..< 22).map { i in
            .init(role: i.isMultiple(of: 2) ? .user : .assistant, text: "row-\(i)")
        }
        store.seedMessagesForTesting(seed)
        #expect(store.messages.count == 16)
        // The first 6 entries should have been dropped — last seeded
        // row (row-21) must still be the tail.
        #expect(store.messages.last?.text == "row-21")
        // The first surviving row must be row-6 (we dropped 0..5).
        #expect(store.messages.first?.text == "row-6")
    }

    @Test("Refusal sentinels survive trim-to-cap")
    func refusalSentinelsSurviveTrim() {
        let store = makeStore()
        var seed: [MiniCoachStore.Message] = (0 ..< 14).map { i in
            .init(role: i.isMultiple(of: 2) ? .user : .assistant, text: "row-\(i)")
        }
        seed.append(.init(role: .user, text: "verbotene-frage"))
        seed.append(.init(role: .refused, text: "Ich kann nur die Daten erklären."))
        seed.append(.init(role: .user, text: "row-x"))
        seed.append(.init(role: .assistant, text: "row-y"))
        store.seedMessagesForTesting(seed)
        let refused = store.messages.filter { $0.role == .refused }
        #expect(refused.count == 1)
        #expect(refused.first?.text == "Ich kann nur die Daten erklären.")
    }

    // MARK: - Disclaimer cadence

    @Test("Disclaimer pulse off before first assistant turn")
    func disclaimerOffPreFirstTurn() {
        let store = makeStore()
        #expect(!store.shouldPulseDisclaimer)
    }

    @Test("Disclaimer pulse fires at 5th completed assistant turn")
    func disclaimerOnFifthTurn() {
        let store = makeStore()
        store.setCompletedAssistantTurnsForTesting(5)
        #expect(store.shouldPulseDisclaimer)
    }

    @Test("Disclaimer pulse fires at every 5th turn (5, 10, 15)")
    func disclaimerOnEveryFifthTurn() {
        let store = makeStore()
        store.setCompletedAssistantTurnsForTesting(10)
        #expect(store.shouldPulseDisclaimer)
        store.setCompletedAssistantTurnsForTesting(15)
        #expect(store.shouldPulseDisclaimer)
    }

    @Test("Disclaimer pulse off on turns that are not multiples of 5")
    func disclaimerOffOnOffTurns() {
        let store = makeStore()
        for turn in [1, 2, 3, 4, 6, 7, 8, 9, 11, 12] {
            store.setCompletedAssistantTurnsForTesting(turn)
            #expect(!store.shouldPulseDisclaimer, "turn \(turn) should not pulse")
        }
    }

    // MARK: - Send pipeline

    @Test("Empty ask short-circuits to refused without touching history")
    func emptyAskShortCircuits() async {
        let store = makeStore()
        let outcome = await store.send(
            ask: "   ",
            context: MiniCoachContext(),
            locale: Locale(identifier: "de_DE")
        )
        #expect(outcome.disposition == .refusedByClassifier)
        #expect(store.messages.isEmpty)
    }

    @Test("appendSystem renders a system bubble")
    func appendSystemAddsRow() {
        let store = makeStore()
        store.appendSystem("Mini-Coach erfordert iOS 26+ mit Apple Intelligence.")
        #expect(store.messages.count == 1)
        #expect(store.messages.first?.role == .system)
    }

    @Test("Clear empties messages + resets turn counter")
    func clearEmptiesEverything() async {
        let store = makeStore()
        store.seedMessagesForTesting([
            .init(role: .user, text: "u1"),
            .init(role: .assistant, text: "a1")
        ])
        store.setCompletedAssistantTurnsForTesting(2)
        await store.clear()
        #expect(store.messages.isEmpty)
        #expect(store.completedAssistantTurns == 0)
    }

    // MARK: - Helpers

    private func makeStore(defaults: UserDefaults? = nil) -> MiniCoachStore {
        let defaults = defaults ?? makeIsolatedDefaults()
        return MiniCoachStore(
            service: MiniCoachService(featureFlags: StubFlags(enabled: true)),
            defaults: defaults
        )
    }

    private func makeIsolatedDefaults() -> UserDefaults {
        let suite = "MiniCoachStoreTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("could not allocate isolated UserDefaults suite")
        }
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}

// MARK: - Helpers

/// Minimal stub `FeatureFlagsServicing` for tests — defaults every flag
/// to a single bool.
struct StubFlags: FeatureFlagsServicing {
    let enabled: Bool
    func isEnabled(_: FeatureFlag) -> Bool {
        enabled
    }
}
