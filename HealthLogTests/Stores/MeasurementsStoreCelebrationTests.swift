import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// v0.5.5.6 RECONCILE-CELEBRATE — `MeasurementsStore` personal-record
/// detection contract.
///
/// Pins the pure detection helper (`makeCelebrationEvent`) without
/// wiring a full network stub: the helper is deterministic + I/O-free
/// and represents the only branching logic the celebration trigger
/// adds to the commit path. End-to-end coverage of the commit → publish
/// chain is provided by the `CelebrationCoordinator` tests + the
/// hand-wired AppContainer composition.
@Suite("MeasurementsStore — celebration detection")
@MainActor
struct MeasurementsStoreCelebrationTests {
    private let now = Date(timeIntervalSince1970: 1_716_854_400)

    @Test("New scalar value strictly above prior leader fires a celebration")
    func newRecordFires() {
        let priorLeader = Self.makeEnriched(id: "p1", metricType: "ACTIVITY_STEPS", value: 18000, now: now)
        let measurement = Self.makeMeasurement(id: "local-1", kind: .steps, value: 22500, now: now)
        let event = MeasurementsStore.makeCelebrationEvent(
            for: measurement,
            value: 22500,
            snapshot: [priorLeader],
            now: now
        )
        #expect(event != nil)
        #expect(event?.base.metricType == "ACTIVITY_STEPS")
        #expect(event?.base.value == 22500)
        #expect(event?.previousValue == 18000)
        #expect(event?.kind == .steps)
    }

    @Test("Equal value to prior leader does not fire (no strict improvement)")
    func equalValueSilent() {
        let priorLeader = Self.makeEnriched(id: "p1", metricType: "WEIGHT", value: 80, now: now)
        let measurement = Self.makeMeasurement(id: "local-1", kind: .weight, value: 80, now: now)
        let event = MeasurementsStore.makeCelebrationEvent(
            for: measurement,
            value: 80,
            snapshot: [priorLeader],
            now: now
        )
        #expect(event == nil)
    }

    @Test("Value below prior leader does not fire")
    func belowLeaderSilent() {
        let priorLeader = Self.makeEnriched(id: "p1", metricType: "ACTIVITY_STEPS", value: 25000, now: now)
        let measurement = Self.makeMeasurement(id: "local-1", kind: .steps, value: 22500, now: now)
        let event = MeasurementsStore.makeCelebrationEvent(
            for: measurement,
            value: 22500,
            snapshot: [priorLeader],
            now: now
        )
        #expect(event == nil)
    }

    @Test("Empty snapshot is silent (first-ever commit must not celebrate)")
    func emptySnapshotSilent() {
        let measurement = Self.makeMeasurement(id: "local-1", kind: .weight, value: 80, now: now)
        let event = MeasurementsStore.makeCelebrationEvent(
            for: measurement,
            value: 80,
            snapshot: [],
            now: now
        )
        #expect(event == nil)
    }

    @Test("BP measurements skip celebration (no client-side BP records today)")
    func bloodPressureSkipped() {
        // Even with a prior leader for BP-metric, BP synthesis is silent.
        let priorLeader = Self.makeEnriched(id: "p1", metricType: "BLOOD_PRESSURE_SYS", value: 130, now: now)
        let measurement = HealthLog.Measurement(
            id: "local-bp",
            kind: .bloodPressure,
            recordedAt: now,
            value: .bloodPressure(systolic: 140, diastolic: 90)
        )
        // Direct call to makeCelebrationEvent uses scalar value extraction
        // by the production path; here we assert the kind-mapping returns
        // nil so the production guard short-circuits without even reading
        // the snapshot.
        #expect(MeasurementsStore.personalRecordMetricType(for: measurement.kind) == nil)
        // Sanity: even if the call site forwarded a synthetic scalar, the
        // metric-type guard inside makeCelebrationEvent rejects it.
        let event = MeasurementsStore.makeCelebrationEvent(
            for: measurement,
            value: 140,
            snapshot: [priorLeader],
            now: now
        )
        #expect(event == nil)
    }

