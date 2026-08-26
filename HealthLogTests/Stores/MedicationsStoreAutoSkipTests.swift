import Foundation
@testable import HealthLog
import Testing

/// REG-10 auto-skip coverage. Past-due intakes that the server still
/// reports as `skipped: false / takenAt: nil` should render as
/// "Ausgelassen" once they slip past the 24h grace window — operator
/// regression filed 2026-05-21 against TestFlight build 23 (March
/// entries surfacing as "Offen" in mid-May).
///
/// The auto-skip is a pure read-side projection on
/// `PaginatedIntakeEvent` — no store mutation, no server write. The
/// server-side reconciliation is tracked separately in
/// `.planning/v056-marathon/B2-report.md`.
@Suite("REG-10 — PaginatedIntakeEvent auto-skip grace")
struct MedicationsStoreAutoSkipTests {
    // MARK: - Grace boundaries

    @Test("Past-due pending event older than the 24h grace is effectively skipped")
    func pastDueBeyondGraceIsEffectivelySkipped() {
        let now = Date(timeIntervalSince1970: 1_715_817_600)
        let event = PaginatedIntakeEvent(
            id: "evt-march",
            takenAt: nil,
            skipped: false,
            scheduledFor: now.addingTimeInterval(-7 * 24 * 3600),
            injectionSite: nil
        )
        #expect(event.isEffectivelySkipped(now: now))
    }

    @Test("Pending event scheduled exactly 24h ago is NOT yet effectively skipped")
    func exactlyAtGraceBoundaryStaysPending() {
        let now = Date(timeIntervalSince1970: 1_715_817_600)
        // `addingTimeInterval(grace) < now` — strict less-than, so the
        // boundary moment itself doesn't flip yet.
        let event = PaginatedIntakeEvent(
            id: "evt-boundary",
            takenAt: nil,
            skipped: false,
            scheduledFor: now.addingTimeInterval(-PaginatedIntakeEvent.autoSkipGrace),
            injectionSite: nil
        )
        #expect(!event.isEffectivelySkipped(now: now))
    }

    @Test("Pending event scheduled 23h ago stays pending")
    func withinGraceWindowStaysPending() {
        let now = Date(timeIntervalSince1970: 1_715_817_600)
        let event = PaginatedIntakeEvent(
            id: "evt-recent",
            takenAt: nil,
            skipped: false,
            scheduledFor: now.addingTimeInterval(-23 * 3600),
            injectionSite: nil
        )
        #expect(!event.isEffectivelySkipped(now: now))
    }

    @Test("Future-scheduled event is never effectively skipped")
    func futureEventIsNeverEffectivelySkipped() {
        let now = Date(timeIntervalSince1970: 1_715_817_600)
        let event = PaginatedIntakeEvent(
            id: "evt-future",
            takenAt: nil,
            skipped: false,
            scheduledFor: now.addingTimeInterval(24 * 3600),
            injectionSite: nil
        )
        #expect(!event.isEffectivelySkipped(now: now))
    }

    // MARK: - State-specific short-circuits

    @Test("Explicitly skipped event does not depend on the grace window")
    func explicitlySkippedShortCircuitsFalse() {
        let now = Date(timeIntervalSince1970: 1_715_817_600)
        // `isEffectivelySkipped` returns *false* for explicitly-skipped
        // rows on purpose — the caller already renders the skipped chip
        // via the `event.skipped` branch. The auto-skip projection only
        // covers the "server still says pending but operator-visible
        // state should read skipped" case.
        let event = PaginatedIntakeEvent(
            id: "evt-skipped",
            takenAt: nil,
            skipped: true,
            scheduledFor: now.addingTimeInterval(-7 * 24 * 3600),
            injectionSite: nil
        )
        #expect(!event.isEffectivelySkipped(now: now))
    }

    @Test("Event with takenAt set is never auto-skipped")
    func takenEventIsNeverAutoSkipped() {
        let now = Date(timeIntervalSince1970: 1_715_817_600)
        let event = PaginatedIntakeEvent(
            id: "evt-taken",
            takenAt: now.addingTimeInterval(-7 * 24 * 3600),
            skipped: false,
            scheduledFor: now.addingTimeInterval(-7 * 24 * 3600),
            injectionSite: nil
        )
        #expect(!event.isEffectivelySkipped(now: now))
    }

    @Test("Grace constant is 24h — matches the operator handoff value")
    func graceConstantIs24h() {
        #expect(PaginatedIntakeEvent.autoSkipGrace == 24 * 60 * 60)
    }
}
