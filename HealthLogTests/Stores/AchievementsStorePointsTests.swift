import Foundation
@testable import HealthLog
import Testing

/// Verifies `AchievementsStore.earnedPoints` + `.totalPoints` arithmetic.
/// Pulls together the new Achievement.points field + the hidden-card-skip
/// rule (denominator stays honest for unlocked counts).
@MainActor
@Suite("AchievementsStore points aggregates")
struct AchievementsStorePointsTests {
    @Test("earned + total sums correctly across unlocked / locked")
    func happyPath() async {
        let api = StubAPIClient()
        let repo = AchievementsRepository(api: api)
        await api.setHandler { _ in
            [
                Achievement(id: "a", key: "a", title: "A", description: "", iconName: "Trophy", unlocked: true, points: 100),
                Achievement(id: "b", key: "b", title: "B", description: "", iconName: "Heart", unlocked: false, points: 50),
                Achievement(id: "c", key: "c", title: "C", description: "", iconName: "Pill", unlocked: true, points: 25)
            ] as [Achievement]
        }
        let store = AchievementsStore(repo: repo)
        await store.load()
        #expect(store.earnedPoints == 125, "100 + 25 unlocked")
        #expect(store.totalPoints == 175, "100 + 50 + 25 total")
    }

    @Test("Hidden-placeholder cells count for denominator only after unlock")
    func hiddenSkippedInTotal() async {
        let api = StubAPIClient()
        let repo = AchievementsRepository(api: api)
        await api.setHandler { _ in
            [
                Achievement(id: "a", key: "a", title: "A", description: "", iconName: "Trophy", unlocked: true, points: 100),
                Achievement(id: "secret", key: "x", title: "?", description: "?", iconName: "HelpCircle", unlocked: false, points: 999)
            ] as [Achievement]
        }
        let store = AchievementsStore(repo: repo)
        await store.load()
        // Hidden + locked cards contribute 0 to total — denominator is 100, not 1099.
        #expect(store.totalPoints == 100)
        #expect(store.earnedPoints == 100)
    }

    @Test("Hidden-placeholder cells DO count after unlock")
    func hiddenCountsWhenUnlocked() async {
        let api = StubAPIClient()
        let repo = AchievementsRepository(api: api)
        await api.setHandler { _ in
            // Unlocked hidden cards are revealed by the server with their
            // real definition; their isHiddenPlaceholder evaluates false
            // (icon flips off "HelpCircle"). We model that here.
            [
                Achievement(id: "unlocked-hidden", key: "x", title: "Nacht", description: "", iconName: "Moon", unlocked: true, points: 25),
                Achievement(
                    id: "still-hidden",
                    key: "x2",
                    title: "?",
                    description: "?",
                    iconName: "HelpCircle",
                    unlocked: false,
                    points: 999
                )
            ] as [Achievement]
        }
        let store = AchievementsStore(repo: repo)
        await store.load()
        #expect(store.earnedPoints == 25)
        #expect(store.totalPoints == 25, "still-hidden+locked skipped, unlocked-hidden counted")
    }

    @Test("nil points contribute 0")
    func nilPointsCountAsZero() async {
        let api = StubAPIClient()
        let repo = AchievementsRepository(api: api)
        await api.setHandler { _ in
            [
                Achievement(id: "a", key: "a", title: "A", description: "", iconName: "Trophy", unlocked: true, points: 100),
                Achievement(id: "b", key: "b", title: "B", description: "", iconName: nil, unlocked: false, points: nil)
            ] as [Achievement]
        }
        let store = AchievementsStore(repo: repo)
        await store.load()
        #expect(store.earnedPoints == 100)
        #expect(store.totalPoints == 100)
    }
}
