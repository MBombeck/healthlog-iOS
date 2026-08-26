import SwiftUI

/// **CU-24 (GH iOS #73)** — the honest empty state shared by both
/// medication-logging surfaces (`MedicationQuickIntakeSheet` and
/// `MedicationFreeIntakeSheet`).
///
/// The reporter hit two dead ends on an account with **no active medications**:
/// the free-log sheet rendered a bare "Keine aktiven Medikamente" line with a
/// disabled save button, and the quick-intake sheet claimed "Gerade ist nichts
/// fällig. Schau später wieder rein." — advice that can never come true, because
/// nothing ever becomes due until a medication exists.
///
/// The two server states are already distinguishable from the client with the
/// reads that exist today, so the empty state depends on **account state**, not
/// on which sheet the person happened to open:
///
/// - `GET /api/medications` empty (→ ``noMedications``): there is nothing to log
///   against until a medication is created. The primary action is the create
///   flow; there is no "check back later".
/// - list non-empty + `GET /api/medications/intake?scope=today` empty
///   (→ ``nothingDue``): a real, temporary state. Today's copy is correct here
///   and stays; logging manually against an active medication is the useful
///   secondary action.
///
/// ``loading`` exists so neither claim is made before the medication list has
/// hydrated — `medications == []` is ambiguous until
/// `MedicationsStore.hasLoadedMedications` flips.
enum MedicationLoggingEmptyState: String, Equatable, CaseIterable {
    /// Medication list not hydrated yet — claim nothing.
    case loading
    /// No active medication exists. Nothing will ever become due.
    case noMedications
    /// Active medications exist, today's intake set is (currently) empty.
    case nothingDue

    /// Pure resolution of the two reads into one verdict. `hasActiveMedications`
    /// is the `GET /api/medications` answer narrowed to `active` rows — an
    /// archived / paused medication cannot receive an intake, so it does not
    /// make the account loggable.
    static func resolve(hasLoadedMedications: Bool, hasActiveMedications: Bool) -> Self {
        guard hasLoadedMedications else { return .loading }
        return hasActiveMedications ? .nothingDue : .noMedications
    }

    /// The one action an empty state may offer as its primary CTA. Modelled as
    /// a value (not a closure) so "the create path really leads into the create
    /// flow" is pinned by a test instead of by reviewer vigilance — the view has
    /// exactly one place that maps it onto `AddMedicationSheet`.
    enum PrimaryAction: String, Equatable {
        case addMedication
    }

    /// Render contract for one empty state. Snapshot-locked (CU-24) so a copy or
    /// action regression on either dead end surfaces as a diff.
    struct Descriptor: Equatable {
        let icon: String
        let titleKey: String
        let messageKey: String
        let primaryAction: PrimaryAction?
        /// Whether "manuell nachtragen" is a sensible secondary action here. It
        /// is only sensible when an active medication exists to log against.
        let offersManualLog: Bool
    }

    /// `nil` for ``loading`` — a spinner is the honest render while the list is
    /// still in flight, not a copy block.
    func presentationDescriptor() -> Descriptor? {
        switch self {
        case .loading:
            nil
        case .noMedications:
            Descriptor(
                icon: "pills",
                titleKey: "No medications yet",
                messageKey: "meds.empty.noMeds.logging.message",
                primaryAction: .addMedication,
                offersManualLog: false
            )
        case .nothingDue:
            Descriptor(
                icon: "checkmark.seal",
                titleKey: "meds.quick.empty.title",
                messageKey: "meds.quick.empty.subtitle",
                primaryAction: nil,
                offersManualLog: true
            )
        }
    }
}

/// The one lockup both logging sheets render when there is nothing to act on.
///
/// Owns the create-flow presentation so the "Medikament anlegen" CTA lands in
/// the same `AddMedicationSheet` the Medikamente tab uses — no second create
/// path, and no dead end that only offers a close button.
struct MedicationLoggingEmptyStateView: View {
    let state: MedicationLoggingEmptyState
    /// Rendered only when the state offers it (`nothingDue`). `nil` hides it.
    var onLogManually: (() -> Void)?
    /// Rendered when the host has no other way out (the quick sheet's root).
    /// `nil` on pushed screens, where the navigation back-affordance already is
    /// the way out.
    var onClose: (() -> Void)?

    @Environment(MedicationsStore.self) private var store
    @State private var isPresentingAdd = false

    var body: some View {
        Group {
            if let descriptor = state.presentationDescriptor() {
                HLEmptyState(
                    icon: descriptor.icon,
                    title: LocalizedStringKey(descriptor.titleKey),
                    message: LocalizedStringKey(descriptor.messageKey)
                ) {
                    actions(for: descriptor)
                }
            } else {
                ProgressView()
            }
        }
        .containerCentered()
        .background(HLColor.background)
        // A failed cold-start load leaves `hasLoadedMedications` false, i.e. the
        // spinner above. Without this the honest "claim nothing" state would be
        // its own dead end (an endless spinner); the canonical banner names the
        // failure and offers the retry.
        .hlErrorBannerOverlay(error: store.error) {
            Task { await store.load(force: true) }
        }
        .sheet(isPresented: $isPresentingAdd) {
            AddMedicationSheet(
                onSaved: {
                    isPresentingAdd = false
                    // The create is optimistic in the store, but a forced load
                    // pulls the freshly materialised today-intakes with it, so
                    // the sheet behind repaints into its real next state.
                    Task { await store.load(force: true) }
                },
                onDismiss: { isPresentingAdd = false }
            )
        }
    }

    private func actions(for descriptor: MedicationLoggingEmptyState.Descriptor) -> some View {
        VStack(spacing: HLSpace.sm) {
            if descriptor.primaryAction == .addMedication {
                HLButton(
                    String(localized: "Add medication"),
                    icon: "plus",
                    variant: .restrained,
                    size: .regular
                ) {
                    isPresentingAdd = true
                }
                .accessibilityIdentifier("meds.empty.addMedication")
            }
            if descriptor.offersManualLog, let onLogManually {
                HLButton(
                    String(localized: "med.freelog.open"),
                    icon: "square.and.pencil",
                    variant: .restrained,
                    size: .regular
                ) {
                    onLogManually()
                }
                .accessibilityIdentifier("meds.quick.freelog")
            }
            if let onClose {
                HLButton(
                    String(localized: "meds.quick.empty.close"),
                    variant: .secondary,
                    size: .regular
                ) {
                    onClose()
                }
            }
        }
    }
}