    @Test("Unknown kind (no server bucket) is silent")
    func unknownKindSilent() {
        #expect(MeasurementsStore.personalRecordMetricType(for: .walkingSpeed) == nil)
        #expect(MeasurementsStore.personalRecordMetricType(for: .bmi) == nil)
    }

    @Test("personalRecordMetricType maps the supported kinds")
    func metricTypeMappingCovered() {
        #expect(MeasurementsStore.personalRecordMetricType(for: .weight) == "WEIGHT")
        #expect(MeasurementsStore.personalRecordMetricType(for: .steps) == "ACTIVITY_STEPS")
        #expect(MeasurementsStore.personalRecordMetricType(for: .pulse) == "PULSE")
        #expect(MeasurementsStore.personalRecordMetricType(for: .sleep) == "SLEEP_DURATION")
        #expect(MeasurementsStore.personalRecordMetricType(for: .glucose) == "BLOOD_GLUCOSE")
        #expect(MeasurementsStore.personalRecordMetricType(for: .restingHeartRate) == "RESTING_HEART_RATE")
        #expect(MeasurementsStore.personalRecordMetricType(for: .vo2Max) == "VO2_MAX")
        #expect(MeasurementsStore.personalRecordMetricType(for: .hrv) == "HEART_RATE_VARIABILITY")
    }

    @Test("Snapshot with multiple records picks the max value as leader")
    func leaderIsMax() {
        let lo = Self.makeEnriched(id: "p1", metricType: "ACTIVITY_STEPS", value: 12000, now: now)
        let hi = Self.makeEnriched(id: "p2", metricType: "ACTIVITY_STEPS", value: 22000, now: now)
        let measurement = Self.makeMeasurement(id: "local-1", kind: .steps, value: 21000, now: now)
        // 21k beats the 12k row but not the 22k row → no celebration.
        let event = MeasurementsStore.makeCelebrationEvent(
            for: measurement,
            value: 21000,
            snapshot: [lo, hi],
            now: now
        )
        #expect(event == nil)
        // Now 23k beats the 22k leader → fires.
        let firingMeasurement = Self.makeMeasurement(id: "local-2", kind: .steps, value: 23000, now: now)
        let firingEvent = MeasurementsStore.makeCelebrationEvent(
            for: firingMeasurement,
            value: 23000,
            snapshot: [lo, hi],
            now: now
        )
        #expect(firingEvent?.previousValue == 22000)
    }

    @Test("metricType match is case-insensitive against snapshot rows")
    func caseInsensitiveMetricTypeMatch() {
        // Server rows may arrive lowercase / mixed-case in some
        // sources; the detector uppercases both sides for the compare.
        let priorLeader = Self.makeEnriched(id: "p1", metricType: "activity_steps", value: 18000, now: now)
        let measurement = Self.makeMeasurement(id: "local-1", kind: .steps, value: 22500, now: now)
        let event = MeasurementsStore.makeCelebrationEvent(
            for: measurement,
            value: 22500,
            snapshot: [priorLeader],
            now: now
        )
        #expect(event != nil)
    }

    // MARK: - Fixtures

    private static func makeEnriched(
        id: String,
        metricType: String,
        value: Double,
        now: Date
    ) -> PersonalRecord {
        let dto = PersonalRecordDTO(
            id: id,
            userId: "u1",
            metricType: metricType,
            metricSlot: nil,
            direction: .max,
            value: value,
            unit: "",
            achievedAt: now,
            sourceMeasurementId: nil,
            source: "TEST",
            externalId: nil,
            createdAt: now
        )
        return PersonalRecord(
            id: dto.id,
            base: dto,
            kind: MetricTypeKindResolver.kind(forMetricType: metricType),
            sparklineValues: [],
            peakIndex: nil,
            previousValue: nil,
            bucket: .allTime,
            impressiveness: 0.8
        )
    }

    private static func makeMeasurement(
        id: String,
        kind: MetricKind,
        value: Double,
        now: Date
    ) -> HealthLog.Measurement {
        HealthLog.Measurement(
            id: id,
            kind: kind,
            recordedAt: now,
            value: .scalar(value)
        )
    }
}

// swiftlint:enable force_unwrapping
