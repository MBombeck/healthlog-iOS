import SwiftUI

/// **Reminder settings in words** on the medication detail page (server
/// 1.49.0 UX point 6).
///
/// One or two plain sentences on when the reminders for this medication come,
/// read from its schedule and its reminder phases
/// (``MedicationReminderWords``), and "Adjust" for the phases
/// (``MedicationReminderPhasesSheet``). A medication whose doses are recorded
/// automatically says that no reminders are sent and offers no phases. As
/// needed, kept as a record, paused or ended: the section is absent.
///
/// Self-contained: it reads the API client from the app container and the
/// caller's rights from the auth store. "Adjust" needs the right to change the
/// medication (always on the own record, on a shared one only with a write
/// grant for medications).
struct MedicationReminderSettingsSection: View {
    let medication: Medication
    /// Tests and previews pass their own; the app builds one from the container.
    private let repository: (any MedicationPhaseConfigProviding)?

    @Environment(\.appContainer) private var container
    @Environment(AuthStore.self) private var authStore: AuthStore?
    @State private var model: MedicationPhaseConfigModel?
    @State private var isEditing = false

    /// The server's current dose (`complianceDisplay.currentDose`), `nil`
    /// before the compliance read or when there is none.
    let currentDose: ComplianceCurrentDose?
    let timeZone: TimeZone

    init(
        medication: Medication,
        currentDose: ComplianceCurrentDose?,
        timeZone: TimeZone = .current,
        repository: (any MedicationPhaseConfigProviding)? = nil
    ) {
        self.medication = medication
        self.currentDose = currentDose
        self.timeZone = timeZone
        self.repository = repository
    }

    var body: some View {
        if let summary = MedicationReminderWords.summary(for: medication, currentDose: currentDose) {
            card(summary)
                .task(id: medication.id) {
                    guard summary.offersPhaseConfig else { return }
                    await loadPhases()
                }
                .sheet(isPresented: $isEditing) {
                    if let model {
                        MedicationReminderPhasesSheet(model: model)
                    }
                }
        }
    }

    private func card(_ summary: MedicationReminderWords.Summary) -> some View {
        HLCard("med.reminders.title") {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                Text(verbatim: MedicationReminderWords.text(summary, timeZone: timeZone))
                    .hlText(.prose)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("med.reminders.words")
                if summary.offersPhaseConfig, canAdjust, let model {
                    HLButton("med.reminders.adjust", variant: .secondary) {
                        model.beginEditing()
                        isEditing = true
                    }
                    .accessibilityIdentifier("med.reminders.adjust")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("med.reminders.section")
    }

    private func loadPhases() async {
        if model?.medicationID != medication.id {
            let source: (any MedicationPhaseConfigProviding)? = if let repository {
                repository
            } else {
                container.map { MedicationPhaseConfigRepository(api: $0.api) }
            }
            guard let source else { return }
            model = MedicationPhaseConfigModel(medicationID: medication.id, repository: source)
        }
        if let model, model.state == .idle || model.state == .failed {
            await model.load()
        }
    }

    /// The record in use lets the caller change medications (a signed-out or
    /// unknown phase reads as the own record; the server refuses otherwise).
    private var canAdjust: Bool {
        guard let authStore, case let .authenticated(user) = authStore.phase else { return true }
        return user.accountAccess.canManageMedications
    }
}
