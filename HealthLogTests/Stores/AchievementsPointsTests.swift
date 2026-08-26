import Foundation
@testable import HealthLog
import Testing

/// Verifies the iOS-side `AchievementPoints` static table stays in sync with
/// the server's library + that `Achievement.resolvingPoints()` hydrates
/// correctly without trampling already-set values.
///
/// **Why this matters:** the server `format=ios` adapter still strips
/// `points`. If the iOS table drifts behind the server library, the
/// achievements screen renders `+0` pills + "0 Punkte" detail blocks
/// silently. The drift-coverage test fails loud on the next build.
@Suite("AchievementPoints + Achievement.resolvingPoints")
struct AchievementsPointsTests {
    /// Locked snapshot of every achievement ID the server library ships at
    /// the time this test was written. New entries on the server **must**
    /// be added here AND to `AchievementPoints.table` simultaneously.
    /// Sourced verbatim from
    /// the server repo's `src/lib/gamification/achievements.ts`
    /// (definitions + 5 buildStreakAchievements families expanded across
    /// targets `[1, 7, 30, 180, 360]`).
    private static let serverAchievementIDs: [String] = [
        // intake-totals (5)
        "intake-total-1", "intake-total-10", "intake-total-50",
        "intake-total-150", "intake-total-300",
        // compliance edge cases (2)
        "over-intake-1", "skipped-intake-1",
        // account / security (4)
        "passkey-created-1", "passkey-login-1", "password-login-1", "bugreport-1",
        // login streaks (2)
        "login-streak-7", "login-streak-30",
        // 5 buildStreakAchievements families × 5 targets = 25
        "on-time-perfect-1", "on-time-perfect-7", "on-time-perfect-30", "on-time-perfect-180", "on-time-perfect-360",
        "compliance-80-1", "compliance-80-7", "compliance-80-30", "compliance-80-180", "compliance-80-360",
        "bmi-green-1", "bmi-green-7", "bmi-green-30", "bmi-green-180", "bmi-green-360",
        "bp-green-1", "bp-green-7", "bp-green-30", "bp-green-180", "bp-green-360",
        "pulse-green-1", "pulse-green-7", "pulse-green-30", "pulse-green-180", "pulse-green-360",
        // mood (4)
        "mood-first", "mood-streak-7", "mood-streak-30", "mood-up-7",
        // weight (3)
        "weight-first", "weight-50", "weight-200",
        // bp (3)
        "bp-first", "bp-50", "bp-200",
        // pulse (1)
        "pulse-first",
        // engagement (4 — consistent-month + 7/30/weekend)
        "consistent-month", "entry-streak-7", "entry-streak-30", "weekend-warrior",
        // hidden (6)
        "hidden-night-owl", "hidden-early-bird", "hidden-leap-day",
        "hidden-doctor-pdf", "hidden-locale-flip", "hidden-bug-buddy",
        // care achievements (6 — server v1.16.1: miss-free family,
        // measurement consistency, self-context, sleep logging)
        "miss-free-7", "miss-free-30", "miss-free-90",
        "measurement-weeks-4", "self-context-complete", "sleep-log-7"
    ]

    @Test("Every server-known achievement ID has a points entry")
    func everyServerIDIsMapped() {
        var missing: [String] = []
        for id in Self.serverAchievementIDs where AchievementPoints.value(for: id) == nil {
            missing.append(id)
        }
        #expect(missing.isEmpty, "Achievement IDs without points: \(missing)")
    }

    @Test("Mapping table holds 65 server IDs at server v1.16.1")
    func tableSizeIsExpected() {
        // 65 = 5 (intake-totals) + 2 (compliance edges) + 4 (account/security)
        //    + 2 (login streaks) + 25 (5 family×5 streak tiers)
        //    + 4 (mood) + 3 (weight) + 3 (bp) + 1 (pulse-first)
        //    + 4 (engagement) + 6 (hidden) + 6 (care, v1.16.1). Bump this
        // number when the server library grows — the drift coverage test
        // above will already have failed first, this just makes the bump
        // explicit.
        #expect(AchievementPoints.table.count == 65)
    }

    @Test("resolvingPoints fills nil from the table")
    func resolvesPointsFromTable() {
        let raw = Achievement(
            id: "weight-50",
            key: "weight-50",
            title: "Wiegen-Profi",
            description: "...",
            iconName: "Scale",
            unlocked: true,
            progress: 1.0,
            points: nil
        )
        let resolved = raw.resolvingPoints()
        #expect(resolved.points == 90)
    }

    @Test("resolvingPoints leaves already-set points alone")
    func preservesExistingPoints() {
        let raw = Achievement(
            id: "weight-50",
            key: "weight-50",
            title: "x",
            description: "x",
            iconName: "Scale",
            unlocked: false,
            progress: 0.5,
            points: 999
        )
        let resolved = raw.resolvingPoints()
        #expect(resolved.points == 999)
    }

    @Test("resolvingPoints for unknown id keeps nil")
    func unknownIDStaysNil() {
        let raw = Achievement(
            id: "this-id-does-not-exist",
            key: "x",
            title: "x",
            description: "x",
            iconName: nil,
            unlocked: false,
            points: nil
        )
        let resolved = raw.resolvingPoints()
        #expect(resolved.points == nil)
    }

    @Test("isHiddenPlaceholder fires only on HelpCircle icon")
    func hiddenPlaceholderDetection() {
        let hidden = Achievement(
            id: "hidden-night-owl",
            key: "hidden-night-owl",
            title: "achievements.hiddenCard.title",
            description: "...",
            iconName: "HelpCircle",
            unlocked: false
        )
        let visible = Achievement(
            id: "hidden-night-owl",
            key: "hidden-night-owl",
            title: "Nachteule",
            description: "...",
            iconName: "Moon",
            unlocked: true
        )
        #expect(hidden.isHiddenPlaceholder)
        #expect(!visible.isHiddenPlaceholder)
    }

    @Test("isHiddenPlaceholder is case-insensitive on icon name")
    func hiddenPlaceholderCaseInsensitive() {
        let lower = Achievement(id: "x", key: "x", title: "x", description: "x", iconName: "helpcircle", unlocked: false)
        let upper = Achievement(id: "x", key: "x", title: "x", description: "x", iconName: "HELPCIRCLE", unlocked: false)
        #expect(lower.isHiddenPlaceholder)
        #expect(upper.isHiddenPlaceholder)
    }
}
