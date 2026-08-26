import Foundation
@testable import HealthLog
import Testing

/// A360-5 H-3 — schedule-time rows carry a STABLE identity (per-row UUID), not
/// the mutable array offset. The Add/Edit medication sheets keyed `ForEach` on
/// `id: \.offset`, so after removing a middle time SwiftUI re-used a row's view
/// identity and the user's NEXT edit landed on the WRONG row.
///
/// `ScheduleTimeRow` is the identity wrapper; these tests lock the invariant the
/// View binding relies on: editing-by-id after a remove hits the intended row,
/// and the derived `[TimeOfDay]` round-trips.
@Suite("ScheduleTimeRow — stable identity (A360-5 H-3)")
struct ScheduleTimeRowIdentityTests {
    @Test("each row gets a distinct id; rows ⇄ times round-trips")
    func roundTrip() {
        let times = [
            TimeOfDay(hour: 8, minute: 0),
            TimeOfDay(hour: 12, minute: 0),
            TimeOfDay(hour: 20, minute: 0)
        ]
        let rows = ScheduleTimeRow.rows(times)
        #expect(Set(rows.map(\.id)).count == 3, "every row has a distinct id")
        #expect(ScheduleTimeRow.times(rows) == times, "rows → times preserves order + values")
    }

    /// The core regression: remove the MIDDLE row, then edit the row that USED
    /// to be at the removed index. With offset identity the edit would mutate
    /// the now-shifted neighbour; with stable id it mutates exactly the row the
    /// user is pointing at.
    @Test("remove-then-edit-by-id mutates the intended row, not a shifted neighbour")
    func removeThenEditHitsRightRow() throws {
        var rows = ScheduleTimeRow.rows([
            TimeOfDay(hour: 8, minute: 0), // A
            TimeOfDay(hour: 12, minute: 0), // B (removed)
            TimeOfDay(hour: 20, minute: 0) // C
        ])
        let idA = rows[0].id
        let idC = rows[2].id

        // Remove the middle row B by id (mirrors the View's `removeAll { $0.id }`).
        let idB = rows[1].id
        rows.removeAll { $0.id == idB }
        #expect(rows.count == 2)

        // Now edit row C *by its stable id* — at offset 1 after the remove.
        // The fix's binding resolves by id, so this must change C, not A.
        if let idx = rows.firstIndex(where: { $0.id == idC }) {
            rows[idx].time = TimeOfDay(hour: 21, minute: 30)
        }

        let a = try #require(rows.first { $0.id == idA })
        let c = try #require(rows.first { $0.id == idC })
        #expect(a.time == TimeOfDay(hour: 8, minute: 0), "row A must be untouched by editing C")
        #expect(c.time == TimeOfDay(hour: 21, minute: 30), "edit landed on the intended row C")
    }
}
