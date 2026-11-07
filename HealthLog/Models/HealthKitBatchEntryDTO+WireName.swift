import Foundation

/// **REG (1.5, public #13) and POLISH-B B6 — the one table of HealthKit types
/// whose run-time identifier is not the name the server maps them under.**
///
/// The server keys `APPLE_HEALTH_TYPE_MAP` by the SDK constant's NAME and
/// looks a batch row up by exactly that string (v1.47.0); any other spelling
/// comes back as `unmappable_identifier`. State of Mind runs as
/// `HKDataTypeStateOfMind`, and the environmental audio exposure event kept
/// the string of its pre-iOS-14 name, `…AudioExposureEvent`.
///
/// Foundation-only and in `Models`, so the outbox replay (which also compiles
/// into the widget extension and the package) can translate rows that were
/// parked under the old name. `HealthKitServer144Types.wireNames` reads this
/// table; there is no second copy.
public extension HealthKitBatchEntryDTO {
    /// Run-time identifier → the server's name.
    static let serverWireNames: [String: String] = [
        "HKDataTypeStateOfMind": "HKDataTypeIdentifierStateOfMind",
        "HKCategoryTypeIdentifierAudioExposureEvent": "HKCategoryTypeIdentifierEnvironmentalAudioExposureEvent"
    ]

    /// The same row under the name the server maps; every other row is
    /// returned unchanged (same bytes on the wire).
    func withServerWireName() -> HealthKitBatchEntryDTO {
        guard let wire = Self.serverWireNames[hkIdentifier] else { return self }
        return HealthKitBatchEntryDTO(
            hkIdentifier: wire,
            value: value,
            valueMin: valueMin,
            valueMax: valueMax,
            unit: unit,
            startDate: startDate,
            endDate: endDate,
            sleepStage: sleepStage,
            categoryValue: categoryValue,
            externalId: externalId,
            externalSourceVersion: externalSourceVersion,
            deviceType: deviceType
        )
    }
}

public extension HealthKitBatchPayload {
    /// A persisted page with every row under the server's name. A page
    /// written before REG (1.4.1 and the 1.5 betas) carries the old name of
    /// the noise event; it would be refused again on every replay.
    func withServerWireNames() -> HealthKitBatchPayload {
        HealthKitBatchPayload(entries: entries.map { $0.withServerWireName() }, syncTrigger: syncTrigger)
    }
}
