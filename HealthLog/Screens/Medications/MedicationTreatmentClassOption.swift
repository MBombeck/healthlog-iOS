import Foundation

/// Picker-friendly enumeration of `MedicationTreatmentClass` server values.
enum MedicationTreatmentClassOption: String, CaseIterable, Identifiable {
    case generic = "GENERIC"
    case glp1 = "GLP1"

    var id: String {
        rawValue
    }

    var wireValue: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .generic: String(localized: "med.treatmentClass.generic")
        case .glp1: "GLP-1" // drug-class name, identical in every locale
        }
    }
}
