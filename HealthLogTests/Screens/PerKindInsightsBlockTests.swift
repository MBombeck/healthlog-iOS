import Foundation
@testable import HealthLog
import Testing

/// Tests for v0.5.4 BF-6 Insights coverage block. The block must produce
/// a bucket for every `MetricKind` (except BP + Weight) where the
/// operator has ≥5 measurements in the last 30 days, ordered by sample
/// count descending.
@Suite("PerKindInsightsBlock coverage")
struct PerKindInsightsBlockTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14

    private func samples(kind: MetricKind, count: Int, daysAgoStart: Int, from base: Date) -> [HealthLog.Measurement] {
        (0 ..< count).map { i in
            HealthLog.Measurement(
                id: "m-\(kind.rawValue)-\(i)",
                kind: kind,
                recordedAt: base.addingTimeInterval(-Double(daysAgoStart + i) * 86400),
                value: .scalar(70 + Double(i))
            )
        }
    }

    @Test("qualifyingBuckets returns empty when no measurements")
    func emptyMeasurements() {
        let buckets = PerKindInsightsBlock.qualifyingBuckets(
            measurements: [],
            now: now
        )
        #expect(buckets.isEmpty)
    }

    @Test("qualifyingBuckets ignores kinds below minimum sample count")
    func ignoresLowSampleKinds() {
        let m = samples(kind: .pulse, count: 4, daysAgoStart: 1, from: now)
        let buckets = PerKindInsightsBlock.qualifyingBuckets(
            measurements: m,
            now: now
        )
        #expect(buckets.isEmpty)
    }

    @Test("qualifyingBuckets includes kind with 5+ samples in last 30 days")
    func includesQualifyingKind() {
        let m = samples(kind: .pulse, count: 6, daysAgoStart: 1, from: now)
        let buckets = PerKindInsightsBlock.qualifyingBuckets(
            measurements: m,
            now: now
        )
        #expect(buckets.count == 1)
        #expect(buckets.first?.kind == .pulse)
        #expect(buckets.first?.samples == 6)
    }

    @Test("qualifyingBuckets excludes BP and Weight even with ample data")
    func excludesBPandWeight() {
        let m = samples(kind: .pulse, count: 10, daysAgoStart: 1, from: now)
            + samples(kind: .weight, count: 10, daysAgoStart: 1, from: now)
            + (0 ..< 10).map { i in
                HealthLog.Measurement(
                    id: "bp-\(i)",
                    kind: .bloodPressure,
                    recordedAt: now.addingTimeInterval(-Double(i + 1) * 86400),
                    value: .bloodPressure(systolic: 128, diastolic: 82)
                )
            }
        let buckets = PerKindInsightsBlock.qualifyingBuckets(
            measurements: m,
            now: now
        )
        #expect(buckets.count == 1)
        #expect(buckets.first?.kind == .pulse)
    }

    @Test("qualifyingBuckets excludes samples older than 30 days")
    func excludesOldSamples() {
        // 4 recent samples + 4 old samples — total in window = 4, below threshold.
        let recent = samples(kind: .pulse, count: 4, daysAgoStart: 1, from: now)
        let old = samples(kind: .pulse, count: 4, daysAgoStart: 60, from: now)
        let buckets = PerKindInsightsBlock.qualifyingBuckets(
            measurements: recent + old,
            now: now
        )
        #expect(buckets.isEmpty)
    }

    @Test("qualifyingBuckets sorts by sample count descending")
    func sortsBySampleCount() {
        let m = samples(kind: .pulse, count: 5, daysAgoStart: 1, from: now)
            + samples(kind: .steps, count: 20, daysAgoStart: 1, from: now)
            + samples(kind: .hrv, count: 8, daysAgoStart: 1, from: now)
        let buckets = PerKindInsightsBlock.qualifyingBuckets(
            measurements: m,
            now: now
        )
        #expect(buckets.count == 3)
        #expect(buckets[0].kind == .steps)
        #expect(buckets[1].kind == .hrv)
        #expect(buckets[2].kind == .pulse)
    }

    @Test("qualifyingBuckets surfaces every MetricKind with data — broad coverage")
    func broadCoverage() {
        let kinds: [MetricKind] = [
            .pulse, .glucose, .hrv, .vo2Max, .sleep, .steps,
            .restingHeartRate, .spo2, .bodyTemperature, .bodyFat, .bmi,
            .walkingSpeed, .walkingAsymmetry, .walkingStepLength, .bodyWater, .boneMass
        ]
        var allMeasurements: [HealthLog.Measurement] = []
        for kind in kinds {
            allMeasurements += samples(kind: kind, count: 5, daysAgoStart: 1, from: now)
        }
        let buckets = PerKindInsightsBlock.qualifyingBuckets(
            measurements: allMeasurements,
            now: now
        )
        #expect(buckets.count == kinds.count, "Every populated kind (except BP+Weight) should surface")
        let bucketKinds = Set(buckets.map(\.kind))
        for kind in kinds {
            #expect(bucketKinds.contains(kind), "Kind \(kind.rawValue) missing from coverage")
        }
    }

    /// AUD-2 C2 — the view now memoizes `qualifyingBuckets` into `@State`
    /// instead of recomputing it inside `body`. The cached result must equal
    /// the naive (recomputed) result for the same inputs; since the cache
    /// simply stores the pure function's output, idempotency across repeated
    /// calls is the contract that guarantees the displayed data is unchanged.
    @Test("qualifyingBuckets is deterministic — memoized result equals naive recompute")
    func memoizedEqualsNaive() {
        let m = samples(kind: .pulse, count: 5, daysAgoStart: 1, from: now)
            + samples(kind: .steps, count: 20, daysAgoStart: 1, from: now)
            + samples(kind: .hrv, count: 8, daysAgoStart: 1, from: now)
            + samples(kind: .glucose, count: 7, daysAgoStart: 2, from: now)
        let first = PerKindInsightsBlock.qualifyingBuckets(measurements: m, now: now)
        let second = PerKindInsightsBlock.qualifyingBuckets(measurements: m, now: now)
        // Same inputs → identical buckets (kinds, order, and per-bucket stats).
        #expect(first == second)
        #expect(first.map(\.kind) == second.map(\.kind))
    }

    @Test("qualifyingBuckets honors additional exclusions identically across calls")
    func additionalExclusionsStable() {
        let m = samples(kind: .pulse, count: 6, daysAgoStart: 1, from: now)
            + samples(kind: .steps, count: 6, daysAgoStart: 1, from: now)
        let withExclusion = PerKindInsightsBlock.qualifyingBuckets(
            measurements: m, additionalExcluded: [.steps], now: now
        )
        #expect(withExclusion.map(\.kind) == [.pulse])
        // Re-running with the same exclusion set yields the identical slice
        // (the memoized path stores exactly this output).
        let again = PerKindInsightsBlock.qualifyingBuckets(
            measurements: m, additionalExcluded: [.steps], now: now
        )
        #expect(withExclusion == again)
    }

    @Test("PerKindInsightBucket computes correct direction arrow (rising)")
    func directionArrowRising() {
        let m: [HealthLog.Measurement] = (1 ... 5).map { i in
            HealthLog.Measurement(
                id: "p-\(i)",
                kind: .pulse,
                recordedAt: now.addingTimeInterval(-Double(6 - i) * 86400),
                value: .scalar(70)
            )
        } + [
            HealthLog.Measurement(
                id: "p-latest",
                kind: .pulse,
                recordedAt: now.addingTimeInterval(-3600),
                value: .scalar(110) // big jump up
            )
        ]
        let bucket = PerKindInsightBucket(kind: .pulse, rows: m)
        #expect(bucket.directionArrow == "↑")
    }

    @Test("PerKindInsightBucket leaves direction arrow nil for BP")
    func directionArrowNilForBP() {
        let m: [HealthLog.Measurement] = (0 ..< 6).map { i in
            HealthLog.Measurement(
                id: "bp-\(i)",
                kind: .bloodPressure,
                recordedAt: now.addingTimeInterval(-Double(i + 1) * 86400),
                value: .bloodPressure(systolic: 128, diastolic: 82)
            )
        }
        let bucket = PerKindInsightBucket(kind: .bloodPressure, rows: m)
        #expect(bucket.directionArrow == nil)
    }

    @Test("PerKindInsightBucket detects mixed sources")
    func mixedSources() {
        let m: [HealthLog.Measurement] = [
            HealthLog.Measurement(id: "p-1", kind: .pulse, recordedAt: now.addingTimeInterval(-3600), value: .scalar(72), source: .manual),
            HealthLog.Measurement(
                id: "p-2",
                kind: .pulse,
                recordedAt: now.addingTimeInterval(-7200),
                value: .scalar(74),
                source: .appleHealth
            ),
            HealthLog.Measurement(id: "p-3", kind: .pulse, recordedAt: now.addingTimeInterval(-10800), value: .scalar(76), source: .manual)
        ]
        let bucket = PerKindInsightBucket(kind: .pulse, rows: m)
        #expect(bucket.mixedSources == true)
        #expect(bucket.dominantSource == .manual)
    }
}
