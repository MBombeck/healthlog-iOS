#if !SWIFT_PACKAGE
    import Foundation
    @testable import HealthLog

    extension MedicationDetailStore {
        /// The dose set the drug-level curve is computed from, empty while the
        /// intake collection is still arriving. The same gate
        /// `recomputeDrugLevelSection()` applies before it draws.
        func pkDoseEvents() -> [Glp1PK.DoseEvent] {
            guard hasSettledIntakeCollection else { return [] }
            return settledDoseEvents()
        }
    }
#endif
