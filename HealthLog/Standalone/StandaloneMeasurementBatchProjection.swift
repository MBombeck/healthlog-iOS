import Foundation

// v0.11 W4 — projects a local-canonical manual `LocalMeasurementSnapshot` into
// the `HealthKitBatchEntryDTO` shape `POST /api/measurements/batch` ingests.
//
// **Why a projection (not the HK write path):** the local mirror stores values
// in the server-canonical DB unit (the same `MetricKind.unit` the manual-entry
// UI captured). The batch route, however, speaks HealthKit's vocabulary —
// `hkIdentifier` + HK unit — and applies its own HK→DB conversion server-side
// (`mapAppleHealthEntry`). So this projection INVERTS that conversion: it emits
// the HK identifier + HK unit + the value re-expressed in HK units, so the
// server's `convertToDbUnit` lands back on exactly the DB value the user typed.
//
// **`source: MANUAL`:** the batch route's `batchSourceEnum` accepts
// `APPLE_HEALTH | MANUAL`. We tag these `MANUAL` so a hand-entered standalone
// row is not mis-attributed to HealthKit (the source is part of the dedup key,
// so a `MANUAL` adopt-on-pair row and a later `APPLE_HEALTH` HK sample sharing
// an externalId stay distinct rows).
//
// **Dedup key = `(userId, type, source, externalId)`.** The local `externalId`
// is the stable identity, so a re-run surfaces `duplicate` per entry — the
// idempotency the adopt-on-pair contract relies on.
//
// **Blood pressure** is the one fan-out: it projects to TWO entries (systolic +
// diastolic, distinct HK identifiers / server types) sharing the externalId,
// exactly like the HK write path + the server's BP-pair merge expect.
//
// Kinds the server's batch route does not ingest (e.g. `totalBodyWater`,
// `boneMass`, the HK-only walking/audio aggregates a user can't hand-enter)
// return `nil` and are skipped by the uploader with a logged warning — never
// fabricated.
public enum StandaloneMeasurementBatchProjection {
    /// Returns the batch entries for a local measurement snapshot. Most kinds
    /// produce one entry; blood pressure produces two (sys + dia). Returns `[]`
    /// when the kind has no server batch mapping.
    public static func entries(from snapshot: LocalMeasurementSnapshot) -> [HealthKitBatchEntryDTO] {
        guard let kind = MetricKind(rawValue: snapshot.kind) else { return [] }
        let at = snapshot.recordedAt

        switch kind {
        case .bloodPressure:
            guard let sys = snapshot.systolic, let dia = snapshot.diastolic else { return [] }
            // Both legs share the externalId; the server's
            // (type, source, externalId) key keeps them distinct rows and the
            // BP-pair merge re-joins them on read.
            return [
                makeEntry(
                    hkIdentifier: HKID.bloodPressureSystolic,
                    value: sys, unit: "mmHg", at: at, externalId: snapshot.externalId
                ),
                makeEntry(
                    hkIdentifier: HKID.bloodPressureDiastolic,
                    value: dia, unit: "mmHg", at: at, externalId: snapshot.externalId
                )
            ]

        default:
            guard let mapped = scalarMapping(for: kind) else { return [] }
            return [
                makeEntry(
                    hkIdentifier: mapped.hkIdentifier,
                    value: mapped.toHK(snapshot.value),
                    unit: mapped.hkUnit,
                    at: at,
                    externalId: snapshot.externalId
                )
            ]
        }
    }

    /// Single-entry convenience — returns the first projected entry (or `nil`),
    /// used by the uploader's `compactMap` for the common non-BP path. BP rows
    /// surface both legs through `entries(from:)`; callers that must preserve
    /// the diastolic leg use that array form.
    public static func entry(from snapshot: LocalMeasurementSnapshot) -> HealthKitBatchEntryDTO? {
        entries(from: snapshot).first
    }

    // MARK: - Scalar kind table

    private struct ScalarMapping {
        let hkIdentifier: String
        let hkUnit: String
        /// `true` for the percent kinds the server stores 0..100 but HK ships as
        /// a 0..1 fraction — the value is `÷100` before upload so the server's
        /// `convertToDbUnit` (`×100`) lands back on the DB value the user typed.
        let percentFraction: Bool

        func toHK(_ dbValue: Double) -> Double {
            percentFraction ? dbValue / 100.0 : dbValue
        }
    }

