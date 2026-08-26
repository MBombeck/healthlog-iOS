import Foundation

// Domain → wire CREATE mapping, split out of `MeasurementDTO.swift` under the
// PROJECT_GUIDE.md file-length discipline when Build 3 / item 3.3 added 23
// `ServerMeasurementType` cases. **Pure move** — same module, same access
// levels, same behaviour; only the file boundary changes.
//
// This is the manual-entry half of the contract: the exhaustive `(kind, value)`
// switch that decides which kinds can be WRITTEN by the client. Build 1 pruned
// the MeasureSheet picker down to the kinds that actually have an arm here, and
// Build 3's 21 read-only additions deliberately fall through to `default: []`.

public extension Measurement {
    // swiftlint:disable cyclomatic_complexity
    /// Konvertiert ein Domain-Measurement zu einem oder zwei Wire-DTOs.
    /// BP liefert ZWEI Records (sys + dia) — Server-Pattern. Exhaustive
    /// `(kind, value)` switch — every supported MetricKind has its own
    /// wire-row shape, so the case count tracks `MetricKind.allCases`.
    func toCreateDTOs() -> [MeasurementCreateDTO] {
        switch (kind, value) {
        case let (.weight, .scalar(v)):
            [.init(type: .weight, value: v, measuredAt: recordedAt, notes: note, source: source.wire, externalId: externalUUID)]
        case let (.bloodPressure, .bloodPressure(sys, dia)):
            [
                .init(
                    type: .bloodPressureSystolic,
                    value: sys,
                    measuredAt: recordedAt,
                    notes: note,
                    source: source.wire,
                    externalId: externalUUID
                ),
                .init(
                    type: .bloodPressureDiastolic,
                    value: dia,
                    measuredAt: recordedAt,
                    notes: nil,
                    source: source.wire,
                    externalId: externalUUID
                )
            ]
        case let (.glucose, .scalar(v)):
            // T-2: glucoseContext is sent on the wire as part of the create
            // body so the server can persist it on the row. Only meaningful
            // when set by the user via the entry-picker; otherwise nil and
            // the server stores no context.
            [.init(
                type: .bloodGlucose,
                value: v,
                measuredAt: recordedAt,
                notes: note,
                source: source.wire,
                glucoseContext: glucoseContext,
                externalId: externalUUID
            )]
        case let (.pulse, .scalar(v)):
            [.init(type: .pulse, value: v, measuredAt: recordedAt, notes: note, source: source.wire, externalId: externalUUID)]
        case let (.spo2, .scalar(v)):
            [.init(type: .oxygenSaturation, value: v, measuredAt: recordedAt, notes: note, source: source.wire, externalId: externalUUID)]
        case let (.bodyFat, .scalar(v)):
            [.init(type: .bodyFat, value: v, measuredAt: recordedAt, notes: note, source: source.wire, externalId: externalUUID)]
        case let (.bodyTemperature, .scalar(v)):
            [.init(type: .bodyTemperature, value: v, measuredAt: recordedAt, notes: note, source: source.wire, externalId: externalUUID)]
        case let (.bodyWater, .scalar(v)):
            [.init(type: .totalBodyWater, value: v, measuredAt: recordedAt, notes: note, source: source.wire, externalId: externalUUID)]
        case let (.boneMass, .scalar(v)):
            [.init(type: .boneMass, value: v, measuredAt: recordedAt, notes: note, source: source.wire, externalId: externalUUID)]
        case let (.restingHeartRate, .scalar(v)):
            [.init(
                type: .restingHeartRate,
                value: v,
                measuredAt: recordedAt,
                notes: note,
                source: source.wire,
                externalId: externalUUID
            )]
        case let (.hrv, .scalar(v)):
            [.init(
                type: .heartRateVariability,
                value: v,
                measuredAt: recordedAt,
                notes: note,
                source: source.wire,
                externalId: externalUUID
            )]
        case let (.vo2Max, .scalar(v)):
            [.init(type: .vo2Max, value: v, measuredAt: recordedAt, notes: note, source: source.wire, externalId: externalUUID)]
        case let (.respiratoryRate, .scalar(v)):
            // v1.25 (GH iOS #38) — respiratoryRate is first-class (manual picker +
            // HK observer path) but had NO create-DTO arm, so a manually-entered
            // breathing rate silently fell through to `default: []` and never
            // persisted. The server enum has carried `RESPIRATORY_RATE` (3–60
            // breaths/min, vitals) since v1.5.5, so this round-trips cleanly.
            [.init(
                type: .respiratoryRate,
                value: v,
                measuredAt: recordedAt,
                notes: note,
                source: source.wire,
                externalId: externalUUID
            )]
        case let (.painNRS, .scalar(v)):
            // v0158 — v1.25 manual clinical signal. The 0–10 NRS integer is
            // enforced client-side by the MeasureSheet picker; the server accepts
            // any 0–10 float (`PAIN_NRS`, LOINC 72514-3).
            [.init(type: .painNRS, value: v, measuredAt: recordedAt, notes: note, source: source.wire, externalId: externalUUID)]
        case let (.gripStrength, .scalar(v)):
            // v0158 — manual-only (HealthKit has no grip-strength quantity type).
            [.init(
                type: .gripStrength,
                value: v,
                measuredAt: recordedAt,
                notes: note,
                source: source.wire,
                externalId: externalUUID
            )]
        case let (.waistCircumference, .scalar(v)):
            // v0158 — manual-only for now. HK round-trip is blocked on a server
            // `apple-health-mapping.ts` waist entry (server coord); ship manual.
            [.init(
                type: .waistCircumference,
                value: v,
                measuredAt: recordedAt,
                notes: note,
                source: source.wire,
                externalId: externalUUID
            )]
        default:
            // walkingSpeed / walkingAsymmetry / walkingStepLength / bmi and
            // the W-D activity aggregates are HK-derived only — they have no
            // manual-entry surface. They reach the server over the HK observer
            // path via `HealthKitBatchEntryDTO` (raw `hkIdentifier`, server-
            // side mapping), not this manual-create DTO path. WalkingSpeed +
            // walkingStepLength are server-persisted since v1.6.0 (W-WALK) but
            // still flow exclusively through the batch path, so this manual
            // path correctly produces no wire rows for them.
            //
            // v0158 — `waistToHeight` also lands here: it is RENDER-ONLY on iOS
            // (decode + display), with no manual-entry surface, so it correctly
            // produces no wire row.
            []
        }
    }
    // swiftlint:enable cyclomatic_complexity
}
