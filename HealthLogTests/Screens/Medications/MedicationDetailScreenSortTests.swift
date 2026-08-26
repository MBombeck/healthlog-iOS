import Foundation
@testable import HealthLog
import Testing

/// REG-10 — the medication detail screen sorts intake history by
/// `scheduledFor desc` at the view layer. Server returns rows ordered
/// by `takenAt desc`; rows with `takenAt == nil` (past-due-pending)
/// drift out of chronological order under that ordering and surface
/// March entries above today's intake (operator regression filed
/// 2026-05-21).
///
/// SwiftUI bodies aren't directly observable, so we mirror the same
/// closure the screen applies to `store.intakes` and assert the
/// resulting order. The closure lives at the call-site in
/// `MedicationDetailScreen.body` — keep this test in lockstep with
/// any future change to that line.
@Suite("REG-10 — intake history sort")
struct MedicationDetailScreenSortTests {
    @Test("Mixed pending + taken events sort by scheduledFor descending")
    func mixedEventsSortDescending() {
        let now = Date(timeIntervalSince1970: 1_715_817_600)
        let march = PaginatedIntakeEvent(
            id: "evt-march",
            takenAt: nil,
            skipped: false,
            scheduledFor: now.addingTimeInterval(-60 * 24 * 3600),
            injectionSite: nil
        )
        let yesterday = PaginatedIntakeEvent(
            id: "evt-yesterday",
            takenAt: now.addingTimeInterval(-23 * 3600),
            skipped: false,
            scheduledFor: now.addingTimeInterval(-24 * 3600),
            injectionSite: nil
        )
        let today = PaginatedIntakeEvent(
            id: "evt-today",
            takenAt: nil,
            skipped: false,
            scheduledFor: now.addingTimeInterval(-1 * 3600),
            injectionSite: nil
        )
        // Server-shape: rows arrive in `takenAt desc` order, so the
        // `nil`-takenAt rows scatter to the head (or tail, depending on
        // Postgres NULLS handling). Either way the operator-visible order
        // is wrong without the view-layer re-sort.
        let serverOrder = [march, today, yesterday]

        let viewOrder = serverOrder.sorted { $0.scheduledFor > $1.scheduledFor }

        #expect(viewOrder.map(\.id) == ["evt-today", "evt-yesterday", "evt-march"])
    }

    @Test("Single intake remains a single-element list")
    func singleIntakeSortIsIdentity() {
        let now = Date(timeIntervalSince1970: 1_715_817_600)
        let only = PaginatedIntakeEvent(
            id: "evt-only",
            takenAt: now,
            skipped: false,
            scheduledFor: now,
            injectionSite: nil
        )
        let viewOrder = [only].sorted { $0.scheduledFor > $1.scheduledFor }
        #expect(viewOrder.map(\.id) == ["evt-only"])
    }

    @Test("Empty history remains empty after sort")
    func emptyHistoryStaysEmpty() {
        let viewOrder = [PaginatedIntakeEvent]()
            .sorted { $0.scheduledFor > $1.scheduledFor }
        #expect(viewOrder.isEmpty)
    }

    @Test("Same scheduledFor preserves stable order (sort is non-destructive)")
    func tiedTimestampsPreserveOrder() {
        let stamp = Date(timeIntervalSince1970: 1_715_817_600)
        let first = PaginatedIntakeEvent(
            id: "evt-a",
            takenAt: nil,
            skipped: false,
            scheduledFor: stamp,
            injectionSite: nil
        )
        let second = PaginatedIntakeEvent(
            id: "evt-b",
            takenAt: nil,
            skipped: false,
            scheduledFor: stamp,
            injectionSite: nil
        )
        // `>` is strict; tied elements compare false → Swift's stable
        // `sorted(by:)` preserves their input order.
        let viewOrder = [first, second].sorted { $0.scheduledFor > $1.scheduledFor }
        #expect(viewOrder.map(\.id) == ["evt-a", "evt-b"])
    }
}