    /// Static DB→HK projection table (keyed by `MetricKind`). A dictionary
    /// rather than a `switch` so the kind set is data, not control-flow — the
    /// only branch left is "kind present or not" (`nil` → skipped). BP is NOT in
    /// here; it fans out to two legs in `entries(from:)`.
    private static let scalarTable: [MetricKind: ScalarMapping] = [
        .weight: .init(hkIdentifier: HKID.bodyMass, hkUnit: "kg", percentFraction: false),
        .pulse: .init(hkIdentifier: HKID.heartRate, hkUnit: "count/min", percentFraction: false),
        .restingHeartRate: .init(hkIdentifier: HKID.restingHeartRate, hkUnit: "count/min", percentFraction: false),
        .hrv: .init(hkIdentifier: HKID.heartRateVariabilitySDNN, hkUnit: "ms", percentFraction: false),
        .glucose: .init(hkIdentifier: HKID.bloodGlucose, hkUnit: "mg/dL", percentFraction: false),
        .bodyTemperature: .init(hkIdentifier: HKID.bodyTemperature, hkUnit: "degC", percentFraction: false),
        .bodyFat: .init(hkIdentifier: HKID.bodyFatPercentage, hkUnit: "%", percentFraction: true),
        .spo2: .init(hkIdentifier: HKID.oxygenSaturation, hkUnit: "fraction", percentFraction: true),
        .vo2Max: .init(hkIdentifier: HKID.vo2Max, hkUnit: "mL/(kg*min)", percentFraction: false),
        .walkingSpeed: .init(hkIdentifier: HKID.walkingSpeed, hkUnit: "m/s", percentFraction: false),
        .walkingStepLength: .init(hkIdentifier: HKID.walkingStepLength, hkUnit: "m", percentFraction: false),
        .walkingAsymmetry: .init(hkIdentifier: HKID.walkingAsymmetryPercentage, hkUnit: "%", percentFraction: true),
        .bmi: .init(hkIdentifier: HKID.bodyMassIndex, hkUnit: "count", percentFraction: false)
    ]

    private static func scalarMapping(for kind: MetricKind) -> ScalarMapping? {
        scalarTable[kind]
    }

    private static func makeEntry(
        hkIdentifier: String,
        value: Double,
        unit: String,
        at: Date,
        externalId: String
    ) -> HealthKitBatchEntryDTO {
        HealthKitBatchEntryDTO(
            hkIdentifier: hkIdentifier,
            value: value,
            unit: unit,
            startDate: at,
            endDate: at,
            externalId: externalId
        )
    }

    /// HealthKit identifier string constants — hardcoded (not `HKQuantityType-
    /// Identifier.*.rawValue`) so this projection stays platform-free and
    /// testable on a non-HealthKit host. The strings are the canonical Apple
    /// constants the server's `APPLE_HEALTH_TYPE_MAP` keys on.
    private enum HKID {
        static let bodyMass = "HKQuantityTypeIdentifierBodyMass"
        static let bodyFatPercentage = "HKQuantityTypeIdentifierBodyFatPercentage"
        static let bodyTemperature = "HKQuantityTypeIdentifierBodyTemperature"
        static let bloodPressureSystolic = "HKQuantityTypeIdentifierBloodPressureSystolic"
        static let bloodPressureDiastolic = "HKQuantityTypeIdentifierBloodPressureDiastolic"
        static let heartRate = "HKQuantityTypeIdentifierHeartRate"
        static let restingHeartRate = "HKQuantityTypeIdentifierRestingHeartRate"
        static let heartRateVariabilitySDNN = "HKQuantityTypeIdentifierHeartRateVariabilitySDNN"
        static let oxygenSaturation = "HKQuantityTypeIdentifierOxygenSaturation"
        static let bloodGlucose = "HKQuantityTypeIdentifierBloodGlucose"
        static let vo2Max = "HKQuantityTypeIdentifierVO2Max"
        static let walkingSpeed = "HKQuantityTypeIdentifierWalkingSpeed"
        static let walkingStepLength = "HKQuantityTypeIdentifierWalkingStepLength"
        static let walkingAsymmetryPercentage = "HKQuantityTypeIdentifierWalkingAsymmetryPercentage"
        static let bodyMassIndex = "HKQuantityTypeIdentifierBodyMassIndex"
    }
}
