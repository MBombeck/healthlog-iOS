import SwiftUI

// #186 — a medication reminder tap lands on the Meds list at its dose, where
// the card offers Take and Skip. The router parks the request
// (`AppRouter.openMedicationsList(for:)`); the pieces here take it, scroll to
// the card and mark it for a moment (``MedicationReminderLanding``).

/// Takes the router's parked landing into the screen's state and lets the
/// mark go once the list has stood with it for ``MedicationReminderLanding/markDuration``.
/// The clock starts only once the medications are loaded, so a cold start
/// from the tap still shows the mark.
struct MedicationLandingConsumer: ViewModifier {
    @Environment(AppRouter.self) private var router
    @Environment(MedicationsStore.self) private var store
    @Binding var landing: MedicationReminderLanding?

    private struct Clock: Equatable {
        let sequence: Int?
        let isLoaded: Bool
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: router.pendingMedicationLanding, initial: true) { _, pending in
                guard pending != nil else { return }
                landing = router.consumeMedicationLanding()
            }
            .task(id: Clock(sequence: landing?.sequence, isLoaded: store.hasLoadedMedications)) {
                guard let sequence = landing?.sequence, store.hasLoadedMedications else { return }
                try? await Task.sleep(for: MedicationReminderLanding.markDuration)
                guard !Task.isCancelled, landing?.sequence == sequence else { return }
                landing = nil
            }
    }
}

/// Scrolls the card stack to the topmost marked card. Keyed by the landing's
/// sequence too, so a second tap on the same reminder scrolls again.
struct MedicationLandingScroll: ViewModifier {
    let cardID: String?
    let sequence: Int?

    private struct Target: Equatable {
        let cardID: String?
        let sequence: Int?
    }

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content
                .onChange(of: Target(cardID: cardID, sequence: sequence), initial: true) { _, target in
                    guard let cardID = target.cardID else { return }
                    withHLAnimation(.smooth) {
                        proxy.scrollTo(cardID, anchor: .center)
                    }
                }
        }
    }
}
