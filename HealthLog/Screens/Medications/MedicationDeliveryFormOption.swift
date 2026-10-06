import SwiftUI

/// Picker-friendly enumeration of the server's `deliveryForm`
/// (`ORAL | INJECTION | OTHER`). The `.unspecified` case maps to `nil` on the
/// wire so a medication that never set a route stays unset.
enum MedicationDeliveryFormOption: String, CaseIterable, Identifiable {
    case unspecified
    case oral = "ORAL"
    case injection = "INJECTION"
    case other = "OTHER"

    var id: String {
        rawValue
    }

    /// `nil` for `.unspecified`; the raw server enum string otherwise.
    var wireValue: String? {
        switch self {
        case .unspecified: nil
        case .oral, .injection, .other: rawValue
        }
    }

    var labelKey: LocalizedStringKey {
        switch self {
        case .unspecified: "—"
        case .oral: "med.schedule.deliveryForm.oral"
        case .injection: "med.schedule.deliveryForm.injection"
        case .other: "med.schedule.deliveryForm.other"
        }
    }

    /// Decode from the wire string; `.unspecified` for nil / unknown.
    static func from(wire: String?) -> MedicationDeliveryFormOption {
        guard let wire, let opt = MedicationDeliveryFormOption(rawValue: wire) else {
            return .unspecified
        }
        return opt
    }
}
