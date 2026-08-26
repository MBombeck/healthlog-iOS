import Foundation
@testable import HealthLog
import Testing

/// v0.5.1-A B3 — `ComplianceSnapshot.ratio` and `hasSchedule` semantics.
@Suite("ComplianceSnapshot — v0.5.1-A B3")
struct ComplianceSnapshotV051ATests {
    @Test("ratio is 0 when nothing scheduled today (was 1.0, rendered as '100% / 0:00 heute')")
    func emptyScheduleHasZeroRatio() {
        let snap = ComplianceSnapshot(scheduledToday: 0, takenToday: 0)
        #expect(snap.ratio == 0)
        #expect(snap.hasSchedule == false)
    }

    @Test("ratio is taken/scheduled when scheduled > 0")
    func partialComplianceRatio() {
        let snap = ComplianceSnapshot(scheduledToday: 4, takenToday: 3)
        #expect(snap.ratio == 0.75)
        #expect(snap.hasSchedule == true)
    }

    @Test("full compliance is 1.0 when all scheduled taken")
    func fullCompliance() {
        let snap = ComplianceSnapshot(scheduledToday: 2, takenToday: 2)
        #expect(snap.ratio == 1.0)
        #expect(snap.hasSchedule == true)
    }
}
