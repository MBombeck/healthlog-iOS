import Foundation

/// #186 — where a medication reminder tap lands.
///
/// The info page of a medication has no Take or Skip, so a reminder opens the
/// Meds list, where each card offers both, scrolled to the dose and with it
/// marked for a moment (the web's `/medications?highlight=<id>`). When one
/// reminder stands for several doses (one slot, several medications), every
/// pending dose of that slot is marked, the first in list order is scrolled to.
extension AppRouter {
    /// `.medications` and `.medicationDue` both open the list root; only the
    /// latter parks a landing for it.
    ///
    /// **D3 #12** — a hidden medication has no card on the list, so its
    /// reminder opened onto nothing and its dose could not be taken there. It
    /// opens the medication's page instead, which has Take, Skip and Snooze.
    func openMedicationsList(for route: DeepLinkRoute) {
        selectedTab = .meds
        medsPath = .init()
        if case let .medicationDue(id, _) = route, isHiddenFromMedicationsList?(id) == true {
            medsPath.append(MedicationDetailRoute(id: id))
            return
        }
        if case let .medicationDue(id, slot) = route {
            pendingMedicationLanding = MedicationReminderLanding(
                medicationId: id,
                slot: slot,
                sequence: (pendingMedicationLanding?.sequence ?? 0) &+ 1
            )
        }
    }

    /// The parked landing, once. A second call returns `nil` until the next tap.
    func consumeMedicationLanding() -> MedicationReminderLanding? {
        defer { pendingMedicationLanding = nil }
        return pendingMedicationLanding
    }
}

/// One reminder tap's request to the Meds list. `sequence` makes two taps on
/// the same dose two requests.
struct MedicationReminderLanding: Equatable, Sendable {
    let medicationId: String
    /// The reminder's `scheduledFor`; `nil` when the link names no slot.
    let slot: Date?
    let sequence: Int

    /// Two slots closer than this are one slot: the server stamps minutes, a
    /// local banner the second it fired.
    nonisolated static let slotTolerance: TimeInterval = 90

    /// How long the mark stays on the cards once the list has them.
    nonisolated static let markDuration: Duration = .seconds(4)

    /// The medications to mark: the reminder's own one, and every other one
    /// with a pending dose in the same slot. Without a slot from the link the
    /// slot is the one the card's Take would record for the reminder's
    /// medication. Order: the list's own (`visibleOrder`), so the first entry
    /// is the topmost card, the one to scroll to.
    nonisolated static func markedIDs(
        medicationId: String,
        slot: Date?,
        todayIntakes: [MedicationIntake],
        visibleOrder: [String],
        now: Date
    ) -> [String] {
        let anchor = slot ?? ActiveMedicationsSection.resolveDispatchDose(
            medicationId: medicationId,
            todayIntakes: todayIntakes,
            now: now
        )?.scheduledAt
        var marked: Set<String> = [medicationId]
        if let anchor {
            for intake in todayIntakes where intake.status == .pending
                && abs(intake.scheduledAt.timeIntervalSince(anchor)) <= slotTolerance
            {
                marked.insert(intake.medicationId)
            }
        }
        return visibleOrder.filter { marked.contains($0) }
    }
}
