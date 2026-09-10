import Foundation
@testable import HealthLog
import Testing

/// **Audit B-8 — a time-zone change re-arms the reminders.**
///
/// Reminders are projected with the zone that was current at registration time
/// (`NotificationService+Registration`, `MedicationsSchedulerModule`). Nothing
/// observed `NSSystemTimeZoneDidChange`, so after the device crossed into a new
/// zone every pending reminder kept firing at the OLD wall-clock time until some
/// other event (a foreground load, a CRUD edit) happened to reconcile.
///
/// The store now observes the notification and runs the SAME reconcile entry
/// point every other trigger uses. The observation is coalesced on the resolved
/// zone: the system posts the notification for events that leave the zone
/// unchanged, and a reconcile per post would be pure churn.
@MainActor
@Suite("MedicationsStore — B-8 system time-zone change reconcile")
struct MedicationsStoreTimeZoneChangeTests {
    /// Mutable zone the store's injected provider reads, so a change can be
    /// simulated without touching the process-wide default.
    @MainActor
    private final class ZoneBox {
        var zone: TimeZone
        init(_ zone: TimeZone) {
            self.zone = zone
        }
    }

    private func makeStore() throws -> MedicationsStore {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        return MedicationsStore(repo: MedicationsRepository(api: api, outbox: outbox))
    }

    @Test("a system time-zone change triggers exactly one reconcile")
    func zoneChangeReconcilesOnce() throws {
        let berlin = try #require(TimeZone(identifier: "Europe/Berlin"))
        let newYork = try #require(TimeZone(identifier: "America/New_York"))
        let box = ZoneBox(berlin)
        let center = NotificationCenter()
        let store = try makeStore()

        var reconciles = 0
        store.onMedicationsDidChange = { _ in reconciles += 1 }
        store.startObservingSystemTimeZoneChanges(center: center, currentTimeZone: { box.zone })
        #expect(reconciles == 0, "starting the observation must not reconcile on its own")

        box.zone = newYork
        center.post(name: .NSSystemTimeZoneDidChange, object: nil)
        #expect(reconciles == 1, "the zone change must re-arm the reminders exactly once")
    }

    @Test("a repeated notification for the same zone does not reconcile again")
    func repeatedNotificationIsCoalesced() throws {
        let berlin = try #require(TimeZone(identifier: "Europe/Berlin"))
        let newYork = try #require(TimeZone(identifier: "America/New_York"))
        let box = ZoneBox(berlin)
        let center = NotificationCenter()
        let store = try makeStore()

        var reconciles = 0
        store.onMedicationsDidChange = { _ in reconciles += 1 }
        store.startObservingSystemTimeZoneChanges(center: center, currentTimeZone: { box.zone })

        box.zone = newYork
        center.post(name: .NSSystemTimeZoneDidChange, object: nil)
        center.post(name: .NSSystemTimeZoneDidChange, object: nil)
        center.post(name: .NSSystemTimeZoneDidChange, object: nil)
        #expect(reconciles == 1, "three posts, one actual zone change → one reconcile")

        box.zone = berlin
        center.post(name: .NSSystemTimeZoneDidChange, object: nil)
        #expect(reconciles == 2, "travelling back is a change again")
    }

    @Test("removing the returned token stops the observation")
    func removingTheTokenStopsObserving() throws {
        let berlin = try #require(TimeZone(identifier: "Europe/Berlin"))
        let newYork = try #require(TimeZone(identifier: "America/New_York"))
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let box = ZoneBox(berlin)
        let center = NotificationCenter()
        let store = try makeStore()

        var reconciles = 0
        store.onMedicationsDidChange = { _ in reconciles += 1 }
        let token = store.startObservingSystemTimeZoneChanges(center: center, currentTimeZone: { box.zone })

        box.zone = newYork
        center.post(name: .NSSystemTimeZoneDidChange, object: nil)
        #expect(reconciles == 1)

        center.removeObserver(token)
        box.zone = tokyo
        center.post(name: .NSSystemTimeZoneDidChange, object: nil)
        #expect(reconciles == 1, "a removed observer must not reconcile any more")
    }
}
