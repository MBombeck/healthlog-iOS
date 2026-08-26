import Foundation
@testable import HealthLog
import SnapshotTesting
import Testing

/// State-dump snapshots for `Achievement`-shapes the detail sheet renders.
/// We dump the value not the view (consistent design-system precedent —
/// pixel-stability across SDK bumps is too noisy to lock).
@MainActor
@Suite("AchievementDetailSheet input state")
struct AchievementDetailSheetTests {
    @Test("Unlocked + points + earned-date snapshot")
    func unlockedSnapshot() {
        let a = Achievement(
            id: "intake-total-50",
            key: "intake-total-50",
            title: "Konsequenter Pillenfreund",
            description: "Du hast 50 Medikamenten-Einnahmen erfasst.",
            iconName: "Pill",
            unlocked: true,
            unlockedAt: Date(timeIntervalSince1970: 1_716_800_000),
            progress: 1.0,
            points: 60
        )
        assertSnapshot(of: dump(of: a), as: .lines, named: "unlocked-with-points")
    }

    @Test("Locked + partial-progress snapshot")
    func lockedPartial() {
        let a = Achievement(
            id: "bp-50",
            key: "bp-50",
            title: "Vitalwerte-Profi",
            description: "Erfasse 50 Blutdruck-Messungen.",
            iconName: "Heart",
            unlocked: false,
            unlockedAt: nil,
            progress: 0.42,
            points: 90
        )
        assertSnapshot(of: dump(of: a), as: .lines, named: "locked-partial-progress")
    }

    @Test("Hidden placeholder snapshot")
    func hiddenPlaceholder() {
        let a = Achievement(
            id: "hidden-night-owl",
            key: "hidden-night-owl",
            title: "achievements.hiddenCard.title",
            description: "achievements.hiddenCard.description",
            iconName: "HelpCircle",
            unlocked: false,
            unlockedAt: nil,
            progress: 0,
            points: 25
        )
        assertSnapshot(of: dump(of: a), as: .lines, named: "hidden-placeholder")
    }

    private func dump(of value: some Any) -> String {
        var output = ""
        Swift.dump(value, to: &output)
        return output
    }
}
