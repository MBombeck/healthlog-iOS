import SwiftUI

/// SUPP-EDIT (1.5.0, #131 P3) — the centred text link under the
/// composition: "Zusammensetzung bearbeiten", or "Zusammensetzung eintragen"
/// for a vitamin or a supplement that has none yet.
///
/// Shown only when the single read carried `ingredients` (server v1.43; the
/// catalogue arrived with it), with a server, and for a caller who may
/// change the medications at MANAGE (always on the own record). The label
/// photo inside the form is decided here too, from the server's capability.
struct MedicationCompositionEditLink: View {
    let medication: Medication
    let lines: [MedicationIngredient]
    let serverKnowsComposition: Bool
    let onSaved: () async -> Void

    @Environment(\.appContainer) private var container
    @Environment(AuthStore.self) private var authStore: AuthStore?

    var body: some View {
        if let container, container.syncModeStore.isPaired, serverKnowsComposition,
           MedicationCompositionAccess.canEdit(access),
           !lines.isEmpty || MedicationCompositionAccess.offersEmptyComposition(category: medication.category)
        {
            NavigationLink {
                MedicationCompositionEditor(
                    model: MedicationCompositionEditorModel(
                        medicationID: medication.id,
                        lines: lines,
                        repository: MedicationIngredientsRepository(api: container.api),
                        offReason: { [gate = container.moduleGate] in gate.offReason(.nutrients) }
                    ),
                    offersLabelPhoto: offersLabelPhoto(container),
                    onSaved: onSaved
                )
            } label: {
                Text(lines.isEmpty ? "medications.composition.edit.add" : "medications.composition.edit.link")
                    .font(.hlSubhead.weight(.semibold))
                    .foregroundStyle(HLText.secondary)
                    .frame(minHeight: 44)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("medications.composition.edit")
        }
    }

    private var access: AccountAccess {
        guard let authStore, case let .authenticated(user) = authStore.phase else { return .ownerOnly }
        return user.accountAccess
    }

    private func offersLabelPhoto(_ container: AppContainer) -> Bool {
        #if DEBUG
            if SuppEditFixtures.offersLabelPhoto { return true }
        #endif
        let gate = container.aiCapabilityGate
        return MedicationCompositionAccess.offersLabelPhoto(
            access: access,
            reportsCapabilities: gate.reportsCapabilities,
            capability: gate.state(.supplementLabel),
            usage: gate.account?.usage?.level
        )
    }
}
