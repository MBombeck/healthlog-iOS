import Foundation
@testable import HealthLog
import Testing

/// #186 — a medication reminder tap lands on the due dose on the Meds list
/// (Take and Skip on the card), not on the info page; a reminder for one slot
/// marks every pending dose of that slot. The links that name a medication
/// itself (`healthlog://medications/<id>`, Spotlight, `/medications/<id>`)
/// keep opening its info page.
@Suite("Medication reminder lands on the due dose (#186)")
@MainActor
struct MedicationReminderLandingTests {
    private func url(_ string: String) throws -> URL {
        try #require(URL(string: string))
    }

    private static let morning = Date(timeIntervalSince1970: 1_779_692_400) // a slot
    private static let evening = morning.addingTimeInterval(12 * 3600)

    private func intake(_ med: String, at date: Date, _ status: IntakeStatus = .pending) -> MedicationIntake {
        MedicationIntake(id: "\(med)-\(Int(date.timeIntervalSince1970))", medicationId: med, scheduledAt: date, status: status)
    }

    // MARK: - Links

    @Test("healthlog://medications?highlight=<id> names the due dose; a tampered id opens the list")
    func customSchemeHighlight() throws {
        #expect(try DeepLinkRoute(url: url("healthlog://medications?highlight=med_1")) == .medicationDue(id: "med_1", slot: nil))
        #expect(try DeepLinkRoute(url: url("healthlog://medications?highlight=..%2Fetc")) == .medications)
        #expect(try DeepLinkRoute(url: url("healthlog://medications")) == .medications)
    }

    @Test("Update path: the links that name a medication still open its info page")
    func existingLinksUnchanged() throws {
        #expect(try DeepLinkRoute(url: url("healthlog://medications/med_1")) == .medication(id: "med_1"))
        #expect(DeepLinkRoute.fromPushPath("/medications/med_1") == .medication(id: "med_1"))
        #expect(DeepLinkRoute.fromPushPath("/medications") == .medications)
    }

    // MARK: - Router

    @Test("The route opens the Meds list root on iPhone tabs and the iPad sidebar alike, and parks the landing once")
    func routerParksLandingOnce() {
        let router = AppRouter()
        router.medsPath.append(MedicationDetailRoute(id: "old"))
        router.apply(.medicationDue(id: "med_1", slot: Self.morning), isAuthenticated: true)
        #expect(router.selectedTab == .meds)
        #expect(router.medsPath.isEmpty)
        let landing = router.consumeMedicationLanding()
        #expect(landing?.medicationId == "med_1")
        #expect(landing?.slot == Self.morning)
        #expect(router.consumeMedicationLanding() == nil)
    }

    @Test("A second tap on the same reminder is a new request")
    func secondTapIsNewRequest() {
        let router = AppRouter()
        router.apply(.medicationDue(id: "med_1", slot: nil), isAuthenticated: true)
        let first = router.pendingMedicationLanding
        router.apply(.medicationDue(id: "med_1", slot: nil), isAuthenticated: true)
        #expect(router.pendingMedicationLanding?.sequence != first?.sequence)
    }

    @Test("A tap before sign-in is parked and lands after it")
    func coldStart() {
        let router = AppRouter()
        router.apply(.medicationDue(id: "med_1", slot: Self.morning), isAuthenticated: false)
        #expect(router.pendingMedicationLanding == nil)
        router.consumePendingRoute()
        #expect(router.selectedTab == .meds)
        #expect(router.pendingMedicationLanding?.medicationId == "med_1")
    }

    @Test("The plain list route parks nothing")
    func plainListParksNothing() {
        let router = AppRouter()
        router.apply(.medications, isAuthenticated: true)
        #expect(router.selectedTab == .meds)
        #expect(router.pendingMedicationLanding == nil)
    }

    // MARK: - What is marked

    @Test("A reminder for one slot marks every pending dose of that slot, in list order")
    func bundleMarksTheSlot() {
        let intakes = [
            intake("a", at: Self.morning),
            intake("b", at: Self.morning.addingTimeInterval(30)),
            intake("c", at: Self.evening),
            intake("d", at: Self.morning, .taken)
        ]
        let marked = MedicationReminderLanding.markedIDs(
            medicationId: "b",
            slot: Self.morning,
            todayIntakes: intakes,
            visibleOrder: ["d", "c", "a", "b"],
            now: Self.morning.addingTimeInterval(60)
        )
        #expect(marked == ["a", "b"])
    }

    @Test("Without a slot the dose the card's Take would record is the slot")
    func noSlotUsesDispatchDose() {
        let intakes = [intake("a", at: Self.morning), intake("b", at: Self.morning), intake("c", at: Self.evening)]
        let marked = MedicationReminderLanding.markedIDs(
            medicationId: "a",
            slot: nil,
            todayIntakes: intakes,
            visibleOrder: ["a", "b", "c"],
            now: Self.morning.addingTimeInterval(600)
        )
        #expect(marked == ["a", "b"])
    }

    @Test("Before the intakes load, and for a hidden card, only what the list shows is marked")
    func onlyVisibleCards() {
        let none = MedicationReminderLanding.markedIDs(
            medicationId: "a", slot: Self.morning, todayIntakes: [], visibleOrder: ["a", "b"], now: Self.morning
        )
        #expect(none == ["a"])
        let hidden = MedicationReminderLanding.markedIDs(
            medicationId: "x", slot: Self.morning, todayIntakes: [intake("x", at: Self.morning)], visibleOrder: ["a"], now: Self.morning
        )
        #expect(hidden.isEmpty)
    }
}
