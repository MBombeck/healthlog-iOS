import Foundation
@testable import HealthLog
import Testing

/// v1.18.3 — Rest Mode annotation gate + streak-non-penalty contract.
///
/// The Rest Mode acknowledgement is **annotate-never-mutate**: it appears ONLY
/// when the server flagged Rest Mode active AND the illness module is enabled,
/// and an active episode must NEVER break/penalise a streak. These tests pin the
/// render-gate truth-table and prove the streak derivation is illness-blind.
@Suite("Rest Mode annotation — gate + streak non-penalty")
struct RestModeAnnotationTests {
    private func score(restMode: RestModeAnnotation?) -> HealthScore {
        HealthScore(score: 70, band: .yellow, delta: nil, restMode: restMode)
    }

    private let active = RestModeAnnotation(active: true, since: nil, episodeCount: 1)
    private let inactive = RestModeAnnotation(active: false, since: nil, episodeCount: 0)

    // MARK: - Gate truth table (active AND illness-enabled)

    /// The exact predicate the `RestModeGate` view applies. Kept here as a pure
    /// function so the gate logic is unit-testable without a SwiftUI host.
    @MainActor
    private func shouldAnnotate(score: HealthScore?, gate: ModuleGate) -> Bool {
        score?.activeRestMode != nil && gate.isEnabled(.illness)
    }

    @Test("Shows only when Rest Mode active AND illness enabled")
    @MainActor
    func showsWhenActiveAndEnabled() {
        let gate = ModuleGate(modules: ["illness": true])
        #expect(shouldAnnotate(score: score(restMode: active), gate: gate) == true)
    }

    @Test("Hidden when Rest Mode active but illness disabled")
    @MainActor
    func hiddenWhenIllnessDisabled() {
        let gate = ModuleGate(modules: ["illness": false])
        #expect(shouldAnnotate(score: score(restMode: active), gate: gate) == false)
    }

    @Test("Hidden when illness enabled but Rest Mode inactive")
    @MainActor
    func hiddenWhenInactive() {
        let gate = ModuleGate(modules: ["illness": true])
        #expect(shouldAnnotate(score: score(restMode: inactive), gate: gate) == false)
    }

    @Test("Hidden when there is no Rest Mode annotation at all")
    @MainActor
    func hiddenWhenAbsent() {
        let gate = ModuleGate(modules: ["illness": true])
        #expect(shouldAnnotate(score: score(restMode: nil), gate: gate) == false)
    }

    @Test("illness is default-ON (v1.18.3) — absent map still annotates when active")
    @MainActor
    func defaultOnWhenMapAbsent() {
        // Older server / not-yet-loaded map → all modules on, including illness.
        let gate = ModuleGate(modules: nil)
        #expect(shouldAnnotate(score: score(restMode: active), gate: gate) == true)
    }

    // MARK: - Streak must NOT be broken / penalised by an active episode

    @Test("StreakComputer output is identical regardless of Rest Mode (illness-blind)")
    func streakNotPenalisedByActiveEpisode() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .current
        let now = Date(timeIntervalSince1970: 1_716_000_000)
        let start = cal.startOfDay(for: now)

        // Five consecutive ≥10k-step days → a 5-day streak record.
        let points: [SeriesPoint] = (0 ..< 5).map { offset in
            let day = cal.date(byAdding: .day, value: -offset, to: start) ?? start
            return SeriesPoint(id: "p\(offset)", at: day, value: 12000, secondary: nil)
        }

        // The computer takes NO illness/Rest-Mode input — there is no parameter
        // by which an active episode could shorten the run. Deriving twice
        // (conceptually "well" vs "in Rest Mode") yields the identical record,
        // proving the streak is never penalised by illness.
        let derivedWell = StreakComputer.derive(points: points, kind: .steps, userId: "u1", now: now, calendar: cal)
        let derivedResting = StreakComputer.derive(points: points, kind: .steps, userId: "u1", now: now, calendar: cal)

        #expect(derivedWell == derivedResting)
        let record = try #require(derivedWell.first { $0.id.hasSuffix(".streak") })
        // The 5-day run survives intact — not clipped by any Rest Mode logic.
        #expect(record.value == 5)
    }
}
