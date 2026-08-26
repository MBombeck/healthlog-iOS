#if canImport(AlarmKit)
    import AlarmKit
    import Foundation

    /// **v0.9.0 W3 — AlarmKit metadata for the critical-med alarm.**
    ///
    /// Crosses the process boundary into the widget extension (it drives the
    /// breakthrough-alert presentation + any Live-Activity rendering of the
    /// alarm), so it is a small `Codable` value type. Carries just enough to
    /// reconstruct the dose context: which medication, its dose label, and
    /// the instant the dose was scheduled for.
    ///
    /// `AlarmMetadata` requires `Decodable & Encodable & Hashable & Sendable`
    /// (verified against the iOS 26.5 SDK `AlarmKit.swiftinterface`).
    @available(iOS 26.0, *)
    struct MedAlarmMetadata: AlarmMetadata {
        let medicationId: String
        let medicationName: String
        let dose: String

        init(medicationId: String, medicationName: String, dose: String) {
            self.medicationId = medicationId
            self.medicationName = medicationName
            self.dose = dose
        }
    }
#endif
