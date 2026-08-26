import Foundation
import Testing

#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// #33 — locks the client-side defensive guard that stops a malformed
/// 0-systolic / 0-diastolic blood-pressure row from ever surfacing as the
/// "latest / last measurement" value on the dashboard tile, the chart-detail
/// HeroStrip, and the AI/Spotlight summaries.
///
/// The rule lives in one place — ``Measurement/isDisplayableLatest`` (backed by
/// ``MeasurementValue/isDisplayableBloodPressure``) — and is applied wherever a
/// single latest reading is selected. `MetricDataState.derive` is the shared
/// selector the dashboard tile roots onto, so these tests pin both the property
/// itself and the derive-level behaviour the operator sees.
@Suite("Blood-pressure displayable-latest guard (#33)")
struct BloodPressureDisplayableLatestTests {
    // MARK: - Fixtures

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func daysAgo(_ days: Int) -> Date {
        now.addingTimeInterval(-Double(days) * 86400)
    }

    private func bp(
        systolic: Double,
        diastolic: Double,
        at date: Date
    ) -> HealthLog.Measurement {
        HealthLog.Measurement(
            id: UUID().uuidString,
            kind: .bloodPressure,
            recordedAt: date,
            value: .bloodPressure(systolic: systolic, diastolic: diastolic)
        )
    }

    private func weight(_ value: Double, at date: Date) -> HealthLog.Measurement {
        HealthLog.Measurement(id: UUID().uuidString, kind: .weight, recordedAt: date, value: .scalar(value))
    }

    // MARK: - Property: isDisplayableBloodPressure / isDisplayableLatest

    @Test("a real BP pair (both components > 0) is displayable")
    func validPairDisplayable() {
        let reading = bp(systolic: 116, diastolic: 74, at: now)
        #expect(reading.value.isDisplayableBloodPressure)
        #expect(reading.isDisplayableLatest)
    }

    @Test("a 0-systolic BP row is NOT displayable")
    func zeroSystolicRejected() {
        let reading = bp(systolic: 0, diastolic: 77, at: now)
        #expect(!reading.value.isDisplayableBloodPressure)
        #expect(!reading.isDisplayableLatest)
    }

    @Test("a 0-diastolic BP row is NOT displayable")
    func zeroDiastolicRejected() {
        let reading = bp(systolic: 124, diastolic: 0, at: now)
        #expect(!reading.value.isDisplayableBloodPressure)
        #expect(!reading.isDisplayableLatest)
    }

    @Test("the rule only constrains BP — a scalar value is always displayable, even 0")
    func nonBloodPressureAlwaysDisplayable() {
        #expect(weight(72, at: now).isDisplayableLatest)
        // A 0 scalar is a different concern (not BP); the guard must not touch it.
        #expect(weight(0, at: now).isDisplayableLatest)
        #expect(MeasurementValue.scalar(0).isDisplayableBloodPressure)
    }

    // MARK: - derive: shared latest selection (dashboard tile + friends)

    @Test("a leading 0-systolic row is skipped — the prior VALID reading wins latest")
    func leadingZeroSystolicPicksPriorValid() {
        let valid = bp(systolic: 116, diastolic: 74, at: daysAgo(2))
        // The malformed row is the newest by timestamp — the naive max() would pick it.
        let malformed = bp(systolic: 0, diastolic: 77, at: daysAgo(1))
        let series = [valid, malformed]
        let state = MetricDataState.derive(
            allSamples: series,
            inRange: series,
            sourceFilterApplied: false
        )
        guard case let .ready(latest, samples) = state else {
            Issue.record("Expected .ready, got \(state)")
            return
        }
        #expect(latest.id == valid.id)
        if case let .bloodPressure(s, d) = latest.value {
            #expect(s == 116)
            #expect(d == 74)
        } else {
            Issue.record("Expected a blood-pressure value")
        }
        // `samples` keeps the full in-range set (the sparkline projection drops
        // the systolic-0 artefact separately).
        #expect(samples.count == 2)
    }

    @Test("a leading 0-diastolic row is skipped just like 0-systolic")
    func leadingZeroDiastolicPicksPriorValid() {
        let valid = bp(systolic: 118, diastolic: 76, at: daysAgo(3))
        let malformed = bp(systolic: 124, diastolic: 0, at: daysAgo(1))
        let series = [valid, malformed]
        let state = MetricDataState.derive(
            allSamples: series,
            inRange: series,
            sourceFilterApplied: false
        )
        #expect(state.latestMeasurement?.id == valid.id)
    }

    @Test("an all-invalid BP series yields the honest no-data state, never a 0 value")
    func allInvalidYieldsNoData() {
        let series = [
            bp(systolic: 0, diastolic: 77, at: daysAgo(2)),
            bp(systolic: 122, diastolic: 0, at: daysAgo(1))
        ]
        let state = MetricDataState.derive(
            allSamples: series,
            inRange: series,
            sourceFilterApplied: false
        )
        #expect(state == .empty(reason: .noData))
        #expect(state.latestMeasurement == nil)
    }

    @Test("all in-range invalid but a valid out-of-range reading exists → outsideRange with its timestamp")
    func inRangeInvalidFallsBackToValidOutsideRange() {
        let validOld = bp(systolic: 120, diastolic: 78, at: daysAgo(120))
        let malformedRecent = bp(systolic: 0, diastolic: 80, at: daysAgo(1))
        let state = MetricDataState.derive(
            allSamples: [validOld, malformedRecent],
            inRange: [malformedRecent],
            sourceFilterApplied: false
        )
        guard case let .empty(reason) = state, case let .outsideRange(latestAt) = reason else {
            Issue.record("Expected .empty(.outsideRange), got \(state)")
            return
        }
        // The timestamp must be the VALID reading's, not the malformed recent one.
        #expect(latestAt == validOld.recordedAt)
    }

    @Test("a fully valid BP series is unaffected — newest valid reading wins")
    func validSeriesUnaffected() {
        let older = bp(systolic: 118, diastolic: 76, at: daysAgo(5))
        let newest = bp(systolic: 121, diastolic: 79, at: daysAgo(1))
        let state = MetricDataState.derive(
            allSamples: [older, newest],
            inRange: [older, newest],
            sourceFilterApplied: false
        )
        guard case let .ready(latest, samples) = state else {
            Issue.record("Expected .ready, got \(state)")
            return
        }
        #expect(latest.id == newest.id)
        #expect(samples.count == 2)
    }

    // MARK: - Dashboard cold-launch snapshot guard

    @Test("a 0/77 server snapshot is NOT a displayable BP snapshot")
    func malformedSnapshotNotDisplayable() {
        let metric = DashboardMetric(
            id: "bp",
            kind: .bloodPressure,
            title: "Blood pressure",
            latestValue: 0,
            secondaryValue: 77,
            unit: "mmHg",
            trend: .unknown,
            sparkline: [],
            updatedAt: nil
        )
        #expect(!metric.hasDisplayableBloodPressureSnapshot)
    }

    @Test("a real server snapshot IS a displayable BP snapshot")
    func validSnapshotDisplayable() {
        let metric = DashboardMetric(
            id: "bp",
            kind: .bloodPressure,
            title: "Blood pressure",
            latestValue: 116,
            secondaryValue: 74,
            unit: "mmHg",
            trend: .unknown,
            sparkline: [],
            updatedAt: nil
        )
        #expect(metric.hasDisplayableBloodPressureSnapshot)
    }
}
