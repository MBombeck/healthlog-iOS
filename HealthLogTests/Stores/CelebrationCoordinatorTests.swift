import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// v0.5.5.6 RECONCILE-CELEBRATE — `CelebrationCoordinator` contract.
///
/// Pins the publish + auto-dismiss + replace + manual-dismiss semantics
/// the SwiftUI root depends on. Mirrors the `UndoCoordinator` test
/// surface so a future engineer can navigate both stores by analogy.
@Suite("CelebrationCoordinator — publish + dismiss + replace")
@MainActor
struct CelebrationCoordinatorTests {
    private let now = Date(timeIntervalSince1970: 1_716_854_400)

    @Test("celebrate(_:) publishes record into `current`")
    func celebratePublishesRecord() {
        let coordinator = CelebrationCoordinator()
        #expect(coordinator.current == nil)
        let record = Self.makeRecord(id: "celebrate.1", metricType: "WEIGHT", value: 80, now: now)
        // TTL = 0 ensures no auto-dismiss races inside the test runtime.
        coordinator.celebrate(record, ttl: 0)
        #expect(coordinator.current?.id == "celebrate.1")
    }

    @Test("dismiss() clears the slot")
    func dismissClearsSlot() {
        let coordinator = CelebrationCoordinator()
        let record = Self.makeRecord(id: "celebrate.1", metricType: "WEIGHT", value: 80, now: now)
        coordinator.celebrate(record, ttl: 0)
        coordinator.dismiss()
        #expect(coordinator.current == nil)
    }

    @Test("celebrate(_:) replaces an existing slot atomically")
    func celebrateReplacesExisting() {
        let coordinator = CelebrationCoordinator()
        let first = Self.makeRecord(id: "celebrate.1", metricType: "WEIGHT", value: 80, now: now)
        let second = Self.makeRecord(id: "celebrate.2", metricType: "ACTIVITY_STEPS", value: 25000, now: now)
        coordinator.celebrate(first, ttl: 0)
        coordinator.celebrate(second, ttl: 0)
        #expect(coordinator.current?.id == "celebrate.2")
    }

    @Test("Auto-dismiss fires after the TTL elapses")
    func autoDismissAfterTTL() async throws {
        let coordinator = CelebrationCoordinator()
        let record = Self.makeRecord(id: "celebrate.1", metricType: "WEIGHT", value: 80, now: now)
        // 50 ms TTL keeps the test fast while still exercising the
        // sleep + wake + id-check path inside `scheduleDismissal`.
        coordinator.celebrate(record, ttl: 0.05)
        #expect(coordinator.current?.id == "celebrate.1")
        // Wait beyond TTL to let the scheduled task fire.
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(coordinator.current == nil)
    }

    @Test("Replace cancels the previous TTL countdown")
    func replaceCancelsPreviousCountdown() async throws {
        let coordinator = CelebrationCoordinator()
        let first = Self.makeRecord(id: "celebrate.1", metricType: "WEIGHT", value: 80, now: now)
        let second = Self.makeRecord(id: "celebrate.2", metricType: "ACTIVITY_STEPS", value: 25000, now: now)
        coordinator.celebrate(first, ttl: 0.05)
        coordinator.celebrate(second, ttl: 5)
        // After the first TTL elapses, the second record must still be
        // there — the replace cancelled the first countdown.
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(coordinator.current?.id == "celebrate.2")
    }

    @Test("dismiss() on empty slot is a no-op")
    func dismissNoOpOnEmpty() {
        let coordinator = CelebrationCoordinator()
        coordinator.dismiss()
        #expect(coordinator.current == nil)
    }

    // MARK: - Fixtures

    private static func makeRecord(
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
            bucket: .week,
            impressiveness: 0.9
        )
    }
}

// swiftlint:enable force_unwrapping
