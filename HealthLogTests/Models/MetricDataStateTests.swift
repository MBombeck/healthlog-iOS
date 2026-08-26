import Foundation
import Testing

#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// Locks the `MetricDataState.derive` decision table — the four-way bucket
/// that replaces the 13 ad-hoc empty predicates catalogued in PA4. The
/// branch logic here is the single rule every tile + chart-detail section
/// re-roots onto, so the transitions are pinned with explicit fixtures.
@Suite("MetricDataState.derive transitions")
struct MetricDataStateTests {
    // MARK: - Fixtures

    private func makeWeight(value: Double, at date: Date, source: MeasurementSource = .manual) -> HealthLog.Measurement {
        HealthLog.Measurement(
            id: UUID().uuidString,
            kind: .weight,
            recordedAt: date,
            value: .scalar(value),
            source: source
        )
    }

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func daysAgo(_ days: Int) -> Date {
        now.addingTimeInterval(-Double(days) * 86400)
    }

    // MARK: - Decision-table tests

    @Test("noData when allSamples and inRange are both empty")
    func noDataWhenEmpty() {
        let state = MetricDataState.derive(allSamples: [], inRange: [], sourceFilterApplied: false)
        #expect(state == .empty(reason: .noData))
        #expect(!state.hasValue)
        #expect(state.latestMeasurement == nil)
        #expect(state.sampleCount == 0)
        #expect(!state.isPending)
    }

    @Test("outsideRange when allSamples populated but inRange empty (no filter)")
    func outsideRangeWhenInRangeEmpty() {
        let old = makeWeight(value: 72.0, at: daysAgo(120))
        let state = MetricDataState.derive(
            allSamples: [old],
            inRange: [],
            sourceFilterApplied: false
        )
        guard case let .empty(reason) = state, case let .outsideRange(latestAt) = reason else {
            Issue.record("Expected .empty(.outsideRange), got \(state)")
            return
        }
        #expect(latestAt == old.recordedAt)
    }

    @Test("sourceFiltered when filter applied and removes every otherwise-eligible row")
    func sourceFilteredWhenFilterRemovesAll() {
        let one = makeWeight(value: 71.0, at: daysAgo(5), source: .appleHealth)
        let state = MetricDataState.derive(
            allSamples: [one],
            inRange: [], // filter dropped it
            sourceFilterApplied: true
        )
        #expect(state == .empty(reason: .sourceFiltered))
    }

    @Test("ready picks the most-recent inRange row as `latest`")
    func readyPicksMostRecentLatest() {
        let older = makeWeight(value: 72.0, at: daysAgo(7))
        let newer = makeWeight(value: 71.0, at: daysAgo(2))
        // Pass the in-range slice in arbitrary order to confirm derive sorts.
        let state = MetricDataState.derive(
            allSamples: [older, newer],
            inRange: [older, newer],
            sourceFilterApplied: false
        )
        guard case let .ready(latest, samples) = state else {
            Issue.record("Expected .ready, got \(state)")
            return
        }
        #expect(latest.id == newer.id)
        #expect(samples.count == 2)
        #expect(state.hasValue)
        #expect(state.sampleCount == 2)
        #expect(state.latestMeasurement?.id == newer.id)
    }

    @Test("ready wins even when allSamples carries extra older rows outside range")
    func readyWithMixedInsideOutside() {
        let veryOld = makeWeight(value: 80.0, at: daysAgo(400))
        let recent = makeWeight(value: 72.0, at: daysAgo(3))
        let state = MetricDataState.derive(
            allSamples: [veryOld, recent],
            inRange: [recent],
            sourceFilterApplied: false
        )
        guard case let .ready(latest, samples) = state else {
            Issue.record("Expected .ready, got \(state)")
            return
        }
        #expect(latest.id == recent.id)
        #expect(samples.count == 1)
    }

    @Test("filtered+ready when filter is applied AND in-range rows survive")
    func filteredButReady() {
        let kept = makeWeight(value: 70.0, at: daysAgo(1), source: .manual)
        let dropped = makeWeight(value: 75.0, at: daysAgo(2), source: .appleHealth)
        let state = MetricDataState.derive(
            allSamples: [kept, dropped],
            inRange: [kept], // appleHealth filtered away
            sourceFilterApplied: true
        )
        guard case let .ready(latest, samples) = state else {
            Issue.record("Expected .ready, got \(state)")
            return
        }
        #expect(latest.id == kept.id)
        #expect(samples.count == 1)
    }

    // MARK: - Convenience derivations

    @Test("isPending true only for .unknown / .loading")
    func isPendingShape() {
        #expect(MetricDataState.unknown.isPending)
        #expect(MetricDataState.loading.isPending)
        #expect(!MetricDataState.empty(reason: .noData).isPending)
        let sample = HealthLog.Measurement(
            id: "x",
            kind: .weight,
            recordedAt: now,
            value: .scalar(70)
        )
        #expect(!MetricDataState.ready(latest: sample, samples: [sample]).isPending)
    }

    @Test("latestMeasurement nil for empty.outsideRange even though a latestAt exists in the reason")
    func latestMeasurementHidesOutsideRange() {
        // Important contract: tiles shouldn't render the stale value as if it
        // were current. The reason carries the timestamp for "letzte Messung
        // vor X Tagen" copy, but `latestMeasurement` stays nil.
        let state = MetricDataState.empty(reason: .outsideRange(latestAt: daysAgo(120)))
        #expect(state.latestMeasurement == nil)
    }
}
