import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// W-HR-BUCKET-UPLOAD / GH #34 — the locked 10-minute-HR `stats:` externalId +
/// value/valueMin/valueMax contract.
@Suite("HealthKitHRBucketRow — locked externalId + value/min/max contract")
struct HealthKitHRBucketRowTests {
    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter.fractional.date(from: iso)!
    }

    @Test("externalId — UTC 10-minute bucket START, ms-zeroed, trailing Z")
    func externalIdLockedFormat() {
        let row = HealthKitHRBucketRow(
            bucketStartUTC: date("2026-07-18T14:30:00.000Z"),
            averageBpm: 72,
            minBpm: 60,
            maxBpm: 90
        )
        #expect(row.externalId == "stats:HKQuantityTypeIdentifierHeartRate:2026-07-18T14:30:00.000Z")
    }

    @Test("bucketKey floors an arbitrary in-bucket instant to the 10-minute UTC grid")
    func bucketKeyFloors() {
        // 14:37:10.523 → the 14:30 bucket (minutes floor to the nearest 10).
        let key = HealthKitHRBucketRow.bucketKey(for: date("2026-07-18T14:37:10.523Z"))
        #expect(key == "2026-07-18T14:30:00.000Z")
    }

    @Test("bucket minutes floor to {00,10,20,30,40,50}")
    func minutesFloorToTens() {
        // 09:09 → 09:00, 09:19 → 09:10, 09:59 → 09:50.
        #expect(HealthKitHRBucketRow.bucketKey(for: date("2026-07-18T09:09:59.000Z"))
            == "2026-07-18T09:00:00.000Z")
        #expect(HealthKitHRBucketRow.bucketKey(for: date("2026-07-18T09:19:00.000Z"))
            == "2026-07-18T09:10:00.000Z")
        #expect(HealthKitHRBucketRow.bucketKey(for: date("2026-07-18T09:59:59.999Z"))
            == "2026-07-18T09:50:00.000Z")
    }

    @Test("bucket key is UTC-stable regardless of the device local TZ")
    func bucketKeyUTCStable() {
        // 23:35Z is still the 23:30 UTC bucket even though it is the next day in
        // some local zones. The key must stay UTC.
        let row = HealthKitHRBucketRow(
            bucketStartUTC: HealthKitHRBucketRow.flooredToUTCTenMinutes(date("2026-07-18T23:35:00.000Z")),
            averageBpm: 60,
            minBpm: 55,
            maxBpm: 65
        )
        #expect(row.externalId == "stats:HKQuantityTypeIdentifierHeartRate:2026-07-18T23:30:00.000Z")
    }

    @Test("value = average; valueMin/valueMax = bucket spread; measuredAt = bucket END")
    func valueMinMaxAndMeasuredAt() {
        let start = date("2026-07-18T14:30:00.000Z")
        let row = HealthKitHRBucketRow(bucketStartUTC: start, averageBpm: 72, minBpm: 58, maxBpm: 101)
        #expect(row.averageBpm == 72)
        #expect(row.minBpm == 58)
        #expect(row.maxBpm == 101)
        // measuredAt anchor is start + 10 min.
        #expect(row.bucketEndUTC == date("2026-07-18T14:40:00.000Z"))
    }

    @Test("value contract — PULSE wire shape: identifier=heartRate, unit=count/min")
    func valueContract() {
        #expect(HealthKitHRBucketRow.hkIdentifier == "HKQuantityTypeIdentifierHeartRate")
        #expect(HealthKitHRBucketRow.wireUnit == "count/min")
        #expect(HealthKitHRBucketRow.bucketSeconds == 600)
    }

    @Test("re-posting the same bucket yields the SAME externalId (idempotent overwrite)")
    func idempotentSameBucket() {
        let bucket = HealthKitHRBucketRow.flooredToUTCTenMinutes(date("2026-07-18T14:32:00.000Z"))
        let first = HealthKitHRBucketRow(bucketStartUTC: bucket, averageBpm: 70, minBpm: 60, maxBpm: 80)
        // Same bucket, corrected values after a late Watch sync.
        let corrected = HealthKitHRBucketRow(bucketStartUTC: bucket, averageBpm: 74, minBpm: 61, maxBpm: 88)
        #expect(first.externalId == corrected.externalId)
        #expect(first.externalId == "stats:HKQuantityTypeIdentifierHeartRate:2026-07-18T14:30:00.000Z")
    }

    @Test("flooredToUTCTenMinutes is idempotent on an already-floored instant")
    func flooredIdempotent() {
        let floored = date("2026-07-18T14:30:00.000Z")
        #expect(HealthKitHRBucketRow.flooredToUTCTenMinutes(floored) == floored)
    }
}

// swiftlint:enable force_unwrapping
