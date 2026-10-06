import Foundation

/// Server-authoritative supply summary (`MedicationSupplySummary`, v1.19.0):
/// pooled units / doses over the available (ACTIVE / IN_USE) containers, plus
/// the units still sitting in EXPIRED containers. Every value is the server's.
public struct MedicationSupplySummary: Codable, Sendable, Hashable {
    public let unitsRemaining: Double
    public let unitsTotal: Double
    public let dosesRemaining: Double
    public let dosesTotal: Double
    public let expiredUnits: Double

    public init(
        unitsRemaining: Double,
        unitsTotal: Double,
        dosesRemaining: Double,
        dosesTotal: Double,
        expiredUnits: Double
    ) {
        self.unitsRemaining = unitsRemaining
        self.unitsTotal = unitsTotal
        self.dosesRemaining = dosesRemaining
        self.dosesTotal = dosesTotal
        self.expiredUnits = expiredUnits
    }
}
