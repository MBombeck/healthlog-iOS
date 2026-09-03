import Foundation
@testable import HealthLog
import Testing

/// Build 273 (sync audit A17) — the two-tap confirm marker must be bound to
/// the SLOT, not only the medication. Armed for the 08:00 dose, a second tap
/// that arrives after the widget rolled over to the 20:00 dose must NOT commit.
@Suite("Widget pending-confirm marker is slot-bound (A17)")
struct WidgetPendingConfirmSlotTests {
    private func makeStore() -> WidgetPendingConfirmStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-\(UUID().uuidString).json")
        return WidgetPendingConfirmStore(url: url)
    }

    @Test("armed for one slot is not armed for another slot of the same medication")
    func armedIsSlotBound() throws {
        let store = makeStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let morning = Date(timeIntervalSince1970: 1_800_000_000 - 600)
        let evening = morning.addingTimeInterval(12 * 3600)
        try store.arm(medicationId: "med-1", scheduledFor: morning, now: now)
        #expect(store.armed(for: "med-1", scheduledFor: morning, now: now) == true)
        #expect(store.armed(for: "med-1", scheduledFor: evening, now: now) == false)
        #expect(store.armed(for: "med-2", scheduledFor: morning, now: now) == false)
        store.clear()
    }
}
