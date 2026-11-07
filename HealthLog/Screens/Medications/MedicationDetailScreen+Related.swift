import SwiftUI

/// #141 (RELATED, 1.5.0) — the "Related" section of a medication reads
/// the single medication (`GET /api/medications/{id}`), whose `related` the
/// list rows do not carry. Only with a server: a standalone install has no
/// relations to show.
///
/// #131 (SUPP, 1.5.0) — the same read carries the composition
/// (`ingredients`), so it feeds ``MedicationCompositionModel`` too: one read,
/// and pull to refresh (`related.reload()`) renews both.
extension MedicationDetailScreen {
    func loadRelated() async {
        guard let container = appContainer, container.syncModeStore.isPaired else { return }
        let repo = container.medicationsRepo
        let id = store.medication.id
        let composition = composition
        await related.load {
            do {
                let medication = try await repo.medication(id: id)
                composition.apply(medication)
                return medication.related?.items
            } catch {
                composition.apply(error)
                throw error
            }
        }
    }
}
